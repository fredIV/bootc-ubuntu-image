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
# bootc-initramfs-setup: a second binary in the same workspace (crates/
# initramfs), built here alongside bootc itself so both land in the same
# target/release/ output - see the dracut module install below for why
# this one's needed too.
RUN cargo build --release --bin bootc --bin bootc-initramfs-setup

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
# - podman, skopeo: `bootc install to-disk` runs as a container of THIS
#   image, and once disk formatting is done it execs `podman images`
#   (crates/lib/src/podstorage.rs, `imgstorage::create`) to initialize its
#   own containers-storage root on the target disk, and uses skopeo
#   (crates/lib/src/deploy.rs) to pull/copy the container image during
#   deployment. Neither is installed by default; without them bootc's
#   own binary can't find them to exec, failing with a bare ENOENT
#   ("No such file or directory") that gives no hint it's podman/skopeo
#   that's missing - found by reading bootc's Rust source directly after
#   the error persisted across every composefs-related theory.
# - systemd-boot-efi: `bootctl install` (see below) copies its EFI stub
#   binaries from /usr/lib/systemd/boot/efi/ into the ESP. That directory
#   only exists if this package is installed.
# - systemd-boot-tools: provides the bootctl binary itself. Assumed above
#   to come from the base systemd package (true on older releases), but
#   bootc's own "No such file or directory (os error 2)" trying to exec
#   it - a bare ENOENT, not a bootctl-internal error - showed that wrong.
#   Recent Debian (trixie/testing/unstable, which 25.10 tracks closely)
#   split bootctl out of systemd into this separate package - confirmed
#   via Debian's own manpage index before adding it, not guessed.
# - ostree-boot: the actual dracut integration for ostree/composefs -
#   ships /usr/lib/dracut/modules.d/50ostree/ (dracut's ostree module,
#   from ostree upstream's own src/boot/dracut/module-setup.sh) and the
#   ostree-prepare-root.service unit that mounts the real deployment
#   during early boot. Debian/Ubuntu package this separately from the
#   base `ostree` package we already had - confirmed via Debian's own
#   package file listing, not guessed - so our dracut-generated initrd
#   never included it, and boot-testing showed the kernel and systemd
#   coming up fine in the initrd, then hanging waiting on a device by
#   UUID before dropping to an emergency shell: dracut had no ostree/
#   composefs-aware module to actually assemble the real root, only the
#   generic "wait for a filesystem UUID" path every distro's dracut
#   ships by default. Must be installed before the dracut initrd is
#   built below so dracut's own module auto-detection (`check()` in
#   module-setup.sh) picks it up.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ostree ostree-boot \
        linux-image-generic \
        dracut cpio \
        grub-efi-amd64-bin grub-common \
        systemd-boot-efi systemd-boot-tools \
        selinux-basics selinux-policy-default policycoreutils \
        fdisk dosfstools \
        podman skopeo \
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

# bootc's declarative kernel-argument mechanism (kargs.d), applied at
# deploy time to whatever bootloader entry gets generated. Without this,
# the kernel boots with no console= arg at all, so nothing it prints ever
# reaches a serial port - found after a QEMU boot-test hung silently past
# UEFI's own "BdsDxe: starting Boot0001" firmware message with zero
# kernel or bootloader output for the full 5-minute timeout, on a build
# that had otherwise installed cleanly. tty0 is kept alongside ttyS0 so a
# real (non-headless) boot still gets console output on the physical
# display too.
RUN mkdir -p /usr/lib/bootc/kargs.d && \
    printf 'kargs = ["console=ttyS0,115200n8", "console=tty0"]\nmatch-architectures = ["x86_64"]\n' > /usr/lib/bootc/kargs.d/01-console.toml

COPY --from=bootc-builder /src/bootc/target/release/bootc /usr/bin/bootc

# bootc's own dracut module (crates/initramfs/), separate from and in
# addition to ostree upstream's dracut module (installed above via the
# ostree-boot package): that one drives the *classic* ostree sysroot/
# deployment boot path via ostree-prepare-root.service, but this image
# uses bootc's *composefs-native* install backend (--composefs-backend),
# which has its own completely different early-boot unit,
# bootc-root-setup.service, that mounts the composefs EROFS image
# directly. Installing ostree-boot alone got the classic module in place
# but changed nothing for this image, since composefs-native boot never
# looks at ostree-prepare-root at all - confirmed by hitting the exact
# same "Expecting device ...uuid...device" timeout/emergency-shell
# failure again, byte for byte, even with ostree-boot installed.
#
# Per bootc's own docs (docs/src/packaging-and-integration.md) and
# Makefile, this module - "51bootc" - is a `make install` artifact that
# our from-source build never ran (we only copy the bootc binary itself
# out of the builder stage), and its own module-setup.sh explicitly
# returns "never install by default" from its check() function: a distro
# base image has to opt in via dracut config, not just have the module
# files present. Reproducing that install by hand here: build the
# separate bootc-initramfs-setup binary alongside bootc (above), copy it
# and the module's own dracut/systemd-unit sources straight out of the
# builder's checkout, and add the dracut.conf.d file that actually
# requests the module - all confirmed against bootc's own source/build
# system rather than guessed.
COPY --from=bootc-builder /src/bootc/crates/initramfs/dracut/module-setup.sh /usr/lib/dracut/modules.d/51bootc/module-setup.sh
COPY --from=bootc-builder /src/bootc/target/release/bootc-initramfs-setup /usr/lib/bootc/initramfs-setup
COPY --from=bootc-builder /src/bootc/crates/initramfs/*.service /usr/lib/systemd/system/
RUN mkdir -p /etc/dracut.conf.d && \
    printf 'add_dracutmodules+=" bootc "\n' > /etc/dracut.conf.d/50-bootc.conf

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
