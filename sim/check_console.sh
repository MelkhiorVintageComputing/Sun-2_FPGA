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
else
	echo "FAIL: no monitor prompt"
	rc=1
fi

# The VME machine has on-board Ethernet, and its boot PROM always tries to net
# boot: ieprobe() reports the chip present from the ID PROM alone.  So how far
# that gets is a real test of the 82586 and of DVMA, not a cosmetic one.
if [ "$machine" = vme ]; then
	if grep -q 'ie: cannot initialize' "$log"; then
		echo "FAIL: the Ethernet controller did not initialise"
		rc=1
	elif grep -q 'no file server' "$log"; then
		echo "PASS: Ethernet initialised, transmitted, and found no server"
	else
		echo "FAIL: the boot never reached the network"
		rc=1
	fi
fi

exit $rc
