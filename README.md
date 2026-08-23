# bootc-ubuntu-image

A proof-of-concept: can [bootc](https://github.com/containers/bootc)'s
container-image-based, atomic OS update model - the same one used by
Fedora Silverblue/CoreOS and [Universal Blue](https://universal-blue.org/) -
work on an **Ubuntu** base instead of Fedora/RHEL?

Short version of the idea being tested: ship the OS as a normal OCI
container image. `bootc` pulls it and hands it to `ostree`, which stores it
as a versioned, bootable filesystem tree. "Updating" becomes: pull a new
image tag, reboot into it atomically, roll back with one command if it's
bad. That's a genuinely different (and much less fragile) model than
patching a live filesystem package-by-package - but `bootc` and its
tooling are written with Fedora-family assumptions baked in (RPM packaging,
a BLS-patched grub, dracut-style kernel layout). This repo is where those
assumptions get tested against Ubuntu directly instead of taken on faith.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full breakdown of
what's different on Ubuntu, what's already handled, and what's still an open
question.

## Status

**Working, end to end.** The pipeline builds an Ubuntu 25.10 image, passes
`bootc container lint`, installs it to a real disk with bootc's own
`bootc install to-disk --composefs-backend` (no Fedora tooling involved),
and boots that disk under QEMU/KVM to an actual login prompt - no manual
intervention. **The GitHub Actions run history on this repo is the source
of truth** - not this README - but as of this writing it's green
([latest passing run](https://github.com/fredIV/bootc-ubuntu-image/actions/runs/32646473638)).
See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full list of
gaps that had to be closed to get there, and which of them were genuinely
architectural versus just Ubuntu/Debian packaging splits.

## Layout

- `Containerfile` - builds `bootc` from source and assembles an Ubuntu image
  that satisfies bootc's container-image contract.
- `.github/workflows/build-and-test.yml` - build → lint → disk image → boot
  test, run on every push.
- `docs/ARCHITECTURE.md` - why each piece exists, and the known Fedora- vs
  Ubuntu-specific gaps this project has to close.

## Building locally

Requires Docker/Podman with registry access (some steps pull from Docker
Hub, GHCR, and quay.io).

```sh
docker build -f Containerfile -t bootc-ubuntu-image:dev .
docker run --rm bootc-ubuntu-image:dev bootc container lint
```

If you hit a `403` from `api.github.com` during the build (its
unauthenticated rate limit is easy to hit), pass a GitHub token as a build
secret instead of retrying blind:

```sh
docker build -f Containerfile --secret id=gh_token,env=GH_TOKEN -t bootc-ubuntu-image:dev .
```

## A note on scope

This is a personal, from-scratch reference project exploring the bootc/
ostree atomic-update pattern - not tied to any employer, internal system, or
production fleet. Config values here are placeholders; nothing here should
be read as describing real infrastructure.
