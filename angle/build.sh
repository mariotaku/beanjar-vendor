#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build ANGLE's libEGL and libGLESv2 for macOS with only its Metal backend, for this Mac's
# architecture (arm64 or x86_64), and pack them with ANGLE's headers as a tarball. Run it on a
# throwaway Mac (a CI runner) with Xcode: it installs a few tools with Homebrew.
#
#   angle/build.sh [OUT]     default OUT: build/angle in the repository
#
# VERSION holds the version: the Chromium branch the ANGLE commit is the tip of and the commit
# (8149.29d18232), plus a Beanjar revision. `sources` pins ANGLE and depot_tools by git commit;
# ANGLE's DEPS file pins everything else gclient fetches, its own clang and libc++ included, and
# ANGLE is built the way its own documentation does, with gn and ninja. The result is
# OUT/angle-<version>-macos-<arch>.tar.xz (<arch> arm64 or amd64), whose root is a relocatable
# prefix:
#
#   lib/libEGL.dylib, lib/libGLESv2.dylib   install names @rpath/<name>; they link only the
#                                           system's libraries and frameworks (ANGLE's libc++
#                                           is built in)
#   lib/pkgconfig/egl.pc, glesv2.pc         prefix=${pcfiledir}/../..
#   include/EGL, GLES2, GLES3, KHR          ANGLE's headers
#   share/doc/angle/                        ANGLE's LICENSE, the licences of the third-party code
#                                           linked in, NOTICE
#   BUILDINFO                               what was built from what and how
#
# test-tarball.sh then builds and runs an EGL program against the tarball unpacked in another
# directory.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ "$(uname -s)" = Darwin ] || die "macOS required"
OUT=${1:-$TOP/../build/angle}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
case $(uname -m) in
arm64) arch=macos-arm64 cpu=arm64 ;;
x86_64) arch=macos-amd64 cpu=x64 ;;
*) die "arm64 or x86_64, not $(uname -m)" ;;
esac
version=$(cat "$TOP/VERSION")
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "VERSION $version is not <branch>.<commit>+beanjar<N>"
t0=$(date +%s)

step "build tools"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
brew install --quiet pkgconf gnu-tar xz
xcodebuild -version
xcrun --show-sdk-version

step "sources"
SRC=$OUT/src
rm -rf "$SRC"
mkdir -p "$SRC"
while read -r name url commit; do
	git init -q "$SRC/$name"
	git -C "$SRC/$name" fetch -q --depth 1 "$url" "$commit"
	git -C "$SRC/$name" checkout -q FETCH_HEAD
	[ "$(git -C "$SRC/$name" rev-parse HEAD)" = "$commit" ] || die "$name is not at $commit"
done < "$TOP/sources"
A=$SRC/angle
commit=$(git -C "$A" rev-parse HEAD)
case $commit in "${upstream#*.}"*) ;; *) die "VERSION $version does not name commit $commit" ;; esac
SOURCE_DATE_EPOCH=$(git -C "$A" log -1 --format=%ct)
export SOURCE_DATE_EPOCH
# depot_tools at its pinned commit, never updating itself
export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0 GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1
export PATH="$SRC/depot_tools:$PATH"
# The checkout is ANGLE's own, unmanaged; the test suites' sources are left out, since no test
# is built
cat > "$SRC/.gclient" <<'EOF'
solutions = [{
  "name": "angle",
  "url": "https://chromium.googlesource.com/angle/angle.git",
  "deps_file": "DEPS",
  "managed": False,
  "custom_deps": {
    "third_party/VK-GL-CTS/src": None,
    "third_party/SwiftShader": None,
    "third_party/catapult": None,
    "third_party/cherry": None,
  },
}]
EOF
(cd "$SRC" && gclient sync --no-history --shallow --jobs 8 --nohooks)
(cd "$SRC" && gclient runhooks)
du -sh "$SRC"

step "build"
# A release build with the Metal backend only: no OpenGL, Vulkan, SwiftShader, WebGPU or null
# backend, no tests.
args="is_debug=false is_component_build=false target_cpu=\"$cpu\" symbol_level=0"
args="$args angle_enable_metal=true angle_enable_gl=false angle_enable_vulkan=false"
args="$args angle_enable_swiftshader=false angle_enable_wgpu=false angle_enable_null=false"
args="$args angle_build_tests=false"
(cd "$A" && gn gen out/Release --args="$args")
(cd "$A" && ninja -C out/Release libEGL libGLESv2)

