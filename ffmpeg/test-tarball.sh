#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check an FFmpeg tarball from build.sh: unpack it into another directory than its prefix, build a
# small program against it with pkg-config --define-prefix, and run it. The program checks that
# the headers and the libraries agree, that the V4L2 request device type and the configured
# hwaccels are there, and that libx264 encodes and the native decoder decodes a few frames. ldd
# must resolve every FFmpeg library to the unpacked tree.
#
#   ffmpeg/test-tarball.sh TARBALL [DIR]     default DIR: a temporary directory, removed after
set -eu
tarball=$(readlink -f "$1")
DIR=${2:-}
die() { echo "test-tarball.sh: $*" >&2; exit 1; }
[ ! -e /usr/lib/beanjar/ffmpeg ] || die "remove /usr/lib/beanjar/ffmpeg first"
if [ -z "$DIR" ]; then
	DIR=$(mktemp -d)
	trap 'rm -rf "$DIR"' EXIT
fi
rm -rf "$DIR"
root=$DIR/unpacked/ffmpeg
mkdir -p "$root"
tar -C "$root" -xJf "$tarball"
export PKG_CONFIG_PATH="$root/lib/pkgconfig"
[ "$(pkg-config --define-prefix --variable=libdir libavcodec)" = "$root/lib" ] ||
	die "pkg-config --define-prefix does not relocate libavcodec.pc"
mods="libavcodec libavutil"
cat > "$DIR/t.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>

static int fail(const char *what) { fprintf(stderr, "FAIL: %s\n", what); return 1; }

int main(void)
{
	if (avcodec_version() != LIBAVCODEC_VERSION_INT || avutil_version() != LIBAVUTIL_VERSION_INT)
		return fail("headers and libraries differ");
	printf("libavcodec %s, %s\n", AV_STRINGIFY(LIBAVCODEC_VERSION), av_version_info());
	if (!strstr(avcodec_configuration(), "--enable-v4l2-request"))
		return fail("not configured with --enable-v4l2-request");
	if (av_hwdevice_find_type_by_name("v4l2request") != AV_HWDEVICE_TYPE_V4L2REQUEST)
		return fail("no v4l2request device type");
	const char *codecs[] = { "h264", "hevc", "vp8", "vp9", "mpeg2video", "av1" };
	for (unsigned c = 0; c < sizeof(codecs) / sizeof(*codecs); c++) {
		const AVCodec *dec = avcodec_find_decoder_by_name(codecs[c]);
		int found = 0;
		for (int i = 0; dec; i++) {
			const AVCodecHWConfig *hw = avcodec_get_hw_config(dec, i);
			if (!hw)
				break;
			found |= hw->device_type == AV_HWDEVICE_TYPE_V4L2REQUEST;
		}
		printf("%s: v4l2request %s\n", codecs[c], found ? "yes" : "no");
		if (!found && strcmp(codecs[c], "av1"))
			return fail("hwaccel missing");
	}

	/* libx264 encodes 10 frames, the native decoder decodes them */
	const AVCodec *enc = avcodec_find_encoder_by_name("libx264");
	const AVCodec *dec = avcodec_find_decoder(AV_CODEC_ID_H264);
	if (!enc || !dec)
		return fail("no libx264 or h264");
	AVCodecContext *e = avcodec_alloc_context3(enc), *d = avcodec_alloc_context3(dec);
	e->width = 320; e->height = 240; e->pix_fmt = AV_PIX_FMT_YUV420P;
	e->time_base = (AVRational){ 1, 25 }; e->gop_size = 10; e->max_b_frames = 0;
	if (avcodec_open2(e, enc, NULL) < 0 || avcodec_open2(d, dec, NULL) < 0)
		return fail("open");
	AVFrame *f = av_frame_alloc(), *out = av_frame_alloc();
	AVPacket *pkt = av_packet_alloc();
	f->width = e->width; f->height = e->height; f->format = e->pix_fmt;
	if (av_frame_get_buffer(f, 0) < 0)
		return fail("frame");
	int decoded = 0;
	for (int n = 0; n <= 10; n++) {
		if (n < 10) {
			av_frame_make_writable(f);
			for (int y = 0; y < f->height; y++)
				memset(f->data[0] + y * f->linesize[0], (y + n * 8) & 0xff, f->width);
			memset(f->data[1], 128, f->linesize[1] * f->height / 2);
			memset(f->data[2], 128, f->linesize[2] * f->height / 2);
			f->pts = n;
		}
		if (avcodec_send_frame(e, n < 10 ? f : NULL) < 0)
			return fail("send_frame");
		while (avcodec_receive_packet(e, pkt) == 0) {
			if (avcodec_send_packet(d, pkt) < 0)
				return fail("send_packet");
			av_packet_unref(pkt);
			while (avcodec_receive_frame(d, out) == 0)
				decoded++;
		}
	}
	avcodec_send_packet(d, NULL);
	while (avcodec_receive_frame(d, out) == 0)
		decoded++;
	printf("libx264 -> h264: %d frames decoded\n", decoded);
	return decoded == 10 ? 0 : fail("frame count");
}
C
# shellcheck disable=SC2046,SC2086 # pkg-config output is word-split on purpose
cc -o "$DIR/t" "$DIR/t.c" $(pkg-config --define-prefix --cflags $mods) \
	$(pkg-config --define-prefix --libs $mods) -Wl,-rpath,"$root/lib"
ldd "$DIR/t" | tee "$DIR/ldd.txt"
for l in avcodec avutil swresample; do
	grep -q "lib$l\.so\.[0-9]* => $root/lib/" "$DIR/ldd.txt" ||
		die "lib$l does not resolve into $root/lib"
done
if grep -E 'lib(av|sw|postproc)[a-z]*\.so' "$DIR/ldd.txt" | grep -v -q "=> $root/lib/"; then
	die "an FFmpeg library resolves outside the tree"
fi
"$DIR/t"
echo "test-tarball.sh: $(basename "$tarball") OK"
