#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a test guest tarball from build.sh where it is unpacked: the root filesystem has BusyBox
# init, the C library and Mesa's virgl driver, and a program using GBM, EGL and OpenGL ES compiles
# and links against the sysroot with Debian's armel cross compiler and the options BUILDINFO names,
# taking the C library and every other library from the sysroot, and everything it needs is in the
# root filesystem.
# It cannot run the program: that takes an ARM guest with a virtio GPU, which Beanjar's own tests
# boot.
#
#   testguest/test-tarball.sh TARBALL [DIR]     default DIR: a new directory next to TARBALL
#
# Needs xz-utils, gcc-arm-linux-gnueabi, binutils (readelf) and squashfs-tools (unsquashfs).
set -eu
die() { echo "test-tarball.sh: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: test-tarball.sh TARBALL [DIR]"
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
DIR=${2:-${tarball%.tar.xz}-test}
rm -rf "$DIR"
mkdir -p "$DIR/root"
DIR=$(cd "$DIR" && pwd)
tar -C "$DIR/root" -xJf "$tarball"
info=$DIR/root/BUILDINFO
field() { sed -n "s/^$1: //p" "$info"; }
[ "$(field Program)" = testguest ] || die "BUILDINFO: not the test guest"
[ "$(field Architecture)" = armel ] || die "BUILDINFO: not armel"

# the root filesystem
unsquashfs -d "$DIR/rootfs" -no-xattrs "$DIR/root/rootfs.squashfs" >/dev/null
[ "$(sha256sum < "$DIR/root/rootfs.squashfs" | cut -d' ' -f1)" = "$(field Root-Filesystem | cut -d' ' -f4)" ] ||
	die "rootfs.squashfs does not match BUILDINFO"
for f in bin/busybox sbin/init etc/inittab etc/init.d/rcS lib/ld-linux.so.3 usr/lib/libEGL.so.1 \
	usr/lib/libGLESv2.so.2 usr/lib/libgbm.so.1 usr/lib/gbm/dri_gbm.so; do
	[ -e "$DIR/rootfs/$f" ] || [ -L "$DIR/rootfs/$f" ] || die "the root filesystem has no /$f"
done
# Mesa's gallium drivers are one library; the virgl driver is in it
set -- "$DIR"/rootfs/usr/lib/libgallium-*.so
[ -f "$1" ] || die "the root filesystem has no Mesa gallium library"
grep -q virgl "$1" || die "$1 has no virgl driver"

# the compiler: any GCC for the triplet; Debian's
cc=$(field Target-Triplet)-gcc
"$cc" --version | head -1
sysroot=$DIR/root/sysroot

cat > "$DIR/t.c" <<'EOF'
#include <fcntl.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

int main(void)
{
	int fd = open("/dev/dri/renderD128", O_RDWR);
	struct gbm_device *gbm = gbm_create_device(fd);
	EGLDisplay d = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	return eglInitialize(d, NULL, NULL) && glGetString(GL_RENDERER) ? 0 : 1;
}
EOF
# shellcheck disable=SC2046 # the flags are a list
"$cc" --sysroot="$sysroot" $(field Target-Flags) -O2 -Wall -Werror -o "$DIR/t" "$DIR/t.c" \
	-lgbm -lEGL -lGLESv2 -Wl,--trace > "$DIR/trace"
# every shared library the linker took is the sysroot's, not the compiler's own C library; only
# GCC's runtime (libgcc_s, by its soname, which the root filesystem has) comes from the compiler
gcc_dir=$(dirname "$(realpath "$("$cc" -print-libgcc-file-name)")")
grep -o '/[^ ()]*\.so[^ ()]*' "$DIR/trace" | while read -r f; do
	case $(realpath -m "$f") in
	"$(realpath "$sysroot")"/*) ;;
	"$gcc_dir"/libgcc_s.so*) ;;
	*) die "linked against $f, outside the sysroot" ;;
	esac
done
grep -q 'sysroot/lib/libc\.so\.6\|sysroot/usr/lib/libc\.so' "$DIR/trace" || die "the C library is not the sysroot's"
readelf -h "$DIR/t" | grep -q 'Machine:.*ARM$' || die "the program is not 32-bit ARM"
readelf -h "$DIR/t" | grep -q 'soft-float ABI' || die "the program is not EABI soft-float"
readelf -A "$DIR/t" | grep -q 'Tag_ABI_VFP_args' && die "the program passes floats in VFP registers"
interp=$(readelf -l "$DIR/t" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
[ -e "$DIR/rootfs$interp" ] || die "the root filesystem has no $interp"
for lib in $(readelf -d "$DIR/t" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
	[ -e "$DIR/rootfs/usr/lib/$lib" ] || [ -e "$DIR/rootfs/lib/$lib" ] ||
		die "the program needs $lib, which the root filesystem does not have"
	echo "needs $lib: in the root filesystem"
done
[ "$interp" = /lib/ld-linux.so.3 ] || die "the program's interpreter is $interp, not /lib/ld-linux.so.3"
rm -rf "$DIR/rootfs"
echo "$tarball: a GBM, EGL and GLES program built against it, and its root filesystem has all it needs"
