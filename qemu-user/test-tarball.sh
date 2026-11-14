#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a qemu-user tarball from build.sh where it is unpacked: qemu-arm is a static aarch64
# program of the expected QEMU release that carries the compat bridge. The bridge itself needs
# Beanjar's guest kernel; Beanjar's own tests run it there.
#
#   qemu-user/test-tarball.sh TARBALL [DIR]     default DIR: a new directory next to TARBALL
#
# Needs xz-utils and file, and an arm64 machine to run the program on.
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

q=$root/bin/qemu-arm
file "$q" | tee "$DIR/file.txt"
grep -q 'ARM aarch64' "$DIR/file.txt" || die "qemu-arm is not an aarch64 program"
grep -q 'statically linked\|static-pie linked' "$DIR/file.txt" || die "qemu-arm is not static"
"$q" --version | tee "$DIR/version.txt"
grep -q "^qemu-arm version $upstream\b" "$DIR/version.txt" || die "qemu-arm is not version $upstream"
grep -q "kernel has no compat bridge" "$q" || die "qemu-arm has no compat bridge"
[ -f "$root/share/doc/qemu-user/COPYING" ] || die "no licence texts in share/doc/qemu-user"
echo "$tarball: ran its program, unpacked in $root"
