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

## `bootc-image-builder` finding: it doesn't know Ubuntu's default filesystem

Past the `lsinitrd` fix, the next failure was:

```
error: cannot build manifest: failed to initialize bootc distro: missing required info: DefaultRootFs
```

`bootc-image-builder` keeps an internal table of known distros
(Fedora/CentOS/RHEL) with a default root filesystem type for each. Ubuntu
isn't in that table, so it has nothing to fall back to. This is real
evidence of the tool being written for a fixed, Fedora-family distro set -
but it's not a hard wall: the tool ships a `--rootfs` flag precisely for
images it doesn't recognize (confirmed via its own GitHub issues, e.g.
"no default root filesystem type specified in container, please use
'--rootfs' to set manually"). Fixed by passing `--rootfs ext4` explicitly
in the workflow.

## `bootc-image-builder` finding: it assumes SELinux, unconditionally

Past both fixes above, the build reached actual disk-image assembly and
failed differently:

```
subprocess.CalledProcessError: Command '['setfiles', '-F', '-r', '/run/osbuild/tree', ...,
  '/run/osbuild/tree/etc/selinux/targeted/contexts/files/file_contexts', '/run/osbuild/tree/']'
  returned non-zero exit status 255.
```

The underlying `osbuild` pipeline that `bootc-image-builder` drives
includes an unconditional SELinux-relabeling stage for any ostree/bootc
target - reasonable for Fedora/RHEL, which always run SELinux, but Ubuntu
defaults to AppArmor and ships no SELinux policy at all. The stage reads
`/etc/selinux/targeted/contexts/files/file_contexts` from the *target*
tree; with nothing there, `setfiles` fails outright.

Fixed by installing Ubuntu's own SELinux policy (`selinux-basics`,
`selinux-policy-default`, `policycoreutils` - all packaged, confirmed via
packages.ubuntu.com) and aliasing it to the path osbuild expects
(`ln -sfn default /etc/selinux/targeted`), since Debian/Ubuntu's policy
package uses the type name `default` rather than Fedora's `targeted`.
This makes `setfiles` see a real, internally-consistent policy rather than
a missing file. The labels it writes are inert since AppArmor - not
SELinux - is what Ubuntu's kernel actually enforces; this exists purely to
satisfy osbuild's build-time step, not to turn SELinux on at runtime.

## Pivot: dropped `bootc-image-builder`, testing `bootc install to-disk` directly

Past the SELinux fix, the build got further than ever - all the way into
actual disk assembly (GPT partition table construction) - and then failed
with:

```
FileNotFoundError: [Errno 2] No such file or directory: 'sfdisk'
```

At the time this looked like a gap in `bootc-image-builder`'s own
container orchestration (it mounts `/var/run/docker.sock`, suggesting it
dispatches some stages to sibling containers) rather than anything about
our image. **That diagnosis turned out to be wrong** - see the correction
below, where `bootc install to-disk` hits the exact same missing binary,
which only makes sense if it was always our image missing a package.

Rather than keep debugging a third-party wrapper's internal plumbing -
especially one that's [being deprecated upstream](#note-bootc-image-builder-itself-is-being-deprecated-upstream)
in favor of a different tool entirely - this repo now tests the thing it's
actually trying to prove more directly: `bootc install to-disk`, bootc's
own native disk-installation path, run straight from our built image
against a loopback-mounted raw disk file, with no osbuild/Fedora-tooling
layer in between. This is also a more faithful test of the real question
(does bootc/ostree's own logic work on Ubuntu) than routing through a tool
built and tuned for Fedora's ecosystem.

First attempt ran it via plain `docker run` and failed immediately with
`Either --source-imgref must be defined or this command must be executed
inside a podman container` - `bootc install` figures out which image it's
installing by inspecting its own container runtime environment, which
only podman sets up. Fixed by running that one step via `podman run`
instead.

With that cleared, `bootc install to-disk` ran for real and failed with
`No root filesystem specified` - the same underlying gap as
bootc-image-builder's `DefaultRootFs` error earlier, but now hit in
bootc's own native path rather than the (now-dropped) wrapper tool.
Rather than pass a one-off CLI flag, this is fixed properly at the image
level: bootc reads install defaults from
`/usr/lib/bootc/install/*.toml` files baked into the image itself (the
same mechanism a real distro's own bootc-enabled base image would use),
so `00-ubuntu.toml` now declares `[install.filesystem.root] type = "ext4"`
directly in the `Containerfile`. This makes the image self-sufficient for
installs rather than depending on every caller remembering a flag.

## Correction: the `sfdisk` failure was ours all along

With the root-filesystem config in place, `bootc install to-disk` ran
further and failed with:

```
error: Installing to disk: Creating rootfs: Failed to run sfdisk: No such file or directory (os error 2)
```

The exact same missing binary as the `bootc-image-builder` failure earlier
- except this time it's `bootc`'s own code shelling out directly, with no
sibling-container dispatch involved at all. That retroactively disproves
the earlier theory: it was never a `bootc-image-builder` orchestration
bug, it was our image missing `sfdisk` the whole time. Recent Debian/
Ubuntu split `sfdisk`/`fdisk`/`cfdisk` out of the base `util-linux`
package into a separate `fdisk` package, so a minimal Ubuntu image
doesn't have it unless installed explicitly - confirmed via
packages.ubuntu.com, which lists `/usr/sbin/sfdisk` under `fdisk`, not
`util-linux`. Fixed by adding `fdisk` to the `Containerfile`.

Same pattern repeated one step later: with partitioning working, `bootc`
formatted the root partition (`mkfs.ext4`) fine, then failed formatting
the EFI System Partition with `mkfs.fat` - also not installed by default,
also shelled out to directly, also a separate package (`dosfstools`) on
Debian/Ubuntu. Same fix, same reason: a minimal Ubuntu image doesn't carry
partitioning/formatting tools that a Fedora-family bootc image gets for
free as part of its base package set.

Third occurrence, past both of those: `Creating imgstorage: Initializing
images: No such file or directory`. "imgstorage" is bootc's composefs
storage backend - which this image opted into via `prepare-root.conf`
above - and it stores deployed container images as EROFS filesystem
images. `mkfs.erofs` (package `erofs-utils`) wasn't installed, same
pattern again. Fixed the same way.

Worth being honest about: the earlier bootc-image-builder pivot reasoning
was built on a wrong diagnosis. The pivot to `bootc install to-disk` was
still the right call independently (it's the more direct test of the
actual question, and bootc-image-builder is being deprecated regardless),
but the specific claim that bootc-image-builder had an internal
sibling-container bug wasn't correct - it just needed the same missing
package this repo needed anyway.

## Note: `bootc-image-builder` itself is being deprecated upstream

While chasing the issues above it came up that `osbuild/bootc-image-builder`
was archived (June 2026) - its functionality is merging into a unified
`image-builder` CLI/container (`--bootc-ref` and related flags). This repo
still uses `bootc-image-builder` because it's what's currently published
and working end-to-end; the SELinux/rootfs/dracut findings above are about
`osbuild`'s manifest generation, which the unified tool inherits too, so
switching wouldn't avoid them. Worth revisiting once the unified tool
stabilizes, but not blocking this PoC's goal.

## Status

Early-stage PoC. Read the Actions run history for current pass/fail state
rather than assuming this README is up to date with it.
