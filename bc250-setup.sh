#!/usr/bin/bash
# bc250-setup : installe Bazzite Deck + amdgpu 40 CU sur une AMD BC-250.
#
#   curl -fsSL https://raw.githubusercontent.com/PicSte/bazzite-40CU-unlock/HEAD/bc250-setup.sh -o /tmp/bc250-setup.sh
#   sudo bash /tmp/bc250-setup.sh
#
# Bascule le système sur l'image ghcr.io/picste/bazzite-deck-bc250, ajoute
# l'argument noyau amdgpu.bc250_cc_write_mode=3 et redémarre. Au démarrage
# suivant, un service vérifie le résultat et active tout seul la
# vérification de signature de l'image dès qu'elle est disponible.
# « bc250-setup help » pour les autres commandes.
set -euo pipefail

REPO="PicSte/bazzite-40CU-unlock"
IMAGE="ghcr.io/picste/bazzite-deck-bc250"
TAG="latest"
OFFICIAL_REF="ostree-image-signed:docker://ghcr.io/ublue-os/bazzite-deck:stable"
KARG_KEY="amdgpu.bc250_cc_write_mode"
KARG_VALUE=3
BC250_DEVICE=0x13fe

SELF=/usr/local/bin/bc250-setup
CONF=/etc/bc250-setup.conf
STATE=/var/lib/bc250-setup
UNIT_DIR=/etc/systemd/system
RAW_URL="https://raw.githubusercontent.com/$REPO/HEAD/bc250-setup.sh"

ORIG_ARGS=("$@")
ASSUME_YES=0 NO_REBOOT=0 ENABLE_40CU=1 STAGED=0 REMOTE_TRIES=1
REMOTE_JSON="" STATUS_JSON=""

# --- Affichage ----------------------------------------------------------------
if [[ -t 1 ]]; then
    B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'
else
    B="" G="" Y="" R="" N=""
fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sERREUR :%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

has_tty() { { : </dev/tty; } 2>/dev/null; }

# ask "question" [O|N] : O = oui par défaut
ask() {
    local def="${2:-O}" ans=""
    (( ASSUME_YES )) && return 0
    has_tty || { [[ $def == O ]]; return; }
    if [[ $def == O ]]; then
        read -r -p "$1 [O/n] " ans </dev/tty || true
    else
        read -r -p "$1 [o/N] " ans </dev/tty || true
    fi
    [[ ${ans:-$def} =~ ^[oOyY] ]]
}

usage() {
    cat <<EOF
bc250-setup — Bazzite Deck + déverrouillage 40 CU pour AMD BC-250

Usage : sudo bc250-setup [commande] [options]

Commandes :
  install        (par défaut) bascule sur l'image patchée, active les 40 CU,
                 redémarre ; la suite se fait toute seule au démarrage
  status         état du système, du module amdgpu et des CU actifs
  enable-40cu    ajoute l'argument noyau $KARG_KEY=$KARG_VALUE
  disable-40cu   retire cet argument (retour à 24 CU, module patché conservé)
  uninstall      revient à l'image Bazzite d'origine
  signing-key    (sans sudo) crée la clé de signature pour GitHub Actions

Options :
  -y, --yes      ne pose aucune question (redémarre après 15 s)
  --no-reboot    ne redémarre pas
  --no-40cu      installe l'image sans activer les 40 CU
  --image REF    image à utiliser (défaut : $IMAGE)
  --tag TAG      tag à suivre (défaut : $TAG)
EOF
}

# --- Configuration persistante ------------------------------------------------
load_conf() {
    local v
    [[ -r $CONF ]] || return 0
    v="$(sed -n 's/^IMAGE=//p' "$CONF" | tail -1)"; [[ -z $v ]] || IMAGE="$v"
    v="$(sed -n 's/^TAG=//p' "$CONF" | tail -1)";   [[ -z $v ]] || TAG="$v"
}

