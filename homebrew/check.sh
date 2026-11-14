#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check that Beanjar's Homebrew formulae build what this repository builds: each formula's
# version is the program's VERSION here, its source is the one `sources` or the checksum file
# pins, and every file it takes from this repository (patches, check programs) is pinned at a
# commit of this repository, with the SHA-256 that file has there and still has now, and no patch
# here is left out. It fails, naming the formula, when they have drifted apart.
#
#   homebrew/check.sh [FORMULA_DIR]      default FORMULA_DIR: homebrew/Formula
#
# Needs this repository's git history (the pinned commits) and sha256sum or shasum.
set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
F=${1:-$TOP/homebrew/Formula}
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok: $*"; }
sha() { if command -v sha256sum > /dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
# the formula's value of a one-line field: version, sha256 (the first), revision
field() { sed -n "s/^  $2 \"\([^\"]*\)\".*/\1/p" "$F/$1.rb" | head -1; }
url() { sed -n 's/^  url "\([^"]*\)".*/\1/p' "$F/$1.rb" | head -1; }
eq() { [ "$2" = "$3" ] && ok "$1: $2" || fail "$1: formula has '$2', this repository '$3'"; }

for f in beanjar-angle beanjar-libepoxy beanjar-virglrenderer beanjar-qemu; do
	[ -f "$F/$f.rb" ] || fail "$F/$f.rb missing"
done
[ "$fails" = 0 ] || exit 1

# Versions
eq "beanjar-angle version" "$(field beanjar-angle version)" "$(cat "$TOP/angle/VERSION")"
eq "beanjar-virglrenderer version" "$(field beanjar-virglrenderer version)" "$(cat "$TOP/virglrenderer/VERSION")"
eq "beanjar-qemu version" "$(field beanjar-qemu version)" "$(cat "$TOP/qemu/VERSION")"
v=$(cat "$TOP/virglrenderer/VERSION")
lv=$(field beanjar-libepoxy version)
eq "beanjar-libepoxy Beanjar revision" "+beanjar${lv##*+beanjar}" "+beanjar${v##*+beanjar}"

# Sources
src() { awk -v n="$1" '$1 == n { print $3 }' "$TOP/$2/sources"; }
av=$(cat "$TOP/angle/VERSION")
au=${av%%+beanjar*}
case $(url beanjar-angle) in
*/angle-"$au"-source.tar.xz) ok "beanjar-angle source: angle-$au-source.tar.xz" ;;
*) fail "beanjar-angle url $(url beanjar-angle) is not angle-$au-source.tar.xz" ;;
esac
hash=$(sed -n 's/.*ENV\["ANGLE_UPSTREAM_HASH"\] = "\([0-9a-f]*\)".*/\1/p' "$F/beanjar-angle.rb")
case $(src angle angle) in
"$hash"*) ok "beanjar-angle commit: $hash" ;;
*) fail "beanjar-angle ANGLE_UPSTREAM_HASH '$hash' is not angle/sources' $(src angle angle)" ;;
esac
eq "beanjar-virglrenderer commit" \
	"$(sed -n 's/^ *revision: "\([0-9a-f]*\)".*/\1/p' "$F/beanjar-virglrenderer.rb")" \
	"$(src virglrenderer virglrenderer)"
eq "beanjar-libepoxy commit" \
	"$(url beanjar-libepoxy | sed -n 's|.*/archive/\([0-9a-f]*\)\.tar\.gz$|\1|p')" \
	"$(src libepoxy virglrenderer)"
qv=$(cat "$TOP/qemu/VERSION")
qf=qemu-${qv%%+beanjar*}.tar.xz
eq "beanjar-qemu source" "$(basename "$(url beanjar-qemu)")" "$qf"
eq "beanjar-qemu sha256" "$(field beanjar-qemu sha256)" "$(awk -v f="$qf" '$2 == f { print $1 }' "$TOP/qemu/qemu.sha256")"

# Files taken from this repository: each URL at a commit, with the SHA-256 on the line after it
pins=$(awk '
	/url "https:\/\/raw\.githubusercontent\.com\/mariotaku\/beanjar-vendor\// {
		match($0, /beanjar-vendor\/[0-9a-f]+\/[^"]+/)
		p = substr($0, RSTART + 15, RLENGTH - 15)
		getline
		if (match($0, /sha256 "[0-9a-f]+"/)) print FILENAME, p, substr($0, RSTART + 8, 64)
		else print FILENAME, p, "none"
	}' "$F"/*.rb)
echo "$pins" | while read -r file pin want; do
	commit=${pin%%/*}
	path=${pin#*/}
	at=$(git -C "$TOP" show "$commit:$path" 2> /dev/null | sha) || true
	if ! git -C "$TOP" cat-file -e "$commit:$path" 2> /dev/null; then
		fail "$(basename "$file"): $path is not in commit $commit"
	elif [ "$at" != "$want" ]; then
		fail "$(basename "$file"): $path at $commit has SHA-256 $at, the formula $want"
	elif [ ! -f "$TOP/$path" ]; then
		fail "$(basename "$file"): $path is gone from this repository"
	elif [ "$(sha < "$TOP/$path")" != "$want" ]; then
		fail "$(basename "$file"): $path has changed since $commit: pin the formula to a newer commit"
	else
		ok "$(basename "$file"): $path at ${commit%"${commit#????????????}"}"
	fi
done 2>&1 | tee "${TMPDIR:-/tmp}/check-pins.$$"
grep -q '^FAIL' "${TMPDIR:-/tmp}/check-pins.$$" && fails=$((fails + 1))
rm -f "${TMPDIR:-/tmp}/check-pins.$$"
# ...and every patch here is one of them
for p in "$TOP"/qemu/patches/*.patch "$TOP"/virglrenderer/patches/*/*.patch; do
	rel=${p#"$TOP"/}
	echo "$pins" | grep -q "/$rel " || fail "no formula applies $rel"
done

[ "$fails" = 0 ] || { echo "homebrew/check.sh: the formulae and this repository differ" >&2; exit 1; }
echo "homebrew/check.sh: the formulae build what this repository pins"
