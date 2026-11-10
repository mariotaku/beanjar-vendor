#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a QEMU tarball from build.sh where it is unpacked: run qemu-system-aarch64 with -L
# pointing at the unpacked data directory, and check that it has the displays and devices
# Beanjar's launcher uses (egl-headless and dbus; virtio-gpu-gl-pci, vhost-user-gpu-pci and
# usb-redir), and that the vhost-user-gpu backend prints its capabilities. ldd must resolve every
# library of both programs.
#
#   qemu/test-tarball.sh TARBALL [DIR]     default DIR: a new directory next to TARBALL
#
# Needs xz-utils, and the libraries in BUILDINFO's Depends.
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

qemu=$root/bin/qemu-system-aarch64
gpu=$root/libexec/vhost-user-gpu
for p in "$qemu" "$gpu"; do
	if ldd "$p" | grep 'not found'; then
		die "$p: libraries not found"
	fi
done
[ -f "$root/share/qemu/efi-virtio.rom" ] || die "no data directory in share/qemu"

"$qemu" -L "$root/share/qemu" --version | tee "$DIR/version.txt"
grep -q "^QEMU emulator version $upstream\b" "$DIR/version.txt" ||
	die "qemu-system-aarch64 is not version $upstream"
"$qemu" -L "$root/share/qemu" -display help > "$DIR/display.txt"
for d in egl-headless dbus; do
	grep -qx "$d" "$DIR/display.txt" || die "display $d missing: $(cat "$DIR/display.txt")"
done
"$qemu" -L "$root/share/qemu" -device help > "$DIR/device.txt"
for d in virtio-gpu-gl-pci vhost-user-gpu-pci usb-redir; do
	grep -q "^name \"$d\"" "$DIR/device.txt" || die "device $d missing"
done
"$gpu" --print-capabilities | tee "$DIR/capabilities.json"
grep -q '"type": "gpu"' "$DIR/capabilities.json" || die "vhost-user-gpu capabilities"
echo "$tarball: ran its programs, unpacked in $root"