need_root() {
    (( EUID == 0 )) && return 0
    local src="${BASH_SOURCE[0]:-}"
    [[ -f $src ]] && exec sudo bash "$src" "${ORIG_ARGS[@]}"
    die "lance ce script avec sudo"
}

preflight() {
    local c
    [[ -e /run/ostree-booted ]] || die "ce système n'est pas basé sur OSTree (Bazzite attendu)"
    for c in rpm-ostree skopeo jq systemctl curl; do
        command -v "$c" >/dev/null || die "commande manquante : $c"
    done
    grep -qi bazzite /etc/os-release || warn "ce système ne ressemble pas à Bazzite"
}

is_bc250() {
    local d
    for d in /sys/bus/pci/devices/*; do
        [[ -r $d/vendor && -r $d/device ]] || continue
        [[ $(<"$d/vendor") == 0x1002 && $(<"$d/device") == "$BC250_DEVICE" ]] && return 0
    done
    return 1
}

# --- rpm-ostree ---------------------------------------------------------------
refresh_status() { STATUS_JSON="$(rpm-ostree status --json)"; }

booted_ref() {
    jq -r '.deployments[] | select(.booted) | ."container-image-reference" // empty' <<<"$STATUS_JSON"
}
booted_version() {
    jq -r '.deployments[] | select(.booted) | .version // empty' <<<"$STATUS_JSON"
}
# Déploiement par défaut s'il n'est pas celui qui tourne (= au prochain démarrage)
pending_ref() {
    jq -r '.deployments[0] | select(.booted | not) | ."container-image-reference" // empty' <<<"$STATUS_JSON"
}

# ostree-image-signed:docker://ghcr.io/x/y:tag -> ghcr.io/x/y
ref_repo() {
    local r="$1"
    r="${r#ostree-unverified-registry:}"
    r="${r#ostree-unverified-image:}"
    r="${r#ostree-image-signed:}"
    r="${r#ostree-remote-image:*:}"
    r="${r#docker://}"
    r="${r%@*}"
    [[ ${r##*/} == *:* ]] && r="${r%:*}"
    printf '%s\n' "$r"
}
is_ours() { [[ -n $1 && $(ref_repo "$1") == "$IMAGE" ]]; }

wait_idle() {
    local i
    for (( i = 0; i < 180; i++ )); do
        rpm-ostree status --json | jq -e '.transaction == null' >/dev/null && return 0
        (( i == 0 )) && step "Une mise à jour système est en cours, j'attends qu'elle se termine…"
        sleep 10
    done
    die "rpm-ostree est occupé depuis 30 minutes, réessaie plus tard"
}

# Valeurs de l'argument noyau dans le déploiement par défaut
karg_values() {
    rpm-ostree kargs | tr ' ' '\n' | sed -n "s/^${KARG_KEY//./\\.}=//p"
}

karg_enable() {
    local cur
    cur="$(karg_values | tail -1)"
    if [[ $cur == "$KARG_VALUE" ]]; then
        ok "argument noyau $KARG_KEY=$KARG_VALUE déjà présent"
        return 0
    fi
    wait_idle
    if [[ -n $cur ]]; then
        rpm-ostree kargs --replace="$KARG_KEY=$KARG_VALUE"
    else
        rpm-ostree kargs --append-if-missing="$KARG_KEY=$KARG_VALUE"
    fi
    STAGED=1
    ok "argument noyau $KARG_KEY=$KARG_VALUE ajouté"
}

