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
# here.  Everything the machine prints is byte-perfect, so this is usable for
# watching a boot and not yet for driving a shell.
#
# What it is has been measured rather than guessed, and the measurement moved
# the search a long way:
#
#   * It is **not SunOS**.  It reproduces at the monitor's own `>' prompt,
#     where input is polled by the PROM and no zs driver, silo or soft
#     interrupt exists -- typing abcdefghij there echoes `cbedgfiij.
#
#   * **The byte counts are exact at every stage.**  Typing ten bytes and
#     differencing the event counters through tools/deca_reset.tcl gives
#     rd +10, tx +10 host->machine and rx +10, wr +10 machine->host.  Nothing
#     is read twice, nothing is dropped, in either direction.  So it is a
#     data-value fault, not a flow-control or FIFO-ordering one -- which is
#     what "does ev_rd_valid match the bytes typed" was put there to ask, and
#     the answer rules out the whole class it was aimed at.
#
#   * **The signature depends on the typing rate**, and that is the real clue.
#     Sent back to back, abcdefghij returns `cbedgfiij; sent with 400 ms
#     between bytes -- one byte in flight, forty character times of idle --
#     the same input returns `bbddffhhj.  Written as indices into what was
#     sent, the output is emitted in pairs: (n+1, n) when the bytes are close
#     together and (n, n) when they are far apart.  One mechanism gives both:
#     a two-entry buffer emitted newest-first, which swaps when the second
#     entry has been refilled and repeats when it has not.
#
#   * Byte 0 is separate and unexplained: it always comes back with bit 0
#     cleared ('a' -> 0x60, 'A' -> 0x40) and only the first byte after a
#     terminal attaches does it.
#
# tb_deca_console's loopback case passes on the same RTL, so the modelled JTAG
# UART does not reproduce any of this -- the same limit that hid the console's
# clock fault earlier.  The next place to look is the two-entry buffer the pair
# signature names, on the host->machine side: deca_jtag_console's tx_data latch
# against deca_uart_tx's sampling of `data', which is the only two-deep thing
# between the Avalon read and the wire.
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
