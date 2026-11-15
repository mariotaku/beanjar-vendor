#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build Beanjar's qemu-arm, QEMU's 32-bit ARM user-mode emulator with the compat bridge, as one
# static program for this machine's architecture, and pack it as a tarball. It runs inside
# Beanjar's guest kernel, not on the host: the arm64 one runs in the arm64 guest kernel on every
# host, the amd64 one in the experimental x86-64 guest kernel on amd64 hosts. The amd64 tarball
# also has qemu-aarch64, QEMU's 64-bit ARM user-mode emulator, for the 64-bit ARM programs that an
# arm64 kernel runs natively. Run as root in a
# throwaway debian:trixie container on arm64 or amd64: it installs the build dependencies into the
# system it runs in.
#
#   qemu-user/build.sh [OUT]     default OUT: build/qemu-user in the repository
#
# VERSION holds the version, QEMU's upstream version plus a Beanjar revision (10.0.2+beanjar1).
# Its upstream part names the release tarball, downloaded from qemu.org and checked against
# qemu.sha256. patches/*.patch are applied in order, and QEMU is configured for arm-linux-user
# (and aarch64-linux-user on amd64) only, static. The result is
# OUT/qemu-user-<version>-<arch>.tar.xz (arch: arm64 or amd64):
#
#   bin/qemu-arm               stripped, statically linked
#   bin/qemu-aarch64           amd64 only, the same
#   share/doc/qemu-user/       QEMU's licence texts, NOTICE
#   BUILDINFO                  what was built from what and how, with the Debian packages whose
#                              static libraries are linked in (Static-Libraries); no Depends
#
# OUT/qemu-<upstream>.tar.xz is the upstream release tarball the program is built from.
# test-tarball.sh then runs the program from the tarball unpacked in another directory.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$TOP/../build/qemu-user}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
export DEBIAN_FRONTEND=noninteractive
PREFIX=/qemu-user
STATIC_PACKAGES="libc6-dev libglib2.0-dev libpcre2-dev zlib1g-dev"

die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ "$(id -u)" = 0 ] || die "run as root in a throwaway Debian 13 container"
grep -q '^VERSION_ID="13"' /etc/os-release || die "Debian 13 required"
arch=$(dpkg --print-architecture)
case $arch in arm64|amd64) ;; *) die "arm64 or amd64 (the guest kernels' architectures), not $arch" ;; esac
version=$(cat "$TOP/VERSION")
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "VERSION $version is not <QEMU version>+beanjar<N>"
# an arm64 guest kernel runs 64-bit ARM programs natively; an x86-64 one needs qemu-aarch64
case $arch in
arm64) programs=qemu-arm targets=arm-linux-user ;;
amd64) programs="qemu-arm qemu-aarch64" targets=arm-linux-user,aarch64-linux-user ;;
esac
t0=$(date +%s)

step "build dependencies"
apt-get update
apt-get install -y --no-install-recommends \
	ca-certificates curl xz-utils patch gcc make binutils file \
	meson ninja-build pkg-config python3 python3-venv flex bison $STATIC_PACKAGES

step "sources"
DL=$OUT/download
mkdir -p "$DL"
f=qemu-$upstream.tar.xz
f_sha=$(grep "  $f\$" "$TOP/qemu.sha256" | cut -d' ' -f1)
[ -n "$f_sha" ] || die "qemu.sha256 has no checksum for $f"
if ! echo "$f_sha  $DL/$f" | sha256sum -c --status 2>/dev/null; then
	curl -fL --retry 3 -o "$DL/$f.part" "https://download.qemu.org/$f"
	mv "$DL/$f.part" "$DL/$f"
	echo "$f_sha  $DL/$f" | sha256sum -c
fi
SRC=$OUT/src
rm -rf "$SRC"
mkdir -p "$SRC"
tar -C "$SRC" -xJf "$DL/$f"
S=$SRC/qemu-$upstream
for p in "$TOP"/patches/*.patch; do
	echo "applying $(basename "$p")"
	patch -d "$S" -p1 --batch --forward --quiet < "$p"
done
SOURCE_DATE_EPOCH=$(stat -c %Y "$S/VERSION")
export SOURCE_DATE_EPOCH
cp "$DL/$f" "$OUT/$f"

step "configure"
# the linux-user targets only, static: no system emulation, tools, docs, plugins, disassembler or crypto
# libraries. --disable-download: the tarball carries the subprojects QEMU still needs.
set -- --prefix="$PREFIX" --target-list=$targets --static --disable-download \
	--disable-system --disable-tools --disable-docs --disable-plugins --disable-capstone \
	--disable-gnutls --disable-nettle --disable-gcrypt --disable-libudev --disable-selinux \
	--disable-libdw --disable-zstd --disable-bzip2 --disable-lzo
B=$SRC/obj
mkdir -p "$B"
(cd "$B" && "$S/configure" "$@")
configure_line="configure $*"

step "build ($(nproc) jobs)"
ninja -C "$B" $programs

step "tree"
ROOT=$SRC/root
mkdir -p "$ROOT/bin" "$ROOT/share/doc/qemu-user"
for q in $programs; do
	install -m 0755 "$B/$q" "$ROOT/bin/$q"
	strip --strip-unneeded "$ROOT/bin/$q"
	file "$ROOT/bin/$q" | grep -q 'statically linked\|static-pie linked' || die "$q is not static"
done
for d in COPYING COPYING.LIB LICENSE; do
	install -m 0644 "$S/$d" "$ROOT/share/doc/qemu-user/$d"
done
install -m 0644 "$TOP/NOTICE" "$ROOT/share/doc/qemu-user/NOTICE"
{
	echo "Program: qemu-user"
	echo "Version: $version"
	echo "Architecture: $arch"
	echo "Debian-Release: $(cat /etc/debian_version)"
	echo "Prefix: $PREFIX"
	echo "License: GPL-2.0-only"
	echo "Programs:$(for q in $programs; do printf ' bin/%s' "$q"; done)"
	echo "Sources:"
	echo " $f $f_sha https://download.qemu.org/$f"
	echo "Patches:"
	for p in "$TOP"/patches/*.patch; do
		echo " $(basename "$p") $(sha256sum < "$p" | cut -d' ' -f1)"
	done
	echo "Configure:"
	echo " $configure_line"
	echo "Static-Libraries:"
	for p in $STATIC_PACKAGES; do
		echo " $(dpkg-query -W -f '${Package} ${Version} (source ${source:Package} ${source:Version})' "$p")"
	done
} > "$ROOT/BUILDINFO"
cat "$ROOT/BUILDINFO"

step "tarball"
tarball=$OUT/qemu-user-$version-$arch.tar.xz
tar -C "$ROOT" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cJf "$tarball" .
tar -tvJf "$tarball"
rm -rf "$SRC"

step "test"
sh "$TOP/test-tarball.sh" "$tarball" "$OUT/test"
echo "$tarball: built in $(( $(date +%s) - t0 )) s"
