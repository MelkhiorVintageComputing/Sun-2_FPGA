#!/bin/bash
#
# Regression check: did the boot PROM get as far as the monitor prompt?
#
# usage: check_console.sh [console.log]
#
# The Rev R PROM says, in order:
#
#   Self Test completed successfully.
#   Sun Workstation, Model Sun-2/120 or Sun-2/170, Sun-2 keyboard
#   ...
#   Auto-boot in progress...
#   No default boot devices
#   >
#
set -u

log=${1:-../build/sim/xsim/console.log}
rc=0

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

if grep -q 'Sun Workstation, Model Sun-2/120' "$log"; then
	echo "PASS: identified itself as a Sun-2/120"
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

exit $rc
