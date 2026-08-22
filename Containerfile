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
# - linux-image-generic: kernel bootc will relocate into ostree's expected
#   layout below.
# - dracut (not Ubuntu's default initramfs-tools): bootc-image-builder
#   shells into the target image and runs dracut's `lsinitrd` to inspect
#   the initramfs when generating a disk image. initramfs-tools doesn't
#   ship that tool at all, so bootc-image-builder can't introspect an
#   Ubuntu-standard initrd - found by actually running it, not guessed.
#   Using dracut to build the initrd too (below) rather than just
#   installing it for the binary, so what lsinitrd inspects is real.
# - grub-efi-amd64-bin: bootc's install/deploy path is written primarily
#   against grub2. Whether plain (non-BLS) Ubuntu grub is compatible
#   enough is the biggest open question this PoC exists to answer -
#   see docs/ARCHITECTURE.md.
# - fdisk: provides /usr/sbin/sfdisk, which `bootc install to-disk`
#   shells out to directly when partitioning. Recent Debian/Ubuntu split
#   sfdisk out of the base util-linux package into this separate one, so
#   a minimal Ubuntu image doesn't have it unless asked for explicitly.
# - dosfstools: provides mkfs.fat, which bootc shells out to directly to
#   format the EFI System Partition. Not installed by default either.
# - cpio: dracut's own package postinst runs update-initramfs
#   automatically on install, which needs cpio to build the archive.
#   Previously masked by erofs-utils incidentally pulling cpio in as a
#   dependency; surfaced once that package was removed.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ostree \
        linux-image-generic \
        dracut cpio \
        grub-efi-amd64-bin grub-common \
        selinux-basics selinux-policy-default policycoreutils \
        fdisk dosfstools \
        ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/cache/debconf/*.dat* /var/log/* /tmp/* /run/*

# bootc-image-builder's osbuild pipeline unconditionally relabels the
# tree with SELinux contexts (Fedora/RHEL always have SELinux; Ubuntu
# defaults to AppArmor and has none). It looks for the policy at the
# hardcoded path /etc/selinux/targeted/..., but Debian/Ubuntu's policy
# package installs itself under the type name "default" instead - alias
# it so osbuild finds a real, self-consistent file_contexts to read.
# The resulting xattr labels are inert under AppArmor; this exists only
# to satisfy osbuild's build-time relabeling step, not to enable SELinux
# enforcement at runtime.
RUN ln -sfn default /etc/selinux/targeted

# bootc install (both `to-disk` and bootc-image-builder before it) has no
# default root filesystem type for a distro it doesn't recognize, and
# fails with "No root filesystem specified" without one. Fedora/RHEL
# images get a default for free; Ubuntu doesn't, so declare it explicitly
# via bootc's own image-level install config rather than requiring every
# caller to pass a CLI flag - this is the same mechanism a real distro
# would use.
RUN mkdir -p /usr/lib/bootc/install && \
    printf '[install.filesystem.root]\ntype = "ext4"\n' > /usr/lib/bootc/install/00-ubuntu.toml

COPY --from=bootc-builder /src/bootc/target/release/bootc /usr/bin/bootc

# --- ostree/bootc filesystem contract -----------------------------------
# ostree expects the kernel + initramfs for a deployment to live under
# /usr/lib/modules/<kver>/{vmlinuz,initramfs.img}. Ubuntu's kernel
# packaging puts the kernel at /boot/vmlinuz-<kver>, so that's copied
# into place; the initramfs is generated fresh with dracut rather than
# copied from initramfs-tools' /boot/initrd.img-<kver> (see above).
# --no-hostonly matters: this build container's "hardware" isn't the
# target machine's, so a hostonly initrd would be missing drivers.
RUN set -eux; \
    kver="$(ls /usr/lib/modules | sort -V | tail -n1)"; \
    moddir="/usr/lib/modules/${kver}"; \
    test -f "/boot/vmlinuz-${kver}"; \
    cp "/boot/vmlinuz-${kver}" "${moddir}/vmlinuz"; \
    dracut --no-hostonly --force "${moddir}/initramfs.img" "${kver}"

# ostree requires an empty /sysroot to exist (it's where the real root
# filesystem gets mounted at deploy time) plus an /ostree symlink pointing
# into it, mirroring the layout of an already-deployed ostree system.
# Found both via `bootc container lint` failing the build on each in turn.
RUN mkdir -p /sysroot && ln -s sysroot/ostree /ostree

# `bootc container lint` suggests enabling ostree's composefs backend
# (baseimage-composefs warning), and this image tried that - but composefs
# is documented upstream as bootc's *experimental* backend, and its own
# install-time image-storage initialization failed here with an
# underdocumented "Initializing images: No such file or directory" that
# didn't resolve even after installing every filesystem tool it plausibly
# needed (erofs-utils included). Removing the file entirely (rather than
# just disabling composefs in it) turned out to be wrong too: bootc
# install requires *a* prepare-root.conf to exist at all, regardless of
# backend ("Failed to find ostree/prepare-root.conf in /usr/lib or /etc")
# - lint's warning undersold how required this file actually is. So it's
# back, just with composefs explicitly declared off instead of removed -
# see docs/ARCHITECTURE.md for the full writeup.
RUN mkdir -p /usr/lib/ostree && printf '[composefs]\nenabled = false\n' > /usr/lib/ostree/prepare-root.conf

# Required label per bootc's own image contract: marks this as a valid
# bootc base/target image rather than an arbitrary container image.
LABEL containers.bootc=1
LABEL org.opencontainers.image.title="bootc-ubuntu-image"
LABEL org.opencontainers.image.description="Proof-of-concept: bootc/ostree atomic OS updates on an Ubuntu base"

# Fail the build here, not downstream: bootc ships a linter that checks
# an image actually satisfies bootc's layout/metadata requirements.
RUN bootc container lint
