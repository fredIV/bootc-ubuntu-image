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
storage backend - which this image had opted into via `prepare-root.conf`
(in response to a `bootc container lint` warning suggesting it) - and it
stores deployed container images as EROFS filesystem images. The first
theory was a missing `mkfs.erofs` (package `erofs-utils`), matching the
pattern of every prior fix in this section.

**That theory was wrong.** Installing `erofs-utils` and re-running
produced the exact same error, byte for byte - meaning `mkfs.erofs` was
never the blocker. Composefs is documented upstream as bootc's
*experimental* storage backend (ostree's classic deployment mechanism is
still the default, production one), and its own image-storage
initialization here failed with no further detail to go on without
digging into bootc's Rust source directly, which was more effort than
this PoC's actual question warrants. Rather than keep guessing at an
underdocumented failure in an admittedly experimental code path, the
`prepare-root.conf` composefs opt-in was reverted (`enabled = true` ->
commented out) - falling back to what looked like bootc/ostree's default
backend instead.

**That went one step too far.** Removing the file's contents entirely
surfaced a build-time regression unrelated to composefs (see the cpio
finding below), and once that was fixed, `bootc install to-disk` failed
with a new, blunter error: `Failed to find ostree/prepare-root.conf in
/usr/lib or /etc`. Turns out the file's *existence* is required by
`bootc install` regardless of backend - `bootc container lint`'s
"warning" framing undersold that. The actual fix: keep the file, just
declare composefs off explicitly (`enabled = false`) instead of deleting
its contents. Net result is the same as intended - default ostree
backend, no composefs - but by editing the config's value rather than
removing the file whose presence bootc apparently requires outright.

This whole detour is worth being explicit about: enabling composefs in
the first place was our own choice, made in response to a soft lint
*warning*, not a hard requirement, and turning it back off isn't a
compromise on the actual thing this repo is testing.

**The data point that finally cracked it:** with `prepare-root.conf`
present and composefs explicitly set to `enabled = false`, `bootc install
to-disk` failed with the *exact same* `Creating imgstorage: Initializing
images: No such file or directory` - byte for byte identical to the
composefs-enabled failure. That ruled out composefs as the cause entirely,
in either direction, and meant the answer wasn't in any config file,
`bootc container lint` output, `bootc --help`, or the public GitHub
issues/docs searched over the course of this investigation.

So: bootc's own Rust source
(`crates/lib/src/podstorage.rs` in `bootc-dev/bootc`). The function
`imgstorage::create()` is annotated `#[context("Creating imgstorage")]`,
and inside it:

```rust
new_podman_cmd_in(&sysroot, &storage_root, &run)?
    .stdout(Stdio::null())
    .arg("images")
    .run_capture_stderr()
    .context("Initializing images")?;
```

"imgstorage" has nothing to do with composefs at all - it's bootc setting
up a `containers-storage:`-format root on the target disk (podman's own
storage format) to hold deployed container images, and it initializes
that root by literally **executing `podman images`** inside it.
`new_podman_cmd_in` builds that command via `Command::new(bootc_utils::podman_bin())`,
and `podman_bin()` (in `crates/utils/src/lib.rs`) just returns the literal
string `"podman"` - a plain `$PATH` lookup, overridable only via an
undocumented `BOOTC_EXP_EXTERNAL_CONTAINER_TOOL` env var.

