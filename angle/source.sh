#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Make ANGLE's source tarball: the commit in `sources` with what its DEPS pins for a macOS build,
# as depot_tools' gclient checks it out, cut down to what building libEGL and libGLESv2 reads
# (source-paths), without git metadata and without the prebuilt toolchains (clang, gn, ninja,
# Rust), which are not source and differ per host. It is what the Homebrew formula
# beanjar-angle builds from, so the formula pins one archive by SHA-256 instead of gclient
# fetching a few GB at install time. The tarball is reproducible: the same `sources` and
# source-paths give the same bytes with the same GNU tar and xz.
#
#   angle/source.sh [OUT]     default OUT: build/angle-source in the repository
#
# Runs on Linux or macOS with git, Python 3, GNU tar (gtar on macOS) and xz. The result is
# OUT/angle-<branch>.<commit>-source.tar.xz, whose top directory angle-<branch>.<commit>/ is
# ANGLE's root, and its SHA-256 in OUT/angle-<branch>.<commit>-source.tar.xz.sha256.
set -eu
umask 022
TOP=$(cd "$(dirname "$0")" && pwd)
die() { echo "source.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
OUT=${1:-$TOP/../build/angle-source}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
version=$(cat "$TOP/VERSION")
upstream=${version%%+beanjar*}
[ "$upstream" != "$version" ] || die "VERSION $version is not <branch>.<commit>+beanjar<N>"
if command -v gtar > /dev/null; then TAR=gtar; else TAR=tar; fi
$TAR --version | head -1 | grep -q 'GNU tar' || die "GNU tar required"
xz --version | head -1

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
mtime=$(git -C "$A" log -1 --format=%ct)
export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0 GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1
export PATH="$SRC/depot_tools:$PATH"
# The checkout build.sh makes, for a macOS target whatever the host, with git dependencies only:
# the clang, gn, ninja and Rust packages (CIPD and Cloud Storage) are left to whoever builds
cat > "$SRC/.gclient" <<'EOF'
solutions = [{
  "name": "angle",
  "url": "https://chromium.googlesource.com/angle/angle.git",
  "deps_file": "DEPS",
  "managed": False,
  "custom_vars": {
    "checkout_angle_cl_deps": False,
    "checkout_angle_dawn_deps": False,
  },
  "custom_deps": {
    "angle/third_party/VK-GL-CTS/src": None,
    "angle/third_party/SwiftShader": None,
    "angle/third_party/catapult": None,
    "angle/third_party/cherry": None,
  },
}]
target_os = ["mac"]
target_os_only = True
EOF
(cd "$SRC" && gclient sync --no-history --shallow --jobs 8 --nohooks \
	--ignore-dep-type=cipd --ignore-dep-type=gcs)
# The one hook whose output the build reads and that needs git: build/util/LASTCHANGE, from
# ANGLE's commit
(cd "$A" && python3 build/util/lastchange.py -o build/util/LASTCHANGE)
cat "$A/build/util/LASTCHANGE"

step "cut"
# Keep ANGLE's own files and the listed dependency directories; every other checkout, all git
# metadata and the dropped paths go
deps=$(cd "$A" && find . -mindepth 2 -name .git -prune -print | sed 's|^\./||; s|/\.git$||' | sort)
keep=$(sed -n '/^[^#!]/p' "$TOP/source-paths")
drop=$(sed -n 's/^!//p' "$TOP/source-paths")
for p in $keep; do
	echo "$deps" | grep -qx "$p" || [ -d "$A/$p" ] || die "source-paths: $p is not in the checkout"
done
for d in $deps; do
	echo "$keep" | grep -qx "$d" && continue
	# a kept directory inside a dropped one (jsoncpp/source in jsoncpp) stays only if listed
	echo "$keep" | grep -q "^$d/" && { echo "partly kept: $d"; continue; }
	rm -rf "${A:?}/$d"
done
for p in $drop; do
	[ -e "$A/$p" ] || die "source-paths: !$p is not in the checkout"
	rm -rf "${A:?}/$p"
done
find "$A" -name .git -prune -exec rm -rf {} +
du -sh "$A"

step "tarball"
name=angle-$upstream
tarball=$OUT/$name-source.tar.xz
mv "$A" "$SRC/$name"
# file order, owners, times and modes fixed, so the bytes depend only on the content
(cd "$SRC" && $TAR --sort=name --format=gnu --owner=0 --group=0 --numeric-owner \
	--mtime="@$mtime" --clamp-mtime --mode='u+rwX,go+rX,go-w' -cf - "$name") |
	xz -T1 -6 -c > "$tarball.part"
mv "$tarball.part" "$tarball"
(cd "$OUT" && shasum -a 256 "$(basename "$tarball")" | tee "$(basename "$tarball").sha256")
ls -l "$tarball"
rm -rf "$SRC"
