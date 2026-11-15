# testguest: the test guest userland

A small, freely licensed 32-bit ARM userland that [Beanjar](https://github.com/mariotaku/beanjar)
boots as its open test guest: a VM that public CI can run without any LG firmware, to check the
launcher, QEMU's devices and the host side. It is built with [Buildroot](https://buildroot.org)
from upstream releases only. Beanjar's own checks are not in it: Beanjar builds them against the
sysroot here and lays them over the root filesystem as a layer of its own.

## Why it lives here

The userland changes rarely (a Buildroot or Mesa update), and a cold Buildroot build, which builds
its own GCC, takes well over half an hour on a CI runner. Beanjar's checks change with its host protocols. Released here, the
userland is a download for Beanjar's CI, and the checks are a quick cross build there.

## What is built

From the Buildroot release in `VERSION` (2026.02.3, the LTS line), checked against
`buildroot.sha256`, with `defconfig`:

- **armv7 EABI softfp, glibc, as webOS's userland.** webOS is 32-bit ARM with the soft-float
  calling convention and VFP hardware (`readelf -h`: "soft-float ABI"; loader `/lib/ld-linux.so.3`;
  VFPv3 with NEON), and so is this: `BR2_ARM_EABI`, Cortex-A9 with NEON (`-mcpu=cortex-a9
  -mfpu=neon -mfloat-abi=softfp -marm`, the CPU and FPU of the webOS SDK's own compiler), which
  every 64-bit ARM host runs in AArch32 EL0 and QEMU's TCG emulates. No external toolchain is
  published for this ABI, so Buildroot builds its own (GCC 14.3, glibc 2.42); the Linux headers are
  5.10, the oldest kernel the C library then runs on.
- **BusyBox init**, with Buildroot's `/etc/init.d/rcS`, which runs `/etc/init.d/S??*`; a getty on
  `hvc0`.
- **Mesa 26.0 with the virgl gallium driver only**: EGL, OpenGL ES and GBM, with libdrm, expat and
  zlib; no LLVM, Vulkan, X11 or Wayland.
- **A squashfs root filesystem**, LZO-compressed. `BR2_REPRODUCIBLE` is set.

## The tarballs

`testguest-<version>-armel.tar.xz`, for example `testguest-2026.02.3+beanjar2-armel.tar.xz`.
`armel` is the guest's architecture (Debian's name for 32-bit ARM EABI with the soft-float calling
convention): the userland runs inside the guest, so the one tarball serves amd64 and arm64 hosts
alike. Releases up to `+beanjar1` were `armhf`, hard-float.

| Path | |
|---|---|
| `rootfs.squashfs` | the root filesystem |
| `sysroot/` | Buildroot's staging directory without its programs and documentation: `lib`, `usr/lib`, `usr/include` and the pkg-config files of the C library, the GCC runtime and every package, for compiling programs that run on the root filesystem |
| `share/doc/testguest/` | Buildroot's `manifest.csv` (every package, its version, licence and source), `licenses/`, `buildroot.config`, legal-info's `README`, and `NOTICE` |
| `BUILDINFO` | program, version, architecture, the Buildroot release and defconfig with their SHA-256, the compiler's triplet and CPU options, the root filesystem's SHA-256 and the packages |

`BUILDINFO` is in Debian control syntax. No compiler is in the tarball: the sysroot is enough for
any GCC for the triplet. `Target-Triplet` is `arm-linux-gnueabi`, and `Target-Flags` the CPU
options Buildroot's wrapper passed (`Toolchain` names Buildroot's GCC, for the record). A program
is compiled for the root filesystem with Debian's cross compiler (`gcc-arm-linux-gnueabi`, on
amd64 or arm64). That compiler is not built for a sysroot: `--sysroot` alone leaves its own tool
directory (`/usr/arm-linux-gnueabi`, where Debian's armel C library is when
`libc6-dev-armel-cross` is installed) ahead of the sysroot, so the sysroot is put first by hand:

```sh
S=<tree>/sysroot
arm-linux-gnueabi-gcc --sysroot=$S -nostdinc -isystem $S/usr/include \
    -idirafter "$(arm-linux-gnueabi-gcc -print-file-name=include)" -U_TIME_BITS \
    -B$S/usr/lib/ -B$S/lib/ -L$S/lib -L$S/usr/lib -Wl,-rpath-link,$S/lib:$S/usr/lib <Target-Flags> ...
```

`-U_TIME_BITS`: Debian 13's armel compiler defines `_TIME_BITS=64` (and `_FILE_OFFSET_BITS=64`) by
default, from Debian's 64-bit `time_t` transition; webOS's userland, like glibc's default, has a
32-bit `time_t`.

and pkg-config with `PKG_CONFIG_SYSROOT_DIR=$S` and `PKG_CONFIG_LIBDIR=$S/usr/lib/pkgconfig`. Then
every header, start file and library is the sysroot's; only GCC's own headers, `libgcc.a`,
`crtbegin.o` and `crtend.o` are the compiler's.

`testguest-<version>-legal-info.tar` is Buildroot's `make legal-info` for the image: the manifests,
the licence texts, the source of every package in it with the patches Buildroot applied (`sources/`,
including GCC, glibc and the Linux headers), and Buildroot's own release tarball (`buildroot/`),
which legal-info does not save. The host tools' sources are left out: nothing of them is in the image.
A copy of the root filesystem passed on should come with it.

## Building

`testguest/build.sh` installs Buildroot's host tools with apt, so run it as root in a throwaway
`debian:trixie` container, for example from the top of a clone:

```sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build:/out" debian:trixie /src/testguest/build.sh /out/testguest
```

The tarballs are written to `build/testguest/`. `BR2_DL_DIR` and `BR2_CCACHE_DIR` set Buildroot's
download and compiler caches (default `dl` and `ccache` in the output directory). `build.sh` ends by
running `testguest/test-tarball.sh` on the tarball: unpacked elsewhere, its root filesystem must have
BusyBox init, the C library and Mesa's virgl driver, and a program using GBM, EGL and OpenGL ES must
compile against the sysroot with Debian's cross compiler, take every library from the sysroot, be
EABI soft-float with the interpreter `/lib/ld-linux.so.3`, and find everything it needs in the root
filesystem. Running it takes an ARM guest with a virtio GPU, which Beanjar's own tests boot.

## Continuous integration and releases

The workflow (`.github/workflows/testguest.yml`) runs `testguest/build.sh` in a `debian:trixie`
container on GitHub's amd64 runner, keeping Buildroot's downloads and ccache between runs. Every
run uploads the two tarballs as the artifact `beanjar-testguest-armel`.

To release, push a tag `testguest-<version>` matching `VERSION`, for example
`testguest-2026.02.3+beanjar2`; a tag that does not match fails the build. The workflow publishes a
GitHub release named after the tag with the two tarballs and a `SHA256SUMS` file.

## Licence

Every package keeps its own licence: BusyBox GPL-2.0, Mesa MIT with SGI and Khronos parts, libdrm,
libpthread-stubs and expat MIT, zlib Zlib, the C library LGPL-2.1-or-later and the GCC runtime
libraries GPL-3.0-or-later with the GCC Runtime Library Exception (`NOTICE`, and `manifest.csv` with
`licenses/` in the tarball). The build scripts, the defconfig, the workflow and the documentation
are GPL-2.0-or-later (the repository's `LICENSE`); every file carries an SPDX header or is covered by
the repository's `REUSE.toml`.
