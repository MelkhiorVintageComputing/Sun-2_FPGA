#!/bin/bash
#
# Board-level simulation: the Sun-2 as it will be on a QMTech Wukong V1.
#
# Environment:
#   BOARD_MEM       fast (default) | ddr3
#                     fast - behavioural Wishbone RAM, boots to the prompt
#                     ddr3 - real MIG plus Micron's DDR3 model
#   XILINX_VIVADO   Vivado install (default /opt/Xilinx/2025.2/Vivado)
#   SUN2_DEFINES    extra `define's, e.g. "MEM_PAGES=512 ROM_FASTBOOT"
#   SUN2_BAUD       console decode rate (default 9600)
#   SUN2_CPU_HZ     CPU clock (default 12500000)
#
# Arguments are passed through to xsim, so plusargs work.
#
set -e -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/.." && pwd)

: "${XILINX_VIVADO:=/opt/Xilinx/2025.2/Vivado}"
: "${BOARD_MEM:=fast}"
: "${SUN2_CPU_HZ:=12500000}"

if [ ! -x "$XILINX_VIVADO/bin/xvlog" ]; then
	echo "xsim not found under $XILINX_VIVADO -- set XILINX_VIVADO" >&2
	exit 1
fi
export PATH="$XILINX_VIVADO/bin:$PATH"

# xelab links the snapshot with Vivado's bundled gcc, which cannot find crt1.o
# on a Debian multiarch system by itself.
if [ -z "${LIBRARY_PATH:-}" ] && [ -e /usr/lib/x86_64-linux-gnu/crt1.o ]; then
	export LIBRARY_PATH=/usr/lib/x86_64-linux-gnu
fi

rundir="$top/build/sim/board-$BOARD_MEM"
mkdir -p "$rundir"

make -s -C "$top/tools"

defargs=()
for d in ${SUN2_DEFINES:-}; do
	defargs+=(-d "$d")
done

mig="$top/build/ip/sun2_mig/sun2_mig/user_design/rtl"
migsim="$XILINX_VIVADO/data/ip/xilinx/mig_7series_v4_2/data/dlib/7series/ddr3_sdram/sim"

if [ "$BOARD_MEM" = "ddr3" ]; then
	if [ ! -d "$mig" ]; then
		echo "MIG has not been generated yet: run" >&2
		echo "    vivado -mode batch -source syn/generate_ip.tcl" >&2
		exit 1
	fi
	defargs+=(-d "BOARD_MEM_DDR3")
else
	defargs+=(-d "BOARD_MEM_FAST")
fi

# The MMCME2 simulation model runs its VCO at 1 GHz, which costs more events
# than the whole rest of the machine: measured, about 6x slower overall, so a
# boot to the monitor prompt takes ~4 hours instead of ~40 minutes.  For the
# fast configuration generate the same frequencies behaviourally instead;
# tb_clkgen is what proves the real MMCMs produce them.  BOARD_CLKGEN=real
# overrides, and the ddr3 configuration always uses the real ones.
: "${BOARD_CLKGEN:=$([ "$BOARD_MEM" = fast ] && echo behavioural || echo real)}"
if [ "$BOARD_CLKGEN" = "behavioural" ]; then
	defargs+=(-d "CLKGEN_BEHAVIOURAL")
fi
echo "== BOARD_MEM=$BOARD_MEM, clock generation: $BOARD_CLKGEN =="

cd "$rundir"

echo "== compiling the Suska MC68010 (VHDL) =="
xvhdl -2008 --work sun2 \
	"$top/Inputs/Suska_Configware/68K10/wf68k10_pkg.vhd" \
	"$top/Inputs/Suska_Configware/68K10/wf68k10_address_registers.vhd" \
	"$top/Inputs/Suska_Configware/68K10/wf68k10_alu.vhd" \
	"$top/Inputs/Suska_Configware/68K10/wf68k10_bus_interface.vhd" \
	"$top/Inputs/Suska_Configware/68K10/wf68k10_control.vhd" \
	"$top/Inputs/Suska_Configware/68K10/wf68k10_data_registers.vhd" \
	"$top/Inputs/Suska_Configware/68K10/wf68k10_exception_handler.vhd" \
	"$top/Inputs/Suska_Configware/68K10/wf68k10_opcode_decoder.vhd" \
	"$top/Inputs/Suska_Configware/68K10/wf68k10_top.vhd"

