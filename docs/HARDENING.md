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
| 3 | Pin third-party GitHub Actions by commit SHA, not version tag | 🟡 In progress | All six `uses:` references in this workflow (`actions/checkout`, `docker/login-action` ×2, `github/codeql-action/upload-sarif`, `actions/upload-artifact`) are now SHA-pinned, with the resolved tag kept as a trailing comment. `codeql-action` was bumped to v4 while at it (the v3 line was already logging a deprecation notice). See the verification note below - this sandbox has no reliable way to query these repos' git data directly, so the SHAs were cross-checked by fetching each release page independently rather than trusted from a single lookup |
| 4 | Image signing (cosign/sigstore, keyless via GitHub OIDC) | 🟡 In progress | Pushed image is signed keylessly (`cosign sign`, no private key generated or stored anywhere) and `boot-test` now refuses to install anything that doesn't verify against this repo's own CI identity. Both directions run via cosign's own container image, digest-pinned the same way as Ubuntu/Trivy — see "How item 4 was verified" below |
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

## How item 3's SHAs were actually verified

This session's GitHub access is scoped to this repo only - no direct
API access to `actions/checkout`, `docker/login-action`,
`github/codeql-action`, or `actions/upload-artifact` to read their tag
data, and `api.github.com` itself is unreachable from here. The SHAs
committed for item 3 came from fetching each repo's own release page
and reading the commit hash off it - the same class of lookup that
went wrong earlier in this branch's history (the first `trivy-action`
version tag was guessed and didn't exist at all). To not repeat that,
each one was either cross-checked with a second, independent fetch of
the same release (`docker/login-action`) or corroborated against an
earlier, separate search result that agreed on the same hash prefix
(`actions/checkout`) before being committed. `docker/login-action` and
`actions/upload-artifact` resolved to releases from early-to-mid 2024,
while `actions/checkout` and `codeql-action` resolved to releases from
the past few days - consistent with each project's real release
cadence rather than a suspiciously uniform "recent-looking" result,
which is some evidence against a fabricated answer, though not a
substitute for verifying directly with `gh api` or the GitHub UI. If
CI fails on any of these with an "unknown revision" style error, that
means one of them is wrong; check it, don't just retry.

## How item 4 was verified

Signing alone isn't a control — it's only one if something refuses to
proceed when verification fails. So this is two changes, not one: a
`Sign the pushed image` step at the end of `build-and-lint`, and a
`Verify the image's cosign signature before installing it` step at the
*start* of `boot-test`, before anything from the image is trusted enough
to run `bootc install to-disk` against a real (if loopback) block device.

Both steps run `ghcr.io/sigstore/cosign/cosign`, pinned to a digest
resolved in CI the same way `ubuntu:25.10` and `aquasec/trivy` are —
this session has no way to confirm from here that `v3.1.3` is a real,
existing tag any more than it could confirm the Action SHAs in item 3;
the workflow will fail loudly and specifically if it isn't, which is
the same acceptable-verifier tradeoff made there. `v3.1.3` was picked
deliberately over the `v2.x` line still referenced in cosign's own
README examples: it backports a fix for
[GHSA-fx35-mq7g-6g98](https://github.com/sigstore/cosign/security/advisories/GHSA-fx35-mq7g-6g98),
a signature-verification bypass — using an older, vulnerable version of
the *verification* tool in the one step whose entire job is verification
would have undercut the point of adding it.

The signing side is keyless: no private key is generated, stored in a
GitHub secret, or rotated by anyone. `cosign sign` exchanges the job's
short-lived OIDC token (`permissions: id-token: write`, scoped only to
this workflow run) for a Fulcio certificate binding the signature to
"this exact GitHub Actions workflow, in this exact repo, running off
this exact ref," and records that in Rekor's public transparency log.
The verify side checks exactly that binding —
`--certificate-identity-regexp` against this repo's own path and
`--certificate-oidc-issuer` pinned to GitHub's own token issuer — so an
attacker who managed to push a different image to this same GHCR
repository couldn't also forge a signature that verifies, without also
compromising this repo's own CI.

What this doesn't yet prove: `bootc install to-disk` itself still
trusts the image once `boot-test`'s pull happens to hand it the same
bytes that were just verified — it isn't re-verifying inside the
podman-installer container. For this CI-loop-back-onto-itself test that
distinction doesn't matter (it's the same job, same runner, same pull),
but it would in a real deployment: the gap between "GitHub Actions
verified this image" and "the machine deploying it verified this image"
is exactly the kind of thing item 5's fs-verity work would close from a
different angle, at the filesystem level instead of the registry level.

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
