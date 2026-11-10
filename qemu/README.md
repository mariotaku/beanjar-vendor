# qemu: beanjar-qemu

The patched QEMU that [Beanjar](https://github.com/mariotaku/beanjar) runs its VMs with, packaged
as `beanjar-qemu` for Debian 13 (trixie) on amd64 and arm64.

Beanjar's launcher runs `/usr/libexec/beanjar/qemu-system-aarch64` (with `-L
/usr/share/beanjar/qemu`) whenever this package is installed, and Debian's `qemu-system-arm` with
`qemu-system-modules-opengl` otherwise; the `beanjar` package depends on one or the other. The
package installs nothing outside those Beanjar directories, so it lives alongside Debian's QEMU.

| Path | |
|---|---|
| `/usr/libexec/beanjar/qemu-system-aarch64` | the emulator, stripped |
| `/usr/libexec/beanjar/vhost-user-gpu` | QEMU's own vhost-user GPU backend: on an ARM host with a render node the launcher runs the VM's virgl GPU in this separate process |
| `/usr/share/beanjar/qemu/` | QEMU's data directory (firmware images, keymaps) |

## Version

`<QEMU version>+beanjar<N>`, for example `10.0.2+beanjar1`: the upstream QEMU release, and the
revision of this repository's patches and build for it. `debian/changelog` holds it; its upstream
part selects the release tarball, which `build.sh` downloads from `download.qemu.org` and checks
against `qemu.sha256`.

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

The package is assembled with Debian's low-level tools rather than `dpkg-buildpackage`: QEMU is
built from the upstream tarball, fetched at build time, and only a staged tree is packaged under
Beanjar's paths, so there is no Debian source package to build. `dpkg-shlibdeps` derives the
library dependencies of the two programs, `dpkg-gencontrol` writes the control file from
`debian/control` and `debian/changelog`, and `dpkg-deb` builds the `.deb`. Besides the libraries
it depends on `libegl1` and `libopengl0`, which libepoxy loads at run time where
`dpkg-shlibdeps` cannot see them.

## Building

`qemu/build.sh` installs the build dependencies with apt, so run it as root in a throwaway
`debian:trixie` container on the architecture you want (amd64 or arm64), for example from the
top of a clone:

```sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build:/out" debian:trixie /src/qemu/build.sh /out/qemu
```

The package is written to `build/qemu/debs/beanjar-qemu_<version>_<arch>.deb`; install it with
`sudo apt install ./build/qemu/debs/beanjar-qemu_*.deb`. A build takes about three minutes on 24
cores, dependencies included.

## Continuous integration

The QEMU workflow (`.github/workflows/qemu.yml`) runs `qemu/build.sh` in a `debian:trixie`
container on GitHub's amd64 and arm64 runners, for pushes and pull requests that change `qemu/` or
the workflow; those runs only check that the package builds. A manual run (Actions, QEMU, "Run
workflow") also uploads the packages as the run's artifacts `beanjar-qemu-amd64` and
`beanjar-qemu-arm64`.

## Licence

QEMU is licensed under the GNU General Public License, version 2. The patches and the build
scripts here are GPL-2.0-or-later (the repository's `LICENSE`); every file carries an SPDX header
or is covered by the repository's `REUSE.toml`.
