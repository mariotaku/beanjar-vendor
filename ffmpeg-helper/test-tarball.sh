#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check an ffmpeg-helper tarball from build.sh where it is unpacked, not at its prefix: build a
# small program against it with the plain pkg-config (its .pc files locate the tree by
# ${pcfiledir}), and run it. The program checks that the headers and the libraries agree, that
# the build is LGPL with no encoder, that each codec of BUILDINFO's Codecs resolves to its
# decoder as the media helper finds it (avcodec_find_decoder), that H.264 has the VA-API, NVDEC
# (cuda), Vulkan and V4L2 request hardware configurations, and that a short H.264 stream parses
# and decodes. ldd must resolve every FFmpeg library to the unpacked tree, and the libraries may
# need nothing but libc, libm, dav1d and the hardware interfaces' libraries.
#
#   ffmpeg-helper/test-tarball.sh TARBALL [DIR]     default DIR: a new directory next to TARBALL
#
# Needs xz-utils, gcc, pkgconf and the development headers that build.sh installs; to run the
# program, the libraries in BUILDINFO's Depends.
set -eu
die() { echo "test-tarball.sh: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: test-tarball.sh TARBALL [DIR]"
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
DIR=${2:-${tarball%.tar.xz}-test}
[ ! -e /usr/lib/beanjar/ffmpeg-helper ] || die "remove /usr/lib/beanjar/ffmpeg-helper first"
rm -rf "$DIR"
mkdir -p "$DIR/root"
DIR=$(cd "$DIR" && pwd)
root=$DIR/root
tar -C "$root" -xJf "$tarball"
for l in "$root"/lib/lib*.so; do
	case $(basename "$l") in libavcodec.so|libavutil.so|libswresample.so) ;;
	*) die "unexpected library $(basename "$l")" ;; esac
done

unset PKG_CONFIG_SYSROOT_DIR
export PKG_CONFIG_PATH="$root/lib/pkgconfig"
for v in libdir:lib includedir:include; do
	d=$(pkg-config --variable="${v%:*}" libavcodec)
	[ "$(realpath "$d")" = "$root/${v#*:}" ] || die "libavcodec.pc: ${v%:*} $d is not in $root"
done
# BUILDINFO's Codecs: " <codec> <decoder>" lines
sed -n '/^Codecs:/,/^[^ ]/s/^ \([^ ]*\) \([^ ]*\)$/\1 \2/p' "$root/BUILDINFO" > "$DIR/codecs"
[ -s "$DIR/codecs" ] || die "BUILDINFO has no Codecs"
# an H.264 stream of four 64x48 pictures, Annex B, made with
#   ffmpeg -f lavfi -i testsrc=size=64x48:rate=25 -frames:v 4 -pix_fmt yuv420p -c:v libx264 \
#          -preset veryfast -bf 0 -bsf:v filter_units=remove_types=6 -f h264 t.h264
base64 -d > "$DIR/t.h264" <<'B64'
AAAAAWdkAAqstCPYCIAAAAMAgAAAGQeJE1AAAAABaO8PywAAAWWIhAh/wK4QKchR/+HAiEZT
MerZFphtm86UMf6tOEjnK13DxebHZ1N6YdzvxhD5whBQjaE9Q29vZWPZwDgc6t4+D3V53GC2
XBU9q8PaoXt6Rav3qw+zERrEiVgd79Hp94mCdgNPEPRgeUB/gZvPgjrVj6A8/oPEdeCScRGp
K+NkC46y7RgFNcQQp0jlsNqEXAN2RTdwITR3StdhIs6IKer9EyfKGSqdS/RKwiTYi+tYRdcr
GFklhjBWm8mcz2hfDJ6OCuIsJwcbB7w74uP/VtgBEJFBltHdwVkcXnefR4gIo5ZEceDMGCxg
8Ry7Vz3W6hJzbQkAvvtIoPVcwymkS/q4X8BsSjIghZuItWlhrRiBC9NtDpex8zLb/XfaeAlm
RXnDIUMrFCHmko3fpDjxmrGX/0QpXUH2LP5A7XApriEF5D4FsukQkJAM+8Qrp5XCXHKdw3Oy
ue1fKEQX8n/krk/5upl5bfHAS6/+uib+LQhdS5JETQ3LmLtwVsXnHI/2FQ/utPsMDT/jFkzN
biL+AEcQBNkjFbJNiElpic+O/ZwKcjECKi6WwqaHcd+jsjc7q/chzCSTjKVGdLO11oJuIk9c
bBBqYyD213sFAva5Gk5F0dUoUzIQr4l8nIucxWy1mz2SmUaNwPaCUkrg/rL4wQAAAAFBmiYh
Lyeqa2Y118wAAAABQZpGIU8pyB3BgcmU77OqlHNH/+0AAAABQZpmIY84EvWQGHLA
B64
cat > "$DIR/t.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>

static int fail(const char *what) { fprintf(stderr, "FAIL: %s\n", what); return 1; }

