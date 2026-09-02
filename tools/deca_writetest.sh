#!/bin/bash
#
# Does this machine write to its disk correctly?
#
#     tools/deca_writetest.sh copy sd      # phase 1: copy and halt
#     tools/deca_writetest.sh check sd     # phase 2: re-read from the medium
#
# Copies two files whose checksums are already known, verifies them, halts, and
# after a reboot checks them again.  The reboot is the point: a `sum' taken
# straight after `cp' reads the buffer cache and so cannot see what reached the
# medium, which is how a write fault hides.  Only the second phase is evidence.
#
# The files are large on purpose.  Measured on a MultiBus SCSI machine, small
# copies survive and large ones do not:
#
#     /wt1 <- sum   3 blocks    54006 -> 54006    ok
#     /wt2 <- od   10 blocks    09808 -> 09808    ok
#     /wt4 <- csh 104 blocks    34435 -> 51819    corrupt
#     /wt5 <- adb 104 blocks    05453 -> 29364    corrupt
#     /wt6 <- csh 104 blocks    34435 -> 53822    corrupt
#
# ...and each corrupt result differs from the others, so it is a race rather
# than a transformation.
#
# **Phase 2 must boot single-user** (`b <dev>(0,0,0)vmunix -s' at the monitor),
# because a multi-user boot runs rc, which rebuilds the link-editor cache and
# clears /tmp -- more writes, on the filesystem being measured.
#
# The two phases are separate commands because a reboot sits between them and
# the monitor needs a carriage return, not a line feed: see deca_netconfig.sh
# for the rest of the console traps (csh, the 20-character threshold).
#
set -e -o pipefail

MODE=${1:?usage: deca_writetest.sh copy|check [dev]}
DEV=${2:-sd}
CONSOLE=${CONSOLE:-/tmp/deca-console}

test -w "$CONSOLE" || { echo "no console at $CONSOLE" >&2; exit 1; }

say() {
    printf '%s\n' "$1" > "$CONSOLE"
    printf '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n' > "$CONSOLE"
    sleep "${2:-15}"
}

case "$MODE" in
copy)
    # Sources first, so the comparison is against this machine's own reading of
    # them rather than against a number remembered from another run.
    say 'echo WT-SOURCES; sum /usr/bin/adb /usr/bin/csh /usr/bin/od /usr/bin/sum' 25
    say 'cp /usr/bin/adb /wa; cp /usr/bin/csh /wb; cp /usr/bin/od /wc; cp /usr/bin/sum /wd; sync; sync; echo WT-COPIED' 60
    say 'echo WT-CACHED; sum /wa /wb /wc /wd' 30
    say 'sync; /usr/etc/halt' 30
    echo "phase 1 done -- machine halted at the monitor." >&2
    echo "now: printf 'b $DEV(0,0,0)vmunix -s\\r' > $CONSOLE   then run: $0 check" >&2
    ;;
check)
    say 'echo WT-MEDIUM; sum /wa /wb /wc /wd' 30
    echo "phase 2 done -- compare WT-MEDIUM against WT-SOURCES." >&2
    ;;
*)
    echo "usage: deca_writetest.sh copy|check [dev]" >&2; exit 1 ;;
esac
