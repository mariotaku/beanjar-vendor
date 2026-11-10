#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build neatvnc and the aml main loop library it needs for Debian 13, for this machine's
# architecture (amd64 or arm64), installed with the prefix /usr/lib/beanjar/neatvnc, and pack that
# prefix's contents as a tarball. Run as root in a throwaway debian:trixie container: it installs
# the build dependencies into the system it runs in, and installs the build into the prefix.
#
#   neatvnc/build.sh [OUT]     default OUT: build/neatvnc in the repository
#
# VERSION holds the version, neatvnc's upstream version plus a Beanjar revision (1.0.4+beanjar1).
# Its upstream part and AML_VERSION below name the upstream tag tarballs, downloaded from GitHub
# and checked against neatvnc.sha256. patches/*.patch are applied to neatvnc in order. Both are
# built with Meson and Debian's default build flags (dpkg-buildflags, hardening=+all), and both
# test suites run. The result is OUT/neatvnc-<version>-<arch>.tar.xz, whose root is the prefix:
#
#   lib/libaml.so.1*, lib/libneatvnc.so.1*   stripped; libneatvnc finds libaml by RUNPATH $ORIGIN
#   lib/pkgconfig/aml1.pc, neatvnc.pc        prefix=${pcfiledir}/../..: usable where unpacked
#   include/aml1/aml.h, include/neatvnc.h
#   share/doc/{aml,neatvnc}/                 upstream COPYING files, NOTICE
#   BUILDINFO                                what was built from what, and its Depends
#
# BUILDINFO is in Debian control syntax; its Depends field is dpkg-shlibdeps' for the two
# libraries. test-tarball.sh then builds and runs a small program against the tarball unpacked
# in another directory, with the installed prefix removed.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$TOP/../build/neatvnc}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
export DEBIAN_FRONTEND=noninteractive
PREFIX=/usr/lib/beanjar/neatvnc
AML_VERSION=1.0.0

die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ "$(id -u)" = 0 ] || die "run as root in a throwaway Debian 13 container"
grep -q '^VERSION_ID="13"' /etc/os-release || die "Debian 13 required"
arch=$(dpkg --print-architecture)
case $arch in amd64|arm64) ;; *) die "amd64 or arm64, not $arch" ;; esac
version=$(cat "$TOP/VERSION")
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "VERSION $version is not <neatvnc version>+beanjar<N>"
t0=$(date +%s)

step "build dependencies"
apt-get update
# python3 and openssl are for neatvnc's handshake test; nettle, hogweed and gmp for its RSA-AES
# security types; libpng is optional and only used by the examples.
apt-get install -y --no-install-recommends \
	ca-certificates curl xz-utils patch gcc libc6-dev dpkg-dev binutils meson ninja-build \
	pkgconf python3 openssl \
	libpixman-1-dev libturbojpeg0-dev gnutls-dev nettle-dev libgmp-dev zlib1g-dev libgbm-dev \
	libdrm-dev libavcodec-dev libavfilter-dev libavutil-dev

step "sources"
mkdir -p "$OUT/download"
for f in neatvnc-$upstream.tar.gz aml-$AML_VERSION.tar.gz; do
	grep "  $f\$" "$TOP/neatvnc.sha256" > "$OUT/download/$f.sha256" ||
		die "neatvnc.sha256 has no checksum for $f"
	if ! (cd "$OUT/download" && sha256sum -c --status "$f.sha256" 2>/dev/null); then
		v=${f%.tar.gz}
		curl -fL --retry 3 -o "$OUT/download/$f.part" \
			"https://github.com/any1/${v%-*}/archive/refs/tags/v${v##*-}.tar.gz"
		mv "$OUT/download/$f.part" "$OUT/download/$f"
		(cd "$OUT/download" && sha256sum -c "$f.sha256")
	fi
	rm "$OUT/download/$f.sha256"
done
SRC=$OUT/src
rm -rf "$SRC" "$PREFIX"
mkdir -p "$SRC"
tar -C "$SRC" -xzf "$OUT/download/aml-$AML_VERSION.tar.gz"
tar -C "$SRC" -xzf "$OUT/download/neatvnc-$upstream.tar.gz"
for p in "$TOP"/patches/*.patch; do
	echo "applying $(basename "$p")"
	patch -d "$SRC/neatvnc-$upstream" -p1 --batch --forward --quiet < "$p"
done
# neatvnc's version string comes from git when its source is in a work tree; it is not, and
# OUT may be inside this repository's
export GIT_CEILING_DIRECTORIES="$SRC"

# Debian's build flags, as debhelper would set them
eval "$(DEB_BUILD_MAINT_OPTIONS=hardening=+all dpkg-buildflags --export=sh)"
# meson_build <source> [options]: configure, build, test and install into PREFIX
meson_build() {
	s=$1
	shift
	meson setup "$SRC/obj-${s##*/}" "$s" --prefix="$PREFIX" --libdir=lib --includedir=include \
		--buildtype=plain --wrap-mode=nodownload -Ddefault_library=shared "$@"
	meson compile -C "$SRC/obj-${s##*/}"
	meson test -C "$SRC/obj-${s##*/}" --print-errorlogs
	meson install -C "$SRC/obj-${s##*/}" --no-rebuild
}

