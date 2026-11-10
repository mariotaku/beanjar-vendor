#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build Beanjar's patched QEMU for Debian 13, for this machine's architecture (amd64 or arm64),
# and pack the installed programs and data as a tarball. Run as root in a throwaway debian:trixie
# container: it installs the build dependencies into the system it runs in.
#
#   qemu/build.sh [OUT]     default OUT: build/qemu in the repository
#
# VERSION holds the version, QEMU's upstream version plus a Beanjar revision (10.0.2+beanjar1).
# Its upstream part names the release tarball, downloaded from qemu.org and checked against
# qemu.sha256. patches/*.patch are applied in order, and QEMU is configured for aarch64-softmmu
# with only what Beanjar's launcher uses. QEMU finds its data relative to its program, and the
# launcher passes -L anyway, so the configure prefix (/qemu) is not used at run time. The result
# is OUT/qemu-<version>-<arch>.tar.xz, the layout of QEMU's installed prefix:
#
#   bin/qemu-system-aarch64    stripped
#   libexec/vhost-user-gpu     QEMU's own vhost-user GPU backend, stripped
#   share/qemu/                QEMU's data directory (firmware images, keymaps), without the
#                              vhost-user JSON, which names the configure prefix
#   share/doc/qemu/            QEMU's licence texts, pc-bios-README, NOTICE
#   BUILDINFO                  what was built from what and how, and its Depends
#
# BUILDINFO is in Debian control syntax. Its Depends field is dpkg-shlibdeps' for the two programs,
# plus libegl1 and libopengl0, which libepoxy loads at run time where dpkg-shlibdeps cannot see
# them. OUT/qemu-<upstream>.tar.xz is the upstream release tarball the programs are built from.
# test-tarball.sh then runs the programs from the tarball unpacked in another directory.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$TOP/../build/qemu}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
export DEBIAN_FRONTEND=noninteractive
PREFIX=/qemu
DLOPEN_DEPENDS="libegl1, libopengl0"

die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ "$(id -u)" = 0 ] || die "run as root in a throwaway Debian 13 container"
grep -q '^VERSION_ID="13"' /etc/os-release || die "Debian 13 required"
arch=$(dpkg --print-architecture)
case $arch in amd64|arm64) ;; *) die "amd64 or arm64, not $arch" ;; esac
version=$(cat "$TOP/VERSION")
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "VERSION $version is not <QEMU version>+beanjar<N>"
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
# file dates clamped to the release tarball's, so equal sources give equal tarballs
SOURCE_DATE_EPOCH=$(stat -c %Y "$S/VERSION")
export SOURCE_DATE_EPOCH
# the corresponding source, with the patches in this directory
cp "$DL/$f" "$OUT/$f"

step "configure"
# Only aarch64-softmmu, with what the launcher uses: OpenGL/virglrenderer for virtio-gpu-gl,
# egl-headless and the D-Bus display (and its audio backend), GBM, slirp, virtio-9p, PNG for the
# QMP screendump, usb-redir and usb-host. The tools option is the only one that builds
# contrib/vhost-user-gpu; the other tools are left out of the tarball. No SDL/GTK/VNC/SPICE/
# curses, host audio drivers, extra block drivers or crypto libraries. --disable-download: the
# tarball carries the subprojects QEMU still needs.
set -- --prefix="$PREFIX" --target-list=aarch64-softmmu --disable-download \
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
	--disable-vduse-blk-export
B=$SRC/obj
mkdir -p "$B"
(cd "$B" && "$S/configure" "$@")
configure_line="configure $*"

step "build ($(nproc) jobs)"
make -C "$B" -j"$(nproc)"
STAGE=$SRC/stage
make -C "$B" install DESTDIR="$STAGE" >/dev/null

step "tree"
# The two programs and the data directory only: QEMU's other tools, the vhost-user JSON (it names
# the configure prefix, not where the backend ends up), the desktop file and icons stay out. The
# tree is assembled where dpkg-shlibdeps expects a package's files, in a debhelper-like layout.
SHL=$SRC/shlibdeps
ROOT=$SHL/debian/beanjar-qemu
mkdir -p "$ROOT/bin" "$ROOT/libexec" "$ROOT/share/doc/qemu"
for p in bin/qemu-system-aarch64 libexec/vhost-user-gpu; do
	install -m 0755 "$STAGE$PREFIX/$p" "$ROOT/$p"
	strip --strip-unneeded "$ROOT/$p"
done
cp -R "$STAGE$PREFIX/share/qemu" "$ROOT/share/qemu"
rm -rf "$ROOT/share/qemu/vhost-user"
for d in COPYING COPYING.LIB LICENSE; do
	install -m 0644 "$S/$d" "$ROOT/share/doc/qemu/$d"
done
install -m 0644 "$S/pc-bios/README" "$ROOT/share/doc/qemu/pc-bios-README"
install -m 0644 "$TOP/NOTICE" "$ROOT/share/doc/qemu/NOTICE"

# dpkg-shlibdeps finds the package's root by its DEBIAN directory
mkdir "$ROOT/DEBIAN"
printf 'Source: beanjar-qemu\n\nPackage: beanjar-qemu\nArchitecture: any\n' > "$SHL/debian/control"
depends=$(cd "$SHL" && dpkg-shlibdeps -O -edebian/beanjar-qemu/bin/qemu-system-aarch64 \
	-edebian/beanjar-qemu/libexec/vhost-user-gpu | sed -n 's/^shlibs:Depends=//p')
rmdir "$ROOT/DEBIAN"
[ -n "$depends" ] || die "dpkg-shlibdeps reported no dependencies"
{
	echo "Program: qemu"
	echo "Version: $version"
	echo "Architecture: $arch"
	echo "Debian-Release: $(cat /etc/debian_version)"
	echo "Prefix: $PREFIX"
	echo "License: GPL-2.0-only"
	echo "Programs: bin/qemu-system-aarch64 libexec/vhost-user-gpu"
	echo "Data: share/qemu"
	echo "Sources:"
	echo " $f $f_sha https://download.qemu.org/$f"
	echo "Patches:"
	for p in "$TOP"/patches/*.patch; do
		echo " $(basename "$p") $(sha256sum < "$p" | cut -d' ' -f1)"
	done
	echo "Configure:"
	echo " $configure_line"
	echo "Depends: $depends, $DLOPEN_DEPENDS"
} > "$ROOT/BUILDINFO"
cat "$ROOT/BUILDINFO"

step "tarball"
tarball=$OUT/qemu-$version-$arch.tar.xz
tar -C "$ROOT" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cJf "$tarball" .
tar -tvJf "$tarball"
rm -rf "$SRC"

step "test"
sh "$TOP/test-tarball.sh" "$tarball" "$OUT/test"
echo "$tarball: built in $(( $(date +%s) - t0 )) s"
