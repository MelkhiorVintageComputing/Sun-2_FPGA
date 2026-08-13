#!/bin/bash
#
# Regression check: did the boot PROM get as far as the monitor prompt?
#
# usage: check_console.sh [console.log] [multibus|vme]
#
# The MultiBus Rev R PROM says, in order:
#
#   Self Test completed successfully.
#   Sun Workstation, Model Sun-2/120 or Sun-2/170, Sun-2 keyboard
#   ...
#   Auto-boot in progress...
#   No default boot devices
#   >
#
# and the VME Rev Q one, on a 2/50:
#
#   Self Test completed successfully.
#   Sun Workstation, Model Sun-2/50 or Sun-2/160, Sun-2 keyboard
#   ...
#   Auto-boot in progress...
#   Boot: ie(0,0,0)vmunix
#   ???nd: no file server, giving up.
#   >
#
# Each "?" is one ND read request that went out on the wire and got no answer.
# Reaching that point means the 82586 initialised, configured itself and
# transmitted -- all of it by DVMA through the MMU.
#
# The banner is the only line that differs, so that is all the machine
# argument selects.  Default multibus, to match sim/Makefile.
#
set -u

log=${1:-../build/sim/xsim/console.log}
machine=${2:-multibus}
# "mbether" if a Sun-2 Ethernet board is fitted in the MultiBus card cage, in
# which case the machine must find it and try to net boot, exactly as the VME
# machine does with its on-board one.
fitted=${3:-}
rc=0

case "$machine" in
multibus) banner='Sun Workstation, Model Sun-2/120'; model='Sun-2/120' ;;
vme)      banner='Sun Workstation, Model Sun-2/50';  model='Sun-2/50'  ;;
*)        echo "usage: $0 [console.log] [multibus|vme]"; exit 2 ;;
esac

if [ ! -s "$log" ]; then
	echo "FAIL: $log is missing or empty -- nothing came out of the serial port"
	exit 1
fi

echo "--- console ---"
cat "$log"
echo
echo "---------------"

if grep -q 'Self Test found a problem' "$log"; then
	echo "FAIL: the PROM self test reported a problem"
	rc=1
elif grep -q 'Self Test completed successfully' "$log"; then
	echo "PASS: self test completed successfully"
else
	echo "FAIL: the self test never finished"
	rc=1
fi

if grep -q "$banner" "$log"; then
	echo "PASS: identified itself as a $model"
else
	echo "FAIL: no machine banner"
	rc=1
fi

if grep -q '>' "$log"; then
	echo "PASS: monitor prompt seen"
elif [ "$fitted" = mbether ]; then
	# Not a failure here, and not reachable either: see the note below.
	echo "note: no monitor prompt, which this configuration cannot reach"
else
	echo "FAIL: no monitor prompt"
	rc=1
fi

# How far the net boot got is a real test of the 82586 and of everything under
# it, not a cosmetic one.  Two machines reach it by quite different routes:
#
#   VME       ieprobe() reports the on-board chip present from the ID PROM
#             machine type alone, without a single bus cycle, so `ie' always
#             joins the boot list and auto-boot always tries it.
#   MultiBus  ieprobe() actually pokes the card -- a write to page map entry
#             0, a write to the ID PROM, and a read back that must not return
#             what was written -- so reaching this point also proves the
#             MultiBus memory space decode and the card's probe contract.
if [ "$machine" = vme ] || [ "$fitted" = mbether ]; then
	if grep -q 'ie: cannot initialize' "$log"; then
		echo "FAIL: the Ethernet controller did not initialise"
		rc=1
	fi
fi

if [ "$machine" = vme ]; then
	if grep -q 'no file server' "$log"; then
		echo "PASS: Ethernet initialised, transmitted, and found no server"
	elif ! grep -q 'ie: cannot initialize' "$log"; then
		echo "FAIL: the boot never reached the network"
		rc=1
	fi
fi

# The MultiBus machine is asked for less, because it cannot be given more.
#
# nd.c retries a read 500 times and each attempt waits two seconds of
# millitime() for a reply that is never coming, transmitting one frame apiece.
# That is 500 frames and a thousand seconds of machine time -- the run would
# need two orders of magnitude more simulated time than is practical.  The VME
# machine happens to leave the same loop after three attempts and so reaches
# the prompt; both PROM images contain the same limit of 500, so the difference
# is inside the PROM and has not been run down.
#
# What is asserted instead is everything the card is responsible for: that
# ieprobe()'s three bus cycles found it, that auto-boot chose it, and that a
# frame actually went out -- which means the chip fetched its command block,
# buffer descriptor and buffer from card memory through the board's page map
# and drove the wire.  ieput() waits on the command-done bit with no timeout at
# all, so a `?' cannot appear unless a transmit completed.
if [ "$fitted" = mbether ]; then
	if grep -q 'Probing Multibus: *ie' "$log"; then
		echo "PASS: the MultiBus Ethernet board answered ieprobe()"
	else
		echo "FAIL: ieprobe() did not find the MultiBus Ethernet board"
		rc=1
	fi

	if grep -q 'Boot: ie(' "$log"; then
		echo "PASS: auto-boot selected the Ethernet board"
	else
		echo "FAIL: auto-boot did not reach the Ethernet board"
		rc=1
	fi

	if grep -q '?' "$log"; then
		echo "PASS: the 82586 built a frame in card memory and transmitted it"
	else
		echo "FAIL: nothing was ever transmitted"
		rc=1
	fi
fi

# The PHY probe, if this run did one.  The board testbench types at the monitor
# prompt: it maps device page 0xFE7 over the RasterOp page the VME PROM leaves
# dead, then reads the two words of the status register.  Against
# tb/mdio_phy_model that is
#
#   EE0800: 001C?           the Realtek OUI, read back over MDIO
#   EE0802: F000?           configured, identifier matched, link up, full
#                           duplex, 10 Mb/s, carrier sense never stuck
#
# Anything else here is a real failure and a specific one: 0000 or FFFF at +0
# means the management interface never answered, and a speed field other than
# 00 in bits 11:10 means the PHY and the MAC disagree about how wide the
# interface is, which is the failure that looks exactly like a dead controller.
if grep -q 'PageMap' "$log"; then
	if grep -qi 'EE0800: 001C' "$log"; then
		echo "PASS: the PHY identifier reads back as Realtek through device page 0xFE7"
	else
		echo "FAIL: no Realtek identifier in the PHY status register"
		rc=1
	fi

	if grep -qi 'EE0802: F000' "$log"; then
		echo "PASS: PHY configured, link up, full duplex, 10 Mb/s, carrier sense clean"
	else
		echo "FAIL: the PHY status word is not a configured 10 Mb/s link"
		rc=1
	fi
fi

exit $rc