`bootc install to-disk` runs *as a container of the image being
installed* (that's why it has to run under `podman run <image> bootc
install to-disk` rather than as a standalone binary) - so when it execs
`podman` mid-install, it's looking for `podman` inside **that same
image's own filesystem**, not on the CI host. This image never had
`podman` installed in it: `podman` was only ever installed on the CI
*runner*, to be able to run `podman run <image> bootc install to-disk`
in the first place. The container being installed had no `podman` binary
of its own to exec, hence a bare ENOENT with no indication of what was
missing. `crates/lib/src/deploy.rs` shows `skopeo` used the same way
elsewhere in the deploy path, so both are now installed in the image
(`podman skopeo`, both packaged in Ubuntu 25.10 - confirmed via
packages.ubuntu.com before adding).

This is, in the end, the exact same category of finding as every other
fix in this document - a tool bootc shells out to that a Fedora-family
bootc image has "for free" (Fedora's own container tooling ships podman/
skopeo as part of its base expectations) and Ubuntu doesn't. It just took
reading the actual source to find, because unlike `sfdisk`/`mkfs.fat`/
`mkfs.erofs`, the missing binary's name never appeared anywhere in the
error output.

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

## Status (as of this writing)

**Proven, with real CI evidence (not assumption):**

- An Ubuntu 25.10 base can be turned into a genuine `bootc`-compatible
  container image: `bootc container lint` passes cleanly, meaning the
  image satisfies bootc/ostree's actual filesystem contract (kernel/
  initrd layout, `/sysroot` + `/ostree` symlink, install config,
  container labels) - not a Fedora-only checklist. `build-and-lint` has
  been green and reproducible across many runs.
- `bootc` itself builds and runs fine against Ubuntu's packaged
  `libostree` once the version floor is met (25.10, not the LTS
  releases - see the version-gap table above).
- `bootc install to-disk` - bootc's own native install path, no
  Fedora-authored tooling involved - gets meaningfully far on Ubuntu: it
  correctly identifies its own source image (via podman), partitions a
  real disk with `sfdisk`, formats both the root filesystem (`mkfs.ext4`)
  and the EFI System Partition (`mkfs.fat`), all using ordinary Ubuntu
  packages (`fdisk`, `dosfstools`) that the Fedora ecosystem doesn't need
  to think about but Ubuntu does.
- The blocker that survived every config/package theory
  (`Creating imgstorage: Initializing images: No such file or directory`,
  unaffected by the composefs setting either way) had a confirmed root
  cause straight from bootc's Rust source: it execs `podman images`
  inside the image being installed to set up its own container storage,
  and this image never had `podman` installed in it (only the CI host
  did, to run `podman run <image> bootc install to-disk` in the first
  place). `skopeo` is used the same way elsewhere in the deploy path.
  **Confirmed fixed via CI** once both were installed: imgstorage
  initialized and the full container image (10 layers) deployed
  successfully - the furthest the install path has gotten.

## Bootloader install: Ubuntu's systemd-boot has no path in bootc's classic backend

Once imgstorage/deploy started working, `bootc install to-disk` got
further and hit a new, later failure:

```
Bootloader: systemd
...
error: Installing to disk: bootupd is required for ostree-based installs
```

bootc auto-detects the target's bootloader from the image contents
(`crates/lib/src/install.rs`, `supports_bootupd`/`detected_bootloader`
logic). It picked `Bootloader::Systemd` for this image - not `Grub` -
because Ubuntu's `systemd` packaging ships systemd-boot's EFI stub, and
this image never installed a BLS-patched grub2 the way Fedora does.

Reading `crates/lib/src/install.rs` directly (around the point it bails)
shows the actual match statement:

```rust
match postfetch.detected_bootloader {
    Bootloader::Grub => {
        crate::bootloader::install_via_bootupd(
            ...
        )?;
    }
    Bootloader::Systemd | Bootloader::GrubCC => {
        anyhow::bail!("bootupd is required for ostree-based installs");
    }
    ...
}
```

Only `Bootloader::Grub` has a real implementation behind it
(`install_via_bootupd`, which shells out to Fedora/CoreOS's `bootupd`/
`bootupctl` tooling - not packaged for Ubuntu at all). The
`Bootloader::Systemd` arm isn't "try bootupd and fail" - it's a hardcoded
bail with no attempt made. This looked, at first, like the architectural
wall this whole project exists to test for: no BLS-grub, no bootupd, no
systemd-boot support in the classic ostree install path.

But `crates/lib/src/bootloader.rs` (read in full) has a second,
completely implemented function sitting right next to
`install_via_bootupd`: **`install_systemd_boot`**, which installs
systemd-boot with plain `bootctl install --root ... --esp-path ...` -
no bootupd, no Fedora tooling, nothing Ubuntu couldn't run. The question
became: why does the classic install path never call it?

Grepping the whole `bootc` source tree for where `install_systemd_boot`
is actually called answers that: it's only invoked from
`crates/lib/src/bootc_composefs/boot.rs`, inside the non-Grub branch of a
bootloader-install `match` that's structurally identical to the one in
`install.rs` above - same three-way split (Grub/GrubCC via bootupd,
s390x via zipl, everything else via `install_systemd_boot`) - but this
one actually has a working arm for `Bootloader::Systemd` instead of a
bail.

`bootc_composefs/boot.rs` belongs to a second, entirely separate install
backend: bootc's composefs-native backend (`crates/lib/src/install.rs`,
the `if state.composefs_options.composefs_backend { ... }` branch around
line 2024). It bypasses ostree's classic sysroot/deployment model
altogether - a different repository format, a different deploy
mechanism, gated behind the `--composefs-backend` CLI flag
(`InstallComposefsOpts::composefs_backend` in `install.rs`). Whichever
backend is selected decides which entire bootloader `match` statement
runs; the classic backend's arm for `Bootloader::Systemd` was simply
never implemented, because Fedora/RHEL images always resolve to `Grub`.

One thing worth being explicit about, since this project already spent a
whole detour on composefs once: **this is a different composefs switch
than the one this repo already has an opinion on.** The
`/usr/lib/ostree/prepare-root.conf` `[composefs] enabled` setting (still
`false` in this image) controls whether the *classic* ostree backend uses
composefs as its own internal object-storage format - unrelated to which
install backend runs at all, and already confirmed (by testing both
values in CI) to have no effect on any of the errors seen so far. The
`--composefs-backend` CLI flag is a completely different, higher-level
switch: it picks the composefs-native backend over the classic one
entirely, before any of that config file is even consulted. Confirmed by
reading both code paths, not guessed.

Given that, the fix committed here is to install using
`bootc install to-disk --composefs-backend --allow-missing-verity`. That
flag is what actually reaches the working `install_systemd_boot` code -
not a workaround, but bootc's own documented (if experimental) answer for
exactly this situation: a target where the classic path's bootloader
support doesn't apply. `--allow-missing-verity` is needed alongside it
because the composefs-native backend hard-requires fs-verity-capable
storage unless told otherwise, and there's no guarantee our loopback disk
image's filesystems have that enabled.

This also meant installing one more package: `bootctl install` copies its
EFI stub binaries from `/usr/lib/systemd/boot/efi/`, which only exists
with `systemd-boot-efi` installed (`bootctl` itself comes from `systemd`,
already present transitively, but not the stub it needs to copy) - found
by reading `install_systemd_boot`'s body directly rather than guessing
from the CLI's own `--help` output.

## Composefs-native backend hits an open upstream bug on registry-pulled images

Re-running CI against `--composefs-backend` got further than ever -
past imgstorage, past deploy, into disk partitioning and both
filesystem formats (`mkfs.ext4 -O verity`, `mkfs.fat`) - then failed
with:

```
error: Installing to disk: Getting container info: failed to invoke
method GetBlob: locating item named
"sha256:db8f07dcc0c2f4f7e65c7771ddfe87e45e5ffa083a98794e4ef9a648e75e10bf"
for image with ID
"d161385000e16278b0f79f514577de75bcd4c69508f8a16d67da4a75614d90d0"
(consider removing the image to resolve the issue): file does not exist
```

The referenced blob digest doesn't match any of the 10 layer blobs the
preceding `podman pull` actually copied (visible earlier in the same
log) - the composefs-native backend is looking up a blob under a digest
that was never fetched at all, not a corrupted/partial download.

Searching bootc's own issue tracker for this exact error text (rather
than guessing at another missing package) found
[bootc-dev/bootc#1703](https://github.com/bootc-dev/bootc/issues/1703),
"composefs fails with Docker v2s2 images" - open, unresolved, same error
shape (`GetBlob` failing to find a layer digest under a given image
config ID), explicitly reproduced by pulling a **Docker v2 schema-2**
image from a registry rather than building it locally. That's exactly
this pipeline's shape: `docker build` + `docker push` to GHCR produces a
Docker-schema manifest by default, then a separate job on a separate
runner does a fresh `podman pull` of it before installing. This isn't
an Ubuntu-specific or Fedora-vs-Ubuntu finding at all - it would hit a
Fedora-built bootc image the same way, on any two-machine build→pull
workflow (which is the normal way images actually get deployed).

Since the upstream issue's own title names the trigger condition
precisely, tried a targeted fix rather than accepting it as a wall
outright: reformat the already-pulled image's stored manifest to OCI
(`skopeo copy --format oci containers-storage:$IMAGE
containers-storage:${IMAGE}-oci`) before handing it to `bootc install
to-disk`. Same blobs, same digests - just OCI-typed metadata instead of
Docker's - so no extra network fetch, and it directly targets what
#1703 says triggers the bug.

**Confirmed fixed via CI.** The OCI-reformat workaround worked cleanly -
the `GetBlob` error is gone entirely, and the pipeline got further than
ever: through partitioning, both filesystem formats (`mkfs.ext4 -O
verity`, `mkfs.fat`), bootloader auto-detection, and into
`install_systemd_boot()` itself - confirming the source-reading
hypothesis from the previous section was correct, not just plausible.

## bootctl itself is a separate package on recent Debian/Ubuntu

The next failure, right after `Installing bootloader via systemd-boot`:

```
error: Installing to disk: Setting up composefs boot: Installing
bootloader: No such file or directory (os error 2)
```

`install_systemd_boot`'s `#[context("Installing bootloader")]`
attribute matches this exactly, and "No such file or directory (os
error 2)" is Rust's characteristic message for a process failing to
*exec* at all (`ENOENT` from `Command::spawn`) - not bootctl running and
reporting its own error (which `run_capture_stderr()` would have
surfaced as readable bootctl output). That distinction mattered: it
meant `bootctl` itself wasn't found on `$PATH`, not that it ran and hit
a missing file internally.

