# Bazzite Deck + amdgpu patché pour le déverrouillage 40 CU de l'AMD BC-250.
# Tout le reste de l'image est l'image officielle, inchangée.

ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite-deck:stable
ARG FEDORA_VERSION=44

FROM ${BASE_IMAGE} AS base

# --- Compilation d'amdgpu.ko --------------------------------------------------
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION} AS builder

RUN dnf -y install --setopt=install_weak_deps=False \
        gcc make flex bison bc perl python3 diffutils findutils \
        elfutils-libelf-devel openssl openssl-devel dwarves \
        git-core patch kmod binutils xz \
    && dnf clean all

# kernel-devel exact de l'image de base (.config, Module.symvers, scripts, objtool)
COPY --from=base /usr/src/kernels/ /usr/src/kernels/
COPY patches/ /tmp/patches/
COPY build_files/build-amdgpu.sh /tmp/build-amdgpu.sh
RUN bash /tmp/build-amdgpu.sh

# --- Image finale -------------------------------------------------------------
FROM base

ARG IMAGE_REF
COPY --from=builder /out/ /tmp/bc250/
COPY cosign.pub /tmp/bc250/cosign.pub
COPY build_files/install-amdgpu.sh /tmp/install-amdgpu.sh

RUN IMAGE_REF="${IMAGE_REF}" bash /tmp/install-amdgpu.sh \
    && rm -rf /tmp/bc250 /tmp/install-amdgpu.sh

RUN --mount=type=tmpfs,target=/run --network=none bootc container lint
