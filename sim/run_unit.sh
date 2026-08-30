#!/bin/bash
#
# Unit tests for the board layer.  Small, fast, and each one fails loudly.
#
#   ./run_unit.sh clkgen    measures what wukong_clkgen actually generates
#   ./run_unit.sh adapter   wb_to_mig_ui against wb_ram_model, randomised
#   ./run_unit.sh dvma      sun2_dvma: Wishbone master -> 68010 bus cycles
#   ./run_unit.sh bridge    sun2_wishbone_bridge against back-to-back (loop mode) cycles
#   ./run_unit.sh phy       phy_rtl8211_init + wb_mdio against a PHY model
#   ./run_unit.sh mbether   sun2_mb_ether against the boot PROM's own sequences
#   ./run_unit.sh mb3c400  sun2_mb_3c400, the other MultiBus Ethernet
#   ./run_unit.sh vtiming  video_timing against the published VESA numbers
#   ./run_unit.sh vmescsi  the Sun VME SCSI/RTC board's register file
#   ./run_unit.sh adv7513  the DECA's ADV7513 setup, against an I2C target
#   ./run_unit.sh xy450     sun2_xy450's registers, as the PROM and SunOS probe them
#   ./run_unit.sh scc       the Z8530's interrupts, driven as SunOS drives them
#   ./run_unit.sh trace     sun2_trace: the DECA's JTAG-readable capture buffer
#   ./run_unit.sh scanout   fb_scanout: DDR3 to pixels, a whole frame checked
#
set -e -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/.." && pwd)

: "${XILINX_VIVADO:=/opt/Xilinx/2025.2/Vivado}"
export PATH="$XILINX_VIVADO/bin:$PATH"
if [ -z "${LIBRARY_PATH:-}" ] && [ -e /usr/lib/x86_64-linux-gnu/crt1.o ]; then
	export LIBRARY_PATH=/usr/lib/x86_64-linux-gnu
fi

: "${BOARD:=v1}"

what=${1:-}
rundir="$top/build/sim/unit-$what"
mkdir -p "$rundir"
cd "$rundir"

case "$what" in
clkgen)
	# The MMCM primitives come from unisims, and they need glbl for GSR.
	xvlog --sv "$top/boards/Wukong/wukong_clkgen.sv" "$top/boards/Wukong/hdmi_clkgen.sv" \
		"$top/tb/tb_clkgen.sv" >/dev/null
	xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" >/dev/null
	for hz in ${CPU_HZ_LIST:-12500000 40000000}; do
		echo "---- CPU_CLK_HZ=$hz ----"
		xelab -debug off -L unisims_ver \
			-generic_top "CPU_CLK_HZ=$hz" \
			work.tb_clkgen work.glbl -s clkgen_sim >/dev/null
		xsim clkgen_sim -R | grep -E 'wukong_clkgen:|measured|PASS|FAIL|ok$|FAIL$|===|kHz'
	done
	;;
trace)
	# The DECA's logic analyser.  It is ordinary RTL precisely so that it can
	# be tested here rather than only on a board -- SignalTap cannot be, and
	# an instrument that reaches hardware unverified is how this project got
	# a console that doubled every byte.
	if xvlog --sv "$top/rtl/sun2-common/sun2_trace.v" "$top/tb/tb_sun2_trace.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_sun2_trace -s trace_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim trace_sim -R | grep -E '===|PASS|FAIL|ok:'
	;;

phy)
	"$top/tools/patch_inputs.sh" Wish82586
	W="$top/build/inputs/Wish82586/src"
	if xvlog --sv "$W/wb_mdio.sv" "$top/boards/Wukong/phy_rtl8211_init.sv" \
		"$top/tb/mdio_phy_model.sv" "$top/tb/tb_phy_init.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_phy_init -s phy_sim 2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim phy_sim -R | grep -E '===|PASS|FAIL|checks|PHY id|link '
	;;

