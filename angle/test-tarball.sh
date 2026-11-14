#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check an ANGLE tarball from build.sh where it is unpacked: build egl-check.c against it with
# the plain pkg-config (its .pc files locate the tree by ${pcfiledir}) and run it. The program
# makes an EGL display on ANGLE's Metal backend, an OpenGL ES 3 context on a pbuffer, clears it,
# reads a pixel back and prints GL_RENDERER. Without a Metal device it cannot get that far: the
# check then only says so, unless ANGLE_REQUIRE_METAL=1.
#
#   angle/test-tarball.sh TARBALL [DIR]     default DIR: a new directory next to TARBALL
#
# Needs xz, pkgconf and Xcode's command line tools.
set -eu
die() { echo "test-tarball.sh: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: test-tarball.sh TARBALL [DIR]"
TOP=$(cd "$(dirname "$0")" && pwd)
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
DIR=${2:-${tarball%.tar.xz}-test}
rm -rf "$DIR"
mkdir -p "$DIR/root"
DIR=$(cd "$DIR" && pwd)
root=$DIR/root
tar -C "$root" -xJf "$tarball"
version=$(sed -n 's/^Version: //p' "$root/BUILDINFO")
upstream=${version%%+beanjar*}

unset PKG_CONFIG_SYSROOT_DIR
export PKG_CONFIG_PATH="$root/lib/pkgconfig"
for m in egl glesv2; do
	[ "$(pkg-config --modversion "$m")" = "$upstream" ] || die "$m.pc is not version $upstream"
	d=$(pkg-config --variable=libdir "$m")
	[ "$(cd "$d" && pwd -P)" = "$(cd "$root/lib" && pwd -P)" ] || die "$m.pc: libdir $d is not in $root"
done
for l in libEGL libGLESv2; do
	codesign --verify "$root/lib/$l.dylib"
done
# shellcheck disable=SC2046 # pkg-config's output is a list of options
cc -o "$DIR/egl-check" "$TOP/egl-check.c" $(pkg-config --cflags --libs egl glesv2) \
	-Wl,-rpath,"$root/lib"
otool -L "$DIR/egl-check"
r=0
"$DIR/egl-check" || r=$?
case $r in
0) ;;
2)
	echo "test-tarball.sh: WARNING: ANGLE's Metal backend did not initialise on this machine"
	[ "${ANGLE_REQUIRE_METAL:-0}" != 1 ] || die "Metal required"
	;;
*) die "egl-check failed ($r)" ;;
esac
echo "$tarball: built and ran a program against it, unpacked in $root"