step "tree"
ROOT=$SRC/root
mkdir -p "$ROOT/lib/pkgconfig" "$ROOT/include" "$ROOT/share/doc/angle"
for l in libEGL libGLESv2; do
	f=$ROOT/lib/$l.dylib
	install -m 0755 "$A/out/Release/$l.dylib" "$f"
	strip -S -x "$f"
	codesign --force --sign - "$f"
	otool -D "$f" | tail -n +2 | grep -qx "@rpath/$l.dylib" || die "$l: install name"
	otool -L "$f" | tail -n +2
	! otool -L "$f" | tail -n +2 | grep -v -e '@rpath/' -e '/usr/lib/' -e '/System/' ||
		die "$l links a library outside the tree and the system"
done
for d in EGL GLES2 GLES3 KHR; do
	cp -R "$A/include/$d" "$ROOT/include/$d"
done
install -m 0644 "$A/LICENSE" "$ROOT/share/doc/angle/LICENSE"
install -m 0644 "$TOP/NOTICE" "$ROOT/share/doc/angle/NOTICE"
# The licences of the third-party code linked in: every third_party directory the two
# libraries depend on, by gn's account
third=$(cd "$A" && for t in libEGL libGLESv2; do gn desc out/Release "//:$t" deps --all; done |
	sed -n 's|^//\(\(src/\)\{0,1\}third_party/[^/:]*\).*|\1|p' | sort -u)
echo "third-party code: $third"
for t in $third; do
	lic=
	for c in LICENSE LICENSE.TXT LICENSE.txt LICENSE.md COPYING src/LICENSE src/LICENSE.TXT \
		src/LICENSE.txt src/COPYING; do
		[ -f "$A/$t/$c" ] && { lic=$A/$t/$c; break; }
	done
	[ -n "$lic" ] || { echo "no licence file in $t"; continue; }
	install -m 0644 "$lic" "$ROOT/share/doc/angle/LICENSE-$(basename "$t")"
done
for pc in egl:EGL:libEGL glesv2:GLESv2:libGLESv2; do
	IFS=: read -r name lib desc <<-EOF
	$pc
	EOF
	cat > "$ROOT/lib/pkgconfig/$name.pc" <<-EOF
	prefix=\${pcfiledir}/../..
	libdir=\${prefix}/lib
	includedir=\${prefix}/include

	Name: $name
	Description: ANGLE's $desc (Metal)
	Version: $upstream
	Libs: -L\${libdir} -l$lib
	Cflags: -I\${includedir}
	EOF
done
{
	echo "Program: angle"
	echo "Version: $version"
	echo "Architecture: $arch"
	echo "macOS-Release: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), SDK $(xcrun --show-sdk-version), $(xcodebuild -version | head -1)"
	echo "Prefix: relocatable (install names @rpath, pkg-config files by \${pcfiledir})"
	echo "License: BSD-3-Clause (ANGLE); third-party parts in share/doc/angle/LICENSE-*"
	echo "Libraries: lib/libEGL.dylib lib/libGLESv2.dylib"
	echo "Pkg-Config: egl $upstream, glesv2 $upstream"
	echo "Sources:"
	while read -r name url c; do
		echo " $name $c $url"
	done < "$TOP/sources"
	echo "Third-Party:"
	for t in $third; do echo " $t"; done
	echo "GN-Args:"
	echo " $args"
	echo "Links:"
	for l in libEGL libGLESv2; do
		otool -L "$ROOT/lib/$l.dylib" | tail -n +2 | sed 's/^[[:space:]]*//; s/ (.*//; s/^/ /'
	done | sort -u
} > "$ROOT/BUILDINFO"
cat "$ROOT/BUILDINFO"

step "tarball"
tarball=$OUT/angle-$version-$arch.tar.xz
gtar -C "$ROOT" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime -cJf "$tarball" .
gtar -tvJf "$tarball"
rm -rf "$SRC"

step "test"
sh "$TOP/test-tarball.sh" "$tarball" "$OUT/test"
echo "$tarball: built in $(( $(date +%s) - t0 )) s"
