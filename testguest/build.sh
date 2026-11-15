#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build Beanjar's test guest userland with Buildroot: a 32-bit ARM (armv7 EABI softfp, glibc, as
# webOS's) root filesystem with BusyBox init and Mesa's virgl driver, the sysroot to compile
# programs against it, and Buildroot's legal-info. Run as root in a throwaway debian:trixie
# container: it installs Buildroot's host tools into the system it runs in.
#
#   testguest/build.sh [OUT]     default OUT: build/testguest in the repository
#
# VERSION holds the version, the Buildroot release plus a Beanjar revision (2026.02.3+beanjar2);
# Buildroot's release tarball is downloaded and checked against buildroot.sha256, and built with
# defconfig. BR2_DL_DIR (default OUT/dl) and BR2_CCACHE_DIR (default OUT/ccache) are Buildroot's
# download and compiler caches, which CI keeps between runs. The results, in OUT:
#
#   testguest-<version>-armel.tar.xz        rootfs.squashfs, sysroot/, share/doc/testguest/, BUILDINFO
#   testguest-<version>-legal-info.tar      Buildroot's legal-info and its own release tarball
#
# BUILDINFO is in Debian control syntax; Target-Triplet and Target-Flags say how to compile for the
# root filesystem: with any GCC for arm-linux-gnueabi (Debian's gcc-arm-linux-gnueabi) and those
# options, against the sysroot. Buildroot's own toolchain, which built the image, is not shipped.
# test-tarball.sh then compiles and links a program against the tarball unpacked elsewhere, with
# Debian's cross compiler.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$TOP/../build/testguest}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
export DEBIAN_FRONTEND=noninteractive

die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ "$(id -u)" = 0 ] || die "run as root in a throwaway Debian 13 container"
grep -q '^VERSION_ID="13"' /etc/os-release || die "Debian 13 required"
version=$(cat "$TOP/VERSION")
br_version=${version%%+beanjar*}
[ "$br_version" != "$version" ] || die "VERSION $version is not <Buildroot version>+beanjar<N>"
export BR2_DL_DIR="${BR2_DL_DIR:-$OUT/dl}"
export BR2_CCACHE_DIR="${BR2_CCACHE_DIR:-$OUT/ccache}"
mkdir -p "$BR2_DL_DIR" "$BR2_CCACHE_DIR"
# Buildroot refuses to configure as root unless told; the container is throwaway
export FORCE_UNSAFE_CONFIGURE=1
t0=$(date +%s)

step "build dependencies"
apt-get update
# Buildroot's mandatory host tools (its manual, "System requirements"), and squashfs-tools and
# Debian's armel cross compiler for test-tarball.sh
apt-get install -y --no-install-recommends \
	ca-certificates curl wget git build-essential file patch perl python3 bzip2 xz-utils cpio \
	unzip rsync bc squashfs-tools gcc-arm-linux-gnueabi

step "Buildroot $br_version"
f=buildroot-$br_version.tar.xz
grep "  $f\$" "$TOP/buildroot.sha256" > "$BR2_DL_DIR/$f.sha256" || die "buildroot.sha256 has no $f"
if ! (cd "$BR2_DL_DIR" && sha256sum -c --status "$f.sha256" 2>/dev/null); then
	curl -fL --retry 3 -o "$BR2_DL_DIR/$f.part" "https://buildroot.org/downloads/$f"
	mv "$BR2_DL_DIR/$f.part" "$BR2_DL_DIR/$f"
	(cd "$BR2_DL_DIR" && sha256sum -c "$f.sha256")
fi
rm "$BR2_DL_DIR/$f.sha256"
SRC=$OUT/buildroot-$br_version
O=$OUT/output
rm -rf "$SRC" "$O"
tar -C "$OUT" -xJf "$BR2_DL_DIR/$f"

step "build"
make -C "$SRC" O="$O" BR2_DEFCONFIG="$TOP/defconfig" defconfig >/dev/null
make -C "$SRC" O="$O"
make -C "$SRC" O="$O" legal-info >/dev/null

step "tree"
TREE=$OUT/tree
rm -rf "$TREE"
mkdir -p "$TREE/sysroot/usr/share" "$TREE/share/doc/testguest"
cp "$O/images/rootfs.squashfs" "$TREE/rootfs.squashfs"
# The sysroot: Buildroot's staging directory (the toolchain's C library and every package's
# headers, libraries and pkg-config files), without its programs and documentation. The static
# libraries stay: libc.so is a linker script that names libc_nonshared.a.
staging=$(cd -P "$O/staging" && pwd)
for d in lib usr/lib usr/include; do
	cp -a "$staging/$d" "$TREE/sysroot/$d"