int main(int argc, char **argv)
{
	if (argc != 3)
		return fail("usage: t CODECS STREAM");
	if (avcodec_version() != LIBAVCODEC_VERSION_INT || avutil_version() != LIBAVUTIL_VERSION_INT)
		return fail("headers and libraries differ");
	printf("libavcodec %s, %s, %s\n", AV_STRINGIFY(LIBAVCODEC_VERSION), av_version_info(),
	       avcodec_license());
	if (!strstr(avcodec_license(), "LGPL") || strstr(avcodec_configuration(), "--enable-gpl"))
		return fail("not LGPL");
	const AVCodec *c;
	void *it = NULL;
	int decoders = 0;
	while ((c = av_codec_iterate(&it))) {
		if (av_codec_is_encoder(c))
			return fail("an encoder is built");
		decoders++;
	}

	/* each codec the media helper accepts resolves to its decoder */
	FILE *f = fopen(argv[1], "r");
	char codec[64], decoder[64];
	int codecs = 0;
	while (f && fscanf(f, "%63s %63s", codec, decoder) == 2) {
		const AVCodecDescriptor *d = avcodec_descriptor_get_by_name(codec);
		const AVCodec *dec = d ? avcodec_find_decoder(d->id) : NULL;
		if (!dec || strcmp(dec->name, decoder)) {
			fprintf(stderr, "%s: %s, not %s\n", codec, dec ? dec->name : "no decoder", decoder);
			return fail("codec without its decoder");
		}
		codecs++;
	}
	if (!f || !codecs)
		return fail("no codecs");
	printf("%d codecs, each to its decoder; %d decoders, no encoder\n", codecs, decoders);

	/* H.264's hardware configurations */
	const enum AVHWDeviceType want[] = { AV_HWDEVICE_TYPE_VAAPI, AV_HWDEVICE_TYPE_CUDA,
		AV_HWDEVICE_TYPE_VULKAN, AV_HWDEVICE_TYPE_V4L2REQUEST };
	const AVCodec *h264 = avcodec_find_decoder(AV_CODEC_ID_H264);
	for (unsigned w = 0; w < sizeof want / sizeof *want; w++) {
		int found = 0;
		for (int i = 0;; i++) {
			const AVCodecHWConfig *hw = avcodec_get_hw_config(h264, i);
			if (!hw)
				break;
			found |= hw->device_type == want[w];
		}
		printf("h264: %s %s\n", av_hwdevice_get_type_name(want[w]), found ? "yes" : "no");
		if (!found)
			return fail("hardware configuration missing");
	}

	/* the stream through the parser into the decoder, as the helper does */
	static unsigned char buf[4096 + AV_INPUT_BUFFER_PADDING_SIZE];
	FILE *s = fopen(argv[2], "rb");
	size_t n = s ? fread(buf, 1, 4096, s) : 0;
	AVCodecParserContext *parser = av_parser_init(AV_CODEC_ID_H264);
	AVCodecContext *ctx = avcodec_alloc_context3(h264);
	if (!n || !parser || !ctx || avcodec_open2(ctx, h264, NULL) < 0)
		return fail("open");
	AVPacket *pkt = av_packet_alloc();
	AVFrame *frame = av_frame_alloc();
	int decoded = 0;
	for (size_t off = 0;;) {
		uint8_t *data;
		int size;
		/* the last call, with no data left, flushes the parser's last picture */
		int left = (int)(n - off);
		off += av_parser_parse2(parser, ctx, &data, &size, buf + off, left, AV_NOPTS_VALUE,
		                        AV_NOPTS_VALUE, 0);
		if (size) {
			pkt->data = data;
			pkt->size = size;
			if (avcodec_send_packet(ctx, pkt) < 0)
				return fail("send_packet");
			while (avcodec_receive_frame(ctx, frame) == 0)
				decoded++;
		} else if (!left)
			break;
	}
	avcodec_send_packet(ctx, NULL);
	while (avcodec_receive_frame(ctx, frame) == 0)
		decoded++;
	printf("h264: %d pictures parsed and decoded, %dx%d\n", decoded, ctx->width, ctx->height);
	return decoded == 4 && ctx->width == 64 && ctx->height == 48 ? 0 : fail("picture count");
}
C
# shellcheck disable=SC2046 # pkg-config output is word-split on purpose
cc -o "$DIR/t" "$DIR/t.c" $(pkg-config --cflags --libs libavcodec libavutil) \
	-Wl,-rpath,"$root/lib"
ldd "$DIR/t" | tee "$DIR/ldd.txt"
for l in avcodec avutil swresample; do
	grep -q "lib$l\.so\.[0-9]* => $root/lib/" "$DIR/ldd.txt" ||
		die "lib$l does not resolve into $root/lib"
done
if grep -E 'lib(av|sw|postproc)[a-z]*\.so' "$DIR/ldd.txt" | grep -v -q "=> $root/lib/"; then
	die "an FFmpeg library resolves outside the tree"
fi
# what the libraries need besides each other: libc (and its loader), libm, dav1d, VA-API, DRM
# and udev
others=$(for l in "$root"/lib/lib*.so.*.*.*; do
	readelf -d "$l" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'
done | grep -v -E '^lib(avcodec|avutil|swresample)\.so' | sort -u | tr '\n' ' ')
echo "needed: $others"
for n in $others; do
	case $n in
	ld-linux*.so.*|libc.so.*|libm.so.*|libdav1d.so.*|libva.so.*|libva-drm.so.*|libdrm.so.*|libudev.so.*) ;;
	*) die "the libraries need $n" ;;
	esac
done
"$DIR/t" "$DIR/codecs" "$DIR/t.h264"
echo "$tarball: built and ran a program against it, unpacked in $root"