mbether)
	# The whole MAC comes along, because the test that matters is whether the
	# chip finds its SCP through the board's page map.
	"$top/tools/patch_inputs.sh" Wish82586
	W="$top/build/inputs/Wish82586/src"
	if xvlog --sv \
		"$W/wish82586_pkg.sv" "$W/dp_ram.sv" "$W/sync_fifo.sv" \
		"$W/async_fifo.sv" "$W/crc32_eth.sv" "$W/mii_rx.sv" "$W/mii_tx.sv" \
		"$W/wb_arb.sv" "$W/wb_master.sv" "$W/ie_ru.sv" "$W/ie_cu.sv" \
		"$W/ie_core.sv" "$W/wish82586.sv" \
		"$top/rtl/sun2-multibus/sun2_mb_ether.sv" \
		"$top/tb/mii_peer.sv" "$top/tb/tb_mb_ether.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_mb_ether -s mbether_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim mbether_sim -R | grep -E '===|PASS|FAIL|checks|ISCP'
	;;

adv7513)
	if xvlog --sv \
		-i "$top/rtl/sun2-common" \
		"$top/boards/DECA/deca_adv7513_init.sv" \
		"$top/tb/i2c_slave_model.sv" "$top/tb/tb_adv7513_init.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_adv7513_init -s adv7513_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim adv7513_sim -R | grep -E '===|PASS|FAIL|first mismatch|never written'
	;;

vmescsi)
	if xvlog --sv -i "$top/rtl/sun2-common" -d SUN2_SIM \
		"$top/rtl/sun2-common/mm58167.v" \
		"$top/rtl/sun2-vme/sun2_vme_scsi.sv" \
		"$top/tb/tb_vme_scsi.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug typical --timescale 1ns/1ps work.tb_vme_scsi -s vmescsi_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim vmescsi_sim -R | grep -E '===|PASS|FAIL|checks|acknowledge'
	;;

vtiming)
	# No dependencies at all -- the raster and nothing else.
	if xvlog --sv \
		"$top/rtl/sun2-common/video_timing.sv" \
		"$top/tb/tb_video_timing.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_video_timing -s vtiming_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim vtiming_sim -R | grep -E '===|PASS|FAIL|raster'
	;;

mb3c400)
	"$top/tools/patch_inputs.sh" Wish82586
	W="$top/build/inputs/Wish82586/src"
	# The 3Com card.  Note the file list: the 3C400 masters nothing, so it
	# needs no wb_arb/wb_master and no wish82586_pkg -- only the four MII
	# pieces and dp_ram, which is the measurement behind "8 KiB, not 256".
	if xvlog --sv \
		"$W/dp_ram.sv" "$W/async_fifo.sv" "$W/crc32_eth.sv" \
		"$W/mii_rx.sv" "$W/mii_tx.sv" \
		-i "$top/rtl/sun2-common" \
		-d SUN2_SIM \
		"$top/rtl/sun2-multibus/sun2_mb_3c400.sv" \
		"$top/tb/mii_peer.sv" "$top/tb/tb_mb_3c400.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_mb_3c400 -s mb3c400_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim mb3c400_sim -R | grep -E '===|PASS|FAIL|checks|\.\.\.'
	;;

xy450)
	# The card, a memory behind its DVMA port, and a real disk image -- built
	# here rather than committed, so the test also checks that the tool and the
	# controller agree about byte order.
	"$top/tools/mkxydisk" -o xy0.img > /dev/null
	if xvlog --sv \
		"$top/rtl/sun2-multibus/sun2_xy450.sv" \
		"$top/tb/blk_file.sv" \
		"$top/tb/tb_xy450.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_xy450 -s xy450_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim xy450_sim -R -testplusarg blk_image=xy0.img \
		| grep -E '===|PASS|FAIL|checks|blk\]|DVMA:'
	;;

decaphy)
	# The DP83620 bring-up against a clause-22 PHY model.  Every register
	# value in the sequencer is transcribed from Inputs/doc/dp83620.pdf, and
	# each is wrong in a quiet way: a mismatched PHYIDR1 reports "no PHY" on
	# a good board, an uncleared RMII strap makes the MII deaf, and PHYSTS
	# bit 1 is named Speed10 and reads the opposite way round from instinct.
	"$top/tools/patch_inputs.sh" Wish82586
	if xvlog --sv \
		"$top/build/inputs/Wish82586/src/wb_mdio.sv" \
		"$top/boards/DECA/phy_dp83620_init.sv" \
		"$top/tb/mdio_phy_model.sv" \
		"$top/tb/tb_phy_dp83620.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_phy_dp83620 -s decaphy_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim decaphy_sim -R | grep -E '===|PASS|FAIL|ok:'
	;;