done
cp -a "$staging/usr/share/pkgconfig" "$TREE/sysroot/usr/share/pkgconfig" 2>/dev/null || true
# lib32 and usr/lib32 are Buildroot's links to lib
for d in lib32 usr/lib32; do
	[ ! -L "$staging/$d" ] || cp -a "$staging/$d" "$TREE/sysroot/$d"
done
rm -rf "$TREE/sysroot/usr/lib/gconv"
# no link may leave the sysroot
find "$TREE/sysroot" -type l | while read -r l; do
	case $(readlink "$l") in /*) die "$l is an absolute link to $(readlink "$l")" ;; esac
done
LEGAL=$O/legal-info
cp "$LEGAL/manifest.csv" "$LEGAL/buildroot.config" "$LEGAL/README" "$TREE/share/doc/testguest/"
cp -a "$LEGAL/licenses" "$TREE/share/doc/testguest/licenses"
install -m 0644 "$TOP/NOTICE" "$TREE/share/doc/testguest/NOTICE"

# The CPU options Buildroot built its GCC for (its defaults: the wrapper passes none), which a
# compiler for the root filesystem needs: webOS's
cfg() { sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$O/.config"; }
flags="-mcpu=$(cfg BR2_GCC_TARGET_CPU) -mfpu=$(cfg BR2_GCC_TARGET_FPU) -mfloat-abi=$(cfg BR2_GCC_TARGET_FLOAT_ABI)"
flags="$flags -mabi=$(cfg BR2_GCC_TARGET_ABI) -m$(cfg BR2_GCC_TARGET_MODE)"
[ "$flags" = "-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=softfp -mabi=aapcs-linux -marm" ] ||
	die "defconfig's CPU options are not those of webOS's userland: $flags"
gcc_config=" $("$O/host/bin/arm-linux-gcc" -v 2>&1 | tr "\n" " ") "
for x in --with-cpu=cortex-a9 --with-fpu=neon --with-float=softfp --with-abi=aapcs-linux --with-mode=arm; do
	case $gcc_config in *" $x "*) ;; *) die "Buildroot's GCC is not configured $x" ;; esac
done
gcc_version=$("$O/host/bin/arm-linux-gcc" -dumpfullversion)
src_date=$(stat -c %Y "$SRC/Makefile")
{
	echo "Program: testguest"
	echo "Version: $version"
	echo "Architecture: armel"
	echo "Build-Architecture: amd64"
	echo "Debian-Release: $(cat /etc/debian_version)"
	echo "Buildroot: $br_version $(cut -d' ' -f1 "$TOP/buildroot.sha256") https://buildroot.org/downloads/$f"
	echo "Defconfig: $(sha256sum < "$TOP/defconfig" | cut -d' ' -f1)"
	echo "Toolchain: Buildroot's own, GCC $gcc_version (not shipped)"
	echo "Target-Triplet: arm-linux-gnueabi"
	echo "Target-Flags: $flags"
	echo "Root-Filesystem: rootfs.squashfs squashfs lzo $(sha256sum < "$TREE/rootfs.squashfs" | cut -d' ' -f1)"
	echo "Packages:"
	sed -n '2,$s/^"\([^"]*\)","\([^"]*\)","\([^"]*\)".*/ \1 \2 (\3)/p' "$LEGAL/manifest.csv"
} > "$TREE/BUILDINFO"
cat "$TREE/BUILDINFO"

step "tarballs"
tarball=$OUT/testguest-$version-armel.tar.xz
tar -C "$TREE" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$src_date" --clamp-mtime -cJf "$tarball" .
# The legal-info of what is in the image (the host tools' sources are left out: nothing of them is
# in it) with Buildroot's own release, which its legal-info does not save
rm -rf "$OUT/legal-info"
mkdir -p "$OUT/legal-info"
for x in README buildroot.config legal-info.sha256 manifest.csv licenses sources host-manifest.csv host-licenses; do
	cp -al "$LEGAL/$x" "$OUT/legal-info/$x"
done
mkdir -p "$OUT/legal-info/buildroot"
cp "$BR2_DL_DIR/$f" "$OUT/legal-info/buildroot/$f"
legal=$OUT/testguest-$version-legal-info.tar
tar -C "$OUT" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$src_date" --clamp-mtime \
	--transform "s|^legal-info|testguest-$version-legal-info|" -cf "$legal" legal-info
rm -rf "$OUT/legal-info" "$TREE"
ls -l "$tarball" "$legal"

step "test"
sh "$TOP/test-tarball.sh" "$tarball" "$OUT/test"
echo "$tarball: built in $(( $(date +%s) - t0 )) s"