The Containerfile had assumed `bootctl` came for free with the base
`systemd` package (true historically) and only added `systemd-boot-efi`
for the EFI stub binaries `bootctl install` copies. Checking Debian's
own manpage index directly (rather than guessing another package name)
showed that's no longer true: `bootctl`'s manpage lives under
`systemd-boot-tools` on Debian trixie/testing/unstable, split out of the
base `systemd` package - and Ubuntu 25.10 tracks that generation of
Debian's systemd closely. Added `systemd-boot-tools` alongside
`systemd-boot-efi`. Same category of finding as `fdisk`/`dosfstools`/
`podman`/`skopeo` before it: a tool a Fedora-family bootc image doesn't
need to think about (Fedora hasn't made this particular package split),
Ubuntu does - not architectural, just another gap in the "what does a
non-Fedora distro need installed explicitly" list this whole project is
mapping out.

**Not yet confirmed via CI as of this writing.**

**Net assessment:** the image-level compatibility question - can an
Ubuntu base satisfy bootc's own contract - is answered *yes*, cleanly,
and reproducibly. The install/deploy path has turned out to be a mix of
both kinds of gap this project set out to distinguish: mostly missing
packages a Fedora-family image carries for free (`sfdisk`, `mkfs.fat`,
`podman`/`skopeo`, now `systemd-boot-efi`) - but the bootloader-install
finding above is the first one that's genuinely architectural rather than
a missing binary: bootc's classic ostree backend was written assuming
every target resolves to a BLS-patched grub, and Ubuntu's systemd-boot
default doesn't fit that assumption at all. Whether bootc's own
composefs-native backend is a real answer to that, or just trades one
unfinished path for a different unfinished one, is what the next CI run
tests.

Read the Actions run history for current pass/fail state rather than
assuming this document is up to date with it.