decaddr3)
	# The Wishbone-to-DDR3 adapter against a model of BrianHG's command port.
	# What is under test is a set of claims read out of someone else's
	# source -- mask polarity, strobe-not-level handshake, no write ack,
	# 128-bit line as four lanes -- each of which corrupts memory quietly
	# rather than failing loudly if it is wrong.  The model varies CMD_busy
	# and the read latency, because a handshake that only works when the far
	# end is always ready is not a handshake.
	if xvlog --sv \
		"$top/boards/DECA/deca_wb_to_ddr3.sv" \
		"$top/tb/tb_deca_wb_ddr3.sv" \
		-i "$top/rtl/sun2-common" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_deca_wb_ddr3 -s decaddr3_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim decaddr3_sim -R | grep -E '===|PASS|FAIL|ok:'
	;;

decaconsole)
	# The console bridge against a model of the Avalon slave it talks to.
	# The real IP ties its Atlantic port off under translate_off and cannot
	# be simulated, so this FSM reached a board with only a hand-trace of
	# the protocol behind it -- and produced doubled and skipped characters
	# that three readings of the source did not explain.  This is what
	# closed that gap.
	if xvlog --sv \
		"$top/boards/DECA/deca_uart_rx.sv" \
		"$top/boards/DECA/deca_uart_tx.sv" \
		"$top/boards/DECA/deca_jtag_console.sv" \
		"$top/tb/jtag_uart_model.sv" \
		"$top/tb/tb_deca_console.sv" \
		-d SUN2_SIM -i "$top/rtl/sun2-common" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_deca_console -s decacon_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim decacon_sim -R | grep -E '===|PASS|FAIL|ok:|sent:|got:'
	;;

decauart)
	# The two halves of the DECA's console bridge.  The console is the
	# instrument on that board -- no serial port, no display yet -- so a
	# garbled console and a dead machine look identical, and the bridge is
	# tested before it is trusted to report anything else.
	#
	# The transmitter is decoded by an independent counter rather than by
	# the receiver under test, so a shared misunderstanding of 8N1 cannot
	# pass; and the receiver is driven at deliberate rate offsets, because
	# the interesting question is margin, not whether 0x55 survives.
	if xvlog --sv \
		"$top/boards/DECA/deca_uart_rx.sv" \
		"$top/boards/DECA/deca_uart_tx.sv" \
		"$top/tb/tb_deca_uart.sv" \
		-i "$top/rtl/sun2-common" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_deca_uart -s decauart_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim decauart_sim -R | grep -E '===|PASS|FAIL|ok:'
	;;

mm58167)
	# The MM58167 time-of-day clock at MultiBus device page 7, driven over
	# the Sun-2's bus protocol -- cs_n tied low, rd_n/wr_n selecting, and
	# strobes several clocks wide, because a 68010 holds its data strobes
	# for the whole data portion of a cycle.  The two drivers disagree about
	# the rollover status bit in opposite directions: SunOS retries while it
	# is set, NetBSD's loop exits only when it *is* set, so a bit that never
	# sets hangs NetBSD at boot and one stuck at 1 makes SunOS print "TOD
	# chip has gone berserk".  Both sequences are replayed here.
	if xvlog "$top/rtl/sun2-common/mm58167.v" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xvlog --sv "$top/tb/tb_mm58167.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_mm58167 -s mm58167_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim mm58167_sim -R | grep -E '===|PASS|FAIL|--|took'
	;;

scc)
	# The console SCC, driven the way SunOS drives it rather than the way the
	# chip's own testbench does: the Sun-2 bus protocol (cs_n tied low,
	# rd_n/wr_n selecting), and every chip-wide register written through
	# channel B, which is where zsattach() leaves its pointer.  Interrupts are
	# the part no boot has ever exercised -- the PROM polls RR0 and never
	# touches WR9.
	"$top/tools/patch_inputs.sh" z8530_scc
	if xvlog --sv \
		"$top/build/inputs/z8530_scc/z8530_scc.sv" \
		"$top/tb/tb_scc.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_scc -s scc_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim scc_sim -R | grep -E '===|PASS|FAIL|ok:|RR2'
	;;

