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

Early-stage PoC, under active iteration. **The GitHub Actions run history on
this repo is the source of truth for what currently works** - not this
README. The pipeline builds the image, lints it for bootc-compatibility,
converts it to a bootable disk image, and boots it in QEMU/KVM.

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

## A note on scope

This is a personal, from-scratch reference project exploring the bootc/
ostree atomic-update pattern - not tied to any employer, internal system, or
production fleet. Config values here are placeholders; nothing here should
be read as describing real infrastructure.