step "aml $AML_VERSION"
meson_build "$SRC/aml-$AML_VERSION"

step "neatvnc $upstream"
# libneatvnc finds libaml next to itself, wherever the tree is unpacked
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
LDFLAGS="$LDFLAGS -Wl,-rpath,\$ORIGIN" meson_build "$SRC/neatvnc-$upstream" -Dtests=true \
	-Djpeg=enabled -Dtls=enabled -Dnettle=enabled -Dgbm=enabled -Dh264=enabled

step "tree"
rm -f "$PREFIX"/lib/*.a
for l in "$PREFIX"/lib/*.so.*.*; do
	[ -L "$l" ] || strip --strip-unneeded "$l"
done
for p in aml neatvnc; do
	mkdir -p "$PREFIX/share/doc/$p"
done
install -m 0644 "$SRC/aml-$AML_VERSION/COPYING" "$PREFIX/share/doc/aml/COPYING"
install -m 0644 "$SRC/neatvnc-$upstream/COPYING" "$PREFIX/share/doc/neatvnc/COPYING"
install -m 0644 "$TOP/NOTICE" "$PREFIX/share/doc/neatvnc/NOTICE"
# The .pc files find the tree from their own place, so they need no --define-prefix (which would
# redefine the prefix of every other .pc file too, Debian's included) and no sysroot.
for f in "$PREFIX"/lib/pkgconfig/*.pc; do
	grep -qx "prefix=$PREFIX" "$f" || die "$f: prefix is not $PREFIX"
	# shellcheck disable=SC2016 # ${pcfiledir} is pkg-config's
	sed -i 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$f"
done
runpath=$(readelf -d "$PREFIX/lib/libneatvnc.so.1" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')
# shellcheck disable=SC2016 # the literal $ORIGIN
[ "$runpath" = '$ORIGIN' ] || die "libneatvnc's RUNPATH is '$runpath', not \$ORIGIN"
! readelf -d "$PREFIX/lib/libaml.so.1" | grep -qE 'RPATH|RUNPATH' ||
	die "libaml has a RUNPATH"

# dpkg-shlibdeps runs on a copy of lib/ in a debhelper-like package tree, where it resolves
# libneatvnc's $ORIGIN and leaves out libaml as part of the same package.
SHL=$OUT/shlibdeps
rm -rf "$SHL"
mkdir -p "$SHL/debian/beanjar-neatvnc/DEBIAN" "$SHL/debian/beanjar-neatvnc$PREFIX"
printf 'Source: beanjar-neatvnc\n\nPackage: beanjar-neatvnc\nArchitecture: any\n' \
	> "$SHL/debian/control"
cp -a "$PREFIX/lib" "$SHL/debian/beanjar-neatvnc$PREFIX/"
depends=$(cd "$SHL" && dpkg-shlibdeps -O \
	"debian/beanjar-neatvnc$PREFIX/lib/libaml.so.$AML_VERSION" \
	"debian/beanjar-neatvnc$PREFIX/lib/libneatvnc.so.$upstream" | sed -n 's/^shlibs:Depends=//p')
[ -n "$depends" ] || die "dpkg-shlibdeps reported no dependencies"
rm -rf "$SHL"
{
	echo "Program: neatvnc"
	echo "Version: $version"
	echo "Architecture: $arch"
	echo "Debian-Release: $(cat /etc/debian_version)"
	echo "Prefix: $PREFIX"
	echo "Sonames: libneatvnc.so.1 libaml.so.1"
	echo "Pkg-Config: neatvnc $upstream, aml1 $AML_VERSION"
	echo "Sources:"
	while read -r sum f; do
		v=${f%.tar.gz}
		echo " $f $sum https://github.com/any1/${v%-*}/archive/refs/tags/v${v##*-}.tar.gz"
	done < "$TOP/neatvnc.sha256"
	echo "Patches:"
	for p in "$TOP"/patches/*.patch; do
		echo " $(basename "$p") $(sha256sum < "$p" | cut -d' ' -f1)"
	done
	echo "Depends: $depends"
} > "$PREFIX/BUILDINFO"
cat "$PREFIX/BUILDINFO"

step "tarball"
tarball=$OUT/neatvnc-$version-$arch.tar.xz
# file dates clamped to neatvnc's tag (its tarball's date for COPYING), so equal sources give an
# equal tarball
SOURCE_DATE_EPOCH=$(stat -c %Y "$SRC/neatvnc-$upstream/COPYING")
tar -C "$PREFIX" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cJf "$tarball" .
tar -tvJf "$tarball"
rm -rf "$SRC" "$PREFIX"

step "test"
sh "$TOP/test-tarball.sh" "$tarball" "$OUT/test"
echo "$tarball: built in $(( $(date +%s) - t0 )) s"
