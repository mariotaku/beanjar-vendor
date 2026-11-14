#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build libepoxy with EGL and virglrenderer for macOS, for this Mac's architecture (arm64 or
# x86_64), against ANGLE's EGL and OpenGL ES from this repository's angle/ tarball, and pack the
# installed libraries as a tarball. Run it on a throwaway Mac (a CI runner): it installs the build
# tools with Homebrew.
#
#   virglrenderer/build.sh ANGLE_TARBALL [OUT]     default OUT: build/virglrenderer in the repository
#
# VERSION holds the version: virglrenderer's upstream version and the commit date and hash it is
# built from (1.3.0+git20261111.01637fc7), plus a Beanjar revision. `sources` pins both projects
# by git commit; patches/<project>/*.patch are applied to each in order. Only vrend (virgl, OpenGL
# ES through ANGLE) is built: no Venus, no video, no DRM renderers, no render server. The result
# is OUT/virglrenderer-<version>-macos-<arch>.tar.xz (<arch> arm64 or amd64), whose root is a
# relocatable prefix:
#
#   lib/libepoxy.0.dylib, lib/libvirglrenderer.1.dylib
#                    install names @rpath/<name>, LC_RPATH @loader_path; libepoxy dlopens
#                    @rpath/libEGL.dylib and @rpath/libGLESv2.dylib (its patch), so it finds
#                    them in the angle tarball unpacked into the same directory
#   lib/pkgconfig/epoxy.pc, virglrenderer.pc   prefix=${pcfiledir}/../..; epoxy.pc requires the
#                    angle tarball's egl.pc
#   include/epoxy/, include/virgl/
#   share/doc/{libepoxy,virglrenderer}/        upstream licences, NOTICE
#   BUILDINFO        what was built from what, and what it needs
#
# test-tarball.sh then builds and runs a program against it and the angle tarball, unpacked in
# another directory.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ $# -ge 1 ] || die "usage: build.sh ANGLE_TARBALL [OUT]"
[ "$(uname -s)" = Darwin ] || die "macOS required"
angle_tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
OUT=${2:-$TOP/../build/virglrenderer}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
case $(uname -m) in
arm64) arch=macos-arm64 ;;
x86_64) arch=macos-amd64 ;;
*) die "arm64 or x86_64, not $(uname -m)" ;;
esac
version=$(cat "$TOP/VERSION")
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "VERSION $version is not <version>+beanjar<N>"
t0=$(date +%s)

step "build tools"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
brew install --quiet meson ninja pkgconf gnu-tar xz
# virglrenderer generates its format tables with Python and PyYAML, at a pinned version
SRC=$OUT/src
rm -rf "$SRC"
python3 -m venv "$SRC/python"
"$SRC/python/bin/pip" install --quiet --disable-pip-version-check PyYAML==6.0.3
export PATH="$SRC/python/bin:$PATH"

step "sources"
mkdir -p "$SRC/angle"
while read -r name url commit; do
	git init -q "$SRC/$name"
	git -C "$SRC/$name" fetch -q --depth 1 "$url" "$commit"
	git -C "$SRC/$name" checkout -q FETCH_HEAD
	[ "$(git -C "$SRC/$name" rev-parse HEAD)" = "$commit" ] || die "$name is not at $commit"
