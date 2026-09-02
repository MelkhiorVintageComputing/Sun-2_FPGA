#!/bin/bash
#
# Give a disk-booted Sun-2 its network identity, over the JTAG console.
#
#     tools/deca_netconfig.sh                    # the defaults below
#     tools/deca_netconfig.sh 192.168.0.31 192.168.0.123 sun2_f_m
#
# The machine has no other way in.  A disk image comes up as whatever the
# image's /etc/rc.boot says -- `sun2', with an empty /etc/hosts -- so it cannot
# name the NFS server and the server cannot name it.  This types the three
# things that fix that and nothing else:
#
#    /etc/hosts             the server and this machine
#    /etc/hostname.ie0      the name, which is also what ifconfig is given
#    /etc/hostname.ec0      ...and the same for the 3Com, see below
#    /etc/rc.boot:17        made to *read* that file instead of hardcoding
#
# Written as a script because getting it right by hand costs four or five
# console round trips and every one of the traps below is silent.
#
# ---- Which interface ------------------------------------------------------
#
# Both files are written, because the interface name depends on the *card* and
# a disk image should not care which machine it is booted on:
#
#    ie0   the Sun MultiBus Ethernet (SUN2_MB_ETHER).  256 KiB of on-card RAM
#          is 256 M9K, so it fits a Wukong and cannot fit a DECA at all.
#    ec0   the 3Com 3C400 (SUN2_MB_3C400), which is the DECA's only option.
#    le0   nothing here builds one; rc.boot tries it anyway and it is harmless.
#
# rc.boot ifconfigs all three unconditionally and the ones that do not exist
# fail harmlessly, so the only thing that has to be right is the *name*, and
# rc.boot takes that from hostname.ie0 whichever card is fitted.
#
# **A build with no Ethernet card is not an error here.**  `ifconfig -a' says
# `no such interface' and the configuration sits there correctly until a
# bitstream with a card is loaded -- MB_SCSI=1 alone has no network.
#
# ---- Four traps, each of which has cost time -----------------------------
#
#  1. **Root's shell is csh.**  `2>&1' is `Ambiguous output redirect' and `$?'
#     is `Variable syntax.'  Everything below is handed to `sh -c' in single
#     quotes for that reason.
#  2. **zsa_rxint raises its soft interrupt every 20 characters**
#     (zs_async.c:670-676), so a short line produces *no echo at all* and looks
#     exactly like dead input.  Each line here is followed by newlines until
#     the threshold is crossed.
#  3. **The image's grep has no `\|' alternation.**  A pattern like
#     `grep "a\|b" file' matches nothing and reports no error, which reads as
#     "the file does not contain either" -- it is not a 4.2BSD grep feature.
#     Use separate greps or egrep.
#  4. **/etc/rc.boot hardcodes the hostname** in the images this project uses
#     (`hostname=sun2', line 17, and the file is dated long after /etc/rc), so
#     writing /etc/hostname.ie0 alone changes nothing.  The original is kept as
#     /etc/rc.boot.orig.
#
set -e -o pipefail

SERVER_IP=${1:-192.168.0.31}
SERVER=${SERVER_NAME:-x11spl}
MY_IP=${2:-192.168.0.123}
MY_NAME=${3:-sun2_f_m}
CONSOLE=${CONSOLE:-/tmp/deca-console}

test -w "$CONSOLE" || { echo "no console at $CONSOLE -- is deca_console_pty.sh running?" >&2; exit 1; }

# One line, then enough newlines to cross the 20-character soft-interrupt
# threshold.  Padding with spaces instead would make them part of the argument,
# which is how a `root' login once became `root            '.
say() {
    printf '%s\n' "$1" > "$CONSOLE"
    printf '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n' > "$CONSOLE"
    sleep "${2:-12}"
}

echo "configuring $MY_NAME ($MY_IP), server $SERVER ($SERVER_IP)" >&2

say "sh -c 'echo \"127.0.0.1 localhost loghost\" > /etc/hosts; echo \"$SERVER_IP $SERVER\" >> /etc/hosts; echo \"$MY_IP $MY_NAME sun2\" >> /etc/hosts; echo $MY_NAME > /etc/hostname.ie0; echo $MY_NAME > /etc/hostname.ec0; echo WROTE-OK'"

# Only patch rc.boot once: a second pass would rewrite the .orig with the
# already-patched file and lose the original.
say "sh -c 'test -f /etc/rc.boot.orig || cp /etc/rc.boot /etc/rc.boot.orig; sed \"s|^hostname=sun2\\\$|hostname=\\\`cat /etc/hostname.ie0\\\`|\" /etc/rc.boot.orig > /etc/rc.boot; grep -n hostname= /etc/rc.boot; echo PATCH-OK'"

say "sh -c 'cat /etc/hosts; cat /etc/hostname.ie0; echo NETCONFIG-DONE'"

echo "done -- reboot for rc.boot to apply it, and note that a build with no" >&2
echo "Ethernet card reports 'no such interface' until one is fitted." >&2
