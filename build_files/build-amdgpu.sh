#!/usr/bin/bash
# Compile amdgpu.ko avec le patch BC-250 40 CU, pour le noyau OGC exact
# de l'image Bazzite de base (kernel-devel copié depuis cette image).
#
# Entrée : /usr/src/kernels/<KVER>   (kernel-devel de l'image de base)
#          /tmp/patches/*.patch
# Sortie : /out/amdgpu.ko  (sans infos de debug)
#          /out/kver       (version du noyau ciblée)
set -euo pipefail
shopt -s nullglob

OGC_REPO="${OGC_REPO:-https://github.com/OpenGamingCollective/linux.git}"
PATCH_DIR="${PATCH_DIR:-/tmp/patches}"
OUT_DIR="${OUT_DIR:-/out}"
WORK_DIR="${WORK_DIR:-/build}"

die() { echo "ERREUR: $*" >&2; exit 1; }

# --- 1. Noyau cible -----------------------------------------------------------
if [[ -z "${KDIR:-}" ]]; then
    kdirs=(/usr/src/kernels/*/)
    [[ ${#kdirs[@]} -eq 1 ]] || die "il faut exactement un kernel-devel dans /usr/src/kernels (trouvé : ${#kdirs[@]})"
    KDIR="${kdirs[0]%/}"
fi
KVER="${KVER:-$(basename "$KDIR")}"
[[ -f "$KDIR/Module.symvers" || -n "${ALLOW_MISSING_SYMVERS:-}" ]] \
    || die "$KDIR/Module.symvers absent : kernel-devel incomplet"
echo "Noyau cible : $KVER ($KDIR)"

# 7.2.9-ogc3.1.fc44.x86_64 -> tag git v7.2.9-ogc3
if [[ -z "${OGC_TAG:-}" ]]; then
    [[ "$KVER" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-ogc([0-9]+)\.[0-9]+\.fc[0-9]+\.x86_64$ ]] \
        || die "format de version inattendu « $KVER » (noyau OGC attendu). Forcer avec OGC_TAG=…"
    OGC_TAG="v${BASH_REMATCH[1]}-ogc${BASH_REMATCH[2]}"
fi
echo "Sources : $OGC_REPO @ $OGC_TAG"

# --- 2. Sources amdgpu uniquement (sparse checkout) ---------------------------
rm -rf "$WORK_DIR"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$OGC_TAG" --filter=blob:none --sparse \
    "$OGC_REPO" "$WORK_DIR/src" \
    || die "tag $OGC_TAG introuvable dans $OGC_REPO"
git -C "$WORK_DIR/src" sparse-checkout set drivers/gpu/drm/amd

# Garde-fou : la version des sources doit correspondre au noyau installé
src_ver="$(sed -nE 's/^VERSION = ([0-9]+)$/\1/p' "$WORK_DIR/src/Makefile").$(sed -nE 's/^PATCHLEVEL = ([0-9]+)$/\1/p' "$WORK_DIR/src/Makefile").$(sed -nE 's/^SUBLEVEL = ([0-9]+)$/\1/p' "$WORK_DIR/src/Makefile")"
[[ "$KVER" == "$src_ver"-* ]] || die "sources $src_ver ≠ noyau $KVER"

# --- 3. Patchs ----------------------------------------------------------------
patches=("$PATCH_DIR"/*.patch)
[[ ${#patches[@]} -gt 0 ]] || die "aucun patch dans $PATCH_DIR"
for p in "${patches[@]}"; do
    echo "Patch : $(basename "$p")"
    patch -d "$WORK_DIR/src" -p1 --forward --fuzz=2 --no-backup-if-mismatch < "$p" \
        || die "le patch $(basename "$p") ne s'applique plus sur $OGC_TAG"
done
grep -q 'bc250_cc_write_mode' "$WORK_DIR/src/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" \
    || die "patch 40 CU absent de gfx_v10_0.c après application"

# --- 4. Compilation externe contre kernel-devel -------------------------------
# On sort l'arborescence amd/ de l'arbre : amdgpu ne référence que ../ (FULL_AMD_PATH)
mv "$WORK_DIR/src/drivers/gpu/drm/amd" "$WORK_DIR/amd"
rm -rf "$WORK_DIR/src"

# -g0 : pas d'infos de debug (gain de temps et de disque, sans effet sur l'ABI)
make -C "$KDIR" M="$WORK_DIR/amd/amdgpu" KCFLAGS="-g0" \
    ${MODPOST_WARN:+KBUILD_MODPOST_WARN=1} -j"$(nproc)" modules

ko="$WORK_DIR/amd/amdgpu/amdgpu.ko"
[[ -f "$ko" ]] || die "amdgpu.ko n'a pas été produit"
strip --strip-debug "$ko"

# --- 5. Vérifications ---------------------------------------------------------
vermagic="$(modinfo -F vermagic "$ko")"
[[ "$vermagic" == "$KVER "* ]] || die "vermagic « $vermagic » ne correspond pas à $KVER"
modinfo -F parm "$ko" | grep -q '^bc250_cc_write_mode:' \
    || die "paramètre bc250_cc_write_mode absent du module"

install -Dm644 "$ko" "$OUT_DIR/amdgpu.ko"
printf '%s\n' "$KVER" > "$OUT_DIR/kver"
printf '%s\n' "$OGC_TAG" > "$OUT_DIR/ogc_tag"
echo "OK : $(du -h "$OUT_DIR/amdgpu.ko" | cut -f1) — vermagic: $vermagic"
