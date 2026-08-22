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
#
# Base release: bootc's latest release requires libostree >= 2025.3.
# Ubuntu's LTS releases don't clear that bar (24.04 "noble" ships 2024.5,
# 22.04 "jammy" ships 2022.2) - only the 25.10 "questing" interim release
# does, at 2025.6. That's why both stages below pin to 25.10 rather than
# an LTS. See docs/ARCHITECTURE.md for the full version-gap writeup.
ARG UBUNTU_RELEASE=25.10

########################################
# Stage 1: build bootc from source
########################################
FROM ubuntu:${UBUNTU_RELEASE} AS bootc-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git pkg-config build-essential \
        libostree-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH="${CARGO_HOME}/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal

# Ubuntu/Debian don't package bootc, so we build it from the latest
# upstream release tag instead of pinning a version number by hand here.
# api.github.com rate-limits unauthenticated requests hard, and CI runner
# IPs are shared, so this reads a token from a build secret when one is
# provided (CI passes one; a local `docker build` without --secret still
# works, just subject to the anonymous rate limit).
RUN --mount=type=secret,id=gh_token set -eux; \
    AUTH=""; \
    if [ -s /run/secrets/gh_token ]; then AUTH="Authorization: Bearer $(cat /run/secrets/gh_token)"; fi; \
    BOOTC_TAG="$(curl -fsSL ${AUTH:+-H "$AUTH"} https://api.github.com/repos/containers/bootc/releases/latest \
        | grep -m1 '"tag_name"' | cut -d '"' -f4)"; \
    echo "Building bootc ${BOOTC_TAG}"; \
    git clone --depth 1 --branch "${BOOTC_TAG}" https://github.com/containers/bootc /src/bootc

WORKDIR /src/bootc
RUN cargo build --release --bin bootc

########################################
# Stage 2: the bootc-compatible Ubuntu image
########################################
FROM ubuntu:${UBUNTU_RELEASE}

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
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/cache/debconf/*.dat* /var/log/* /tmp/* /run/*

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

# ostree requires an empty /sysroot to exist (it's where the real root
# filesystem gets mounted at deploy time) plus an /ostree symlink pointing
# into it, mirroring the layout of an already-deployed ostree system.
# Found both via `bootc container lint` failing the build on each in turn.
RUN mkdir -p /sysroot && ln -s sysroot/ostree /ostree

# Opts the image into ostree's composefs backend, which is what current
# bootc/ostree expect by default (also flagged by `bootc container lint`).
RUN mkdir -p /usr/lib/ostree && printf '[composefs]\nenabled = true\n' > /usr/lib/ostree/prepare-root.conf

# Required label per bootc's own image contract: marks this as a valid
# bootc base/target image rather than an arbitrary container image.
LABEL containers.bootc=1
LABEL org.opencontainers.image.title="bootc-ubuntu-image"
LABEL org.opencontainers.image.description="Proof-of-concept: bootc/ostree atomic OS updates on an Ubuntu base"

# Fail the build here, not downstream: bootc ships a linter that checks
# an image actually satisfies bootc's layout/metadata requirements.
RUN bootc container lint
