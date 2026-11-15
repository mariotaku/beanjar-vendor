#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Keep homebrew/Formula, the copy of Beanjar's Homebrew formulae that the Homebrew workflow builds
# bottles from, the same as Beanjar's Formula/ directory. Beanjar's repository is the formulae's
# home (it is the tap); this copy exists only because the workflow cannot fetch them from there
# yet.
#
#   homebrew/sync.sh BEANJAR             copy BEANJAR/Formula/*.rb here, dropping formulae gone
#                                        from there
#   homebrew/sync.sh --check BEANJAR     only compare; exit 1 and show the differences if the
#                                        copy is not the same
#
# BEANJAR is a checkout of Beanjar's repository. Run it after every change to the formulae
# there, then commit the copy here with the change it brings.
set -eu
die() { echo "sync.sh: $*" >&2; exit 1; }
check=0
[ "${1:-}" = --check ] && { check=1; shift; }
[ $# -eq 1 ] || die "usage: sync.sh [--check] BEANJAR"
TOP=$(cd "$(dirname "$0")" && pwd)
src=$1/Formula
[ -d "$src" ] || die "$src: no such directory"
dst=$TOP/Formula
if [ "$check" = 1 ]; then
	diff -ru "$src" "$dst" || die "homebrew/Formula differs from $src: run homebrew/sync.sh $1"
	echo "homebrew/Formula is the same as $src"
	exit 0
fi
mkdir -p "$dst"
rm -f "$dst"/*.rb
cp "$src"/*.rb "$dst"/
ls "$dst"
