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

# the compiler: Debian's for the triplet. It is not built for a sysroot: --sysroot alone leaves its
# own tool directory (/usr/<triplet>, Debian's armel C library when libc6-dev-armel-cross is
# installed) ahead of it, so the sysroot is put first by hand (README.md, "The tarballs")
cc=$(field Target-Triplet)-gcc
"$cc" --version | head -1
sysroot=$DIR/root/sysroot
s=$sysroot
sysroot_flags="--sysroot=$s -nostdinc -isystem $("$cc" -print-file-name=include) -isystem $s/usr/include
	-B$s/usr/lib/ -B$s/lib/ -L$s/lib -L$s/usr/lib -Wl,-rpath-link,$s/lib:$s/usr/lib"

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
# shellcheck disable=SC2086 # the flags are a list
"$cc" $sysroot_flags $(field Target-Flags) -O2 -Wall -Werror -o "$DIR/t" "$DIR/t.c" \
	-lgbm -lEGL -lGLESv2 -H -Wl,--trace > "$DIR/trace" 2>&1
# every header, start file and library the compiler took is the sysroot's; only GCC's own headers,
# libgcc.a, crtbegin and crtend (and libgcc_s's link script, which names the sysroot's
# libgcc_s.so.1) are the compiler's
gcc_dir=$(dirname "$(realpath "$("$cc" -print-libgcc-file-name)")")
grep -o '/[^ ()]*\.\(so[.0-9]*\|o\|a\|h\)$' "$DIR/trace" | sort -u | while read -r f; do
	case $(realpath -m "$f") in
	"$(realpath "$sysroot")"/*) ;;
	"$gcc_dir"/*) ;;
	"${TMPDIR:-/tmp}"/cc*.o) ;; # the program's own object
	*) die "compiled or linked with $f, outside the sysroot" ;;
	esac
done
grep -q 'sysroot/lib/libc\.so\.6' "$DIR/trace" || die "the C library is not the sysroot's"
grep -q 'sysroot/usr/include/stdio\.h\|sysroot/usr/include/fcntl\.h' "$DIR/trace" ||
	die "the C library's headers are not the sysroot's"
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
