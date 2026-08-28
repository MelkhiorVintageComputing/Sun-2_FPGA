#!/bin/bash
#
# Present the DECA's JTAG console as an ordinary serial device.
#
#     tools/deca_console_pty.sh &          creates /tmp/deca-console
#     minicom -D /tmp/deca-console         ... and talks to it
#
# The JTAG UART is not a character device: juart-terminal speaks the JTAG
# Atlantic protocol straight to the cable, so there is no /dev/tty* to open and
# minicom cannot see it.  socat wraps that program in a pseudo-terminal and
# links it where a terminal emulator expects one.
#
# Baud, bits and flow control are all meaningless on this link -- the bytes
# never touch a UART between here and the FPGA -- so minicom's line settings are
# ignored.  The 9600 8N1 framing exists only *inside* the FPGA, between the
# SCC and the console bridge.
#
# Note this holds the JTAG chain: while it runs, quartus_pgm and quartus_stp
# cannot reach the board.  Stop it before programming or before reading the
# probes with tools/deca_reset.tcl.
#
# The alternative needs no software at all: GPIO0_D[0] = PIN_W18 carries the
# machine's raw 9600-baud transmit line, and PIN_W18 is what the DECA's own
# template calls UART_TXD on P8 pin 3.  A 3.3 V USB-TTL cable there gives a real
# /dev/ttyUSB* with no JTAG involvement -- and, unlike this, leaves the chain
# free for programming and probing at the same time.
#
# ----------------------------------------------------------------- CAVEAT
#
# Output works; **input is corrupted**, and the fault is in the gateware, not
# here.  Typing ABCDEFGHIJ at the machine arrives as @CBEDGFIH -- adjacent bytes
# swapped in pairs, with bit 0 cleared on the first.  Everything the machine
# prints is byte-perfect, so this is usable for watching a boot and not yet for
# driving a shell.
#
# The same signature turned up in test/deca_console's loopback and was written
# off there as an artifact of one FSM running full duplex through itself.  It is
# not: it reproduces here with no loopback anywhere, so it is a real defect in
# deca_jtag_console's host-to-machine path.  tb_deca_console's loopback case
# passes on the same RTL, so the modelled JTAG UART does not reproduce it --
# the same limit that hid the console's clock fault earlier, and the reason the
# event counters exist.  Whether ev_rd_valid matches the bytes typed says at
# once if the FSM reads the FIFO more often than it transmits.

set -e -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/.." && pwd)
link=${1:-/tmp/deca-console}

: "${QUARTUS_ROOTDIR:=/opt/Altera/quartus}"
export QUARTUS_ROOTDIR

echo "deca_console_pty: linking $link -> juart-terminal" >&2
echo "deca_console_pty: minicom -D $link      (line settings are ignored)" >&2
echo "deca_console_pty: this holds the JTAG chain; stop it before programming" >&2

exec socat -d \
    "EXEC:'$top/syn/altera.sh juart-terminal',pty,raw,echo=0" \
    "PTY,link=$link,raw,echo=0,mode=666"
