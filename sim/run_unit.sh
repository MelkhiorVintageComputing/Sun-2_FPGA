#!/bin/bash
#
# Unit tests for the board layer.  Small, fast, and each one fails loudly.
#
#   ./run_unit.sh clkgen    measures what wukong_clkgen actually generates
#   ./run_unit.sh adapter   wb_to_mig_ui against wb_ram_model, randomised
#   ./run_unit.sh dvma      sun2_dvma: Wishbone master -> 68010 bus cycles
#   ./run_unit.sh phy       phy_rtl8211_init + wb_mdio against a PHY model
#   ./run_unit.sh mbether   sun2_mb_ether against the boot PROM's own sequences
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
phy)
	"$top/tools/patch_inputs.sh" Wish82586
	W="$top/build/inputs/Wish82586/src"
	if xvlog --sv "$W/wb_mdio.sv" "$top/boards/Wukong/phy_rtl8211_init.sv" \
		"$top/tb/mdio_phy_model.sv" "$top/tb/tb_phy_init.sv" \
		| grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_phy_init -s phy_sim | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
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
		| grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_mb_ether -s mbether_sim \
		| grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim mbether_sim -R | grep -E '===|PASS|FAIL|checks|ISCP'
	;;

scanout)
	if xvlog --sv "$top/boards/Wukong/fb_scanout.sv" "$top/tb/tb_fb_scanout.sv" \
		| grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off --timescale 1ns/1ps work.tb_fb_scanout -s scanout_sim \
		| grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	xsim scanout_sim -R | grep -E '===|PASS|FAIL|checked|beats read|line starts'
	;;

dvma)
	# Compiler output is filtered, not discarded: a syntax error here used to
	# make the whole target exit silently with nothing to show for it.
	# An `if' condition is exempt from set -e, so a clean compile does not
	# abort the script just because grep matched nothing.
	if xvlog "$top/rtl/sun2-vme/sun2_dvma.v" | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xvlog --sv "$top/tb/tb_dvma.sv" | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
	if xelab -debug off work.tb_dvma -s dvma_sim | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi
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
