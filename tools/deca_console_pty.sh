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
# ------------------------------------------------------------------- STATUS
#
# Both directions work.  A 48-character string echoes back byte for byte and
# typed commands reach the shell verbatim.
#
# It was not always so, and the fix is worth knowing because it constrains any
# future change to this block: **the JTAG UART's user clock must be
# comfortably faster than TCK**, which quartus_sta puts at 10 MHz.  The bridge
# runs on MAX10_CLK1_50 -- 5x TCK -- and moving it back onto a PLL output near
# TCK brings the fault back.  At 4.915 MHz, below TCK, the host read every byte
# twice and out of order; at 12.5 and 16.667 MHz, 1.25x and 1.67x, output was
# clean and input came back with adjacent bytes swapped in pairs.
#
# ------------------------------------------------------------------ minicom
#
# Line settings are meaningless on this link -- the bytes never touch a UART
# between here and the FPGA -- so minicom's baud, bits and flow control are
# ignored.  The 9600 8N1 framing exists only *inside* the FPGA, between the SCC
# and the console bridge.  Turn hardware flow control OFF; with it on, minicom
# waits for a CTS that no pseudo-terminal will ever assert.
#
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
