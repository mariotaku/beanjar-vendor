# ffmpeg: FFmpeg with V4L2 request hwaccels

A private copy of FFmpeg's libraries for [Beanjar](https://github.com/mariotaku/beanjar)'s host
programs, built for Debian 13 (trixie) on amd64 and arm64 with Jonas Karlman's V4L2 Request API
(stateless decoder) hwaccels. Those let libavcodec decode on the hardware video decoders of SoCs
such as the Rockchip RK3399 or Allwinner H6, which Linux exposes as stateless V4L2 devices and for
which Debian's FFmpeg has no hwaccel.

The libraries are installed under `/usr/lib/beanjar/ffmpeg`, alongside Debian's FFmpeg rather
than in place of it. This directory builds a tarball of that prefix; Beanjar's own packaging turns
it into a package.

| Path, under the prefix | |
|---|---|
| `lib/libav{codec,device,filter,format,util}.so.*`, `libpostproc.so.*`, `libsw{resample,scale}.so.*` | stripped, with Debian's sonames (`libavcodec.so.61`, ...); each finds the others through RUNPATH `$ORIGIN` |
| `lib/pkgconfig/*.pc` | pkg-config files with `prefix=${pcfiledir}/../..` |
| `include/` | the headers |
| `share/doc/ffmpeg/` | FFmpeg's licence texts and `NOTICE` |
| `BUILDINFO` | version, architecture, sources and patches with their SHA-256, the configure line, and the Debian packages the libraries need (`dpkg-shlibdeps`), in Debian control syntax |

A program built against the copy needs a RUNPATH (or RPATH) to `/usr/lib/beanjar/ffmpeg/lib`.
The libraries keep FFmpeg's symbol versions (`LIBAVCODEC_61`, ...), the same as Debian's, so one
process must not load both copies: everything in it that uses FFmpeg has to use this one.

## Version

`<FFmpeg version>+beanjar<N>`, for example `7.1.5+beanjar1`, in `VERSION`: the FFmpeg release
Debian 13 ships, and the revision of this build. Debian's `7:7.1.5-0+deb13u1` is that upstream
release without source patches; its `orig.tar.xz` is byte-identical to ffmpeg.org's tarball. The
upstream part selects the tarball, which `build.sh` downloads from `ffmpeg.org` and checks against
`ffmpeg.sha256`.

## Patches

The 14 commits of [`Kwiboo/FFmpeg`](https://github.com/Kwiboo/FFmpeg) branch
`v4l2-request-n7.1.3` from tag `n7.1.3` up to `fad85d9c76611c09b561167ab405c667a0dcdeb7`,
fetched at build time and exported with `git format-patch`; each exported patch is checked
against `ffmpeg.sha256`. They add the `v4l2request` hardware device type, which finds its media
devices through libudev, hwaccels for MPEG-2, H.264, HEVC, VP8, VP9 and AV1, and the AFBC and
SAND128 capture formats, and apply to 7.1.5 without fuzz. The hwaccels are Linux-generic and
build on amd64 too, although x86 machines have no stateless V4L2 decoder hardware.

## What is built

A plain upstream `configure` build, with a configure line derived from Debian 13's (in
`debian/rules` of its `ffmpeg` source package). Building through Debian's packaging would mean
three flavours (shared, static, extra) and packages and symbols files that would all be thrown
away here, so the plain build is simpler. It uses the same hardened toolchain setting, and runs
FATE, FFmpeg's test suite, without external samples as Debian's build does.

Kept from Debian's set: `--enable-gpl`; the external encoders and decoders (aom, codec2, dav1d,
gsm, jxl, lame, openjpeg, opus, rav1e, shine, snappy for HAP, speex, svt-av1, theora, twolame,
vorbis, vpx, webp, x264, x265, xvid) and soxr for libswresample; the hardware interfaces VA-API,
VDPAU, Vulkan, NVDEC/NVENC/CUVID (through Debian's `libffmpeg-nvenc-dev` headers), V4L2 M2M and
libdrm, and oneVPL (Quick Sync) on amd64 as in Debian; zlib, bzip2, lzma and iconv. Added:
`--enable-libudev --enable-v4l2-request`.

Dropped, because they are not about encoding or decoding audio and video:

- libraries for filters: ass, bs2b, fontconfig, freetype, fribidi, harfbuzz, flite, frei0r,
  ladspa, lv2, mysofa, OpenCL, OpenGL, placebo, glslang, rubberband, vidstab, zimg,
  pocketsphinx;
- input and output devices: ALSA, PulseAudio, JACK, OpenAL, SDL2, xcb and Xlib, caca, dc1394,
  iec61883, cdio;
- protocols and formats: GnuTLS (so no `https:`), libssh, SRT, RIST, ZeroMQ, RabbitMQ, libxml2
  (DASH demuxing), Blu-ray and DVD reading, chromaprint, gme, openmpt;
- rsvg (SVG rendering) and zvbi (teletext);
- the `ffmpeg`, `ffprobe` and `ffplay` programs (`ffmpeg` is built for FATE but not installed),
  the documentation and the static libraries. Debian's GPL-3 `extra` flavour is not built either.

`--disable-autodetect` keeps the result independent of whatever else is installed in the build
system; the autodetected features that are wanted are enabled by name.

## Building

`ffmpeg/build.sh` installs the build dependencies with apt, so run it as root in a throwaway
`debian:trixie` container on the architecture you want (amd64 or arm64), for example from the
top of a clone:

```sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build:/out" debian:trixie /src/ffmpeg/build.sh /out/ffmpeg
```

It writes `build/ffmpeg/ffmpeg-<version>-<arch>.tar.xz` and the patched source,
`build/ffmpeg/ffmpeg-<version>-source.tar.xz`, and then runs `test-tarball.sh` with the installed
prefix removed: that unpacks the tarball in another directory, builds a small program against it
with the plain `pkg-config` (the `.pc` files find the tree from where they are, as neatvnc's do),
and checks that the program runs on the unpacked libraries, finds the `v4l2request` device type
and hwaccels, and encodes and decodes a few H.264 frames. A build takes about four and a half minutes on 24 cores, dependencies and FATE
included. With `-e STOP_AFTER=configure` the script stops once FFmpeg is configured, which is as
far as is practical for the other architecture under qemu-user emulation.

## Continuous integration and releases

The FFmpeg workflow (`.github/workflows/ffmpeg.yml`) runs `ffmpeg/build.sh` in a `debian:trixie`
container on GitHub's amd64 and arm64 runners, natively on each, tests included. Pushes and pull
requests that change `ffmpeg/` or the workflow only check that it builds. A manual run (Actions,
FFmpeg, "Run workflow") also uploads the tarballs as the run's artifacts `beanjar-ffmpeg-amd64`
and `beanjar-ffmpeg-arm64`, and the patched source as `beanjar-ffmpeg-source`.

To release, push a tag `ffmpeg-<version>` matching `VERSION`, for example `ffmpeg-7.1.5+beanjar1`;
a tag that does not match fails the build. The workflow builds both architectures and publishes a
GitHub release named after the tag with the two tarballs, the patched source and a `SHA256SUMS`
file.

## Licence

Most of FFmpeg, and the V4L2 request patches, are LGPL-2.1-or-later. This build is configured
with `--enable-gpl` and links libx264, libx265 and libxvidcore, so the libraries as built are
GPL-2.0-or-later; `share/doc/ffmpeg/NOTICE` in the tarball says so. The build scripts here are
GPL-2.0-or-later (the repository's `LICENSE`); every file carries an SPDX header or is covered by
the repository's `REUSE.toml`.