karg_disable() {
    local v args=()
    while read -r v; do
        [[ -n $v ]] && args+=("--delete=$KARG_KEY=$v")
    done < <(karg_values)
    if (( ${#args[@]} == 0 )); then
        ok "argument noyau $KARG_KEY absent"
        return 0
    fi
    wait_idle
    rpm-ostree kargs "${args[@]}"
    STAGED=1
    ok "argument noyau $KARG_KEY retiré"
}

# --- Registre -----------------------------------------------------------------
# Remplit REMOTE_JSON ; en cas d'échec, explique pourquoi (sauf si « quiet »)
inspect_remote() {
    local err owner name
    err="$(mktemp)"
    if REMOTE_JSON="$(skopeo inspect --retry-times 3 --no-tags "docker://$IMAGE:$TAG" 2>"$err")"; then
        rm -f "$err"
        return 0
    fi
    if [[ ${1:-} != quiet ]]; then
        owner="${IMAGE#*/}"; owner="${owner%%/*}"; name="${IMAGE##*/}"
        if grep -qiE 'unauthorized|denied|authentication required' "$err"; then
            warn "l'image $IMAGE est privée. Rends-la publique : https://github.com/users/$owner/packages/container/$name/settings → Change visibility → Public"
        elif grep -qiE 'manifest unknown|not found|name unknown' "$err"; then
            warn "l'image $IMAGE:$TAG n'est pas encore publiée. Suis le build ici : https://github.com/$REPO/actions"
        else
            warn "impossible de joindre $IMAGE:$TAG :"
            sed 's/^/      /' "$err" >&2
        fi
    fi
    rm -f "$err"
    return 1
}
# Comme inspect_remote, en réessayant (réseau pas encore prêt au démarrage)
wait_remote() {
    local i
    for (( i = 1; i < REMOTE_TRIES; i++ )); do
        inspect_remote quiet && return 0
        sleep 30
    done
    inspect_remote
}
remote_label() { jq -r --arg l "$1" '.Labels[$l] // empty' <<<"$REMOTE_JSON"; }

# Signature cosign (ancien format) : tag sha256-<digest>.sig à côté de l'image
remote_signed() {
    local digest
    digest="$(jq -r '.Digest' <<<"$REMOTE_JSON")"
    skopeo inspect --raw --retry-times 2 "docker://$IMAGE:${digest/:/-}.sig" >/dev/null 2>&1
}

policy_trusts() {
    [[ -r $1 ]] && jq -e --arg r "$IMAGE" \
        '[.transports.docker[$r][]? | select(.type == "sigstoreSigned")] | length > 0' "$1" >/dev/null 2>&1
}

# /etc/containers/policy.json modifié localement : OSTree a gardé la version
# locale au lieu de celle de l'image, on y reporte l'entrée de l'image.
merge_policy() {
    local name="${IMAGE##*/}" tmp f
    tmp="$(mktemp)"
    jq --slurpfile img /usr/etc/containers/policy.json --arg r "$IMAGE" \
        '.transports.docker[$r] = $img[0].transports.docker[$r]' /etc/containers/policy.json >"$tmp" \
        || { rm -f "$tmp"; return 1; }
    install -m644 "$tmp" /etc/containers/policy.json
    rm -f "$tmp"
    for f in "pki/containers/$name.pub" "containers/registries.d/$name.yaml"; do
        [[ -e /etc/$f || ! -e /usr/etc/$f ]] || install -Dm644 "/usr/etc/$f" "/etc/$f"
    done
    ok "entrée de signature ajoutée à /etc/containers/policy.json (fichier modifié localement)"
}

# Passe de ostree-unverified-registry à ostree-image-signed quand c'est possible.
# Appelée dans des « if » (donc sans set -e) : chaque erreur est traitée.
secure_transport() {
    local booted pending
    refresh_status || return 1
    booted="$(booted_ref)"; pending="$(pending_ref)"
    if [[ $booted == ostree-image-signed:* ]] || { is_ours "$pending" && [[ $pending == ostree-image-signed:* ]]; }; then
        ok "vérification de signature active"
        return 0
    fi
    if ! policy_trusts /usr/etc/containers/policy.json; then
        warn "cette version de l'image n'embarque pas de clé de signature (secret SIGNING_SECRET absent côté GitHub ?)"
        return 1
    fi
    if ! policy_trusts /etc/containers/policy.json; then
        merge_policy || { warn "impossible de mettre à jour /etc/containers/policy.json"; return 1; }
    fi
    wait_remote || return 1
    if ! remote_signed; then
        warn "la dernière image publiée n'est pas signée"
        return 1
    fi
    wait_idle
    step "Activation de la vérification de signature"
    if ! rpm-ostree rebase "ostree-image-signed:docker://$IMAGE:$TAG"; then
        warn "rpm-ostree a refusé l'image signée"
        return 1
    fi
    STAGED=1
    ok "vérification de signature activée (effective au prochain démarrage)"
}

# --- systemd ------------------------------------------------------------------
install_self() {
    local src="${BASH_SOURCE[0]:-}"
    # /usr/local -> /var/usrlocal sur Bazzite : on crée la cible du lien
    mkdir -p "$(realpath -m "${SELF%/*}")"
    if [[ -f $src ]]; then
        [[ $(realpath "$src") == "$(realpath -m "$SELF")" ]] || install -m755 "$src" "$SELF"
    else
        curl -fsSL --retry 3 "$RAW_URL" -o "$SELF.tmp"
        chmod 755 "$SELF.tmp"
        mv "$SELF.tmp" "$SELF"
    fi
    printf 'IMAGE=%s\nTAG=%s\n' "$IMAGE" "$TAG" >"$CONF"
}

install_units() {
    cat >"$UNIT_DIR/bc250-setup.service" <<EOF
[Unit]
Description=BC-250 : vérifie l'installation et active la signature de l'image
Documentation=https://github.com/$REPO
Wants=network-online.target
After=network-online.target
ConditionPathExists=$STATE/pending

[Service]
Type=oneshot
ExecStart=$SELF boot
EOF
    # Minuteur plutôt que service au démarrage : ne retarde pas le mode Jeu
    cat >"$UNIT_DIR/bc250-setup.timer" <<EOF
[Unit]
Description=BC-250 : finalisation de l'installation après le démarrage
ConditionPathExists=$STATE/pending

[Timer]
OnBootSec=2min
Unit=bc250-setup.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --quiet bc250-setup.timer
}

finish() {
    rm -f "$STATE/pending"
    systemctl disable --quiet bc250-setup.timer 2>/dev/null || true
    ok "installation terminée, le service de finalisation est désactivé"
}

reboot_prompt() {
    if (( NO_REBOOT )); then
        step "Redémarre quand tu veux : systemctl reboot"
    elif (( ASSUME_YES )); then
        step "Redémarrage dans 15 secondes (Ctrl-C pour annuler)…"
        sleep 15
        systemctl reboot
    elif has_tty && ask "Redémarrer maintenant ?" O; then
        systemctl reboot
    else
        step "Redémarre quand tu veux : systemctl reboot"
    fi
}

# --- État ---------------------------------------------------------------------
report_gpu() {
    local p=/sys/module/amdgpu/parameters/bc250_cc_write_mode cu h
    if is_bc250; then ok "BC-250 détectée"; else warn "aucune BC-250 détectée (PCI 1002:13fe)"; fi
    if [[ -r $p ]]; then
        ok "module amdgpu patché chargé ($KARG_KEY=$(<"$p"))"
    elif [[ -d /sys/module/amdgpu ]]; then
        warn "le module amdgpu chargé n'est pas la version patchée"
    else
        warn "module amdgpu non chargé"
    fi
    cu="$(journalctl -k -b 0 -o cat 2>/dev/null | sed -nE 's/.*active_cu_number ([0-9]+).*/\1/p' | tail -1)"
    [[ -z $cu ]] || ok "CU actifs : $cu"
    for h in /sys/class/hwmon/hwmon*; do
        [[ -r $h/name && $(<"$h/name") == amdgpu && -r $h/temp1_input ]] || continue
        ok "température GPU : $(( $(<"$h/temp1_input") / 1000 )) °C"
        break
    done
}

cmd_status() {
    local booted pending v
    need_root
    refresh_status
    booted="$(booted_ref)"; pending="$(pending_ref)"
    step "Système"
    echo "  démarré    : ${booted:-?} ($(booted_version))"
    [[ -z $pending ]] || echo "  en attente : $pending (au prochain redémarrage)"
    if is_ours "$booted"; then
        if [[ $booted == ostree-image-signed:* ]]; then ok "image BC-250, signature vérifiée"
        else warn "image BC-250, signature non vérifiée"; fi
    else
        warn "le système ne tourne pas sur $IMAGE"
    fi
    step "GPU"
    report_gpu
    step "Déverrouillage 40 CU"
    v="$(karg_values | tail -1)"
    if [[ $v == "$KARG_VALUE" ]]; then ok "$KARG_KEY=$v"; else warn "argument noyau absent (sudo bc250-setup enable-40cu)"; fi
    if [[ -e $STATE/pending ]]; then
        step "Finalisation : en attente (journalctl -u bc250-setup)"
    fi
}

# --- Commandes ----------------------------------------------------------------
cmd_install() {
    local booted pending target
    need_root
    preflight
    step "BC-250 + Bazzite Deck 40 CU — image $IMAGE:$TAG"

    if is_bc250; then
        ok "BC-250 détectée"
    else
        warn "aucune BC-250 détectée (PCI 1002:13fe) : le patch restera inactif sur ce GPU"
        ask "Continuer quand même ?" N || die "annulé"
    fi

    refresh_status
    booted="$(booted_ref)"; pending="$(pending_ref)"
    if ! is_ours "$booted" && ! is_ours "$pending" \
        && [[ $(ref_repo "$booted") != ghcr.io/ublue-os/bazzite-deck ]]; then
        warn "système actuel : ${booted:-inconnu}"
        warn "l'image patchée est basée sur bazzite-deck (mode Jeu + bureau KDE) : la bascule change d'édition"
        ask "Continuer quand même ?" N || die "annulé"
    fi

    inspect_remote || exit 1
    ok "image disponible : Bazzite $(remote_label org.opencontainers.image.version), noyau $(remote_label ostree.linux)"
    if remote_signed; then
        ok "image signée"
    else
        warn "image non signée : l'installation se fait quand même, la vérification s'activera toute seule plus tard"
    fi

    mkdir -p "$STATE"
    if [[ -n $booted ]] && ! is_ours "$booted" && [[ ! -s $STATE/original-image ]]; then
        printf '%s\n' "$booted" >"$STATE/original-image"
    fi
    install_self
    install_units
    touch "$STATE/pending"

    if is_ours "$booted"; then
        ok "déjà démarré sur l'image BC-250"
        if secure_transport; then finish; fi
    elif is_ours "$pending"; then
        ok "bascule vers l'image BC-250 déjà prête, il reste à redémarrer"
    else
        if policy_trusts /etc/containers/policy.json && remote_signed; then
            target="ostree-image-signed:docker://$IMAGE:$TAG"
        else
            # La clé de l'image n'est pas encore connue du système : premier
            # passage non vérifié, le service bascule en signé au démarrage.
            target="ostree-unverified-registry:$IMAGE:$TAG"
        fi
        step "Téléchargement et préparation de l'image (quelques minutes)…"
        wait_idle
        rpm-ostree rebase "$target"
        STAGED=1
        ok "nouvelle image prête : $target"
    fi

    if (( ENABLE_40CU )); then
        karg_enable
    fi

    if (( STAGED )); then
        echo
        step "Au redémarrage : module patché + 40 CU. Vérifie ensuite avec : sudo bc250-setup status"
        reboot_prompt
    else
        ok "rien à changer"
        cmd_status
    fi
}

# Lancé par bc250-setup.timer après chaque démarrage, tant que l'installation
# n'est pas finalisée.
cmd_boot() {
    local booted pending
    (( EUID == 0 )) || die "réservé au service systemd"
    [[ -e $STATE/pending ]] || exit 0
    refresh_status
    booted="$(booted_ref)"; pending="$(pending_ref)"
    if ! is_ours "$booted"; then
        if is_ours "$pending"; then
            echo "bascule vers $IMAGE en attente de redémarrage"
        else
            echo "le système n'est plus sur $IMAGE : arrêt du suivi"
            finish
        fi
        exit 0
    fi
    report_gpu
    REMOTE_TRIES=10
    if secure_transport; then
        finish
    else
        echo "nouvel essai au prochain démarrage"
    fi
}

cmd_enable_40cu() {
    need_root
    karg_enable
    (( STAGED )) && reboot_prompt
    return 0
}

cmd_disable_40cu() {
    need_root
    karg_disable
    (( STAGED )) && reboot_prompt
    return 0
}

cmd_uninstall() {
    local target=""
    need_root
    [[ -s $STATE/original-image ]] && target="$(<"$STATE/original-image")"
    if [[ -z $target ]] || is_ours "$target"; then target="$OFFICIAL_REF"; fi
    step "Retour à $target (le déverrouillage 40 CU est retiré)"
    ask "Confirmer ?" O || die "annulé"
    refresh_status
    if is_ours "$(booted_ref)" || is_ours "$(pending_ref)"; then
        wait_idle
        rpm-ostree rebase "$target"
        STAGED=1
    fi
    karg_disable
    systemctl disable --quiet --now bc250-setup.timer 2>/dev/null || true
    rm -f "$UNIT_DIR/bc250-setup.service" "$UNIT_DIR/bc250-setup.timer" "$CONF" "$SELF"
    systemctl daemon-reload
    rm -rf "$STATE"
    ok "bc250-setup désinstallé"
    (( STAGED )) && reboot_prompt
    return 0
}

# Clé de signature pour la CI : à lancer en utilisateur normal, une seule fois.
cmd_signing_key() {
    local dir="$HOME/.config/bc250-signing"
    (( EUID != 0 )) || die "à lancer sans sudo : bc250-setup signing-key"
    command -v cosign >/dev/null || die "cosign introuvable (fourni par Bazzite, sinon : brew install cosign)"
    mkdir -p "$dir"
    chmod 700 "$dir"
    if [[ -s $dir/cosign.key ]]; then
        ok "clé existante réutilisée : $dir/cosign.key"
    else
        (cd "$dir" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null)
        chmod 600 "$dir/cosign.key"
        ok "clé créée : $dir/cosign.key (mot de passe vide)"
    fi
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        gh secret set SIGNING_SECRET -R "$REPO" <"$dir/cosign.key"
        ok "secret SIGNING_SECRET enregistré dans $REPO"
        gh workflow run build.yml -R "$REPO" -f force=true
        ok "build relancé : https://github.com/$REPO/actions"
    else
        step "Dernière étape, dans le navigateur :"
        echo "  1. Ouvre https://github.com/$REPO/settings/secrets/actions/new"
        echo "  2. Name : SIGNING_SECRET"
        echo "  3. Secret : colle tout le bloc ci-dessous (lignes BEGIN et END comprises)"
        echo "  4. Actions → Build bazzite-deck-bc250 → Run workflow (cocher « force »)"
        echo
        cat "$dir/cosign.key"
        echo
    fi
    echo "La BC-250 passera toute seule en mode signé au démarrage qui suit le prochain build."
}

# --- Point d'entrée -----------------------------------------------------------
load_conf
CMD=install
while (( $# )); do
    case $1 in
        install|status|boot|enable-40cu|disable-40cu|uninstall|signing-key|help) CMD=$1 ;;
        -h|--help)  CMD=help ;;
        -y|--yes)   ASSUME_YES=1 ;;
        --no-reboot) NO_REBOOT=1 ;;
        --no-40cu)  ENABLE_40CU=0 ;;
        --image)    IMAGE="${2:?--image demande une valeur}"; shift ;;
        --tag)      TAG="${2:?--tag demande une valeur}"; shift ;;
        *) die "argument inconnu : $1 (voir bc250-setup --help)" ;;
    esac
    shift
done

case $CMD in
    install)      cmd_install ;;
    status)       cmd_status ;;
    boot)         cmd_boot ;;
    enable-40cu)  cmd_enable_40cu ;;
    disable-40cu) cmd_disable_40cu ;;
    uninstall)    cmd_uninstall ;;
    signing-key)  cmd_signing_key ;;
    help)         usage ;;
esac
