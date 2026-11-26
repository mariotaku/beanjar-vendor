# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# The patched FFmpeg source, shared by ffmpeg/build.sh and ffmpeg-helper/build.sh, which source
# this file so that both build the same source: FFmpeg's release tarball for the upstream part of
# the caller's VERSION, downloaded from ffmpeg.org, then the V4L2 request series, the
# V4L2REQ_COUNT commits of Jonas Karlman's branch up to V4L2REQ_COMMIT exported with git
# format-patch, then Beanjar's own patches in ffmpeg/patches/. The tarball and every patch are
# checked against ffmpeg/ffmpeg.sha256.
#
# Takes FF (the ffmpeg/ directory), OUT, upstream (the FFmpeg release), SOURCE_TARBALL (the
# patched source's tarball to write) and die(). Sets f and f_sha (the release tarball and its
# SHA-256), PATCHES (the exported series), SRC, S (the patched source in SRC) and exports
# SOURCE_DATE_EPOCH; the V4L2REQ_* values are for BUILDINFO.
V4L2REQ_URL=https://github.com/Kwiboo/FFmpeg.git
V4L2REQ_BRANCH=v4l2-request-n7.1.3
V4L2REQ_COMMIT=fad85d9c76611c09b561167ab405c667a0dcdeb7
V4L2REQ_BASE=f46e514491172d15bd74b4abb1814cd2f05a763e # tag n7.1.3
V4L2REQ_COUNT=14

DL=$OUT/download
mkdir -p "$DL"
f=ffmpeg-$upstream.tar.xz
f_sha=$(grep "  $f\$" "$FF/ffmpeg.sha256" | cut -d' ' -f1)
[ -n "$f_sha" ] || die "ffmpeg.sha256 has no checksum for $f"
if ! echo "$f_sha  $DL/$f" | sha256sum -c --status 2>/dev/null; then
	curl -fL --retry 3 -o "$DL/$f.part" "https://ffmpeg.org/releases/$f"
	mv "$DL/$f.part" "$DL/$f"
	echo "$f_sha  $DL/$f" | sha256sum -c
fi
git=$DL/v4l2-request.git
g() { git -c safe.directory="$git" -C "$git" "$@"; }
[ -d "$git" ] || git init -q --bare "$git"
g fetch -q --depth=$((V4L2REQ_COUNT + 1)) "$V4L2REQ_URL" "$V4L2REQ_COMMIT"
base=$(g rev-parse "$V4L2REQ_COMMIT~$V4L2REQ_COUNT")
[ "$base" = "$V4L2REQ_BASE" ] || die "$V4L2REQ_COMMIT~$V4L2REQ_COUNT is $base, not $V4L2REQ_BASE"
PATCHES=$OUT/patches
rm -rf "$PATCHES"
# --full-index and --zero-commit keep the output independent of the clone, so it can be hashed
g format-patch -q --full-index --no-signature --zero-commit -o "$PATCHES" \
	"$V4L2REQ_BASE..$V4L2REQ_COMMIT"
grep -v -e "  $f\$" -e '  patches/' "$FF/ffmpeg.sha256" > "$OUT/patches.sha256"
if ! (cd "$PATCHES" && sha256sum -- *.patch) | cmp -s - "$OUT/patches.sha256"; then
	echo "sources.sh: the exported patches differ from ffmpeg.sha256:" >&2
	(cd "$PATCHES" && sha256sum -- *.patch) | diff "$OUT/patches.sha256" - >&2 || :
	exit 1
fi
rm "$OUT/patches.sha256"
# Beanjar's own patches, in patches/: each listed in ffmpeg.sha256, and nothing else there
grep '  patches/' "$FF/ffmpeg.sha256" > "$OUT/local.sha256"
if ! (cd "$FF" && sha256sum -- patches/*.patch) | cmp -s - "$OUT/local.sha256"; then
	echo "sources.sh: the patches in patches/ differ from ffmpeg.sha256:" >&2
	(cd "$FF" && sha256sum -- patches/*.patch) | diff "$OUT/local.sha256" - >&2 || :
	exit 1
fi
rm "$OUT/local.sha256"
SRC=$OUT/src
rm -rf "$SRC"
mkdir -p "$SRC"
tar -C "$SRC" -xJf "$DL/$f"
S=$SRC/ffmpeg-$upstream
for p in "$PATCHES"/*.patch; do
	echo "applying $(basename "$p")"
	patch -d "$S" -p1 --batch --forward --quiet --fuzz=0 < "$p"
done
for p in "$FF"/patches/*.patch; do
	echo "applying patches/$(basename "$p")"
	patch -d "$S" -p1 --batch --forward --quiet --fuzz=0 < "$p"
done
# file dates clamped to the release tarball's, so equal sources give equal tarballs
SOURCE_DATE_EPOCH=$(stat -c %Y "$S/VERSION")
export SOURCE_DATE_EPOCH
tar -C "$SRC" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" \
	--clamp-mtime -cJf "$SOURCE_TARBALL" "ffmpeg-$upstream"

