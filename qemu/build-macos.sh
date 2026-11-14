#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build Beanjar's patched QEMU for macOS, for this Mac's architecture (arm64 or x86_64), and pack
# the installed program and data as a tarball. The same release, patches and target as build.sh's
# Debian build, configured for what a Mac has: the D-Bus display and audio, CoreAudio, slirp,
# virtio-9p, and OpenGL through libepoxy and virglrenderer from this repository's angle/ and
# virglrenderer/ tarballs. Run it on a throwaway Mac (a CI runner): it installs the build
# dependencies with Homebrew.
#
#   qemu/build-macos.sh ANGLE_TARBALL VIRGLRENDERER_TARBALL [OUT]
#                                       default OUT: build/qemu in the repository
#
# The result is OUT/qemu-<version>-macos-<arch>.tar.xz (<arch> arm64 or amd64), the layout of
# QEMU's installed prefix:
#
#   bin/qemu-system-aarch64    stripped, ad hoc signed with QEMU's own entitlements (HVF)
#   share/qemu/                QEMU's data directory (firmware images, keymaps)
#   share/doc/qemu/            QEMU's licence texts, pc-bios-README, NOTICE
#   BUILDINFO                  what was built from what and how, and what it needs
#
# The program finds libepoxy, virglrenderer and ANGLE in ../lib (LC_RPATH @loader_path/../lib):
# the angle and virglrenderer tarballs are unpacked into the same directory, as BUILDINFO's
# Requires says. The other libraries (GLib, pixman, libslirp...) are Homebrew's, linked at
# Homebrew's paths: BUILDINFO's Homebrew field names the formulae and Links lists every library
# the program loads. test-tarball-macos.sh then runs the program from the three tarballs
# unpacked in another directory.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
die() { echo "build-macos.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ $# -ge 2 ] || die "usage: build-macos.sh ANGLE_TARBALL VIRGLRENDERER_TARBALL [OUT]"
[ "$(uname -s)" = Darwin ] || die "macOS required"
angle_tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
virgl_tarball=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
OUT=${3:-$TOP/../build/qemu}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
PREFIX=/qemu
case $(uname -m) in
arm64) arch=macos-arm64 ;;
x86_64) arch=macos-amd64 ;;
*) die "arm64 or x86_64, not $(uname -m)" ;;
esac
version=$(cat "$TOP/VERSION")
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "VERSION $version is not <QEMU version>+beanjar<N>"
t0=$(date +%s)
# The libraries QEMU links from Homebrew, and the tools that build it
BREW_LIBS="glib pixman libslirp dtc libpng libusb usbredir"
BREW_TOOLS="meson ninja pkgconf gnu-tar xz"

step "build dependencies"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
# shellcheck disable=SC2086 # lists of formulae
brew install --quiet $BREW_TOOLS $BREW_LIBS
BREW=$(brew --prefix)

step "sources"
DL=$OUT/download
mkdir -p "$DL"
f=qemu-$upstream.tar.xz
f_sha=$(grep "  $f\$" "$TOP/qemu.sha256" | cut -d' ' -f1)
[ -n "$f_sha" ] || die "qemu.sha256 has no checksum for $f"
if ! echo "$f_sha  $DL/$f" | shasum -a 256 -c --status 2>/dev/null; then
	curl -fL --retry 3 -o "$DL/$f.part" "https://download.qemu.org/$f"
	mv "$DL/$f.part" "$DL/$f"
	echo "$f_sha  $DL/$f" | shasum -a 256 -c
