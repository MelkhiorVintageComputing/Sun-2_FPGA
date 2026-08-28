#!/bin/bash
#
# Compare a module's port list against an instantiation of it, by name.
#
#   tools/portcheck.sh <module.v> <module-name> <instantiating-file.sv>
#
# This exists because of a specific failure this project has already had, and
# will have again without it: boards/Wukong/wukong_top.sv named every port of
# `top machine (...)' except fb_video_en, so Vivado invented an undriven
# one-bit wire, tied it low, and the frame buffer's DISPEN was a constant zero
# in every bitstream ever produced.  Nothing caught it -- the testbench drives
# top_fpga directly, one level *below* the layer with the mistake in it, and
# the unit test forces video_en high.  Three independent checks all looked past
# one wire.
#
# The fix at the time was "compare the port list against the instantiation
# mechanically rather than by eye".  This is that comparison, and it takes a
# second.  Run it for every board top.
#
# It deliberately does NOT parse Verilog properly.  It extracts identifiers
# from the module header and the `.name(...)' forms from the instantiation and
# diffs the two sets, which is enough to catch an omission and cheap enough to
# run every build.  Ports inside `ifdef are reported as informational rather
# than missing, because whether they exist depends on the defines.
#
set -e -o pipefail

mod_file=${1:?usage: portcheck.sh <module-file> <module-name> <instantiating-file>}
mod_name=${2:?usage: portcheck.sh <module-file> <module-name> <instantiating-file>}
inst_file=${3:?usage: portcheck.sh <module-file> <module-name> <instantiating-file>}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Ports declared in the module header: everything from "module <name>(" to the
# closing ");" at the start of the body.  Block comments are stripped first --
# without that, prose inside /* ... */ is indistinguishable from a port name,
# and the first version of this script duly reported "the", "so" and "in" as
# missing ports on BOTH boards.  That the Wukong control failed identically is
# what said the script was wrong rather than the board.
strip_comments() {
	awk '
	    { line = $0 }
	    {
	        out = ""
	        while (length(line)) {
	            if (inblock) {
	                i = index(line, "*/")
	                if (i == 0) { line = ""; break }
	                line = substr(line, i + 2); inblock = 0
	            } else {
	                i = index(line, "/*")
	                j = index(line, "//")
	                if (j > 0 && (i == 0 || j < i)) { out = out substr(line, 1, j - 1); line = ""; break }
	                if (i == 0) { out = out line; line = ""; break }
	                out = out substr(line, 1, i - 1)
	                line = substr(line, i + 2); inblock = 1
	            }
	        }
	        print out
	    }
	' "$1"
}

strip_comments "$mod_file" | awk -v m="$mod_name" '
    $0 ~ "^[ \t]*module[ \t]+" m "[ \t]*[(#]" { inhdr = 1 }
    inhdr {
        if ($0 ~ /^[ \t]*\);/) { exit }
        if ($0 ~ /^[ \t]*`/) { next }          # ifdef/endif, not a port
        line = $0
        while (match(line, /[A-Za-z_][A-Za-z_0-9]*[ \t]*(,|$)/)) {
            tok = substr(line, RSTART, RLENGTH)
            gsub(/[ \t,]/, "", tok)
            if (tok != "" && tok !~ /^(input|output|inout|wire|reg|logic|parameter|int|module|signed|unsigned)$/)
                print tok
            line = substr(line, RSTART + RLENGTH)
        }
    }
' | sort -u > "$tmp/declared"

# Ports named in the instantiation: the ".name(" forms inside it.
strip_comments "$inst_file" | awk -v m="$mod_name" '
    $0 ~ "^[ \t]*" m "[ \t]+[A-Za-z_]" { ininst = 1 }
    ininst {
        line = $0
        while (match(line, /\.[A-Za-z_][A-Za-z_0-9]*[ \t]*\(/)) {
            tok = substr(line, RSTART + 1, RLENGTH - 2)
            gsub(/[ \t(]/, "", tok)
            print tok
            line = substr(line, RSTART + RLENGTH)
        }
        if (line ~ /\);/) ininst = 0
    }
' | sort -u > "$tmp/connected"

missing=$(comm -23 "$tmp/declared" "$tmp/connected")
extra=$(comm -13 "$tmp/declared" "$tmp/connected")

rc=0
if [ -n "$missing" ]; then
	echo "ERROR: $inst_file instantiates $mod_name without these ports:"
	echo "$missing" | sed 's/^/    /'
	echo "  An unnamed port becomes an undriven wire, not an error."
	rc=1
fi
if [ -n "$extra" ]; then
	echo "ERROR: $inst_file names ports $mod_name does not declare:"
	echo "$extra" | sed 's/^/    /'
	rc=1
fi

if [ $rc -eq 0 ]; then
	echo "portcheck: $mod_name <- $(basename "$inst_file"): $(wc -l < "$tmp/declared") ports, all connected"
fi
exit $rc
