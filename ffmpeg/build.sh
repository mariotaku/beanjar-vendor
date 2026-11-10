#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build FFmpeg with the V4L2 Request API (stateless decoder) hwaccels for Debian 13, for this
# machine's architecture (amd64 or arm64), installed with the prefix /usr/lib/beanjar/ffmpeg, and
# pack that prefix's contents as a tarball. Run as root in a throwaway debian:trixie container: it
# installs the build dependencies into the system it runs in, and installs the build into the
# prefix.
#
#   ffmpeg/build.sh [OUT]     default OUT: build/ffmpeg in the repository
#
# VERSION holds the version: the FFmpeg release Debian 13 ships, plus a Beanjar revision
# (7.1.5+beanjar1). Its upstream part names the release tarball, downloaded from ffmpeg.org. The
# V4L2 request series is the V4L2REQ_COUNT commits of Jonas Karlman's branch up to V4L2REQ_COMMIT,
# exported with git format-patch. The tarball and every patch are checked against ffmpeg.sha256.
# FFmpeg is configured with those of Debian's external libraries and hardware interfaces that
# encode or decode audio and video; FATE, FFmpeg's test suite, runs without external samples as
# in Debian's build. The result is OUT/ffmpeg-<version>-<arch>.tar.xz, whose root is the prefix:
#
#   lib/lib{avcodec,avdevice,avfilter,avformat,avutil,postproc,swresample,swscale}.so.*
#                         stripped, Debian's sonames; each finds the others by RUNPATH $ORIGIN
#   lib/pkgconfig/*.pc    relocatable with pkg-config --define-prefix
#   include/lib*/         the headers
#   share/doc/ffmpeg/     FFmpeg's licence texts, NOTICE
#   BUILDINFO             what was built from what and how, and its Depends
#
# BUILDINFO is in Debian control syntax; its Depends field is dpkg-shlibdeps' for the libraries.
# OUT/ffmpeg-<version>-source.tar.xz is the patched source the libraries are built from.
# test-tarball.sh then builds and runs a small program against the tarball unpacked in another
# directory, with the installed prefix removed.
#
# STOP_AFTER=configure in the environment stops after configure, to check new pins or an
# architecture under emulation, where a full build would take too long.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$TOP/../build/ffmpeg}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
export DEBIAN_FRONTEND=noninteractive
PREFIX=/usr/lib/beanjar/ffmpeg
V4L2REQ_URL=https://github.com/Kwiboo/FFmpeg.git
V4L2REQ_BRANCH=v4l2-request-n7.1.3
V4L2REQ_COMMIT=fad85d9c76611c09b561167ab405c667a0dcdeb7
V4L2REQ_BASE=f46e514491172d15bd74b4abb1814cd2f05a763e # tag n7.1.3
V4L2REQ_COUNT=14
LIBS="avcodec avdevice avfilter avformat avutil postproc swresample swscale"