scanout)
	if xvlog --sv -i "$top/rtl/sun2-common" \
		"$top/rtl/sun2-common/fb_scanout.sv" "$top/tb/tb_fb_scanout.sv" \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_fb_scanout -s scanout_sim \
		2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim scanout_sim -R ${XSIMARGS:-} \
		| grep -E '===|PASS|FAIL|checked|beats read|line starts|white|wrote'
	;;

bridge)
	# The bridge alone, driven the way the 68010's loop mode drives it: one
	# memory cycle immediately after another with no fetch between them.  See
	# the header of tb/tb_wb_bridge.sv for why that is the only case that can
	# leave `done' set across a cycle boundary.
	if xvlog "$top/rtl/sun2-common/sun2_wishbone_bridge.v" 2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xvlog --sv "$top/tb/tb_wb_bridge.sv" 2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_wb_bridge -s bridge_sim 2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim bridge_sim -R | grep -E '===|PASS|FAIL|ok$|LOST|returned|timeout'
	;;

dvma)
	# Compiler output is filtered, not discarded: a syntax error here used to
	# make the whole target exit silently with nothing to show for it.
	# An `if' condition is exempt from set -e, so a clean compile does not
	# abort the script just because grep matched nothing.
	if xvlog "$top/rtl/sun2-vme/sun2_dvma.v" 2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xvlog --sv "$top/tb/tb_dvma.sv" 2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off work.tb_dvma -s dvma_sim 2>&1 | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim dvma_sim -R | grep -E '===|PASS|FAIL|checks'
	;;

adapter)
	xvlog --sv \
		"$top/boards/Wukong/wb_to_mig_ui.sv" \
		"$top/boards/Wukong/mig_arb.sv" \
		"$top/tb/mig_ui_model.sv" \
		"$top/tb/wb_ram_model.sv" \
		"$top/tb/tb_wb_to_mig_ui.sv" >/dev/null
	xelab -debug off work.tb_wb_to_mig_ui -s adapter_sim >/dev/null
	xsim adapter_sim -R | grep -E '===|mismatch|PASS|FAIL|\[mig_ui\]'
	;;
migddr3)
	# The adapter against the real controller and Micron's model.  This is the
	# join the other two tests do not cover: tb_wb_to_mig_ui uses a model of
	# MIG's interface, and tb_wukong's ddr3 mode only gets as far as showing
	# MIG calibrate -- the boot PROM does not touch main memory until L_M_MAP,
	# far beyond what is simulable with a full DDR3 model.
	mig="$top/build/ip/$BOARD/sun2_mig/sun2_mig/user_design/rtl"
	ex="$top/build/ip/$BOARD/sun2_mig/sun2_mig/example_design/sim"
	if [ ! -d "$mig" ]; then
		echo "MIG has not been generated; run: make -C syn ip" >&2
		exit 1
	fi
	mapfile -t mig_src < <(find "$mig" -name '*.v' -o -name '*.sv' \
	                       | grep -v '/sun2_mig_mig\.v$' | sort)
	xvlog --sv -i "$ex" -i "$mig" \
		"$top/boards/Wukong/wukong_clkgen.sv" \
		"$top/boards/Wukong/wb_to_mig_ui.sv" \
		"$top/boards/Wukong/mig_arb.sv" \
		"${mig_src[@]}" \
		"$ex/ddr3_model.sv" \
		"$top/tb/tb_mig_ddr3.sv" >/dev/null
	xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" >/dev/null
	xelab -debug off -L unisims_ver -L unisim -L secureip \
		work.tb_mig_ddr3 work.glbl -s migddr3_sim >/dev/null
	xsim migddr3_sim -R ${XSIMARGS:-} | grep -vE 'ddr3\.(cmd_task|data_task|reset|dqs_)' \
		| grep -E '===|calibration|written and read|MISMATCH|PASS|FAIL|latency|^MIG read|^Wishbone read|^=>|scan-out'
	;;
*)
	echo "usage: $0 {clkgen|adapter|migddr3}" >&2
	exit 1
	;;
esac
