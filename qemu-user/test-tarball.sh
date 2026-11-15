#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a qemu-user tarball from build.sh where it is unpacked: qemu-arm is a static program for
# the tarball's architecture (aarch64 or x86-64) of the expected QEMU release that carries its
# bridge (the compat bridge on aarch64, the ioctl bridge on x86-64). The bridge itself needs
# Beanjar's guest kernel; Beanjar's own tests run it there. The amd64 tarball's qemu-aarch64 is
# checked alike and runs a tiny 64-bit ARM program whose unknown ioctl must reach the kernel
# (EBADF for a bad descriptor, not qemu's ENOTTY); the arm64 tarball has no qemu-aarch64.
#
#   qemu-user/test-tarball.sh TARBALL [DIR]     default DIR: a new directory next to TARBALL
#
# Needs xz-utils, file and perl, and a machine of the tarball's architecture to run the program on.
set -eu
die() { echo "test-tarball.sh: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: test-tarball.sh TARBALL [DIR]"
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
DIR=${2:-${tarball%.tar.xz}-test}
rm -rf "$DIR"
mkdir -p "$DIR/root"
DIR=$(cd "$DIR" && pwd)
root=$DIR/root
tar -C "$root" -xJf "$tarball"
version=$(sed -n 's/^Version: //p' "$root/BUILDINFO")
upstream=${version%%+beanjar*}

arch=$(sed -n 's/^Architecture: //p' "$root/BUILDINFO")
case $arch in
arm64) machine='ARM aarch64' bridge='kernel has no compat bridge' ;;
amd64) machine='x86-64' bridge='kernel has no ioctl bridge' ;;
*) die "BUILDINFO: architecture $arch" ;;
esac

q=$root/bin/qemu-arm
file "$q" | tee "$DIR/file.txt"
grep -q "$machine" "$DIR/file.txt" || die "qemu-arm is not an $machine program"
grep -q 'statically linked\|static-pie linked' "$DIR/file.txt" || die "qemu-arm is not static"
"$q" --version | tee "$DIR/version.txt"
grep -q "^qemu-arm version $upstream\b" "$DIR/version.txt" || die "qemu-arm is not version $upstream"
grep -q "$bridge" "$q" || die "qemu-arm has no bridge ($bridge)"

q=$root/bin/qemu-aarch64
case $arch in
arm64) [ ! -e "$q" ] || die "an arm64 tarball has no qemu-aarch64 (the kernel runs AArch64 natively)" ;;
amd64)
	file "$q" | tee "$DIR/file-aarch64.txt"
	grep -q "$machine" "$DIR/file-aarch64.txt" || die "qemu-aarch64 is not an $machine program"
	grep -q 'statically linked\|static-pie linked' "$DIR/file-aarch64.txt" || die "qemu-aarch64 is not static"
	"$q" --version | tee "$DIR/version-aarch64.txt"
	grep -q "^qemu-aarch64 version $upstream\b" "$DIR/version-aarch64.txt" ||
		die "qemu-aarch64 is not version $upstream"
	# A static AArch64 ELF loaded at 0x400000: ioctl(-1, _IO('Z', 0xef), 0), a command qemu has
	# no table entry for, then exit(-result). The kernel answers EBADF (9); qemu itself ENOTTY (25).
	perl -e 'print pack("H*", join("", @ARGV))' \
		7f454c4602010100000000000000000002 00b70001000000 7800400000000000 4000000000000000 \
		0000000000000000 00000000 4000380001004000000000 00 \
		0100000005000000 0000000000000000 0000400000000000 0000400000000000 \
		9800000000000000 9800000000000000 0010000000000000 \
		00008092 e15d8bd2 020080d2 a80380d2 010000d4 e00300cb a80b80d2 010000d4 \
		> "$DIR/ioctl-aarch64"
	chmod 755 "$DIR/ioctl-aarch64"
	rc=0
	"$q" "$DIR/ioctl-aarch64" || rc=$?
	[ "$rc" = 9 ] || die "qemu-aarch64: an unknown ioctl gave errno $rc, not the kernel's EBADF (9)"
	echo "qemu-aarch64: an unknown ioctl reached the kernel (EBADF)"
	;;
esac
[ -f "$root/share/doc/qemu-user/COPYING" ] || die "no licence texts in share/doc/qemu-user"
echo "$tarball: ran its program, unpacked in $root"
