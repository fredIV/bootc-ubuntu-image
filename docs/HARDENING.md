# Hardening roadmap

This branch (`hardening`) builds on the working PoC in `main` — see
[`SPEC.md`](SPEC.md) §5 for the security posture that motivated it. That
section asked "is this hardened?" and answered honestly: no. This
document is the punch list, turned into tracked work, in the order it's
being tackled and why.

**Scope note:** this is explicitly a *different* goal from `main`.
`main` answers "does bootc/ostree work on Ubuntu at all" — that
question is closed, green, and shouldn't be disturbed. This branch
answers "what would it take to make that image production-safe,"
which is a security-engineering problem, not a systems-feasibility one.
Where the two goals conflict (see the fs-verity item below), that
tension gets written down, not papered over.

## Status

| # | Item | Status | Notes |
|---|---|---|---|
| 1 | Pin the Ubuntu base image by digest, not tag | 🟡 In progress | CI now resolves and logs the digest at build time (see workflow diff); committing it as the default pin is the next step, once a real resolved value exists in a CI run to copy from — this sandbox can't reach Docker Hub to resolve one by hand |
| 2 | Vulnerability scanning gate before push | 🟡 In progress | Trivy added as a CI step, `CRITICAL,HIGH` fails the build; SARIF uploaded to GitHub code scanning |
| 3 | Image signing (cosign/sigstore, keyless via GitHub OIDC) | ⬜ Not started | |
| 4 | Enforce fs-verity instead of `--allow-missing-verity` | ⬜ Not started, likely hard | See "the tension" below — this may not be resolvable inside GitHub Actions' loopback-disk environment at all, only on a real target disk |
| 5 | SBOM generation, published alongside the image | ⬜ Not started | |
| 6 | Secure Boot / signed bootloader chain | ⬜ Not started | Needs a signed shim + MOK enrollment story; out of scope for a QEMU test loop, real item for real hardware |
| 7 | SELinux enforcing (replace the inert alias) or a real AppArmor profile set | ⬜ Not started | Current alias only satisfies an unused build-time tool; does nothing at runtime |
| 8 | Move off an interim Ubuntu release onto a supported LTS-equivalent stream | ⬜ Not started | Blocked upstream: no current LTS ships a `libostree` new enough for bootc's release floor — revisit each Ubuntu release |
| 9 | Disk encryption (LUKS, ideally TPM-bound) | ⬜ Not started | |

## The tension worth naming: item 4

`--allow-missing-verity` exists because bootc's composefs-native backend
hard-requires fs-verity-capable storage unless told otherwise, and the
GitHub Actions runner's loopback-formatted ext4 didn't reliably support
it when this was first hit (`main`, `boot-test` job history). Bootc's
own install log already requests it correctly —
`mkfs.ext4 -O verity` is in the trace — so the gap isn't "nobody asked
for verity," it's some combination of the loopback block device, the
runner's kernel, or ext4's verity feature needing something this
environment doesn't provide. Removing the flag without root-causing
that will just turn a working CI pipeline back into a red one, so this
item needs actual investigation (read bootc's fs-verity detection code,
test what `tune2fs -l` reports on the formatted loopback device, check
whether the *host* kernel's `CONFIG_FS_VERITY` is what's actually being
probed) before it gets touched — not a flag flip.

## Why this order

Items 1–2 are mechanical, CI-only, and don't touch the image's runtime
behavior at all — lowest risk, verify cleanly, and are worth doing
regardless of what happens with the harder items. Item 3 (signing) is
next because it's also CI-only and orthogonal to the image's contents.
Items 4 and 6–9 all require changing what the deployed system actually
*is* (verity-capable storage, a signed boot chain, MAC enforcement, an
encrypted disk) and need to be sequenced deliberately, verified the
same way `main` was — in CI, against a real boot, not asserted.
