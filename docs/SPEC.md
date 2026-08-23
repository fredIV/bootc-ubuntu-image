# bootc-ubuntu-image — Specification

Status: **Implemented and green**. This document specifies what the
system is, how it's built, what it proves, and — explicitly — what its
security posture is and is not. See [`ARCHITECTURE.md`](ARCHITECTURE.md)
for the chronological narrative of how each piece was discovered;
this document is the settled description of the result.

## 1. Purpose

Determine whether [bootc](https://github.com/containers/bootc)'s
container-image-based, atomic OS update model — pull an OCI image,
deploy it via `ostree`/composefs, reboot into it atomically, roll back
with one command — can run on an **Ubuntu** base instead of the
Fedora/RHEL family it's built around, with no Fedora-authored tooling
anywhere in the chain.

## 2. Scope

**In scope:**
- Building `bootc` from source against Ubuntu's packaged `libostree`.
- Assembling an Ubuntu container image that satisfies bootc's own
  image contract (`bootc container lint` passes).
- Installing that image to a raw block device with bootc's native
  `bootc install to-disk`, using bootc's composefs-native backend
  (`--composefs-backend`).
- Booting the resulting disk under QEMU/KVM with UEFI firmware (OVMF)
  to a working login prompt, unattended, in CI.

**Out of scope (not attempted here):**
- Deploying to real (non-VM) hardware.
- Multi-node fleet management, update orchestration, or rollback
  testing (bootc's rollback mechanics are unmodified upstream
  behavior, not re-verified by this project).
- Secure Boot, measured boot, or disk encryption (see §5.3).
- Long-term support / LTS base image (this targets Ubuntu 25.10
  specifically — see §6).

## 3. System Architecture

### 3.1 Build pipeline (`Containerfile`, two stages)

| Stage | Base | Produces |
|---|---|---|
| `bootc-builder` | `ubuntu:25.10` | `bootc` and `bootc-initramfs-setup` binaries, built from bootc's upstream source via `cargo build --release` |
| final image | `ubuntu:25.10` | A `containers.bootc=1` image: Ubuntu packages (`ostree`, `ostree-boot`, `dracut`, `grub-efi-amd64-bin`, `systemd-boot-efi`/`-tools`, `podman`/`skopeo`, `fdisk`, `dosfstools`) + the `bootc` binary + bootc's own `51bootc` dracut module (built and copied by hand, since this from-source build never runs bootc's `make install`) + a dracut-generated initramfs + bootc install-config (`00-ubuntu.toml`, `01-console.toml` kargs) |

The final image is a standard OCI image — no bootc-specific build step
beyond what any container image build does. `bootc container lint`
runs as the last build step and fails the build if the image doesn't
satisfy bootc's filesystem/metadata contract.

### 3.2 CI pipeline (`.github/workflows/build-and-test.yml`)

Two jobs, `ubuntu-latest` GitHub-hosted runners:

1. **`build-and-lint`**: checkout → GHCR login → `docker build` (GitHub
   token passed as a BuildKit `--secret`, not a build-arg) → explicit
   `bootc container lint` → `docker push` to `ghcr.io`.
