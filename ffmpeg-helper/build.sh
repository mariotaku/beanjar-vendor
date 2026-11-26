#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the media helper's own FFmpeg: the libraries libavcodec, libavutil and libswresample
# with only the decoders Beanjar's media helper can open (the list in `decoders`), their parsers,
# and the hardware decoding of VA-API, Vulkan, NVDEC and the V4L2 Request API, for Debian 13 on
# this machine's architecture (amd64 or arm64), installed with the prefix
# /usr/lib/beanjar/ffmpeg-helper, and pack that prefix's contents as a tarball. Run as root in a
# throwaway debian:trixie container: it installs the build dependencies into the system it runs
# in, and installs the build into the prefix.
#
#   ffmpeg-helper/build.sh [OUT]     default OUT: build/ffmpeg-helper in the repository
#
# VERSION holds the version: the FFmpeg release of ../ffmpeg, plus a Beanjar revision
# (7.1.5+beanjar1). The source is ../ffmpeg's, patches and all (../ffmpeg/sources.sh), so the
# code of every decoder here is the code of the full build's.
#
# What is enabled follows from `decoders`, which Beanjar generates from the media helper's code
# (its scripts/media-helper-decoders), and from FFmpeg's own source:
#
#   decoders   each decoder in `decoders`, under its configure name (FFmpeg's decoder name,
#              or for the few that differ, the name of the FFCodec that carries it)
#   parsers    each parser whose codec_ids include a codec in `decoders`: the helper parses a
#              stream into frames with av_parser_init() for whichever codec it opened
#   hwaccels   each of configure's hwaccels for VA-API, Vulkan, NVDEC and V4L2 request whose
#              _hwaccel_select names only decoders (and hwaccels) enabled above
#   bsfs       none but those configure selects for the decoders
#   demuxers, muxers, encoders, protocols, devices, filters: none (--disable-everything); the
#              helper takes elementary streams from the guest and links no libavformat
#
# The result is OUT/ffmpeg-helper-<version>-<arch>.tar.xz, whose root is the prefix:
#
#   lib/lib{avcodec,avutil,swresample}.so.*
#                         stripped, Debian's sonames; each finds the others by RUNPATH $ORIGIN
#   lib/pkgconfig/*.pc    prefix=${pcfiledir}/../..: usable where unpacked
#   include/lib*/         the headers
#   share/doc/ffmpeg-helper/  FFmpeg's licence texts, NOTICE
#   BUILDINFO             what was built from what and how, what it holds, and its Depends
#
# OUT/ffmpeg-helper-<version>-source.tar.xz is the patched source the libraries are built from.
# test-tarball.sh then builds and runs a small program against the tarball unpacked in another
# directory, with the installed prefix removed.
#
# STOP_AFTER=configure in the environment stops after configure.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
FF=$(cd "$TOP/../ffmpeg" && pwd)
OUT=${1:-$TOP/../build/ffmpeg-helper}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
export DEBIAN_FRONTEND=noninteractive
PREFIX=/usr/lib/beanjar/ffmpeg-helper
LIBS="avcodec avutil swresample"
# The hardware decoding the helper may use: FFmpeg's hwaccel name suffixes, and the configure
# options of the interfaces behind them. NVDEC's device type is cuda; the V4L2 request hwaccels
# take DRM PRIME frames (libdrm) and find their media devices through libudev.
HW_APIS="vaapi vulkan nvdec v4l2request"
HW_OPTIONS="--enable-libdrm --enable-vaapi --enable-vulkan --enable-ffnvcodec --enable-cuda
	--enable-nvdec --enable-libudev --enable-v4l2-request"

die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ "$(id -u)" = 0 ] || die "run as root in a throwaway Debian 13 container"
grep -q '^VERSION_ID="13"' /etc/os-release || die "Debian 13 required"
arch=$(dpkg --print-architecture)
case $arch in amd64|arm64) ;; *) die "amd64 or arm64, not $arch" ;; esac
version=$(cat "$TOP/VERSION")
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "VERSION $version is not <FFmpeg version>+beanjar<N>"
[ "$upstream" = "$(sed 's/+beanjar.*//' "$FF/VERSION")" ] ||
	die "VERSION $version is not the FFmpeg release of ../ffmpeg/VERSION"
