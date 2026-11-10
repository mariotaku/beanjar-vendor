# neatvnc: neatvnc 1.0 and aml 1.0

[neatvnc](https://github.com/any1/neatvnc), the VNC server library that
[Beanjar](https://github.com/mariotaku/beanjar)'s `beanjar-vnc` is built on, and
[aml](https://github.com/any1/aml), the main loop library it needs, built for Debian 13 (trixie) on
amd64 and arm64. The result is a tarball of the installed tree, not a package: Beanjar's own
packaging turns it into a `.deb`.

## Why

beanjar-vnc needs neatvnc 1.0. Debian 13 has only 0.9.1, whose RSA-AES security type sends the
server's challenge without the ciphertext's leading zero bytes, so about one login in 256 fails;
1.0.0 sends it at the key's length, and also closes a pre-authentication stack overflow with a
large client key. Debian's 1.0.1 (forky and sid) is built against a newer FFmpeg and libc and does
not install on trixie, and trixie-backports has none.

## What is built

- aml 1.0.0, upstream's tag tarball, unchanged.
- neatvnc 1.0.4, upstream's tag tarball, with the two patches below. 1.0.4 rather than Debian's
  1.0.1: it has upstream's "Use poll() instead of map to wait" for the V4L2 encoder and later
  fixes (WebSocket header bounds checks, the client's bits per pixel validated, the stream
  ordering fixes of 1.0.2 and 1.0.3).

Both are built with Meson against Debian 13's own libraries (FFmpeg 7.1, GnuTLS, nettle, libc
2.41), with Debian's default build flags (`dpkg-buildflags`, `hardening=+all`), and both test
suites run (aml has none; neatvnc's are `base64`, `pixels` and `rfb-handshake`, which goes
through the RFB 3.3, 3.7 and 3.8 handshakes with and without authentication, VeNCrypt included). neatvnc is configured with JPEG, TLS, nettle, GBM and H.264
required, so a missing library fails the build instead of quietly dropping a feature. The
sonames are upstream's, `libneatvnc.so.1` and `libaml.so.1`, as Debian's `libneatvnc1` and
`libaml1` have them.

The prefix is `/usr/lib/beanjar/neatvnc`, out of the way of Debian's `libneatvnc0` and
`libaml0t64` (Weston's VNC backend keeps those). Programs linking it need it on their run path;
`libneatvnc` itself finds `libaml` next to it (`RUNPATH $ORIGIN`).

### Patches

Both change `src/enc/h264/v4l2m2m-impl.c` and are not upstream (checked against 1.0.4 and master,
2026-11-09). beanjar-vnc hands neatvnc its frames as GBM buffers on hosts that have one, so a
client that asks for Open H.264 (noVNC first of all) gets the board's V4L2 hardware encoder, and
two of neatvnc's behaviours there contradict the V4L2 specification.

- `01-v4l2m2m-drm-fourcc.patch`: the DRM fourcc is tried as the V4L2 format first. DRM and V4L2
  share fourcc codes for the same memory layout (DRM `XRGB8888`, `XR24`, bytes B, G, R, X, is V4L2
  `XBGR32`); the name-based table asked for V4L2 `XRGB32` (`BX24`, bytes X, R, G, B), so a driver
  that follows the specification swapped red and blue.
- `02-v4l2m2m-constant-quality.patch`: `open-h264.c` passes a QP-like quality (1 best, 51 worst)
  straight into `V4L2_CID_MPEG_VIDEO_CONSTANT_QUALITY`, whose range is 1 to 100 with 100 best; it
  is mapped as `100 - (q - 1) * 99 / 50`. The QP is held at 18 or better (the client's level 6,
  V4L2 value 67): noVNC's default level 3 (QP 34, value 35) leaves faint vertical streaks in flat
  H.264 areas, and the level also sets Tight's JPEG quality, which a viewer should keep low, so
  the floor is in the H.264 encoder only. Levels 6 to 9 are unchanged.

### Compared with Debian's packaging

Debian's own source packages of these, `aml` 1.0.0-1 and `neatvnc` 1.0.1+dfsg-1, build them with
plain `dh` and Meson. What their packaging carries, and what became of it here:

- `hardening=+all` and Debian's build flags: kept, from `dpkg-buildflags`.
- `-Dtests=true` and running the tests: kept.
- The `+dfsg` repack without `doc/`, `test-images/` and `include/xxhash.h`: dropped. It keeps
  files out of Debian's source package; the tarball has no sources. neatvnc therefore uses its
  bundled header-only xxHash rather than `libxxhash-dev`'s copy, which changes nothing at run
  time.
- The `-dev` and runtime split, `Multi-Arch`, symbols and shlibs files and `-dbgsym` packages:
  Beanjar's packaging's business now. The libraries are stripped.
- The examples Debian installed with `libneatvnc-dev` and `libaml-dev`: not built.

## The tarball

`neatvnc-<version>-<arch>.tar.xz`, for example `neatvnc-1.0.4+beanjar1-amd64.tar.xz`. The version
in `VERSION` is neatvnc's upstream version and the revision of this directory's build of it; aml's
version is in `build.sh`. Its root is the prefix:

| Path | |
|---|---|
| `lib/libneatvnc.so.1.0.4`, `lib/libaml.so.1.0.0` | the libraries, stripped, with their soname and development links; no static libraries |
| `include/neatvnc.h`, `include/aml1/aml.h` | the headers |
| `lib/pkgconfig/neatvnc.pc`, `lib/pkgconfig/aml1.pc` | pkg-config files with `prefix=${pcfiledir}/../..` |
| `share/doc/neatvnc/`, `share/doc/aml/` | upstream's `COPYING` files, and `NOTICE` for the code neatvnc and aml include from elsewhere |
| `BUILDINFO` | program, version, architecture, Debian release, prefix, sonames, the source and patch checksums, and `Depends` |

The pkg-config files find the tree from where they are, so the tree works unpacked anywhere with
`PKG_CONFIG_PATH=<tree>/lib/pkgconfig` and nothing else: no `--define-prefix` (which would
redefine the prefix of every `.pc` file, Debian's too) and no sysroot. They name neatvnc's
dependencies in `Requires.private`, so building against the tree needs the `-dev` packages that
`build.sh` installs.

`BUILDINFO` is in Debian control syntax. Its `Depends` is what `dpkg-shlibdeps` reports for the two
libraries, for the package built from the tarball to depend on; for amd64:

```
Depends: libavcodec61 (>= 7:7.1.5), libavfilter10 (>= 7:7.1.5), libavutil59 (>= 7:7.1.5), libc6 (>= 2.38), libdrm2 (>= 2.4.75), libgbm1 (>= 17.1.0~rc2), libgmp10 (>= 2:6.3.0+dfsg), libgnutls30t64 (>= 3.8.1), libhogweed6t64, libnettle8t64, libpixman-1-0 (>= 0.30.0), libturbojpeg0 (>= 1.2.90), zlib1g (>= 1:1.2.0)
```

## Sources

`neatvnc.sha256` pins GitHub's tag tarballs, `v1.0.4` of `any1/neatvnc` and `v1.0.0` of
`any1/aml`, by SHA-256; `build.sh` downloads them and checks them before anything else. Neither
project uploads release tarballs of its own.

## Building

`neatvnc/build.sh` installs the build dependencies with apt and installs the build into
`/usr/lib/beanjar/neatvnc`, so run it as root in a throwaway `debian:trixie` container on the
architecture you want (amd64 or arm64), for example from the top of a clone:

```sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build:/out" debian:trixie /src/neatvnc/build.sh /out/neatvnc
```

The tarball is written to `build/neatvnc/neatvnc-<version>-<arch>.tar.xz`. `build.sh` ends by
running `neatvnc/test-tarball.sh` on it, with the installed prefix removed: the tarball is
unpacked in another directory and a small program is built against it with pkg-config and run,
which loads both libraries from there. A build takes one to two minutes, dependencies included.

## Continuous integration and releases

The neatvnc workflow (`.github/workflows/neatvnc.yml`) runs `neatvnc/build.sh` in a
`debian:trixie` container on GitHub's amd64 and arm64 runners, natively on each, tests included.
Pushes and pull requests that change `neatvnc/` or the workflow only check that it builds. A
manual run (Actions, neatvnc, "Run workflow") also uploads the tarballs as the run's artifacts
`beanjar-neatvnc-amd64` and `beanjar-neatvnc-arm64`.

To release, push a tag `neatvnc-<version>` matching `VERSION`, for example `neatvnc-1.0.4+beanjar1`;
a tag that does not match fails the build. The workflow builds both architectures and publishes a
GitHub release named after the tag with the two tarballs and a `SHA256SUMS` file.

## Licence

neatvnc and aml are licensed under the ISC licence, and so are the patches here, as changes to
neatvnc (`LICENSES/ISC.txt`). neatvnc and aml include some code from elsewhere under BSD licences;
`NOTICE` lists it and is installed with the libraries. The build scripts, the workflow and the
documentation are GPL-2.0-or-later (the repository's `LICENSE`); every file carries an SPDX header
or is covered by the repository's `REUSE.toml`.