2. **`boot-test`** (needs `build-and-lint`, skipped on `pull_request`):
   installs QEMU + podman on the runner, pulls the just-pushed image,
   reformats it to OCI manifest in place (works around
   [bootc-dev/bootc#1703](https://github.com/bootc-dev/bootc/issues/1703)),
   runs `bootc install to-disk` against a 10GB loopback file inside a
   `--privileged` podman container, then boots the resulting disk under
   `qemu-system-x86_64` with OVMF UEFI firmware and polls the serial
   console for a login prompt.

### 3.3 Install flow

```
podman run --rm --privileged --pid=host -v /dev:/dev <image> \
  bootc install to-disk --wipe --composefs-backend --allow-missing-verity <device>
```

`bootc install to-disk` runs *as a container of the image being
installed* — it determines its own source image by inspecting the
podman-specific container runtime markers of the process it's running
in (this is why the invocation must go through `podman run`, not plain
`docker run`). Once invoked, it:

1. Partitions the target device (GPT: BIOS-boot, EFI System, root).
2. Formats root as ext4 and the ESP as FAT32 (`sfdisk`/`mkfs.ext4`/`mkfs.fat`, shelled out to directly).
3. Initializes its own `containers-storage` image root on the target
   disk (execs `podman images`/`skopeo` from inside the installer
   image — this is why those two packages are in the final image at all).
4. Deploys the container image content into a composefs repository on
   the target disk (`--composefs-backend`; bypasses ostree's classic
   sysroot/deployment model entirely).
5. Installs the bootloader: detects `Bootloader::Systemd` (Ubuntu ships
   systemd-boot, not a BLS-patched grub2) and runs `bootctl install`
   directly — reachable only via the composefs-native backend, since
   bootc's classic ostree backend has no implemented bootloader-install
   path for anything but Grub.

### 3.4 Boot flow

```
UEFI (OVMF) → kernel + dracut initramfs
  → dracut's 51bootc module → bootc-root-setup.service
    → mounts the composefs EROFS image (fs-verity checked, or not — see §5.3)
    → bind-mounts/overlays /etc and /var
    → pivots real root into place
  → systemd (PID 1 in the real root) → getty → login prompt
```

The `51bootc` dracut module and its `bootc-root-setup.service` unit are
part of bootc's own upstream build output (`crates/initramfs/`), not
an Ubuntu package — Fedora's RPM packaging wires this up automatically
via `make install`; this project's from-source build reproduces that
by hand in the Containerfile (see §3.1 and `ARCHITECTURE.md` for why
the more obvious `ostree-boot` package was tried first and confirmed
wrong — it drives a different, classic-ostree-only boot path).

## 4. Functional requirements — status

| Requirement | Status | Evidence |
|---|---|---|
| Build `bootc` from source against Ubuntu's `libostree` | ✅ Met | `build-and-lint` job, every green run |
| Image satisfies bootc's own contract | ✅ Met | `bootc container lint` passes in-build and as an explicit CI step |
| Install to a real block device via bootc's native path | ✅ Met | `Installation complete!` in `boot-test` logs |
| Boot the installed disk to a working login prompt | ✅ Met | [Run #30](https://github.com/fredIV/bootc-ubuntu-image/actions/runs/32646473638): `localhost login:` in 38s, no manual intervention |
| No Fedora-authored tooling in the chain | ✅ Met | `bootc-image-builder` (Fedora/osbuild) was tried and dropped in favor of bootc's own `install to-disk` |
| Reproducible in CI, not a one-off | ✅ Met | Two consecutive green runs (#30, #31) on stock `ubuntu-latest` runners |

## 5. Security posture & threat model

This section states plainly what is and isn't protected against. It is
written for a **CI-driven proof-of-concept**, not a production image —
treat §5.3 as a punch list if this were ever adapted for real deployment.

### 5.1 Trust boundaries

```
┌─ GitHub Actions runner (ephemeral, GitHub-operated VM) ─────────────┐
│                                                                       │
│  ┌─ docker build (unprivileged) ─┐        ┌─ podman run --privileged ─┐
│  │ fetches: api.github.com,      │        │ effectively host-root for  │
│  │ github.com, archive.ubuntu    │        │ the duration of the install│
│  │ .com, sh.rustup.rs            │        │ (raw block-device access,  │
│  │ writes: image layers only     │        │ full device namespace)     │
│  └────────────────────────────────┘        └────────────────────────────┘
│                    │                                    │
│                    ▼                                    ▼
│              ghcr.io (push)                      loopback disk.raw
│              [public, unsigned]                  [ephemeral, destroyed
│                                                    at job end]
└───────────────────────────────────────────────────────────────────────┘
```

The only secret in the system is `secrets.GITHUB_TOKEN` (GHCR
read/write, scoped by the workflow's `permissions:` block). It never
enters a Docker layer: the Containerfile receives it only via a
BuildKit `--secret` mount (`/run/secrets/gh_token`, not an `ARG`/`ENV`).

### 5.2 Mitigations already in place

- **Least-privilege workflow permissions**: `contents: read, packages:
  write` — not the GitHub Actions default of broader scope.
- **Fork-PR isolation**: `pull_request` events never push images or run
  the privileged `boot-test` job (`if: github.event_name !=
  'pull_request'`), so an external PR can't trigger the `--privileged`
  podman invocation or exfiltrate the GHCR push token.
- **Secret hygiene**: the GitHub token used inside the build never
  lands in image history (BuildKit secret mount, verified by design —
  `docker history` on the built image shows no token).
- **Minimal installed surface**: `--no-install-recommends` on every
  `apt-get install`.

### 5.3 Known gaps (accepted risk for a PoC; would need addressing before any real deployment)

| Gap | Detail | Why it's not fixed here |
|---|---|---|
| No pinning/verification of `bootc`'s source | `git clone --branch "$(latest release tag from GitHub API)"` — no commit pin, no GPG/sigstore verification of the tag | The project deliberately tracks upstream's latest release rather than pin a version, to keep testing current bootc behavior |
| `curl \| sh` for rustup | Standard Rust install method; no checksum pinned before execution | Matches rustup's own documented install method; TLS certificate pinning (`--proto '=https' --tlsv1.2`) is the only mitigation applied |
| Ubuntu base pinned by tag, not digest | `FROM ubuntu:25.10` can resolve to a different image over time | Reproducibility trade-off not yet addressed |
| `--allow-missing-verity` | Disables fs-verity enforcement for the composefs backend — the deployed root has no cryptographic integrity verification at boot | The GitHub Actions runner's loopback-formatted ext4 doesn't reliably support fs-verity; a real target disk formatted with fs-verity support wouldn't need this flag |
| No image signing | Pushed GHCR image carries no cosign/sigstore attestation | Not yet implemented |
| No vulnerability scanning | No Trivy/Grype (or similar) step in CI | Not yet implemented |
| No Secure Boot / measured boot | OVMF runs without Secure Boot enrollment; no shim, no MOK, no TPM measurement | Out of scope — this tests the bootc/ostree model itself, not a hardened boot chain |
| No disk encryption | Root and ESP are both plaintext | Out of scope for this PoC |
| `--privileged --pid=host -v /dev:/dev` | Full host device/process-namespace access during install | Inherent to how `bootc install to-disk` works on **any** distro — not specific to this repo or fixable without bootc itself changing its install model |

**Net position**: this pipeline is secure *in the sense that matters
for a CI-driven feasibility test* — secrets don't leak, fork PRs can't
escalate, and the attack surface is scoped to what the test genuinely
needs. It is explicitly **not** hardened for production or real
hardware, and §5.3 is the list of what that would require.

## 6. Known limitations

- Targets Ubuntu 25.10 ("questing"), an interim release, not an LTS —
  neither current LTS (22.04, 24.04) ships a `libostree` new enough for
  bootc's current release (`>= 2025.3`). This means the base tracks a
  9-month support window, not 5 years.
- Uses bootc's **composefs-native** install backend, which upstream
  documents as experimental — chosen because bootc's classic ostree
  backend has no implemented bootloader-install path for systemd-boot
  (Ubuntu's default), only for BLS-patched grub2 (Fedora's default).
- Hit and worked around one confirmed, still-open upstream bug
  ([bootc-dev/bootc#1703](https://github.com/bootc-dev/bootc/issues/1703)).
- Boot-tested only under QEMU/KVM; never tested on physical hardware.

## 7. References

- [bootc](https://github.com/containers/bootc) — the tool this project builds and tests.
- [ostree](https://github.com/ostreedev/ostree) — the filesystem-versioning layer bootc builds on.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — full chronological finding-by-finding writeup.
- [bootc-dev/bootc#1703](https://github.com/bootc-dev/bootc/issues/1703) — the upstream bug this project worked around.
