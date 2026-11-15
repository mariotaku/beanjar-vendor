#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a QEMU tarball from build.sh where it is unpacked: run qemu-system-aarch64 (and the amd64
# tarball's qemu-system-x86_64) with -L pointing at the unpacked data directory, and check that
# each has the displays and devices Beanjar's launcher uses (egl-headless and dbus;
# virtio-gpu-gl-pci, vhost-user-gpu-pci and usb-redir), and that the vhost-user-gpu backend prints its capabilities. ldd must resolve every
# library of the programs, share/qemu must hold exactly the files share-keep lists for the
# programs' targets, and each program must start a VM (paused, no guest) from it.
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
# share/qemu holds exactly what share-keep lists for the tarball's targets: trimming a copy of it
# again must neither fail (a file missing) nor delete anything (a file left over)
targets=$(for q in $systems; do basename "$q" | sed 's/^qemu-system-//'; done)
cp -R "$root/share/qemu" "$DIR/share-keep-check"
# shellcheck disable=SC2086 # a list of targets
sh "$(dirname "$0")/share-trim.sh" "$DIR/share-keep-check" $targets > /dev/null ||
	die "share/qemu lacks files share-keep lists"
diff -r "$root/share/qemu" "$DIR/share-keep-check" > /dev/null ||
	die "share/qemu has files share-keep does not list: $(diff -r "$root/share/qemu" "$DIR/share-keep-check" | sed -n 's/^Only in //p' | tr '\n' ' ')"
echo "share/qemu: $(cd "$root/share/qemu" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')"

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
# Each emulator starts a VM with no guest (a -kernel of zeros) on the launcher's machine with a
# virtio-net-pci NIC, paused, from the trimmed data directory alone: the machine loads its
# firmware (SeaBIOS and the -kernel option ROM on x86_64), the NIC its option ROM. QMP over stdio
# answers query-status, then quits it.
dd if=/dev/zero of="$DIR/kernel" bs=4096 count=1 2> /dev/null
for qemu in $systems; do
	name=$(basename "$qemu")
	case $name in
	qemu-system-aarch64) machine="-M virt -cpu max,pauth=off" ;;
	qemu-system-x86_64) machine="-M q35 -vga none" ;;
	esac
	# shellcheck disable=SC2086 # the machine options
	printf '%s\n' '{"execute": "qmp_capabilities"}' '{"execute": "query-status"}' '{"execute": "quit"}' |
		"$qemu" -L "$root/share/qemu" $machine -m 256 -nodefaults -S -display none \
			-kernel "$DIR/kernel" -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
			-qmp stdio > "$DIR/$name-vm.log" 2>&1 ||
		die "$name: the VM did not start: $(cat "$DIR/$name-vm.log")"
	grep -q '"status": "prelaunch"' "$DIR/$name-vm.log" ||
		die "$name: no query-status: $(cat "$DIR/$name-vm.log")"
	echo "$name: a VM started and quit"
done
"$gpu" --print-capabilities | tee "$DIR/capabilities.json"
grep -q '"type": "gpu"' "$DIR/capabilities.json" || die "vhost-user-gpu capabilities"
echo "$tarball: ran its programs, unpacked in $root"