die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ "$(id -u)" = 0 ] || die "run as root in a throwaway Debian 13 container"
grep -q '^VERSION_ID="13"' /etc/os-release || die "Debian 13 required"
arch=$(dpkg --print-architecture)
case $arch in amd64|arm64) ;; *) die "amd64 or arm64, not $arch" ;; esac
version=$(cat "$TOP/VERSION")
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "VERSION $version is not <FFmpeg version>+beanjar<N>"
revision=${version#"$upstream"+}
t0=$(date +%s)

step "build dependencies"
apt-get update
# Debian's build dependencies for the parts kept (see the configure line), and the tools.
# libvpl (Intel Quick Sync Video) is amd64-only, as in Debian's build.
vpl=
[ "$arch" != amd64 ] || vpl=libvpl-dev
apt-get install -y --no-install-recommends \
	ca-certificates curl git xz-utils patch g++ make nasm pkgconf dpkg-dev binutils patchelf \
	zlib1g-dev libbz2-dev liblzma-dev \
	libaom-dev libdav1d-dev librav1e-dev libsvtav1enc-dev libvpx-dev libx264-dev libx265-dev \
	libxvidcore-dev libtheora-dev libwebp-dev libopenjp2-7-dev libjxl-dev libsnappy-dev \
	libmp3lame-dev libopus-dev libvorbis-dev libspeex-dev libgsm1-dev libshine-dev \
	libtwolame-dev libcodec2-dev libsoxr-dev \
	libdrm-dev libudev-dev libva-dev libvdpau-dev libvulkan-dev libffmpeg-nvenc-dev $vpl

step "sources"
DL=$OUT/download
mkdir -p "$DL"
f=ffmpeg-$upstream.tar.xz
f_sha=$(grep "  $f\$" "$TOP/ffmpeg.sha256" | cut -d' ' -f1)
[ -n "$f_sha" ] || die "ffmpeg.sha256 has no checksum for $f"
if ! echo "$f_sha  $DL/$f" | sha256sum -c --status 2>/dev/null; then
	curl -fL --retry 3 -o "$DL/$f.part" "https://ffmpeg.org/releases/$f"
	mv "$DL/$f.part" "$DL/$f"
	echo "$f_sha  $DL/$f" | sha256sum -c
fi
git=$DL/v4l2-request.git
g() { git -c safe.directory="$git" -C "$git" "$@"; }
[ -d "$git" ] || git init -q --bare "$git"
g fetch -q --depth=$((V4L2REQ_COUNT + 1)) "$V4L2REQ_URL" "$V4L2REQ_COMMIT"
base=$(g rev-parse "$V4L2REQ_COMMIT~$V4L2REQ_COUNT")
[ "$base" = "$V4L2REQ_BASE" ] || die "$V4L2REQ_COMMIT~$V4L2REQ_COUNT is $base, not $V4L2REQ_BASE"
PATCHES=$OUT/patches
rm -rf "$PATCHES"
# --full-index and --zero-commit keep the output independent of the clone, so it can be hashed
g format-patch -q --full-index --no-signature --zero-commit -o "$PATCHES" \
	"$V4L2REQ_BASE..$V4L2REQ_COMMIT"
grep -v "  $f\$" "$TOP/ffmpeg.sha256" > "$OUT/patches.sha256"
if ! (cd "$PATCHES" && sha256sum -- *.patch) | cmp -s - "$OUT/patches.sha256"; then
	echo "build.sh: the exported patches differ from ffmpeg.sha256:" >&2
	(cd "$PATCHES" && sha256sum -- *.patch) | diff "$OUT/patches.sha256" - >&2 || :
	exit 1
fi
rm "$OUT/patches.sha256"
SRC=$OUT/src
rm -rf "$SRC" "$PREFIX"
mkdir -p "$SRC"
tar -C "$SRC" -xJf "$DL/$f"
S=$SRC/ffmpeg-$upstream
for p in "$PATCHES"/*.patch; do
	echo "applying $(basename "$p")"
	patch -d "$S" -p1 --batch --forward --quiet --fuzz=0 < "$p"
done
# file dates clamped to the release tarball's, so equal sources give equal tarballs
SOURCE_DATE_EPOCH=$(stat -c %Y "$S/VERSION")
export SOURCE_DATE_EPOCH
tar -C "$SRC" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" \
	--clamp-mtime -cJf "$OUT/ffmpeg-$version-source.tar.xz" "ffmpeg-$upstream"

step "configure"
# Derived from Debian 13's configure line (debian/rules in its ffmpeg source package). Kept: the
# GPL-2.0-or-later licensing, the hardened toolchain, the external codec libraries and the
# hardware decoders and encoders. Dropped: the external libraries for filters, devices, protocols
# and demuxers, the programs, the documentation and the static libraries. --disable-autodetect
# makes the result independent of whatever else is installed; the autodetected features wanted,
# threads among them, are enabled by name.
set -- \
	--prefix="$PREFIX" --extra-version="$revision" --toolchain=hardened \
	--arch="$(dpkg-architecture -qDEB_HOST_ARCH_CPU)" \
	--enable-gpl --enable-shared --disable-static --disable-doc --disable-stripping \
	--disable-autodetect --enable-pthreads --enable-zlib --enable-bzlib --enable-lzma \
	--enable-iconv \
	--enable-libaom --enable-libcodec2 --enable-libdav1d --enable-libgsm --enable-libjxl \
	--enable-libmp3lame --enable-libopenjpeg --enable-libopus --enable-librav1e \
	--enable-libshine --enable-libsnappy --enable-libsoxr --enable-libspeex \
	--enable-libsvtav1 --enable-libtheora --enable-libtwolame --enable-libvorbis \
	--enable-libvpx --enable-libwebp --enable-libx264 --enable-libx265 --enable-libxvid \
	--enable-libdrm --enable-vaapi --enable-vdpau --enable-vulkan --enable-v4l2-m2m \
	--enable-ffnvcodec --enable-cuda --enable-cuvid --enable-nvdec --enable-nvenc \
	--enable-libudev --enable-v4l2-request
[ "$arch" != amd64 ] || set -- "$@" --enable-libvpl
B=$SRC/obj
mkdir -p "$B"
(cd "$B" && "$S/configure" "$@") || { cat "$B/ffbuild/config.log"; die "configure failed"; }
configure_line="configure $*"
for c in V4L2_REQUEST LIBUDEV LIBDRM VAAPI; do
	grep -q "^#define CONFIG_$c 1\$" "$B/config.h" || die "CONFIG_$c is not enabled"
done
hwaccels=$(sed -n 's/^#define CONFIG_\([A-Z0-9]*\)_V4L2REQUEST_HWACCEL 1$/\1/p' \
	"$B/config_components.h" | tr 'A-Z\n' 'a-z ')
[ -n "$hwaccels" ] || die "no V4L2 request hwaccel is enabled"
if [ "${STOP_AFTER:-}" = configure ]; then
	echo "build.sh: configured, with V4L2 request hwaccels for $hwaccels"
	exit 0
fi

step "build"
jobs=$(nproc)
make -C "$B" -j"$jobs"
# FATE without the external samples, as Debian's build runs it; it needs the ffmpeg program,
# which is built but not installed, and finds the libraries in the build tree as in Debian's
ldpath=
for n in $LIBS; do
	ldpath=$ldpath${ldpath:+:}$B/lib$n
done
LD_LIBRARY_PATH=$ldpath make -C "$B" -j"$jobs" fate
# the libraries, headers and pkg-config files only: no programs, examples or presets
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
mkdir -p "$PREFIX/share/doc/ffmpeg"
for d in COPYING.GPLv2 COPYING.LGPLv2.1 LICENSE.md; do
	install -m 0644 "$S/$d" "$PREFIX/share/doc/ffmpeg/$d"
done
install -m 0644 "$TOP/NOTICE" "$PREFIX/share/doc/ffmpeg/NOTICE"
# relocatable: configure writes libdir and includedir out in full
sed -i -e "s|^libdir=$PREFIX/lib\$|libdir=\${prefix}/lib|" \
	-e "s|^includedir=$PREFIX/include\$|includedir=\${prefix}/include|" "$PREFIX"/lib/pkgconfig/*.pc
if grep -h -v '^prefix=' "$PREFIX"/lib/pkgconfig/*.pc | grep -F "$PREFIX"; then
	die "the .pc lines above name $PREFIX instead of \${prefix}"
fi

# dpkg-shlibdeps needs a debian/control; FFmpeg's own libraries are in the tree, so shlibs.local
# says they need no package.
SHL=$OUT/shlibdeps
rm -rf "$SHL"
mkdir -p "$SHL/debian"
printf 'Source: beanjar-ffmpeg\n\nPackage: beanjar-ffmpeg\nArchitecture: any\n' \
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
{
	echo "Program: ffmpeg"
	echo "Version: $version"
	echo "Architecture: $arch"
	echo "Debian-Release: $(cat /etc/debian_version)"
	echo "Prefix: $PREFIX"
	echo "License: GPL-2.0-or-later"
	echo "Sonames: $sonames"
	echo "V4L2-Request-Hwaccels: ${hwaccels% }"
	echo "Sources:"
	echo " $f $f_sha https://ffmpeg.org/releases/$f"
	echo " $V4L2REQ_URL $V4L2REQ_BRANCH $V4L2REQ_COMMIT ($V4L2REQ_COUNT commits on $V4L2REQ_BASE)"
	echo "Patches:"
	for p in "$PATCHES"/*.patch; do
		echo " $(basename "$p") $(sha256sum < "$p" | cut -d' ' -f1)"
	done
	echo "Configure:"
	echo " $configure_line"
	echo "Depends: $depends"
} > "$PREFIX/BUILDINFO"
cat "$PREFIX/BUILDINFO"

step "tarball"
tarball=$OUT/ffmpeg-$version-$arch.tar.xz
tar -C "$PREFIX" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cJf "$tarball" .
tar -tvJf "$tarball"
rm -rf "$SRC" "$PATCHES" "$PREFIX"

step "test"
sh "$TOP/test-tarball.sh" "$tarball" "$OUT/test"
echo "$tarball: built in $(( $(date +%s) - t0 )) s"
