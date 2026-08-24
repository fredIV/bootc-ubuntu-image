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
| 1 | Pin the Ubuntu base image by digest, not tag | 🟡 In progress | Confirmed working in CI ([run #34](https://github.com/fredIV/bootc-ubuntu-image/actions/runs/32677580100)) - digest is resolved and logged at build time. Committing it as the hardcoded default is the next step, once that value is copied out of a real run - this sandbox can't reach Docker Hub to resolve one by hand |
| 2 | Vulnerability scanning gate before push | 🟡 In progress, weaker than it looks | Confirmed running in CI via Trivy's own container image pinned by digest (not the `aquasecurity/trivy-action` wrapper - see incident note below). But the scan itself reported it can't meaningfully check this base image at all - see "the scan that can't scan" below. The mechanism is real; its current protective value on `ubuntu:25.10` specifically is close to zero |
| 3 | Pin third-party GitHub Actions by commit SHA, not version tag | ⬜ Not started | New item, added after the trivy-action incident (below) proved this isn't theoretical. `actions/checkout@v4`, `docker/login-action@v3`, `github/codeql-action/upload-sarif@v3` are all still tag-pinned as of this writing |
| 4 | Image signing (cosign/sigstore, keyless via GitHub OIDC) | ⬜ Not started | |
| 5 | Enforce fs-verity instead of `--allow-missing-verity` | ⬜ Not started, likely hard | See "the tension" below — this may not be resolvable inside GitHub Actions' loopback-disk environment at all, only on a real target disk |
| 6 | SBOM generation, published alongside the image | ⬜ Not started | |
| 7 | Secure Boot / signed bootloader chain | ⬜ Not started | Needs a signed shim + MOK enrollment story; out of scope for a QEMU test loop, real item for real hardware |
| 8 | SELinux enforcing (replace the inert alias) or a real AppArmor profile set | ⬜ Not started | Current alias only satisfies an unused build-time tool; does nothing at runtime |
| 9 | Move off an interim Ubuntu release onto a supported LTS-equivalent stream | ⬜ Not started | Blocked upstream: no current LTS ships a `libostree` new enough for bootc's release floor — revisit each Ubuntu release |
| 10 | Disk encryption (LUKS, ideally TPM-bound) | ⬜ Not started | |

## Incident that reshaped item 2: trivy-action, 2026-03-19

The first implementation of item 2 used the `aquasecurity/trivy-action`
GitHub Action, pinned to a version tag. Getting that tag *right* turned
out to be moot: on 2026-03-19, attackers force-pushed malicious code
into 75 of that repo's 76 version tags, exfiltrating CI/CD secrets from
every pipeline that referenced any of them by tag - while the scans
themselves kept appearing to succeed, so nothing looked wrong from the
calling workflow's side ([aquasecurity/trivy advisory
GHSA-69fq-xp46-6x23](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23)).
It was the second compromise of Trivy's infrastructure inside three
weeks, using credentials obtained in the first.

This is the exact failure mode item 1 exists to close - a mutable
reference silently repointing to something other than what was
reviewed - just landing on a CI *dependency* instead of the base image.
The fix applied here: stop trusting the Action wrapper at all, and run
Trivy's own published container image directly, pinned to a digest
resolved in CI the same way `ubuntu:25.10` is (see the workflow diff).
That removes a whole third-party Action from the trust chain rather
than picking a tag of it and hoping it stays clean - which is also why
item 3 above exists now: the same reasoning applies to every other
tag-pinned Action still in this workflow, this one was just the one
that got proven.

## The scan that can't scan: item 2's real result

The first real run of the Trivy gate ([run #34](https://github.com/fredIV/bootc-ubuntu-image/actions/runs/32677580100))
reported **0 CRITICAL/HIGH findings** - which reads like a clean bill of
health, but isn't one. The scan's own log carried this alongside the
result:

```
WARN  This OS version is no longer supported by the distribution  family="ubuntu" version="25.10"
WARN  The vulnerability detection may be insufficient because security updates are not provided
```

Ubuntu interim releases like 25.10 don't get an ongoing Ubuntu Security
Notices feed the way LTS releases do, and Trivy's OS-package vulnerability
matching depends on exactly that feed. "0 findings" here means *nothing
was checked against current advisory data*, not *nothing was found*. The
gate is real and will do its job the moment there's a feed for it to
check against - but as long as this image is built on 25.10, it's
providing close to no actual assurance for OS-level packages, only for
anything Trivy's separate secret-scanning and language-ecosystem checks
would catch.

This makes item 9 (move to a supported release stream) load-bearing for
item 2 to mean anything, not just a separate, lower-priority item on the
list - a vulnerability gate on an unsupported OS is closer to a
compliance checkbox than a real control.

## The tension worth naming: item 5

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

Items 1–4 are mechanical, CI-only, and don't touch the image's runtime
behavior at all — lowest risk, verify cleanly, and are worth doing
regardless of what happens with the harder items. Item 5 (fs-verity) and
items 7–10 all require changing what the deployed system actually *is*
(verity-capable storage, a signed boot chain, MAC enforcement, an
encrypted disk) and need to be sequenced deliberately, verified the
same way `main` was — in CI, against a real boot, not asserted.
