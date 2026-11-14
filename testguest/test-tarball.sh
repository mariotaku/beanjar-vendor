#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a test guest tarball from build.sh where it is unpacked: the root filesystem has BusyBox
# init, the C library and Mesa's virgl driver, and a program using GBM, EGL and OpenGL ES compiles
# and links against the sysroot with the toolchain BUILDINFO pins (downloaded and checked, or taken
# from Buildroot's download cache, BR2_DL_DIR), and everything it needs is in the root filesystem.
# It cannot run the program: that takes an ARM guest with a virtio GPU, which Beanjar's own tests
# boot.
#
#   testguest/test-tarball.sh TARBALL [DIR]     default DIR: a new directory next to TARBALL
#
# Needs xz-utils, curl, binutils (readelf) and squashfs-tools (unsquashfs).
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
[ "$(field Architecture)" = armhf ] || die "BUILDINFO: not armhf"

# the root filesystem
unsquashfs -d "$DIR/rootfs" -no-xattrs "$DIR/root/rootfs.squashfs" >/dev/null
[ "$(sha256sum < "$DIR/root/rootfs.squashfs" | cut -d' ' -f1)" = "$(field Root-Filesystem | cut -d' ' -f4)" ] ||
	die "rootfs.squashfs does not match BUILDINFO"
for f in bin/busybox sbin/init etc/inittab etc/init.d/rcS lib/ld-linux-armhf.so.3 usr/lib/libEGL.so.1 \
	usr/lib/libGLESv2.so.2 usr/lib/libgbm.so.1 usr/lib/gbm/dri_gbm.so; do
	[ -e "$DIR/rootfs/$f" ] || [ -L "$DIR/rootfs/$f" ] || die "the root filesystem has no /$f"
done
# Mesa's gallium drivers are one library; the virgl driver is in it
set -- "$DIR"/rootfs/usr/lib/libgallium-*.so
[ -f "$1" ] || die "the root filesystem has no Mesa gallium library"
grep -q virgl "$1" || die "$1 has no virgl driver"

# the toolchain
set -- $(field Toolchain)
tc=$1 sha=$2 url=$3
mkdir -p "$DIR/download"
if [ -f "${BR2_DL_DIR:-/nonexistent}/toolchain-external-bootlin/$tc" ]; then
	cp "$BR2_DL_DIR/toolchain-external-bootlin/$tc" "$DIR/download/$tc"
else
	curl -fL --retry 3 -o "$DIR/download/$tc" "$url"
fi
echo "$sha  $DIR/download/$tc" | sha256sum -c --quiet || die "$tc does not match BUILDINFO"
tar -C "$DIR" -xJf "$DIR/download/$tc"
rm "$DIR/download/$tc"
cc="$DIR/$(field Toolchain-Directory)/bin/$(field Toolchain-Prefix)gcc"
"$cc" --version | head -1

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
"$cc" --sysroot="$DIR/root/sysroot" $(field Toolchain-Flags) -O2 -Wall -Werror -o "$DIR/t" "$DIR/t.c" \
	-lgbm -lEGL -lGLESv2
readelf -h "$DIR/t" | grep -q 'Machine:.*ARM$' || die "the program is not 32-bit ARM"
readelf -A "$DIR/t" | grep -q 'Tag_ABI_VFP_args: VFP registers' || die "the program is not hard-float"
interp=$(readelf -l "$DIR/t" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
[ -e "$DIR/rootfs$interp" ] || die "the root filesystem has no $interp"
for lib in $(readelf -d "$DIR/t" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
	[ -e "$DIR/rootfs/usr/lib/$lib" ] || [ -e "$DIR/rootfs/lib/$lib" ] ||
		die "the program needs $lib, which the root filesystem does not have"
	echo "needs $lib: in the root filesystem"
done
rm -rf "$DIR/rootfs" "$DIR/$(field Toolchain-Directory)"
echo "$tarball: a GBM, EGL and GLES program built against it, and its root filesystem has all it needs"
