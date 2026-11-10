# beanjar-vendor

The patched third-party programs that [Beanjar](https://github.com/mariotaku/beanjar)'s host
packages use. Each lives in its own directory with its patches, the pinned upstream source, its
version in `VERSION` and a build script, and is built for Debian 13 (trixie) on amd64 and arm64 by
its own GitHub Actions workflow, natively on each architecture in a throwaway `debian:trixie`
container.

The result is not a package but a tarball of the built tree, `<program>-<version>-<arch>.tar.xz`
(`<arch>` being Debian's name, `amd64` or `arm64`), with a `BUILDINFO` file and the licence texts
under `share/doc/`. `BUILDINFO` is in Debian control syntax: the program, version, architecture
and Debian release, the prefix, the sources and patches with their SHA-256, and the `Depends` that
`dpkg-shlibdeps` reports for the binaries. Beanjar's packaging turns the tarballs into `.deb`
packages.

Pushes and pull requests that change a program's directory or its workflow check that it builds,
tests included. A manual run of a workflow uploads the tarballs as the run's artifacts
`beanjar-<program>-amd64` and `beanjar-<program>-arm64`. Pushing a tag `<program>-<version>`,
which must match the program's `VERSION`, publishes both tarballs and a `SHA256SUMS` file as a
GitHub release named after the tag.

| Directory | Tarball | Workflow |
|---|---|---|
| [`qemu/`](qemu/README.md) | `qemu-<version>-<arch>.tar.xz`: QEMU 10.0.2 (`qemu-system-aarch64`, `vhost-user-gpu`) with Beanjar's EGL and D-Bus display patches, for `beanjar-qemu` | `.github/workflows/qemu.yml` |
| [`neatvnc/`](neatvnc/README.md) | `neatvnc-<version>-<arch>.tar.xz`: neatvnc 1.0.4 with V4L2 H.264 fixes, and aml 1.0, for `beanjar-vnc` | `.github/workflows/neatvnc.yml` |
| [`ffmpeg/`](ffmpeg/README.md) | `ffmpeg-<version>-<arch>.tar.xz`: FFmpeg 7.1.5 with the V4L2 Request API hwaccels, under `/usr/lib/beanjar/ffmpeg` | `.github/workflows/ffmpeg.yml` |

The patches and build scripts are GPL-2.0-or-later (`LICENSE`), except neatvnc's patches, which
are ISC like neatvnc; every file carries an SPDX header or is covered by `REUSE.toml`. Each program
keeps its own upstream licence. The releases of the GPL-licensed programs, QEMU and FFmpeg, also
carry their source: the upstream QEMU tarball, and FFmpeg's patched source.
