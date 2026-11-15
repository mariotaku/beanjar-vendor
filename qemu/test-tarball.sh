#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a QEMU tarball from build.sh where it is unpacked: run qemu-system-aarch64 (and the amd64
# tarball's qemu-system-x86_64) with -L pointing at the unpacked data directory, and check that
# each has the displays and devices Beanjar's launcher uses (egl-headless and dbus;
# virtio-gpu-gl-pci, vhost-user-gpu-pci and usb-redir), and that the vhost-user-gpu backend prints its capabilities. ldd must resolve every
# library of the programs.
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

gpu=$root/libexec/vhost-user-gpu
systems=$root/bin/qemu-system-aarch64
arch=$(sed -n 's/^Architecture: //p' "$root/BUILDINFO")
if [ "$arch" = amd64 ]; then
	systems="$systems $root/bin/qemu-system-x86_64"
fi
for p in $systems "$gpu"; do
	if ldd "$p" | grep 'not found'; then
		die "$p: libraries not found"
	fi
done
[ -f "$root/share/qemu/efi-virtio.rom" ] || die "no data directory in share/qemu"
[ "$arch" != amd64 ] || [ -f "$root/share/qemu/bios-256k.bin" ] || die "no SeaBIOS in share/qemu"

for qemu in $systems; do
	name=$(basename "$qemu")
	"$qemu" -L "$root/share/qemu" --version | tee "$DIR/$name-version.txt"
	grep -q "^QEMU emulator version $upstream\b" "$DIR/$name-version.txt" ||
		die "$name is not version $upstream"
	"$qemu" -L "$root/share/qemu" -display help > "$DIR/$name-display.txt"
	for d in egl-headless dbus; do
		grep -qx "$d" "$DIR/$name-display.txt" || die "$name: display $d missing: $(cat "$DIR/$name-display.txt")"
	done
	"$qemu" -L "$root/share/qemu" -device help > "$DIR/$name-device.txt"
	for d in virtio-gpu-gl-pci vhost-user-gpu-pci usb-redir; do
		grep -q "^name \"$d\"" "$DIR/$name-device.txt" || die "$name: device $d missing"
	done
done
"$gpu" --print-capabilities | tee "$DIR/capabilities.json"
grep -q '"type": "gpu"' "$DIR/capabilities.json" || die "vhost-user-gpu capabilities"
echo "$tarball: ran its programs, unpacked in $root"
