# syntax=docker/dockerfile:1
#
# bootc-ubuntu-image
#
# Builds an Ubuntu base into a container image that satisfies bootc's
# contract: bootc (https://github.com/containers/bootc) normally targets
# Fedora/CentOS/RHEL, where the distro already ships `bootc` as an RPM and
# grub is patched to understand the Boot Loader Specification (BLS) that
# ostree relies on to manage multiple bootable deployments. Ubuntu has
# neither, so this image builds bootc from source and manually assembles
# the on-disk layout ostree/bootc expect.
#
# See docs/ARCHITECTURE.md for why each step below exists and which parts
# are confirmed-working vs. still-open questions for this PoC.

########################################
# Stage 1: build bootc from source
########################################
FROM rust:1-bookworm AS bootc-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git pkg-config \
        libostree-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu/Debian don't package bootc, so we build it from the latest
# upstream release tag instead of pinning a version number by hand here.
RUN set -eux; \
    BOOTC_TAG="$(curl -fsSL https://api.github.com/repos/containers/bootc/releases/latest \
        | grep -m1 '"tag_name"' | cut -d '"' -f4)"; \
    echo "Building bootc ${BOOTC_TAG}"; \
    git clone --depth 1 --branch "${BOOTC_TAG}" https://github.com/containers/bootc /src/bootc

WORKDIR /src/bootc
RUN cargo build --release --bin bootc

########################################
# Stage 2: the bootc-compatible Ubuntu image
########################################
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Prevent package postinst scripts from trying to start services inside
# the build container (standard trick for building Debian/Ubuntu images).
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d

# - ostree: packaged in Ubuntu universe, does the actual filesystem
#   versioning bootc relies on.
# - linux-image-generic / initramfs-tools: kernel + initrd bootc will
#   relocate into ostree's expected layout below.
# - grub-efi-amd64-bin: bootc's install/deploy path is written primarily
#   against grub2. Whether plain (non-BLS) Ubuntu grub is compatible
#   enough is the biggest open question this PoC exists to answer -
#   see docs/ARCHITECTURE.md.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ostree \
        linux-image-generic \
        initramfs-tools \
        grub-efi-amd64-bin grub-common \
        ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=bootc-builder /src/bootc/target/release/bootc /usr/bin/bootc

# --- ostree/bootc filesystem contract -----------------------------------
# ostree expects the kernel + initramfs for a deployment to live under
# /usr/lib/modules/<kver>/{vmlinuz,initramfs.img}. Ubuntu's kernel
# packaging puts them in /boot/vmlinuz-<kver> and /boot/initrd.img-<kver>
# instead, so we copy them into the layout ostree looks for.
RUN set -eux; \
    kver="$(ls /usr/lib/modules | sort -V | tail -n1)"; \
    moddir="/usr/lib/modules/${kver}"; \
    test -f "/boot/vmlinuz-${kver}"; \
    test -f "/boot/initrd.img-${kver}"; \
    cp "/boot/vmlinuz-${kver}" "${moddir}/vmlinuz"; \
    cp "/boot/initrd.img-${kver}" "${moddir}/initramfs.img"

# Required label per bootc's own image contract: marks this as a valid
# bootc base/target image rather than an arbitrary container image.
LABEL containers.bootc=1
LABEL org.opencontainers.image.title="bootc-ubuntu-image"
LABEL org.opencontainers.image.description="Proof-of-concept: bootc/ostree atomic OS updates on an Ubuntu base"

# Fail the build here, not downstream: bootc ships a linter that checks
# an image actually satisfies bootc's layout/metadata requirements.
RUN bootc container lint
