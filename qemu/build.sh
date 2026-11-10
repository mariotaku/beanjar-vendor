#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the beanjar-qemu Debian 13 package for this machine's architecture (amd64 or arm64).
# Run as root in a throwaway debian:trixie container: it installs the build dependencies into
# the system it runs in.
#
#   qemu/build.sh [OUT]     default OUT: build/qemu in the repository
#
# The version is debian/changelog's, QEMU's upstream version plus a Beanjar revision
# (10.0.2+beanjar1); its upstream part names the release tarball, downloaded from qemu.org and
# checked against qemu.sha256. patches/*.patch are applied in order, QEMU is configured for
# aarch64-softmmu with only what Beanjar's launcher uses, and the package gets
#
#   /usr/libexec/beanjar/qemu-system-aarch64   stripped
#   /usr/libexec/beanjar/vhost-user-gpu        QEMU's own GPU backend, stripped
#   /usr/share/beanjar/qemu/                   QEMU's data directory (the launcher passes -L)
#   /usr/share/doc/beanjar-qemu/copyright      debian/copyright
#
# Its Depends are dpkg-shlibdeps' for the two programs, plus libegl1 and libopengl0, which
# libepoxy dlopens at run time and dpkg-shlibdeps therefore cannot see. dpkg-gencontrol writes
# the control file from debian/control and debian/changelog, and dpkg-deb builds OUT/debs/*.deb,
# its file dates clamped to the changelog entry's (SOURCE_DATE_EPOCH).
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$TOP/../build/qemu}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
export DEBIAN_FRONTEND=noninteractive

die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ "$(id -u)" = 0 ] || die "run as root in a throwaway Debian 13 container"
grep -q '^VERSION_ID="13"' /etc/os-release || die "Debian 13 required"
arch=$(dpkg --print-architecture)
case $arch in amd64|arm64) ;; *) die "amd64 or arm64, not $arch" ;; esac
t0=$(date +%s)

step "build dependencies"
apt-get update
# QEMU's configure takes the system Meson and pycotap into its venv; the libraries are found by
# pkg-config (libfdt by its header and library).
apt-get install -y --no-install-recommends \
	ca-certificates curl xz-utils patch gcc libc6-dev make dpkg-dev binutils \
	meson ninja-build pkg-config python3 python3-venv python3-pycotap flex bison \
	libglib2.0-dev libpixman-1-dev libepoxy-dev libgbm-dev libdrm-dev libpng-dev zlib1g-dev \
	libvirglrenderer-dev libslirp-dev libfdt-dev libusbredirparser-dev libusb-1.0-0-dev

version=$(dpkg-parsechangelog -l "$TOP/debian/changelog" -SVersion)
SOURCE_DATE_EPOCH=$(dpkg-parsechangelog -l "$TOP/debian/changelog" -STimestamp)
export SOURCE_DATE_EPOCH
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "version $version is not <QEMU version>+beanjar<N>"
tarball=qemu-$upstream.tar.xz
grep -q "  $tarball\$" "$TOP/qemu.sha256" || die "qemu.sha256 has no checksum for $tarball"

step "QEMU $upstream source"
mkdir -p "$OUT/download"
if ! (cd "$OUT/download" && sha256sum -c --status "$TOP/qemu.sha256" 2>/dev/null); then
	curl -fL --retry 3 -o "$OUT/download/$tarball.part" "https://download.qemu.org/$tarball"
	mv "$OUT/download/$tarball.part" "$OUT/download/$tarball"
	(cd "$OUT/download" && sha256sum -c "$TOP/qemu.sha256")
