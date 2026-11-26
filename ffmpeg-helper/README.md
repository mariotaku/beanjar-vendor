# ffmpeg-helper: FFmpeg with only what Beanjar's media helper decodes

A second, minimal copy of FFmpeg's libraries for [Beanjar](https://github.com/mariotaku/beanjar)'s
media helper, the per-VM process that decodes the guest's audio and video. The helper decodes
whatever a guest sends it, and a guest is not always trusted, so its FFmpeg holds nothing it
cannot use: the decoders the helper can open, their parsers and bitstream filters, and hardware
decoding through VA-API, Vulkan, NVDEC and the V4L2 Request API. No encoder, demuxer, muxer,
protocol, device or filter, no libavformat, and no external library but dav1d. The other host
programs, `beanjar-vnc` among them, keep the full build of [`ffmpeg/`](../ffmpeg/README.md).

The libraries are installed under `/usr/lib/beanjar/ffmpeg-helper`. They have the same sonames
and symbol versions as the full build's and Debian's (`libavcodec.so.61`, `LIBAVCODEC_61`), so
one process must not load two of them: the media helper links only this one.

| Path, under the prefix | |
|---|---|
| `lib/libavcodec.so.*`, `libavutil.so.*`, `libswresample.so.*` | stripped, with Debian's sonames; each finds the others through RUNPATH `$ORIGIN`. libavcodec needs libswresample even with no decoder that resamples, and the helper converts audio with it |
| `lib/pkgconfig/*.pc` | pkg-config files with `prefix=${pcfiledir}/../..` |
| `include/` | the headers |
| `share/doc/ffmpeg-helper/` | FFmpeg's licence texts and `NOTICE` |
| `BUILDINFO` | version, architecture, the codecs and what was enabled for them, sources and patches with their SHA-256, the configure line, and the Debian packages the libraries need (`dpkg-shlibdeps`), in Debian control syntax |

## What is built

The decoders come from the media helper's own code, not from a hand-kept list. `decoders` has one
line per codec the helper accepts from the guest, the codec's FFmpeg name and the decoder the
helper gets for it. Beanjar's `scripts/media-helper-decoders` writes it: each codec that
`caps_codec()` (`host/media/decode/caps.c`) maps a guest's caps to, with the decoder
`avcodec_find_decoder()` picks for it in the full build (as the helper calls it), and each decoder
the helper asks for by name. Beanjar's tests check that the list in the build it pins is the one
its code gives, so a codec added to the helper without a new build here fails there.

`build.sh` derives the rest from that list and from FFmpeg's source, and prints each list:

- decoders: those in `decoders`, under configure's names. A decoder's name is mostly its configure
  name; where not (MSMPEG4 v3's decoder is called `msmpeg4`), the FFCodec definition in the source
  that carries the name gives it (`ff_msmpeg4v3_decoder`). An external library's decoder
  (`libdav1d`, AV1) enables its library;
- parsers: every parser whose `codec_ids` in the source include a codec of the list, because the
  helper parses a stream into frames (`av_parser_init`) for whichever codec it opened;
- hwaccels: every hwaccel of VA-API, Vulkan, NVDEC and V4L2 request whose `_hwaccel_select` in
  `configure` names only decoders (or hwaccels) already enabled. So AV1 has none: the helper
  decodes AV1 with dav1d, and FFmpeg's own `av1` decoder, which the AV1 hwaccels need, is not
  built. VDPAU, Quick Sync, CUVID and V4L2 M2M are not built either;
- bitstream filters, and any other decoder: only what configure selects for the decoders
  (`vp9_superframe_split` for VP9).

The configure line starts with `--disable-everything` and names each of them; `configure` must
enable every one, and no encoder, demuxer, muxer or protocol, or the build stops. Without
`--enable-gpl`, which none of these needs, the libraries are LGPL-2.1-or-later.

The source is the full build's, patched the same way: `../ffmpeg/sources.sh`, which both build
scripts run, takes the FFmpeg release of `VERSION` with the V4L2 request series and Beanjar's
patches, checked against `../ffmpeg/ffmpeg.sha256`. So this build has the Raspberry Pi 5's HEVC
decoder formats too, and its decoders are the code of the full build's, whose build runs FATE.
FATE needs libavformat and the `ffmpeg` program, so it does not run here.

## Version

`<FFmpeg version>+beanjar<N>` in `VERSION`, for example `7.1.5+beanjar1`: the FFmpeg release of
`../ffmpeg/VERSION`, which must match, and the revision of this build, counted on its own.

## Building

As `ffmpeg/`: `ffmpeg-helper/build.sh` installs the build dependencies with apt, so run it as
root in a throwaway `debian:trixie` container on the architecture you want, from the top of a
clone:

```sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build:/out" debian:trixie /src/ffmpeg-helper/build.sh /out/ffmpeg-helper
```

It writes `build/ffmpeg-helper/ffmpeg-helper-<version>-<arch>.tar.xz` and the patched source,
`build/ffmpeg-helper/ffmpeg-helper-<version>-source.tar.xz`, and then runs `test-tarball.sh` with
the installed prefix removed: that unpacks the tarball in another directory, builds a small
program against it with the plain `pkg-config`, and checks that the program runs on the unpacked
libraries, that they are LGPL with no encoder, that each codec of `BUILDINFO` resolves to its
decoder, that H.264 has its four hardware configurations, and that a short H.264 stream parses and
decodes; and that the libraries need nothing but libc, libm, dav1d, libva, libdrm and libudev. A
build takes about three and a half minutes on 24 cores, dependencies included.
`-e STOP_AFTER=configure` stops once FFmpeg is configured.

To update `decoders` after the media helper's codecs change, run Beanjar's
`scripts/media-helper-decoders > ffmpeg-helper/decoders` (it reads the full build that Beanjar
pins), and release a new revision.

## Continuous integration and releases

The workflow `.github/workflows/ffmpeg-helper.yml` runs `ffmpeg-helper/build.sh` in a
`debian:trixie` container on GitHub's amd64 and arm64 runners, natively on each, tests included.
Pushes and pull requests that change `ffmpeg-helper/`, the shared source and patches in `ffmpeg/`
or the workflow only check that it builds. A manual run also uploads the tarballs as the run's
artifacts `beanjar-ffmpeg-helper-amd64` and `beanjar-ffmpeg-helper-arm64`, and the patched source
as `beanjar-ffmpeg-helper-source`.

To release, push a tag `ffmpeg-helper-<version>` matching `VERSION`, for example
`ffmpeg-helper-7.1.5+beanjar1`; a tag that does not match fails the build. The workflow builds
both architectures and publishes a GitHub release named after the tag with the two tarballs, the
patched source and a `SHA256SUMS` file.

## Licence

FFmpeg, and the V4L2 request patches and Beanjar's patches, are LGPL-2.1-or-later, and so are the
libraries as built here (`share/doc/ffmpeg-helper/NOTICE` in the tarball). The build scripts here
are GPL-2.0-or-later (the repository's `LICENSE`); every file carries an SPDX header or is covered
by the repository's `REUSE.toml`.
