#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a virglrenderer tarball from build.sh where it is unpacked, with the angle tarball it
# requires unpacked into the same directory: build virgl-check.c against both with the plain
# pkg-config (the .pc files locate the tree by ${pcfiledir}) and run it. The program makes OpenGL
# ES contexts on ANGLE's Metal backend through libepoxy's EGL, starts virglrenderer on them as
# QEMU does, prints the renderer and the capability sets, and creates a context and a texture.
# Without a Metal device it cannot get that far: the check then only says so, unless
# ANGLE_REQUIRE_METAL=1.
#
#   virglrenderer/test-tarball.sh ANGLE_TARBALL TARBALL [DIR]
#                                       default DIR: a new directory next to TARBALL
#
# Needs xz, pkgconf and Xcode's command line tools.
set -eu
die() { echo "test-tarball.sh: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: test-tarball.sh ANGLE_TARBALL TARBALL [DIR]"
TOP=$(cd "$(dirname "$0")" && pwd)
tarball=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
DIR=${3:-${tarball%.tar.xz}-test}
rm -rf "$DIR"
mkdir -p "$DIR/root"
DIR=$(cd "$DIR" && pwd)
root=$DIR/root
tar -C "$root" -xJf "$1"
tar -C "$root" -xJf "$tarball"

unset PKG_CONFIG_SYSROOT_DIR
export PKG_CONFIG_PATH="$root/lib/pkgconfig"
for m in epoxy virglrenderer; do
	d=$(pkg-config --variable=libdir "$m")
	[ "$(cd "$d" && pwd -P)" = "$(cd "$root/lib" && pwd -P)" ] || die "$m.pc: libdir $d is not in $root"
done
[ "$(pkg-config --variable=epoxy_has_egl epoxy)" = 1 ] || die "libepoxy has no EGL"
for l in libepoxy.0 libvirglrenderer.1; do
	codesign --verify "$root/lib/$l.dylib"
done
# shellcheck disable=SC2046 # pkg-config's output is a list of options
cc -o "$DIR/virgl-check" "$TOP/virgl-check.c" $(pkg-config --cflags --libs epoxy virglrenderer) \
	-Wl,-rpath,"$root/lib"
otool -L "$DIR/virgl-check"
r=0
"$DIR/virgl-check" || r=$?
case $r in
0) ;;
2)
	echo "test-tarball.sh: WARNING: ANGLE's Metal backend did not initialise on this machine"
	[ "${ANGLE_REQUIRE_METAL:-0}" != 1 ] || die "Metal required"
	;;
*) die "virgl-check failed ($r)" ;;
esac
echo "$tarball: built and ran a program against it, unpacked in $root"