fi
SRC=$OUT/qemu-$upstream
rm -rf "$SRC"
tar -C "$OUT" -xJf "$OUT/download/$tarball"
for p in "$TOP"/patches/*.patch; do
	echo "applying $(basename "$p")"
	patch -d "$SRC" -p1 --batch --forward --quiet < "$p"
done

step "configure"
# Only aarch64-softmmu, with what the launcher uses: OpenGL/virglrenderer for virtio-gpu-gl,
# egl-headless and the D-Bus display (and its audio backend), GBM, slirp, virtio-9p, PNG for the
# QMP screendump, usb-redir and usb-host. The tools option is the only one that builds
# contrib/vhost-user-gpu; the other tools are left out of the package. No SDL/GTK/VNC/SPICE/
# curses, host audio drivers, extra block drivers or crypto libraries. --disable-download: the
# tarball carries the subprojects QEMU still needs.
OBJ=$OUT/obj
rm -rf "$OBJ"
mkdir -p "$OBJ"
(cd "$OBJ" && "$SRC/configure" --prefix=/qemu --target-list=aarch64-softmmu --disable-download \
	--disable-modules --disable-docs --disable-user --enable-tools --disable-guest-agent \
	--enable-opengl --enable-virglrenderer --enable-dbus-display \
	--enable-slirp --enable-fdt=system --enable-virtfs --enable-attr --enable-pixman --enable-png \
	--disable-sdl --disable-gtk --disable-vnc --disable-spice --disable-xen --disable-curses \
	--audio-drv-list= --disable-alsa --disable-pa --disable-pipewire --disable-jack \
	--disable-sndio --disable-oss \
	--disable-curl --disable-gnutls --disable-nettle --disable-gcrypt --disable-capstone \
	--disable-libudev --disable-numa --disable-libdw --disable-selinux \
	--disable-lzo --disable-bzip2 --disable-zstd --enable-libusb --enable-usb-redir \
	--disable-smartcard --disable-libssh --disable-seccomp --disable-libvduse \
	--disable-vduse-blk-export)

step "build ($(nproc) jobs)"
make -C "$OBJ" -j"$(nproc)"
STAGE=$OUT/stage
rm -rf "$STAGE"
make -C "$OBJ" install DESTDIR="$STAGE" >/dev/null
"$STAGE/qemu/bin/qemu-system-aarch64" --version | head -n 1
"$STAGE/qemu/libexec/vhost-user-gpu" --print-capabilities >/dev/null

step "package"
# A debhelper-like layout in OUT/pkg: debian/control and debian/changelog copied in, the
# package's root in debian/beanjar-qemu, where dpkg-shlibdeps and dpkg-gencontrol look for them.
PKG=$OUT/pkg
ROOT=$PKG/debian/beanjar-qemu
rm -rf "$PKG"
mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/libexec/beanjar" "$ROOT/usr/share/beanjar" \
	"$ROOT/usr/share/doc/beanjar-qemu"
cp "$TOP/debian/control" "$TOP/debian/changelog" "$PKG/debian/"
for f in bin/qemu-system-aarch64 libexec/vhost-user-gpu; do
	install -m 0755 "$STAGE/qemu/$f" "$ROOT/usr/libexec/beanjar/"
	strip --strip-unneeded "$ROOT/usr/libexec/beanjar/$(basename "$f")"
done
cp -R "$STAGE/qemu/share/qemu" "$ROOT/usr/share/beanjar/qemu"
# the backend's vhost-user JSON names configure's prefix, not where the backend is installed
rm -rf "$ROOT/usr/share/beanjar/qemu/vhost-user"
install -m 0644 "$TOP/debian/copyright" "$ROOT/usr/share/doc/beanjar-qemu/copyright"
(cd "$PKG" &&
	dpkg-shlibdeps -edebian/beanjar-qemu/usr/libexec/beanjar/qemu-system-aarch64 \
		-edebian/beanjar-qemu/usr/libexec/beanjar/vhost-user-gpu &&
	dpkg-gencontrol -pbeanjar-qemu -Pdebian/beanjar-qemu)
(cd "$ROOT" && find usr -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum > DEBIAN/md5sums)
chmod 0644 "$ROOT/DEBIAN/md5sums"
mkdir -p "$OUT/debs"
deb=$OUT/debs/beanjar-qemu_${version}_$arch.deb
dpkg-deb --root-owner-group -Zxz -z3 --build "$ROOT" "$deb"
dpkg-deb --info "$deb"
echo "$deb: $(dpkg-deb --contents "$deb" | wc -l) entries, built in $(( $(date +%s) - t0 )) s"
