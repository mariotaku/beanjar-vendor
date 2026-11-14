#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Build one of Beanjar's Homebrew formulae as a bottle on this Mac and check it: install its
# dependencies, install it from source with --build-bottle, run its test, check its linkage, audit
# it, and write the bottle and its JSON. Run it on a throwaway Mac (a CI runner) with the tap
# installed (the Homebrew workflow does that).
#
#   homebrew/bottle.sh FORMULA OUT [ROOT_URL]
#
# FORMULA is a formula of the tap webosbrew/beanjar, for example beanjar-qemu. OUT receives
# <formula>--<version>.<macOS tag>.bottle.tar.gz and .bottle.json. ROOT_URL is where the bottle
# will be downloaded from, the GitHub release the bottle is to be published with; it goes into
# the JSON, from which `brew bottle --merge --write` makes the formula's bottle block. By default
# it is this repository's release <formula>-<version>.
set -eu
die() { echo "bottle.sh: $*" >&2; exit 1; }
step() { echo "== $* ($(date -u +%T))"; }
[ $# -ge 2 ] || die "usage: bottle.sh FORMULA OUT [ROOT_URL]"
f=webosbrew/beanjar/$1
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
version=$(brew info --json=v2 "$f" | python3 -c 'import json, sys; print(json.load(sys.stdin)["formulae"][0]["versions"]["stable"])')
# The release tag in a URL: "+" percent-encoded, as GitHub's own links have it
tag=$(printf '%s' "$1-$version" | sed 's/+/%2B/g')
root_url=${3:-https://github.com/mariotaku/beanjar-vendor/releases/download/$tag}
t0=$(date +%s)

step "$f $version: dependencies"
# --build-bottle wants every dependency it would install poured from a bottle, and Homebrew has
# none for Intel Macs (a Tier 3 configuration): install them first, from source where needed
brew install --only-dependencies "$f"
step "$f: install"
brew install --build-bottle --verbose "$f"
step "$f: test"
brew test --verbose "$f"
step "$f: linkage"
brew linkage --test "$f"
step "$f: audit"
# --strict, but not --online: the source archive of beanjar-angle and the bottles are only
# published with a release
brew audit --strict --formula "$f"
step "$f: bottle"
(cd "$OUT" && brew bottle --json --no-rebuild --root-url="$root_url" "$f")
ls -l "$OUT"
du -sh "$(brew --prefix "$f")"
echo "$f: built, tested and bottled in $(($(date +%s) - t0)) s"
