#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a qemu-user tarball from build.sh where it is unpacked: qemu-arm is a static program for
# the tarball's architecture (aarch64 or x86-64) of the expected QEMU release that carries its
# bridge (the compat bridge on aarch64, the ioctl bridge on x86-64). The bridge itself needs
# Beanjar's guest kernel; Beanjar's own tests run it there.
#
#   qemu-user/test-tarball.sh TARBALL [DIR]     default DIR: a new directory next to TARBALL
#
# Needs xz-utils and file, and a machine of the tarball's architecture to run the program on.
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
[ -f "$root/share/doc/qemu-user/COPYING" ] || die "no licence texts in share/doc/qemu-user"
echo "$tarball: ran its program, unpacked in $root"
