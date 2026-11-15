# qemu-user: qemu-arm with the compat bridge

QEMU's 32-bit ARM user-mode emulator, `qemu-arm`, as one static program, for running a TV
firmware's 32-bit ARM userland under [Beanjar](https://github.com/mariotaku/beanjar)'s guest
kernel without AArch32 at EL0. It runs inside the guest, not on the host, so the tarball's
architecture is the guest kernel's:

- `arm64`, for Beanjar's arm64 guest kernel on a CPU without AArch32 at EL0, or to check that
  nothing needs it; it serves amd64 and arm64 hosts alike;
- `amd64`, for Beanjar's experimental x86-64 guest kernel on amd64 hosts (q35 under KVM).

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
- `0002` linux-user: the ioctl bridge, the same idea on an x86-64 kernel with Beanjar's x86
  `compat_bridge` system call (`0x7ff0`, from its guest kernel's patch "x86: a system call for
  64-bit tasks that runs one i386 compat call"). The kernel's compat layer there is i386's, with
  its own call numbers, so qemu converts the ordinary calls itself and hands the kernel only
  those whose meaning depends on a 32-bit caller: every ioctl, `read`, `write`, `readv` and
  `writev` on a descriptor qemu does not translate, the robust futex list, and `getdents`,
  `getdents64`, `lseek` and `_llseek`, for which ext4 sizes directory offsets for the caller (a
  32-bit glibc's `readdir` fails with EOVERFLOW on 64-bit ones). i386 aligns 64-bit fields to 4
  where ARM EABI aligns them to 8: the ioctls whose ARM layout is x86-64's native one run natively,
  and SNDRV_CTL `ELEM_READ`/`ELEM_WRITE` are repacked to i386's layout and back
  (`linux-user/ioctl-bridge.c.inc`). `VIDIOC_DQEVENT` goes through unchanged: Beanjar's emulated
  LG V4L2 nodes take ARM's layout, as on the arm64 kernel. `QEMU_BRIDGE` works as for `0001`.
- `0003` linux-user: `/proc/<pid>/cmdline` and `environ` are the guest's argv and envp, as after
  a native exec, instead of `qemu-arm <path> <argv...>`: programs that find a peer by its command
  line (webOS's `initctl`, which notifies systemd for a service it finds that way) see the
  program. qemu points the kernel's argument and environment range at the guest's strings with
  `prctl(PR_SET_MM, PR_SET_MM_MAP)`, which needs no capability on a kernel with
  `CONFIG_CHECKPOINT_RESTORE` (Beanjar's guest kernels have it); elsewhere nothing changes. It
  works with or without the bridge.
- `0004` linux-user: `/proc/self/status` and `statm` count the guest program's memory (its
  mappings' sizes and their resident pages from the host's `smaps`) instead of the whole qemu
  process's, whose TCG code buffer and heap made webOS's iconnectivity, which aborts when its own
  `VmRSS` passes a limit, abort at start. Another process reading them still sees qemu's.

## The tarball

`qemu-user-<version>-<arch>.tar.xz` (arch `arm64` or `amd64`), for example
`qemu-user-10.0.2+beanjar1-arm64.tar.xz`:

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
`debian:trixie` container on arm64 or amd64 (it builds for the machine it runs on), for example from the top of a clone:

```sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build:/out" debian:trixie /src/qemu-user/build.sh /out/qemu-user
```

The tarball is written to `build/qemu-user/qemu-user-<version>-<arch>.tar.xz`, next to a copy of
the upstream release tarball. `build.sh` ends by running `qemu-user/test-tarball.sh` on it: the
program must be a static one for the tarball's architecture, of the expected release, and carry
its bridge. The bridge
itself needs Beanjar's guest kernel, so Beanjar's own tests run it there.

## Continuous integration and releases

The workflow (`.github/workflows/qemu-user.yml`) runs `qemu-user/build.sh` in a `debian:trixie`
container on GitHub's arm64 and amd64 runners, natively on each. Pushes and pull requests that
change `qemu-user/` or the workflow only check that it builds. A manual run also uploads the
tarballs as the run's artifacts `beanjar-qemu-user-arm64` and `beanjar-qemu-user-amd64`, and the
upstream source as `beanjar-qemu-user-source`.

To release, push a tag `qemu-user-<version>` matching `VERSION`, for example
`qemu-user-10.0.2+beanjar1`; a tag that does not match fails the build. The workflow publishes a
GitHub release named after the tag with the two tarballs, the upstream QEMU tarball and a `SHA256SUMS`
file; the patches are in the tag's source archive.

## Licence

QEMU is licensed under the GNU General Public License, version 2; some of its parts are under
other compatible licences, as the texts in `share/doc/qemu-user` say. The statically linked
libraries keep their own licences (`NOTICE`). The patches and the build scripts here are
GPL-2.0-or-later (the repository's `LICENSE`); every file carries an SPDX header or is covered by
the repository's `REUSE.toml`.
