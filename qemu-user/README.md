# qemu-user: qemu-arm with the compat bridge

QEMU's 32-bit ARM user-mode emulator, `qemu-arm`, as one static aarch64 program, for running a TV
firmware's 32-bit ARM userland under [Beanjar](https://github.com/mariotaku/beanjar)'s arm64 guest
kernel without AArch32 at EL0: on a CPU that has none, or to check that nothing needs it. It runs
inside the guest, not on the host, so the one arm64 tarball serves amd64 and arm64 hosts alike.
Beanjar's packaging puts the program into its guest components.

## Version

`<QEMU version>+beanjar<N>`, for example `10.0.2+beanjar1`, in `VERSION`: the upstream QEMU
release, and the revision of this directory's patches and build for it. Its upstream part selects
the release tarball, which `build.sh` downloads from `download.qemu.org` and checks against
`qemu.sha256`.

## Patches

- `0001` linux-user: the compat bridge. On an aarch64 kernel with Beanjar's `compat_bridge`
  system call (`0x7ff0`, from its guest kernel's patch "arm64: a system call for 64-bit tasks
  that runs one AArch32 call"), a 32-bit ARM guest's system calls run through the kernel's AArch32
  compat syscall table instead of being converted by qemu: the kernel's compat converters do the
  ABI, so every ioctl (DRM, evdev, uinput, V4L2, ALSA, drivers' own) works without a table entry in
  qemu. qemu keeps the calls it must own (tasks and exec, signals, the address space, its file
  descriptor translators and faked `/proc` files, what it fakes for the emulated CPU), listed in
  `bridge_keep()` in `linux-user/compat-bridge.c.inc`. It needs guest addresses equal to host
  addresses (`guest_base` 0). The bridge is on when the kernel answers the call, off otherwise or
  with `QEMU_BRIDGE=0`; with `QEMU_BRIDGE=1` qemu says on stderr why it could not turn it on.
  The same patch copies what qemu logs as unimplemented to `/dev/kmsg`, once per message and
  process with the pid and guest program, so a whole system's gaps show in `dmesg`
  (`QEMU_UNIMP_KMSG=0` turns that off).

## The tarball

`qemu-user-<version>-arm64.tar.xz`, for example `qemu-user-10.0.2+beanjar1-arm64.tar.xz`:

| Path | |
|---|---|
| `bin/qemu-arm` | the emulator, static, stripped |
| `share/doc/qemu-user/` | QEMU's `COPYING`, `COPYING.LIB` and `LICENSE`, and `NOTICE` |
| `BUILDINFO` | program, version, architecture, Debian release, the configure prefix, the source and patch checksums, the configure line, and `Static-Libraries` |

`BUILDINFO` is in Debian control syntax, as the other tarballs' are. The program is static, so
it has no `Depends`; `Static-Libraries` names the Debian packages, with their source packages and
versions, whose libraries are linked in (GLib, PCRE2, zlib, the GNU C Library).

## Building

`qemu-user/build.sh` installs the build dependencies with apt, so run it as root in a throwaway
`debian:trixie` container on arm64, for example from the top of a clone:

```sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build:/out" debian:trixie /src/qemu-user/build.sh /out/qemu-user
```

The tarball is written to `build/qemu-user/qemu-user-<version>-arm64.tar.xz`, next to a copy of
the upstream release tarball. `build.sh` ends by running `qemu-user/test-tarball.sh` on it: the
program must be a static aarch64 one of the expected release and carry the bridge. The bridge
itself needs Beanjar's guest kernel, so Beanjar's own tests run it there.

## Continuous integration and releases

The workflow (`.github/workflows/qemu-user.yml`) runs `qemu-user/build.sh` in a `debian:trixie`
container on GitHub's arm64 runner. Pushes and pull requests that change `qemu-user/` or the
workflow only check that it builds. A manual run also uploads the tarball and the upstream source
as the run's artifact `beanjar-qemu-user-arm64`.

To release, push a tag `qemu-user-<version>` matching `VERSION`, for example
`qemu-user-10.0.2+beanjar1`; a tag that does not match fails the build. The workflow publishes a
GitHub release named after the tag with the tarball, the upstream QEMU tarball and a `SHA256SUMS`
file; the patches are in the tag's source archive.

## Licence

QEMU is licensed under the GNU General Public License, version 2; some of its parts are under
other compatible licences, as the texts in `share/doc/qemu-user` say. The statically linked
libraries keep their own licences (`NOTICE`). The patches and the build scripts here are
GPL-2.0-or-later (the repository's `LICENSE`); every file carries an SPDX header or is covered by
the repository's `REUSE.toml`.
