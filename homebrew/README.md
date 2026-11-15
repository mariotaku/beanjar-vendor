# homebrew: bottles of Beanjar's Homebrew formulae

On a Mac, Beanjar's QEMU and the graphics stack under it are installed with Homebrew, from the tap
that is [Beanjar](https://github.com/mariotaku/beanjar)'s own repository (its `Formula/`
directory), so that they use Homebrew's GLib, pixman, libslirp and the rest instead of bundling
them. This directory builds the bottles (Homebrew's prebuilt binaries) of those formulae:

| Formula | What | Built like |
|---|---|---|
| `beanjar-angle` | ANGLE's `libEGL` and `libGLESv2` on Metal | [`angle/`](../angle/README.md) |
| `beanjar-libepoxy` | libepoxy with EGL, loading ANGLE | [`virglrenderer/`](../virglrenderer/README.md) |
| `beanjar-virglrenderer` | virglrenderer (vrend) with the OpenGL ES host patches | [`virglrenderer/`](../virglrenderer/README.md) |
| `beanjar-qemu` | QEMU, aarch64-softmmu, with Beanjar's patches | [`qemu/`](../qemu/README.md) |

All are for Apple silicon only, and keg-only, so they never clash with Homebrew's own `qemu`,
`libepoxy` or `virglrenderer`.
The formulae take their patches and check programs from this repository by URL at a commit, with
their SHA-256, so each patch has one copy, here. ANGLE's source is the archive `angle/source.sh`
makes: ANGLE's DEPS checkout cut down to what the build reads (`angle/source-paths`), without git
metadata or prebuilt toolchains, reproducible byte for byte. It is published with ANGLE's release
here, and the formula pins it by SHA-256; Chromium's clang and gn, as ANGLE's DEPS pins them, are
resources of the formula.

## The workflow

`.github/workflows/homebrew.yml`, on changes here or to the programs' directories:

1. `homebrew/check.sh` checks that the formulae build what this repository pins: versions equal to
   the `VERSION` files, sources equal to `sources` and the checksum files, and every file the
   formulae take from here pinned at a commit, with the SHA-256 it has there and still has now.
2. `angle/source.sh` makes ANGLE's source archive.
3. On macos-15 (arm64), `homebrew/tap.sh` installs the tap and puts the ANGLE
   archive in Homebrew's download cache (its SHA-256 must be the formula's), and
   `homebrew/bottle.sh` builds each formula with `brew install --build-bottle`, then runs
   `brew test`, `brew linkage --test`, `brew audit --strict` and `brew bottle --json`.
4. `brew bottle --merge --write` puts the bottles in the formulae's bottle blocks.

The artifacts are `beanjar-angle-source`, `beanjar-bottles-macos-arm64` (the bottles and
their JSON) and `beanjar-formulae-with-bottles`. Nothing is released.

## Where the formulae come from

Beanjar's repository is not public yet, so the workflow cannot fetch the formulae from it: it
builds `homebrew/Formula`, a copy. `homebrew/sync.sh BEANJAR` copies them from a checkout of
Beanjar after every change there, and `homebrew/sync.sh --check BEANJAR` fails when the copy
differs. Once Beanjar's repository is public, `TAP_SOURCE` in the workflow names it and a commit
(`https://github.com/webosbrew/beanjar#<commit>`), the jobs take the formulae from there, and the
copy goes.

## Releasing bottles

A bottle is downloaded from the formula's `root_url` and named after the formula, its version and
the macOS it was built on, for example `beanjar-qemu-10.0.2+beanjar1.arm64_sequoia.bottle.tar.gz`.
`homebrew/bottle.sh` gives each formula the root URL of a release here named `<formula>-<version>`,
for example `beanjar-qemu-10.0.2+beanjar1`. Releasing means: publish the bottles in that
release under the `filename` their JSON names, publish ANGLE's source archive
in ANGLE's release, and commit the formulae from `beanjar-formulae-with-bottles`, whose bottle
blocks name the root URL and each bottle's SHA-256, to Beanjar's `Formula/`. Until then the
formulae have no bottle block, and beanjar-angle's source archive cannot be downloaded, so they
install only in the workflow.

## Licence

The scripts and the formulae are GPL-2.0-or-later (the repository's `LICENSE`). The programs keep
their own licences, named in each formula.
