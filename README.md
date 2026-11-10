# beanjar-vendor

The patched third-party programs that [Beanjar](https://github.com/mariotaku/beanjar)'s host
packages use. Each lives in its own directory with its patches, the pinned upstream source and a
build script, and is built as Debian 13 (trixie) packages for amd64 and arm64 by its own GitHub
Actions workflow. Pushes and pull requests check that it builds; a manual run of the workflow
uploads the `.deb` files as the run's artifacts.

| Directory | Package | Workflow |
|---|---|---|
| [`qemu/`](qemu/README.md) | `beanjar-qemu`: QEMU with Beanjar's EGL and D-Bus display patches | `.github/workflows/qemu.yml` |

The patches and build scripts are GPL-2.0-or-later (`LICENSE`); every file carries an SPDX header
or is covered by `REUSE.toml`. Each program keeps its own upstream licence.
