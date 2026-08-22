# Architecture & viability notes

## What this is proving

Fedora/CentOS/RHEL have converged on a specific update model, popularized by
projects like [Universal Blue](https://universal-blue.org/): instead of
patching a live filesystem package-by-package, the OS is built and shipped as
an **OCI container image**. A tool called [`bootc`](https://github.com/containers/bootc)
pulls that image and hands it to [`ostree`](https://ostreedev.github.io/ostree/),
which stores it as a versioned, bootable filesystem tree. Updating the OS
means pulling a new image tag and rebooting into it atomically - with a
one-command rollback if it's bad. `rpm-ostree` is the older, narrower version
of this idea (adapt individual RPMs onto an ostree tree); `bootc` supersedes
it by making the container image itself the unit of shipping.

This repo asks a specific question: **does that same model work on an Ubuntu
base**, or is it inherently tied to Fedora's tooling? That matters for a
broader goal - a generic disk image that, on first boot, is told which
container image to become (via MAAS/VMaaS/etc.), after which all further
updates are just atomic image swaps. Nobody has to hand-build or patch disk
images again.

## Why this isn't a drop-in port

`bootc` and the Fedora ecosystem around it make a few Fedora-shaped
assumptions that Ubuntu doesn't meet out of the box:

| Assumption | Fedora/RHEL | Ubuntu | Handled how |
|---|---|---|---|
| `bootc` binary available | Packaged as an RPM, preinstalled in `quay.io/fedora/fedora-bootc` base images | Not packaged at all | Build from source (latest upstream release tag) in the `Containerfile` builder stage |
| Kernel/initrd layout | dracut + Fedora's kernel packaging places these under `/usr/lib/modules/<kver>/` already | `linux-image-generic` puts them in `/boot/vmlinuz-<kver>` / `/boot/initrd.img-<kver>` | A build step copies them into the layout ostree expects |
| Bootloader | Fedora's `grub2` carries a downstream patch for the [Boot Loader Specification (BLS)](https://uapi-group.org/specifications/specs/boot_loader_specification/), which is what ostree's grub backend writes/reads to manage multiple deployments | Upstream/Debian grub2 does **not** carry the BLS patch | **Open question - see below.** Plan A: try image-builder's BLS handling against plain Ubuntu grub and see exactly where it breaks. Plan B (fallback): move to a UKI (Unified Kernel Image) + systemd-boot, which is bootloader-agnostic and something Ubuntu already supports natively. |
| SELinux labeling | Assumed by some of bootc's storage-separation hardening | Ubuntu defaults to AppArmor | Not fatal - bootc's core deploy/rollback logic doesn't hard-require SELinux, just loses some of that hardening. Documented as a known gap, not solved here. |

**Confirmed finding (from an actual failed CI build, not a guess):** the
latest `bootc` release requires `libostree >= 2025.3`. Checked against
Ubuntu's package archive directly:

| Release | `libostree-1-1` version | Meets bootc's `>= 2025.3`? |
|---|---|---|
| 22.04 "jammy" (LTS) | 2022.2 | No |
| 24.04 "noble" (LTS) | 2024.5 | No |
| 25.10 "questing" (interim) | 2025.6 | Yes |

Neither current Ubuntu LTS release has a new enough `libostree` to build
today's `bootc` against. This repo pins both build stages to Ubuntu 25.10
(`UBUNTU_RELEASE` build arg in the `Containerfile`) to get a matching
`libostree`/`bootc` pair. That's a real constraint worth being upfront
about: as of today, this only works on an interim (non-LTS) Ubuntu release,
with the LTS story depending on either Ubuntu backporting a newer
`libostree` or `bootc` continuing to support older ones. Worth re-checking
against future LTS releases (26.04 is due next) rather than assuming this
stays true forever.

The BLS/bootloader row is the one real unknown that determines whether this
is viable at all versus needing a different bootloader strategy. Rather than
guess at it in documentation, the CI pipeline in this repo is built to
surface the actual failure: `bootc container lint` checks image-level
compliance, and the boot-test job actually deploys the image to a virtual
disk and boots it in QEMU/KVM. Whatever breaks there is the real answer, not
a hypothesis.

## Why the pipeline runs in CI, not locally in this dev session

This repo's first draft was built inside a sandboxed remote dev session with
no outbound access to container registries (Docker Hub, GHCR, and quay.io
were all blocked at the network egress policy level - confirmed, not
assumed). That means no image in this repo has been build- or boot-tested
from that sandbox. GitHub Actions' `ubuntu-latest` runners have full internet
access and (as of the platform's KVM rollout) a working `/dev/kvm`, so the
`.github/workflows/build-and-test.yml` pipeline is where the actual proof
happens: build → `bootc container lint` → convert to a disk image → boot it
for real. Treat the Actions history on this repo as the source of truth for
"does this work," not this document.

## Pipeline stages

1. **build-and-lint**: builds the `Containerfile`, which itself fails the
   build if `bootc container lint` doesn't pass.
2. **boot-test**: takes the built image, uses
   [`bootc-image-builder`](https://github.com/osbuild/bootc-image-builder)
   to produce a bootable `qcow2`, boots it under QEMU with KVM acceleration,
   and checks it reaches a working login/systemd target on a serial console.
3. (Planned, not yet implemented) **update-test**: build a second tagged
   image, `bootc switch`/upgrade the running VM to it, reboot, and confirm
   the atomic swap and `bootc rollback` both work - the actual point of this
   whole exercise.

## `bootc container lint` findings so far

Once the image actually built (after the Ubuntu 25.10 rebase above),
`bootc container lint` ran for real and gave concrete, non-hypothetical
findings:

- **Hard failure, fixed:** `baseimage-root: Missing /sysroot` - ostree
  requires this directory to exist (it's where the real root gets mounted
  at deploy time). Fixed with a plain `mkdir -p /sysroot`.
- **Warning, fixed:** `baseimage-composefs` - added
  `/usr/lib/ostree/prepare-root.conf` to opt into composefs, which current
  bootc/ostree expect by default.
- **Warning, fixed:** `nonempty-run-tmp` / `var-log` - build-time cruft in
  `/run`, `/tmp`, apt/debconf caches and logs. Cleaned up in the same layer
  that installs the packages that created it.
- **Warning, not yet addressed:** `sysusers` - Ubuntu's default `ubuntu`
  user (and `dhcpcd`) exist as plain `/etc/passwd` entries rather than
  systemd `sysusers.d` declarations. ostree-based systems expect users to
  be declared this way so `/etc` can be layered/reset correctly across
  deployments. Real fix is either dropping the default `ubuntu` user from
  the base image (it doesn't belong in a generic OS image anyway) or adding
  proper `sysusers.d` entries - not done yet.
- **Warning, not yet addressed:** `var-tmpfiles` / `nonempty-boot` - a
  stock Debian/Ubuntu rootfs keeps a lot of persistent state directly under
  `/var` and leftover kernel build artifacts under `/boot`
  (`System.map-*`, `config-*`) that ostree instead expects to be either
  empty, declared via systemd `tmpfiles.d`, or simply not present. Fedora's
  bootc images get this "for free" from years of upstream packaging work
  tuned for ostree; matching it on Ubuntu means auditing what's actually in
  `/var` post-install and either trimming it or writing `tmpfiles.d`
  entries for it. Non-trivial, left as follow-up rather than solved here.

None of the remaining warnings fail the build (only `baseimage-root` did),
so they're tracked here rather than blocking progress on the actual
question this repo is testing: whether the image deploys and boots.

## `bootc-image-builder` finding: it assumes dracut

Once the image passed `bootc container lint`, the next real test was
converting it to a disk image with
[`bootc-image-builder`](https://github.com/osbuild/bootc-image-builder) -
itself a Fedora/CentOS-authored tool. It failed with:

```
error: cannot build manifest: failed to run lsinitrd --mod --kver 6.17.0-41-generic: exit status 127
Error: crun: executable file `lsinitrd` not found in $PATH
```

`bootc-image-builder` shells into the *target* image and runs `lsinitrd`
(part of Fedora's `dracut` package) to introspect the initramfs while
generating the disk manifest. Ubuntu's default initramfs tooling is
`initramfs-tools`, which doesn't ship `lsinitrd` - or produce an initrd in
a format that tool expects - at all. This is a second, independent Fedora
assumption baked into the tooling around bootc, not just bootc itself.

Fix: install `dracut` (packaged in Ubuntu's `questing` release, confirmed
via packages.ubuntu.com) and use it to generate the initramfs instead of
`initramfs-tools`, so what `lsinitrd` inspects is an actual dracut-built
initrd rather than just having the binary present with nothing valid to
read. Built with `--no-hostonly`, since the build container's hardware
isn't the target machine's.

## Status

Early-stage PoC. Read the Actions run history for current pass/fail state
rather than assuming this README is up to date with it.
