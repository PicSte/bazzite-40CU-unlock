#!/usr/bin/bash
# Étape finale (dans l'image Bazzite) : remplace amdgpu.ko par la version
# patchée, régénère depmod + initramfs et, si une clé publique est fournie,
# configure la vérification de signature de l'image.
#
# Entrée : /tmp/bc250/{amdgpu.ko,kver,ogc_tag}
#          /tmp/bc250/keys/cosign.pub              (facultatif)
#          IMAGE_REF=ghcr.io/<utilisateur>/<image>   (sans tag)
set -euo pipefail
shopt -s nullglob

SRC=/tmp/bc250
die() { echo "ERREUR: $*" >&2; exit 1; }

KVER="$(cat "$SRC/kver")"
MODDIR="/usr/lib/modules/$KVER"
[[ -d "$MODDIR" ]] || die "$MODDIR absent : l'image de base a changé de noyau pendant le build"

# --- 1. Remplacement du module ------------------------------------------------
originals=("$MODDIR"/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko*)
[[ ${#originals[@]} -eq 1 ]] || die "amdgpu.ko d'origine introuvable (ou multiple) dans $MODDIR"
orig="${originals[0]}"

old_magic="$(modinfo -F vermagic "$orig")"
new_magic="$(modinfo -F vermagic "$SRC/amdgpu.ko")"
[[ "$old_magic" == "$new_magic" ]] \
    || die "vermagic différent : origine « $old_magic » / nouveau « $new_magic »"

tmp="$(mktemp -d)"
cp "$SRC/amdgpu.ko" "$tmp/amdgpu.ko"
case "$orig" in
    *.ko.xz)  xz --check=crc32 --lzma2=dict=1MiB -f "$tmp/amdgpu.ko"; new="$tmp/amdgpu.ko.xz" ;;
    *.ko.zst) zstd -q -T0 --rm -f "$tmp/amdgpu.ko";                     new="$tmp/amdgpu.ko.zst" ;;
    *.ko.gz)  gzip -9 -n -f "$tmp/amdgpu.ko";                           new="$tmp/amdgpu.ko.gz" ;;
    *.ko)     new="$tmp/amdgpu.ko" ;;
    *)        die "compression inconnue : $orig" ;;
esac
install -m644 "$new" "$orig"
rm -rf "$tmp"

modinfo -F parm "$orig" | grep -q '^bc250_cc_write_mode:' \
    || die "le module installé n'expose pas bc250_cc_write_mode"
echo "amdgpu remplacé : $orig (sources OGC $(cat "$SRC/ogc_tag"))"

depmod -a "$KVER"

# --- 2. Initramfs (mêmes options que Bazzite) ---------------------------------
/usr/bin/dracut --no-hostonly --kver "$KVER" --reproducible --zstd -v \
    --add ostree --add fido2 -f "$MODDIR/initramfs.img"
chmod 0600 "$MODDIR/initramfs.img"

# --- 3. Politique de signature de l'image -------------------------------------
[[ -n "${IMAGE_REF:-}" ]] || die "IMAGE_REF non défini"
if [[ ! -s "$SRC/keys/cosign.pub" ]]; then
    echo "Pas de clé publique fournie : image non signée, politique de signature inchangée"
    exit 0
fi
name="${IMAGE_REF##*/}"
install -Dm644 "$SRC/keys/cosign.pub" "/etc/pki/containers/$name.pub"

cat > "/etc/containers/registries.d/$name.yaml" <<EOF
docker:
  $IMAGE_REF:
    use-sigstore-attachments: true
EOF

jq --arg ref "$IMAGE_REF" --arg key "/etc/pki/containers/$name.pub" \
   '.transports.docker[$ref] = [{
        "type": "sigstoreSigned",
        "keyPath": $key,
        "signedIdentity": {"type": "matchRepository"}
    }]' /etc/containers/policy.json > /tmp/policy.json
mv /tmp/policy.json /etc/containers/policy.json
echo "Signature : $IMAGE_REF vérifiée avec /etc/pki/containers/$name.pub"
