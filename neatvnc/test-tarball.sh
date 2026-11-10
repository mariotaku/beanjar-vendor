#!/bin/sh
# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Check a neatvnc tarball from build.sh where it is unpacked, not at its prefix: build a small
# program against it with the plain pkg-config (its .pc files locate the tree by ${pcfiledir}),
# and run it, which loads libneatvnc and (by libneatvnc's RUNPATH) libaml from the unpacked tree.
#
#   neatvnc/test-tarball.sh TARBALL [DIR]     default DIR: a new directory next to TARBALL
#
# Needs xz-utils, gcc, pkgconf and the development packages that neatvnc.pc names (build.sh's
# build dependencies); to run the program, the libraries in BUILDINFO's Depends.
set -eu
die() { echo "test-tarball.sh: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: test-tarball.sh TARBALL [DIR]"
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
DIR=${2:-${tarball%.tar.xz}-test}
rm -rf "$DIR"
mkdir -p "$DIR/root"
DIR=$(cd "$DIR" && pwd)
tar -C "$DIR/root" -xJf "$tarball"
version=$(sed -n 's/^Version: //p' "$DIR/root/BUILDINFO")
upstream=${version%%+beanjar*}

unset PKG_CONFIG_SYSROOT_DIR
export PKG_CONFIG_PATH="$DIR/root/lib/pkgconfig"
[ "$(pkg-config --modversion neatvnc)" = "$upstream" ] ||
	die "neatvnc.pc is $(pkg-config --modversion neatvnc), not $upstream"
for m in neatvnc aml1; do
	for v in libdir:lib includedir:include; do
		d=$(pkg-config --variable="${v%:*}" "$m")
		[ "$(realpath "$d")" = "$DIR/root/${v#*:}" ] || die "$m.pc: ${v%:*} $d is not in $DIR/root"
	done
done

cat > "$DIR/t.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <aml.h>
#include <neatvnc.h>

int main(int argc, char *argv[])
{
	struct aml *aml = aml_new();
	if (!aml)
		return 1;
	aml_set_default(aml);
	struct nvnc *server = nvnc_new();
	if (!server)
		return 1;
	if (nvnc_listen_tcp(server, "127.0.0.1", 0, NVNC_STREAM_NORMAL) < 0)
		return 1;
	nvnc_del(server);
	aml_unref(aml);
	printf("neatvnc %s\n", nvnc_version);
	return argc > 1 && !strstr(nvnc_version, argv[1]);
}
EOF
# shellcheck disable=SC2046 # pkg-config's output is a list of options
gcc -o "$DIR/t" "$DIR/t.c" $(pkg-config --cflags --libs neatvnc aml1) -Wl,-rpath,"$DIR/root/lib"
"$DIR/t" "$upstream"
! ldd "$DIR/t" | grep -E 'lib(neatvnc|aml)' | grep -qv "$DIR/root/lib/" ||
	die "the program did not load the libraries from $DIR/root/lib: $(ldd "$DIR/t")"
echo "$tarball: built and ran a program against it, unpacked in $DIR/root"