echo "== compiling the Sun-2 gateware (Verilog) =="
xvlog --work sun2 "${defargs[@]}" \
	-i "$top/rtl" -i "$top/build/rom" \
	"$top/rtl/top_fpga.v" \
	"$top/rtl/sun2_fpga.v" \
	"$top/rtl/sun2_mmu.v" \
	"$top/rtl/ctx_reg.v" \
	"$top/rtl/pmap.v" \
	"$top/rtl/smap.v" \
	"$top/rtl/sram_sync.v" \
	"$top/rtl/sram_sync_16bits_bytewritable.v" \
	"$top/rtl/bootrom.v" \
	"$top/rtl/idprom.v" \
	"$top/rtl/gen8bit_reg.v" \
	"$top/rtl/sun2_ether_ctl.v" \
	"$top/rtl/sun2_dvma.v" \
	"$top/rtl/ttl_am9513.v" \
	"$top/rtl/ttl_74F151.v" \
	"$top/rtl/ttl_74LS148.v" \
	"$top/rtl/sun2_wishbone_bridge.v" \
	"$top/rtl/tolog.v"

echo "== compiling the board layer and testbench (SystemVerilog) =="
board_src=("$top/rtl/board/wukong_clkgen.sv" "$top/rtl/board/reset_sync.sv" "$top/rtl/board/wukong_v1_top.sv")
tb_src=("$top/tb/wb_ram_model.sv" "$top/tb/uart_monitor.sv" "$top/tb/tb_wukong.sv")

if [ "$BOARD_MEM" = "ddr3" ]; then
	board_src+=("$top/rtl/board/wb_to_mig_ui.sv")

	# MIG's own RTL.  Two files define module sun2_mig_mig: the synthesis one
	# and a simulation one with SIM_BYPASS_INIT_CAL="FAST", which is what
	# MIG's readme recommends so calibration does not dominate the run.  Take
	# the simulation variant and leave the other out, or they collide.
	mapfile -t mig_src < <(find "$mig" -name '*.v' -o -name '*.sv' \
	                       | grep -v '/sun2_mig_mig\.v$' | sort)
	board_src+=("${mig_src[@]}")

	# Micron's DDR3 model, from the generated example design rather than the
	# copy in the Vivado install -- that one is an unsubstituted template, full
	# of %MEM_DENSITY placeholders.  This one is filled in for our part
	# (x2Gb, sg15E, x16).  Not committed: it is Micron's AS-IS licence.
	ex="$top/build/ip/sun2_mig/sun2_mig/example_design/sim"
	tb_src+=("$ex/ddr3_model.sv")
	incargs=(-i "$ex" -i "$mig")
else
	incargs=()
fi

xvlog --sv --work sun2 "${defargs[@]}" "${incargs[@]}" \
	-i "$top/rtl" -i "$top/build/rom" \
	"$top/Inputs/Wish82586/src/wish82586_pkg.sv" \
	"$top/Inputs/Wish82586/src/async_fifo.sv" \
	"$top/Inputs/Wish82586/src/sync_fifo.sv" \
	"$top/Inputs/Wish82586/src/dp_ram.sv" \
	"$top/Inputs/Wish82586/src/crc32_eth.sv" \
	"$top/Inputs/Wish82586/src/mii_rx.sv" \
	"$top/Inputs/Wish82586/src/mii_tx.sv" \
	"$top/Inputs/Wish82586/src/wb_master.sv" \
	"$top/Inputs/Wish82586/src/wb_arb.sv" \
	"$top/Inputs/Wish82586/src/ie_core.sv" \
	"$top/Inputs/Wish82586/src/ie_cu.sv" \
	"$top/Inputs/Wish82586/src/ie_ru.sv" \
	"$top/Inputs/Wish82586/src/wish82586.sv" \
	"$top/rtl/sun2_ethernet.sv" \
	"$top/Inputs/z8530_scc/z8530_scc.sv" \
	"${board_src[@]}" \
	"${tb_src[@]}"

xvlog --work sun2 "$XILINX_VIVADO/data/verilog/src/glbl.v" >/dev/null

debug=off
[ -n "${SUN2_VCD:-}" ] && debug=typical

echo "== elaborating (BOARD_MEM=$BOARD_MEM, debug=$debug) =="
xelab -debug $debug -O3 --timescale 1ns/1ps \
	-L sun2 -L unisims_ver -L unisim -L secureip \
	-generic_top "CPU_CLK_HZ=$SUN2_CPU_HZ" \
	-generic_top "BAUD=${SUN2_BAUD:-9600}" \
	sun2.tb_wukong sun2.glbl -s wukong_sim

echo "== running =="
exec xsim wukong_sim -R "$@"
