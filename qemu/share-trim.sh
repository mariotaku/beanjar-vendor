#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Reduce an installed QEMU data directory to the files share-keep lists for the targets built:
# every other file, and the directories left empty, are deleted. Fails, deleting nothing, if a
# listed file is not there.
#
#   qemu/share-trim.sh SHARE_DIR TARGET...      for example: share-trim.sh "$ROOT/share/qemu" aarch64
#
# share-keep is read from this script's directory.
set -eu
die() { echo "share-trim.sh: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: share-trim.sh SHARE_DIR TARGET..."
list=$(cd "$(dirname "$0")" && pwd)/share-keep
[ -f "$list" ] || die "$list: no such file"
dir=$1
shift
[ -d "$dir" ] || die "$dir: no such directory"
# The files to keep: entries without targets, and those naming one of ours
keep=$(sed 's/#.*//' "$list" | awk -v targets="$*" '
	BEGIN { n = split(targets, t, " "); for (i = 1; i <= n; i++) want[t[i]] = 1 }
	NF == 0 { next }
	NF == 1 { print $1; next }
	{ for (i = 2; i <= NF; i++) if ($i in want) { print $1; next } }')
[ -n "$keep" ] || die "share-keep keeps nothing for $*"
missing=0
for f in $keep; do
	[ -f "$dir/$f" ] || { echo "share-trim.sh: $dir/$f: listed in share-keep, not installed" >&2; missing=1; }
done
[ "$missing" = 0 ] || exit 1
(cd "$dir" && find . -type f -o -type l) | sed 's|^\./||' | sort | while read -r f; do
	echo "$keep" | grep -qxF "$f" || rm -f "$dir/$f"
done
find "$dir" -mindepth 1 -depth -type d -empty -exec rmdir {} \;
echo "share-trim.sh: $dir keeps:"
(cd "$dir" && find . -type f | sed 's|^\./| |' | sort)