done < "$TOP/sources"
for name in libepoxy virglrenderer; do
	for p in "$TOP/patches/$name"/*.patch; do
		echo "applying $name/$(basename "$p")"
		patch -d "$SRC/$name" -p1 --batch --forward --quiet < "$p"
	done
done
SOURCE_DATE_EPOCH=$(git -C "$SRC/virglrenderer" log -1 --format=%ct)
export SOURCE_DATE_EPOCH
vv=$(sed -n "s/^ *version: '\([0-9.]*\)',/\1/p" "$SRC/virglrenderer/meson.build" | head -1)
case $upstream in "$vv"+git*) ;; *) die "VERSION $version is not virglrenderer $vv" ;; esac
tar -C "$SRC/angle" -xJf "$angle_tarball"
[ "$(sed -n 's/^Architecture: //p' "$SRC/angle/BUILDINFO")" = "$arch" ] ||
	die "the angle tarball is not $arch"

ROOT=$SRC/root
export PKG_CONFIG_PATH="$ROOT/lib/pkgconfig:$SRC/angle/lib/pkgconfig"
# Each library finds what it links, and libepoxy what it dlopens, next to itself
export LDFLAGS="-Wl,-rpath,@loader_path"
meson_build() {
	s=$1
	shift
	meson setup "$SRC/obj-$s" "$SRC/$s" --prefix="$ROOT" --libdir=lib --includedir=include \
		--buildtype=release -Db_ndebug=true --wrap-mode=nodownload \
		-Ddefault_library=shared "$@"
	meson compile -C "$SRC/obj-$s"
	meson install -C "$SRC/obj-$s" --no-rebuild
}

step "libepoxy"
meson_build libepoxy -Degl=yes -Dglx=no -Dx11=false -Dtests=false -Ddocs=false

step "virglrenderer"
meson_build virglrenderer -Dplatforms=egl -Dvenus=false -Dvideo=false -Dtests=false \
	-Ddrm-renderers=[] -Dminigbm_allocation=false

step "tree"
rm -rf "$ROOT/bin" "$ROOT/libexec"
rm -f "$ROOT"/lib/*.a
for l in "$ROOT"/lib/*.dylib; do
	[ -L "$l" ] && continue
	strip -S -x "$l"
	codesign --force --sign - "$l"
	echo "$l:"
	otool -D "$l" | tail -n +2 | grep -q '^@rpath/' || die "$l: install name is not @rpath"
	otool -l "$l" | grep -A2 LC_RPATH | grep path
	! otool -l "$l" | grep -A2 LC_RPATH | grep path | grep -v '@loader_path ' ||
		die "$l: an LC_RPATH other than @loader_path"
	otool -L "$l" | tail -n +2
	! otool -L "$l" | tail -n +2 | grep -v -e '@rpath/' -e '/usr/lib/' -e '/System/' ||
		die "$l links a library outside the tree and the system"
done
mkdir -p "$ROOT/share/doc/libepoxy" "$ROOT/share/doc/virglrenderer"
install -m 0644 "$SRC/libepoxy/COPYING" "$ROOT/share/doc/libepoxy/COPYING"
install -m 0644 "$SRC/virglrenderer/COPYING" "$ROOT/share/doc/virglrenderer/COPYING"
install -m 0644 "$TOP/NOTICE" "$ROOT/share/doc/virglrenderer/NOTICE"
for f in "$ROOT"/lib/pkgconfig/*.pc; do
	grep -qx "prefix=$ROOT" "$f" || die "$f: prefix is not $ROOT"
	# shellcheck disable=SC2016 # ${pcfiledir} is pkg-config's
	sed -i '' 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$f"
	! grep -n "$SRC" "$f" || die "$f names the build directory"
	cat "$f"
done
ls "$ROOT/lib/pkgconfig/epoxy.pc" "$ROOT/lib/pkgconfig/virglrenderer.pc" > /dev/null
{
	echo "Program: virglrenderer"
	echo "Version: $version"
	echo "Architecture: $arch"
	echo "macOS-Release: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), SDK $(xcrun --show-sdk-version)"
	echo "Prefix: relocatable (install names @rpath, pkg-config files by \${pcfiledir})"
	echo "License: MIT (virglrenderer), MIT (libepoxy)"
	echo "Libraries: lib/libvirglrenderer.1.dylib lib/libepoxy.0.dylib"
	echo "Pkg-Config: virglrenderer $(PKG_CONFIG_PATH="$ROOT/lib/pkgconfig:$SRC/angle/lib/pkgconfig" pkg-config --modversion virglrenderer), epoxy $(PKG_CONFIG_PATH="$ROOT/lib/pkgconfig:$SRC/angle/lib/pkgconfig" pkg-config --modversion epoxy)"
	echo "Sources:"
	while read -r name url commit; do
		echo " $name $commit $url"
	done < "$TOP/sources"
	echo "Patches:"
	for p in "$TOP"/patches/*/*.patch; do
		echo " ${p#"$TOP"/patches/} $(shasum -a 256 < "$p" | cut -d' ' -f1)"
	done
	echo "Configure:"
	echo " libepoxy: -Degl=yes -Dglx=no -Dx11=false -Dtests=false -Ddocs=false"
	echo " virglrenderer: -Dplatforms=egl -Dvenus=false -Dvideo=false -Dtests=false -Ddrm-renderers=[] -Dminigbm_allocation=false"
	echo "Requires: angle $(sed -n 's/^Version: //p' "$SRC/angle/BUILDINFO") (libEGL.dylib and libGLESv2.dylib in the same lib/, egl.pc to build against it)"
	echo "Links:"
	for l in "$ROOT"/lib/*.dylib; do
		[ -L "$l" ] && continue
		otool -L "$l" | tail -n +2 | sed 's/^[[:space:]]*//; s/ (.*//; s/^/ /'
	done | sort -u
} > "$ROOT/BUILDINFO"
cat "$ROOT/BUILDINFO"

step "tarball"
tarball=$OUT/virglrenderer-$version-$arch.tar.xz
gtar -C "$ROOT" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cJf "$tarball" .
gtar -tvJf "$tarball"
rm -rf "$SRC"

step "test"
sh "$TOP/test-tarball.sh" "$angle_tarball" "$tarball" "$OUT/test"
echo "$tarball: built in $(( $(date +%s) - t0 )) s"