fi
SRC=$OUT/src
rm -rf "$SRC"
mkdir -p "$SRC/deps"
tar -C "$SRC" -xJf "$DL/$f"
S=$SRC/qemu-$upstream
for p in "$TOP"/patches/*.patch; do
	echo "applying $(basename "$p")"
	patch -d "$S" -p1 --batch --forward --quiet < "$p"
done
SOURCE_DATE_EPOCH=$(stat -f %m "$S/VERSION")
export SOURCE_DATE_EPOCH
cp "$DL/$f" "$OUT/$f"
# ANGLE, libepoxy and virglrenderer, unpacked as they will be next to QEMU
DEPS=$SRC/deps
tar -C "$DEPS" -xJf "$angle_tarball"
mv "$DEPS/BUILDINFO" "$SRC/BUILDINFO.angle"
tar -C "$DEPS" -xJf "$virgl_tarball"
mv "$DEPS/BUILDINFO" "$SRC/BUILDINFO.virglrenderer"
field() { sed -n "s/^$1: //p" "$2"; }
for b in angle virglrenderer; do
	[ "$(field Architecture "$SRC/BUILDINFO.$b")" = "$arch" ] || die "the $b tarball is not $arch"
done
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"

step "configure"
# Only aarch64-softmmu, as on Debian, with what a Mac can give the launcher: OpenGL and
# virglrenderer (virtio-gpu-gl), the D-Bus display and its audio backend, CoreAudio, slirp,
# virtio-9p, PNG for the QMP screendump, usb-redir and usb-host. No cocoa, SDL, GTK, VNC, SPICE
# or curses display, and no block drivers or crypto libraries beyond QEMU's built-in ones. HVF is
# QEMU's default on a Mac and stays; it runs AArch64 guests only. No tools: vhost-user-gpu, the
# one the Debian build ships, is Linux-only.
set -- --prefix="$PREFIX" --target-list=aarch64-softmmu --disable-download \
	--disable-modules --disable-docs --disable-user --disable-tools --disable-guest-agent \
	--enable-opengl --enable-virglrenderer --enable-dbus-display \
	--enable-slirp --enable-fdt=system --enable-virtfs --enable-pixman --enable-png \
	--disable-cocoa --disable-sdl --disable-gtk --disable-vnc --disable-spice --disable-curses \
	--audio-drv-list=coreaudio --enable-coreaudio \
	--disable-curl --disable-gnutls --disable-nettle --disable-gcrypt --disable-capstone \
	--disable-lzo --disable-bzip2 --disable-zstd --enable-libusb --enable-usb-redir \
	--disable-smartcard --disable-libssh \
	--extra-ldflags=-Wl,-rpath,@loader_path/../lib
B=$SRC/obj
mkdir -p "$B"
(cd "$B" && "$S/configure" "$@")
configure_line="configure $*"

step "build ($(sysctl -n hw.ncpu) jobs)"
make -C "$B" -j"$(sysctl -n hw.ncpu)"
STAGE=$SRC/stage
make -C "$B" install DESTDIR="$STAGE" >/dev/null

step "tree"
ROOT=$SRC/root
mkdir -p "$ROOT/bin" "$ROOT/share/doc/qemu"
q=$ROOT/bin/qemu-system-aarch64
cp "$STAGE$PREFIX/bin/qemu-system-aarch64" "$q"
chmod 0755 "$q"
# strip drops the signature and its entitlements (com.apple.security.hypervisor, which HVF
# needs); sign again, ad hoc, with the same ones
codesign -d --entitlements - --xml "$q" > "$SRC/entitlements.plist" 2>/dev/null || true
strip -S -x "$q"
if [ -s "$SRC/entitlements.plist" ]; then
	codesign --force --sign - --entitlements "$SRC/entitlements.plist" "$q"
else
	codesign --force --sign - "$q"
fi
codesign --verify --verbose "$q"
cp -R "$STAGE$PREFIX/share/qemu" "$ROOT/share/qemu"
rm -rf "$ROOT/share/qemu/vhost-user"
for d in COPYING COPYING.LIB LICENSE; do
	install -m 0644 "$S/$d" "$ROOT/share/doc/qemu/$d"
done
install -m 0644 "$S/pc-bios/README" "$ROOT/share/doc/qemu/pc-bios-README"
install -m 0644 "$TOP/NOTICE" "$ROOT/share/doc/qemu/NOTICE"

# What the program loads: @rpath libraries come from the angle and virglrenderer tarballs,
# absolute ones outside /usr/lib and /System from Homebrew.
links=$(otool -L "$q" | tail -n +2 | sed 's/^[[:space:]]*//; s/ (.*//')
echo "$links"
for l in $links; do
	case $l in
	@rpath/*) [ -e "$DEPS/lib/${l#@rpath/}" ] || die "$l is in neither dependency tarball" ;;
	/usr/lib/* | /System/*) ;;
	"$BREW"/*) ;;
	*) die "unexpected library $l" ;;
	esac
done
brew_versions=$(brew list --versions $BREW_LIBS | sed 's/$/,/' | tr '\n' ' ' | sed 's/, $//')
{
	echo "Program: qemu"
	echo "Version: $version"
	echo "Architecture: $arch"
	echo "macOS-Release: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), SDK $(xcrun --show-sdk-version)"
	echo "Prefix: $PREFIX"
	echo "License: GPL-2.0-only"
	echo "Programs: bin/qemu-system-aarch64"
	echo "Data: share/qemu"
	echo "Sources:"
	echo " $f $f_sha https://download.qemu.org/$f"
	echo "Patches:"
	for p in "$TOP"/patches/*.patch; do
		echo " $(basename "$p") $(shasum -a 256 < "$p" | cut -d' ' -f1)"
	done
	echo "Configure:"
	echo " $configure_line"
	echo "Requires: angle $(field Version "$SRC/BUILDINFO.angle"), virglrenderer $(field Version "$SRC/BUILDINFO.virglrenderer")"
	echo "Homebrew: $brew_versions"
	echo "Links:"
	for l in $links; do echo " $l"; done
} > "$ROOT/BUILDINFO"
cat "$ROOT/BUILDINFO"

step "tarball"
tarball=$OUT/qemu-$version-$arch.tar.xz
gtar -C "$ROOT" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cJf "$tarball" .
gtar -tvJf "$tarball"
rm -rf "$SRC"

step "test"
sh "$TOP/test-tarball-macos.sh" "$tarball" "$angle_tarball" "$virgl_tarball" "$OUT/test"
echo "$tarball: built in $(( $(date +%s) - t0 )) s"
