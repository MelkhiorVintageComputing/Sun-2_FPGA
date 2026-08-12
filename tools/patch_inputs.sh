#!/bin/bash
#
# Build a patched copy of an immutable input under build/inputs/.
#
#   usage: patch_inputs.sh <name>
#
# Nothing under Inputs/ is ever edited in place -- it is third-party or
# reference material, and most of it consists of git submodules.  Where a change
# is genuinely necessary it lives as a patch in patches/<name>/ and is applied
# to a copy here, the same way the boot PROM is patched into build/rom/ rather
# than on top of Inputs/*.bin.
#
# Patches are meant to be temporary: when one is accepted upstream, drop it and
# move the submodule forward.  That has already happened once, for two
# declaration-order fixes Vivado insisted on and Verilator did not.
#
# The copy is rebuilt whenever a patch or a source file is newer than it, so an
# edit on either side is picked up without a clean.
#
set -e -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/.." && pwd)

name=${1:?usage: patch_inputs.sh <name>}
src="$top/Inputs/$name"
pat="$top/patches/$name"
out="$top/build/inputs/$name"

if [ ! -d "$src" ]; then
	echo "patch_inputs: $src does not exist -- did you run 'git submodule update --init'?" >&2
	exit 1
fi

if [ -e "$out/.stamp" ]; then
	newer=$(find "$src" "$pat" -type f -newer "$out/.stamp" -print -quit 2>/dev/null || true)
	[ -z "$newer" ] && exit 0
fi

rm -rf "$out"
mkdir -p "$(dirname "$out")"
cp -r "$src" "$out"
rm -rf "$out/.git"

if [ -d "$pat" ]; then
	for p in "$pat"/*.patch; do
		[ -e "$p" ] || continue
		echo "patch_inputs: $name < $(basename "$p")"
		patch -s -p1 -d "$out" <"$p"
	done
fi

touch "$out/.stamp"
