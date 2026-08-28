#!/bin/bash
# Run any tool from the Altera (Quartus Prime) installation, putting it on the
# PATH first.
#
#     syn/altera.sh quartus_sh -t quartus.tcl ...
#     syn/altera.sh quartus_map sun2_deca
#
# The twin of syn/vivado.sh, and the same shape as the wrapper the RD68011
# project uses -- this is a copy rather than a reference, because Inputs/ is
# immutable and a build that reached into a submodule for its own tooling would
# break the moment that submodule moved.
#
# Quartus needs no settings script: its bin/ is self-contained, so this is a
# PATH prepend and nothing else.  It is the one place that knows where the
# installation is; point QUARTUS_ROOTDIR at another one to use it instead.
#
# QUARTUS_ROOTDIR is exported rather than merely used, and that is not
# redundant: Quartus itself reads it to find its device database, so a tool
# invoked by absolute path with a stale value set would silently fit against
# the wrong device data.

set -e

: "${QUARTUS_ROOTDIR:=/opt/Altera/quartus}"

if [ $# -lt 1 ]; then
    echo "usage: $0 <tool> [args...]" >&2
    exit 2
fi

tool=$1
shift

if ! command -v "$tool" >/dev/null 2>&1; then
    if [ ! -x "$QUARTUS_ROOTDIR/bin/$tool" ]; then
        echo "$tool is not on PATH and $QUARTUS_ROOTDIR/bin/$tool does not exist;" >&2
        echo "set QUARTUS_ROOTDIR to your Quartus installation" >&2
        exit 1
    fi
    PATH="$QUARTUS_ROOTDIR/bin:$PATH"
fi

export QUARTUS_ROOTDIR PATH

exec "$tool" "$@"