revision=${version#"$upstream"+}
# `decoders`: "<codec> <decoder>" lines, # comments
codecs=$(sed -e 's/#.*//' "$TOP/decoders" | awk 'NF { print $1 }')
decoders=$(sed -e 's/#.*//' "$TOP/decoders" | awk 'NF { print $2 }' | sort -u)
[ -n "$decoders" ] || die "decoders lists none"
t0=$(date +%s)

step "build dependencies"
apt-get update
# The decoders' one external library (dav1d) and the hardware interfaces' headers, and the tools
apt-get install -y --no-install-recommends \
	ca-certificates curl git xz-utils patch gcc libc6-dev make nasm pkgconf dpkg-dev binutils \
	patchelf \
	libdav1d-dev libdrm-dev libudev-dev libva-dev libvulkan-dev libffmpeg-nvenc-dev

step "sources"
SOURCE_TARBALL=$OUT/ffmpeg-helper-$version-source.tar.xz
rm -rf "$PREFIX"
# shellcheck source=ffmpeg/sources.sh
. "$FF/sources.sh"

step "components"
# Decoders by configure name. FFmpeg names a decoder after its FFCodec (ff_<name>_decoder) but
# reports .p.name, and a few differ (ff_msmpeg4v3_decoder is "msmpeg4"): those are looked up in
# the source.
known=$("$S/configure" --list-decoders | tr -s ' \t' '\n\n' | sed '/^$/d')
enable_decoders=
for d in $decoders; do
	if echo "$known" | grep -qx "$d"; then
		c=$d
	else
		c=$(awk -v want="$d" '
			/^const FFCodec ff_[a-z0-9_]+_decoder = \{/ {
				sym = $3; sub(/^ff_/, "", sym); sub(/_decoder$/, "", sym); next
			}
			sym != "" && /\.p\.name *= *"/ {
				n = $0; sub(/.*\.p\.name *= *"/, "", n); sub(/".*/, "", n)
				if (n == want) print sym
				sym = ""
			}
			/^};/ { sym = "" }' $(find "$S/libavcodec" -name "*.c"))
		[ "$(echo "$c" | wc -w)" = 1 ] || die "decoder $d: no single FFCodec in the source ($c)"
		echo "decoder $d is configure's $c"
	fi
	enable_decoders="$enable_decoders $c"
done
enable_decoders=$(echo "$enable_decoders" | tr ' ' '\n' | sed '/^$/d' | sort -u)
# External libraries' decoders (lib<name>) need their library enabled by name
enable_libs=$(echo "$enable_decoders" | sed -n 's/^\(lib[a-z0-9]*\)$/--enable-\1/p')
# Parsers: every "<parser> <codec>" of the source's AVCodecParser definitions, for the codecs
parser_ids=$(awk '
	/^const AVCodecParser ff_[a-z0-9_]+_parser = \{/ {
		p = $3; sub(/^ff_/, "", p); sub(/_parser$/, "", p); ids = ""; in_ids = 0
	}
	p != "" && /\.codec_ids/ { in_ids = 1 }
	in_ids {
		ids = ids " " $0
		if (/\}/) {
			in_ids = 0
			while (match(ids, /AV_CODEC_ID_[A-Z0-9_]+/)) {
				print p, tolower(substr(ids, RSTART + 12, RLENGTH - 12))
				ids = substr(ids, RSTART + RLENGTH)
			}
			p = ""
		}
	}' $(find "$S/libavcodec" -name "*.c") | sort -u)
[ -n "$parser_ids" ] || die "no parser definitions found in the source"
enable_parsers=$(for c in $codecs; do echo "$parser_ids" | awk -v c="$c" '$2 == c { print $1 }'
	done | sort -u)
# Hwaccels: <codec>_<api>, for the APIs above, whose _hwaccel_select is all enabled; a hwaccel
# may select another one (wmv3_vaapi selects vc1_vaapi), so until nothing changes
selects=$(sed -n 's/^\([a-z0-9_]*\)_hwaccel_select="\(.*\)"$/\1 \2/p' "$S/configure")
have=$(echo "$enable_decoders" | sed 's/$/_decoder/')
enable_hwaccels=
while :; do
	more=$(echo "$selects" | while read -r h sel; do
		api=${h##*_}
		case " $HW_APIS " in *" $api "*) ;; *) continue ;; esac
		echo "$have" | grep -qx "${h}_hwaccel" && continue
		ok=1
		for s in $sel; do echo "$have" | grep -qx "$s" || ok=; done
		[ -z "$ok" ] || echo "$h"
	done)
	[ -n "$more" ] || break
	enable_hwaccels=$(printf '%s\n%s\n' "$enable_hwaccels" "$more" | sed '/^$/d' | sort -u)
	have=$(printf '%s\n%s\n' "$have" "$(echo "$more" | sed 's/$/_hwaccel/')")
done
list() { echo "$1" | tr '\n' ',' | sed 's/,$//'; }
echo "decoders: $(list "$enable_decoders")"
echo "parsers: $(list "$enable_parsers")"
echo "hwaccels: $(list "$enable_hwaccels")"

step "configure"
# Only libavcodec, libavutil and libswresample (which libavcodec needs), with nothing in them but
# the components above (--disable-everything first, then each by name). Not GPL: none of the
# components needs it, so the libraries are LGPL-2.1-or-later. The same hardened toolchain as
# ../ffmpeg; --disable-autodetect makes the result independent of whatever else is installed,
# and the features wanted, threads among them, are enabled by name.
# shellcheck disable=SC2086 # the lists are word-split on purpose
set -- \
	--prefix="$PREFIX" --extra-version="$revision" --toolchain=hardened \
	--arch="$(dpkg-architecture -qDEB_HOST_ARCH_CPU)" \
	--enable-shared --disable-static --disable-doc --disable-stripping --disable-programs \
	--disable-autodetect --enable-pthreads \
	--disable-avformat --disable-avdevice --disable-avfilter --disable-swscale \
	--disable-postproc --disable-network \
	--disable-everything \
	--enable-decoder="$(list "$enable_decoders")" \
	--enable-parser="$(list "$enable_parsers")" \
	--enable-hwaccel="$(list "$enable_hwaccels")" \
	$enable_libs $HW_OPTIONS
B=$SRC/obj
mkdir -p "$B"
(cd "$B" && "$S/configure" "$@") || { cat "$B/ffbuild/config.log"; die "configure failed"; }
configure_line="configure $*"
for c in V4L2_REQUEST LIBUDEV LIBDRM VAAPI VULKAN NVDEC CUDA; do
	grep -q "^#define CONFIG_$c 1\$" "$B/config.h" || die "CONFIG_$c is not enabled"
done
! grep -q '^#define CONFIG_GPL 1$' "$B/config.h" || die "configured as GPL"
# What configure enabled: the components asked for, and those it selected for them
enabled() {
	sed -n "s/^#define CONFIG_\\([A-Z0-9_]*\\)_$1 1\$/\\1/p" "$B/config_components.h" |
		tr 'A-Z' 'a-z' | sort
}
# the sets compared as files: what was asked for, and what configure enabled
want=$OUT/want
mkdir -p "$want"
echo "$enable_decoders" > "$want/decoder"
echo "$enable_parsers" > "$want/parser"
echo "$enable_hwaccels" > "$want/hwaccel"
for kind in decoder parser hwaccel; do
	enabled "$(echo "$kind" | tr 'a-z' 'A-Z')" > "$want/$kind.enabled"
	missing=$(sort "$want/$kind" | sed '/^$/d' | comm -23 - "$want/$kind.enabled")
	[ -z "$missing" ] || die "configure did not enable the ${kind}s $(list "$missing")"
done
selected=$(comm -13 "$want/decoder" "$want/decoder.enabled")
rm -rf "$want"
[ -z "$selected" ] || echo "configure selected the decoders $(list "$selected") too"
built_decoders=$(enabled DECODER)
built_parsers=$(enabled PARSER)
built_hwaccels=$(enabled HWACCEL)
built_bsfs=$(enabled BSF)
if [ -n "$(enabled ENCODER)$(enabled DEMUXER)$(enabled MUXER)$(enabled PROTOCOL)" ]; then
	die "an encoder, demuxer, muxer or protocol is enabled"
fi
if [ "${STOP_AFTER:-}" = configure ]; then
	echo "build.sh: configured: decoders $(list "$built_decoders")"
	exit 0
fi

step "build"
make -C "$B" -j"$(nproc)"
# the libraries, headers and pkg-config files only
make -C "$B" install-libs install-headers

step "tree"
for l in "$PREFIX"/lib/*.so.*.*.*; do
	strip --strip-unneeded "$l"
	# shellcheck disable=SC2016 # a literal $ORIGIN
	patchelf --set-rpath '$ORIGIN' "$l"
done
sonames=
for n in $LIBS; do
	so=$(readelf -d "$PREFIX/lib/lib$n.so" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
	[ -e "$PREFIX/lib/$so" ] || die "lib$n has no $so"
	sonames="$sonames $so"
done
sonames=${sonames# }
for l in "$PREFIX"/lib/lib*.so; do
	case " $LIBS " in *" $(basename "$l" .so | sed 's/^lib//') "*) ;; *) die "unexpected $l" ;; esac
done
mkdir -p "$PREFIX/share/doc/ffmpeg-helper"
for d in COPYING.LGPLv2.1 LICENSE.md; do
	install -m 0644 "$S/$d" "$PREFIX/share/doc/ffmpeg-helper/$d"
done
install -m 0644 "$TOP/NOTICE" "$PREFIX/share/doc/ffmpeg-helper/NOTICE"
for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
	grep -qx "prefix=$PREFIX" "$pc" || die "$pc: prefix is not $PREFIX"
	# shellcheck disable=SC2016 # ${pcfiledir} and ${prefix} are pkg-config's
	sed -i -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
		-e "s|^libdir=$PREFIX/lib\$|libdir=\${prefix}/lib|" \
		-e "s|^includedir=$PREFIX/include\$|includedir=\${prefix}/include|" "$pc"
done
if grep -h -v '^prefix=' "$PREFIX"/lib/pkgconfig/*.pc | grep -F "$PREFIX"; then
	die "the .pc lines above name $PREFIX instead of \${prefix}"
fi

# dpkg-shlibdeps needs a debian/control; FFmpeg's own libraries are in the tree, so shlibs.local
# says they need no package.
SHL=$OUT/shlibdeps
rm -rf "$SHL"
mkdir -p "$SHL/debian"
printf 'Source: beanjar-ffmpeg-helper\n\nPackage: beanjar-ffmpeg-helper\nArchitecture: any\n' \
	> "$SHL/debian/control"
for so in $sonames; do
	echo "${so%%.so.*} ${so##*.so.}"
done > "$SHL/debian/shlibs.local"
set --
for so in $sonames; do
	set -- "$@" -e"$(readlink -f "$PREFIX/lib/$so")"
done
depends=$(cd "$SHL" && dpkg-shlibdeps -O -l"$PREFIX/lib" "$@" | sed -n 's/^shlibs:Depends=//p')
[ -n "$depends" ] || die "dpkg-shlibdeps reported no dependencies"
rm -rf "$SHL"
field() { echo "$1" | tr '\n' ' ' | sed 's/ $//'; }
{
	echo "Program: ffmpeg-helper"
	echo "Version: $version"
	echo "Architecture: $arch"
	echo "Debian-Release: $(cat /etc/debian_version)"
	echo "Prefix: $PREFIX"
	echo "License: LGPL-2.1-or-later"
	echo "Sonames: $sonames"
	echo "Codecs:"
	sed -e 's/#.*//' "$TOP/decoders" | awk 'NF { print " " $1, $2 }'
	echo "Decoders: $(field "$built_decoders")"
	echo "Parsers: $(field "$built_parsers")"
	echo "Hwaccels: $(field "$built_hwaccels")"
	echo "Bitstream-Filters: $(field "$built_bsfs")"
	echo "Sources:"
	echo " $f $f_sha https://ffmpeg.org/releases/$f"
	echo " $V4L2REQ_URL $V4L2REQ_BRANCH $V4L2REQ_COMMIT ($V4L2REQ_COUNT commits on $V4L2REQ_BASE)"
	echo "Patches:"
	for p in "$PATCHES"/*.patch; do
		echo " $(basename "$p") $(sha256sum < "$p" | cut -d' ' -f1)"
	done
	for p in "$FF"/patches/*.patch; do
		echo " patches/$(basename "$p") $(sha256sum < "$p" | cut -d' ' -f1)"
	done
	echo "Configure:"
	echo " $configure_line"
	echo "Depends: $depends"
} > "$PREFIX/BUILDINFO"
cat "$PREFIX/BUILDINFO"

step "tarball"
tarball=$OUT/ffmpeg-helper-$version-$arch.tar.xz
tar -C "$PREFIX" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cJf "$tarball" .
tar -tvJf "$tarball"
rm -rf "$SRC" "$PATCHES" "$PREFIX"

step "test"
sh "$TOP/test-tarball.sh" "$tarball" "$OUT/test"
echo "$tarball: built in $(( $(date +%s) - t0 )) s"
