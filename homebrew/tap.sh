#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Install Beanjar's tap, webosbrew/beanjar, on this Mac for the Homebrew workflow, and put the
# ANGLE source archive where Homebrew looks for its download.
#
#   homebrew/tap.sh SOURCE [ANGLE_SOURCE_TARBALL]
#
# SOURCE is where the formulae come from: "copy" for this repository's homebrew/Formula (kept the
# same as Beanjar's by homebrew/sync.sh), or a git URL of Beanjar's repository, optionally with
# "#<commit>" to check out. The tap is a git repository either way, as `brew bottle` wants.
# ANGLE_SOURCE_TARBALL, from angle/source.sh, is checked against beanjar-angle's SHA-256 and put
# in Homebrew's download cache, since the release it will be downloaded from does not exist yet.
set -eu
die() { echo "tap.sh: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: tap.sh SOURCE [ANGLE_SOURCE_TARBALL]"
TOP=$(cd "$(dirname "$0")/.." && pwd)
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
TAP=webosbrew/beanjar
brew --version

if [ "$1" = copy ]; then
	repo=$(mktemp -d)/beanjar-tap
	mkdir -p "$repo/Formula"
	cp "$TOP"/homebrew/Formula/*.rb "$repo/Formula/"
	git -C "$repo" init -q
	git -C "$repo" add Formula
	git -C "$repo" -c user.name=CI -c user.email=ci@invalid commit -q -m "Formulae from beanjar-vendor's homebrew/Formula"
	brew tap "$TAP" "$repo"
else
	url=${1%%#*}
	brew tap "$TAP" "$url"
	case $1 in *"#"*) git -C "$(brew --repository "$TAP")" checkout -q "${1#*#}" ;; esac
fi
# Taps other than Homebrew's own need trusting before their formulae are used by name
if brew commands --quiet | grep -qx trust; then
	brew trust "$TAP"
fi
git -C "$(brew --repository "$TAP")" log -1 --format='tap at %H'
brew style "$TAP"

if [ $# -ge 2 ]; then
	f=$TAP/beanjar-angle
	want=$(brew info --json=v2 "$f" | python3 -c 'import json, sys; print(json.load(sys.stdin)["formulae"][0]["urls"]["stable"]["checksum"])')
	have=$(shasum -a 256 "$2" | cut -d' ' -f1)
	[ "$have" = "$want" ] || die "$2 has SHA-256 $have, beanjar-angle wants $want: angle/source.sh and the formula disagree"
	cache=$(brew --cache --build-from-source "$f")
	mkdir -p "$(dirname "$cache")"
	cp "$2" "$cache"
	touch "$cache"
	echo "ANGLE source $have in $cache"
fi
