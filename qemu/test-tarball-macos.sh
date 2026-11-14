#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a macOS QEMU tarball from build-macos.sh where it is unpacked, with the angle and
# virglrenderer tarballs it requires unpacked into the same directory: every library the program
# loads must resolve, from that directory or Homebrew; qemu-system-aarch64 must be the expected
# release, list the dbus display, the coreaudio and dbus audio drivers, and virtio-gpu-gl-pci; and
# a VM without a guest (virt machine, display dbus in peer-to-peer mode) must start and answer
# QMP's query-status on a unix socket, then quit. Needs no LG firmware and no guest kernel.
#
#   qemu/test-tarball-macos.sh TARBALL ANGLE_TARBALL VIRGLRENDERER_TARBALL [DIR]
#                                       default DIR: a new directory next to TARBALL
#
# Needs xz, and the Homebrew formulae in BUILDINFO's Homebrew field.
set -eu
die() { echo "test-tarball-macos.sh: $*" >&2; exit 1; }
[ $# -ge 3 ] || die "usage: test-tarball-macos.sh TARBALL ANGLE_TARBALL VIRGLRENDERER_TARBALL [DIR]"
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
tarball=$(abs "$1")
DIR=${4:-${tarball%.tar.xz}-test}
rm -rf "$DIR"
mkdir -p "$DIR/root"
DIR=$(cd "$DIR" && pwd)
root=$DIR/root
for t in "$2" "$3"; do
	tar -C "$root" -xJf "$t"
done
tar -C "$root" -xJf "$tarball"
version=$(sed -n 's/^Version: //p' "$root/BUILDINFO")
upstream=${version%%+beanjar*}
qemu=$root/bin/qemu-system-aarch64
[ -f "$root/share/qemu/efi-virtio.rom" ] || die "no data directory in share/qemu"

# Every @rpath library is in the unpacked tree, and every absolute one exists
otool -L "$qemu" | tail -n +2 | sed 's/^[[:space:]]*//; s/ (.*//' | while read -r l; do
	case $l in
	@rpath/*) [ -f "$root/lib/${l#@rpath/}" ] || die "$l not in $root/lib" ;;
	/usr/lib/* | /System/*) ;;
	*) [ -f "$l" ] || die "$l not found" ;;
	esac
done
otool -l "$qemu" | grep -A2 LC_RPATH | grep -q '@loader_path/../lib' ||
	die "no LC_RPATH @loader_path/../lib"
codesign --verify "$qemu"
codesign -d --entitlements - "$qemu" 2>&1 | tee "$DIR/entitlements.txt"

run() { "$qemu" -L "$root/share/qemu" "$@"; }
run --version | tee "$DIR/version.txt"
grep -q "^QEMU emulator version $upstream\b" "$DIR/version.txt" ||
	die "qemu-system-aarch64 is not version $upstream"
run -display help | tee "$DIR/display.txt"
grep -qx dbus "$DIR/display.txt" || die "display dbus missing"
run -audiodev help | tee "$DIR/audiodev.txt"
for a in coreaudio dbus; do
	grep -qx "$a" "$DIR/audiodev.txt" || die "audio driver $a missing"
done
run -device help > "$DIR/device.txt"
for d in virtio-gpu-gl-pci virtio-gpu-pci usb-redir virtio-9p-pci; do
	grep -q "^name \"$d\"" "$DIR/device.txt" || die "device $d missing"
done
run -accel help | tee "$DIR/accel.txt"

# A VM without a guest: start it paused, ask QMP for its status, quit
sock=$DIR/qmp.sock
run -M virt -cpu max -m 256 -nodefaults -S -display dbus,p2p=yes \
	-audiodev dbus,id=snd0 -device virtio-gpu-pci \
	-qmp unix:"$sock",server=on,wait=off > "$DIR/vm.log" 2>&1 &
pid=$!
python3 -I - "$sock" <<'EOF' || { cat "$DIR/vm.log"; kill "$pid" 2>/dev/null; die "QMP"; }
import json, socket, sys, time
for _ in range(100):
    try:
        s = socket.socket(socket.AF_UNIX)
        s.connect(sys.argv[1])
        break
    except OSError:
        time.sleep(0.1)
else:
    sys.exit("no QMP socket")
f = s.makefile("rw")
def cmd(name):
    f.write(json.dumps({"execute": name}) + "\n")
    f.flush()
    while True:
        r = json.loads(f.readline())
        if "event" not in r:
            return r
print("QMP greeting:", json.loads(f.readline())["QMP"]["version"]["qemu"])
assert "return" in cmd("qmp_capabilities")
status = cmd("query-status")["return"]
print("query-status:", status)
assert status["status"] == "prelaunch", status
cmd("quit")
EOF
wait "$pid" || die "QEMU exited with $?: $(cat "$DIR/vm.log")"
cat "$DIR/vm.log"

# OpenGL on the display needs a macOS branch in egl_init() that this release does not have;
# record what it says today rather than fail
run -M virt -nodefaults -S -display dbus,p2p=yes,gl=es -device virtio-gpu-gl-pci \
	> "$DIR/gl.log" 2>&1 < /dev/null &
gpid=$!
sleep 3
if kill "$gpid" 2>/dev/null; then
	echo "display dbus,gl=es: QEMU started"
else
	echo "display dbus,gl=es: QEMU exited: $(cat "$DIR/gl.log")"
fi
wait "$gpid" 2>/dev/null || true
echo "$tarball: ran its program, unpacked in $root"
