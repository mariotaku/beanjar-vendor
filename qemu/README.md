# qemu: QEMU with Beanjar's display patches

The patched QEMU that [Beanjar](https://github.com/mariotaku/beanjar) runs its VMs with, built for
Debian 13 (trixie) on amd64 and arm64. The result is a tarball of the installed programs and data,
not a package: Beanjar's own packaging turns it into the `beanjar-qemu` package, which installs
the two programs in `/usr/libexec/beanjar` and the data directory as `/usr/share/beanjar/qemu`,
alongside Debian's QEMU. Beanjar's launcher runs that QEMU (with `-L /usr/share/beanjar/qemu`)
whenever it is installed, and Debian's `qemu-system-arm` with `qemu-system-modules-opengl`
otherwise.

## Version

`<QEMU version>+beanjar<N>`, for example `10.0.2+beanjar1`, in `VERSION`: the upstream QEMU
release, and the revision of this directory's patches and build for it. Its upstream part selects
the release tarball, which `build.sh` downloads from `download.qemu.org` and checks against
`qemu.sha256`.

## Patches

Taken from Beanjar's `host/tools/build/qemu/patches/`, as of commit
[`f4a51ff4bd7f`](https://github.com/mariotaku/beanjar/commit/f4a51ff4bd7fdbd1c7656905b8ddc3a139920666).

- `0001` ui/egl: a surfaceless EGL display (`rendernode=surfaceless`), so `egl-headless` and
  `dbus,gl=on` work on hosts whose GL driver has no DRM render node, such as Mesa's d3d12 driver
  on WSL2.
- `0002` ui/egl: `egl_fb_read_rect()` stores each row where it belongs when the rectangle does
  not start at y = 0, and accepts a8r8g8b8 surfaces; 0003 reads scanouts back with it.
- `0003` ui/dbus: when the EGL display cannot export dma-bufs (0001's surfaceless one), GL
  scanouts are read back into shared memory and sent to D-Bus listeners that way.
- `0004` ui/dbus: a listener whose D-Bus connection closed is dropped, instead of being sent
  every frame for as long as QEMU runs.

## What is built

Only `aarch64-softmmu`, with what the launcher uses: OpenGL and virglrenderer (`virtio-gpu-gl`),
the `egl-headless` and D-Bus displays and D-Bus audio, GBM, slirp, virtio-9p, PNG for the QMP
screendump, `usb-redir` and `usb-host`. No SDL, GTK, VNC, SPICE or curses display, no host audio
drivers, and no block drivers or crypto libraries beyond QEMU's built-in ones. The libraries are
Debian 13's, among them virglrenderer 1.1, libslirp and libfdt. `build.sh` lists the configure
options.

## The tarball

`qemu-<version>-<arch>.tar.xz`, for example `qemu-10.0.2+beanjar1-amd64.tar.xz`. Its root has the
layout of QEMU's installed prefix, reduced to what Beanjar uses:

| Path | |
|---|---|
| `bin/qemu-system-aarch64` | the emulator, stripped |
| `libexec/vhost-user-gpu` | QEMU's own vhost-user GPU backend, stripped: on an ARM host with a render node the launcher runs the VM's virgl GPU in this separate process |
| `share/qemu/` | QEMU's data directory (firmware images, keymaps), without `vhost-user/50-qemu-gpu.json`, which names the configure prefix rather than where the backend is installed |
| `share/doc/qemu/` | QEMU's `COPYING`, `COPYING.LIB` and `LICENSE`, its `pc-bios/README` (the firmware images' licences) as `pc-bios-README`, and `NOTICE` |
| `BUILDINFO` | program, version, architecture, Debian release, the configure prefix, the source and patch checksums, the configure line, and `Depends` |

The configure prefix is `/qemu`, which nothing uses at run time: QEMU finds its data directory
relative to its program, and Beanjar's launcher passes `-L` anyway. So the tree runs wherever it is
unpacked, for example `bin/qemu-system-aarch64 -L share/qemu`.

`BUILDINFO` is in Debian control syntax. Its `Depends` is what `dpkg-shlibdeps` reports for the two
programs, plus `libegl1` and `libopengl0`, which libepoxy loads at run time where
`dpkg-shlibdeps` cannot see them.

## Building

`qemu/build.sh` installs the build dependencies with apt, so run it as root in a throwaway
`debian:trixie` container on the architecture you want (amd64 or arm64), for example from the
top of a clone:

```sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build:/out" debian:trixie /src/qemu/build.sh /out/qemu
```

The tarball is written to `build/qemu/qemu-<version>-<arch>.tar.xz`, next to a copy of the
upstream release tarball, `build/qemu/qemu-<upstream version>.tar.xz`, which is the source the
programs are built from with the patches here. `build.sh` ends by running `qemu/test-tarball.sh`
on the tarball: it unpacks it in another directory and, with `-L` pointing into that tree, checks
that `qemu-system-aarch64 --version` is the expected release, that `-display help` lists
`egl-headless` and `dbus` and `-device help` lists `virtio-gpu-gl-pci`, `vhost-user-gpu-pci` and
`usb-redir`, and that `vhost-user-gpu --print-capabilities` answers. A build takes about two
minutes on 24 cores, dependencies included.

## Continuous integration and releases

The QEMU workflow (`.github/workflows/qemu.yml`) runs `qemu/build.sh` in a `debian:trixie`
container on GitHub's amd64 and arm64 runners, natively on each, tests included. Pushes and pull
requests that change `qemu/` or the workflow only check that it builds. A manual run (Actions,
QEMU, "Run workflow") also uploads the tarballs as the run's artifacts `beanjar-qemu-amd64` and
`beanjar-qemu-arm64`, and the upstream source as `beanjar-qemu-source`.

To release, push a tag `qemu-<version>` matching `VERSION`, for example `qemu-10.0.2+beanjar1`; a
tag that does not match fails the build. The workflow builds both architectures and publishes a
GitHub release named after the tag with the two tarballs, the upstream QEMU tarball and a
`SHA256SUMS` file; the patches are in the tag's source archive.

## Licence

QEMU is licensed under the GNU General Public License, version 2; some of its parts are under
other compatible licences, and the firmware images in `share/qemu` each under their own, as the
texts in `share/doc/qemu` say. The patches and the build scripts here are GPL-2.0-or-later (the
repository's `LICENSE`); every file carries an SPDX header or is covered by the repository's
`REUSE.toml`.
