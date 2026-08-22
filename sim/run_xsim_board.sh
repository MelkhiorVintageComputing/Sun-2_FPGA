#!/bin/bash
#
# Board-level simulation: the Sun-2 as it will be on a QMTech Wukong.
#
# Environment:
#   BOARD           v1 (default) | v3 -- which Wukong revision's MIG to use.
#                   The board RTL is shared, so this only matters for ddr3.
#   BOARD_MEM       fast (default) | ddr3
#                     fast - behavioural Wishbone RAM, boots to the prompt
#                     ddr3 - real MIG plus Micron's DDR3 model
#   XILINX_VIVADO   Vivado install (default /opt/Xilinx/2025.2/Vivado)
#   SUN2_DEFINES    extra `define's, e.g. "MEM_PAGES=512 ROM_FASTBOOT"
#   SUN2_BAUD       console decode rate (default 9600)
#   SUN2_CPU_HZ     CPU clock (default 12500000)
#   SUN2_CPU        suska (default) | rd68011 -- which MC68010 to build
#
# Arguments are passed through to xsim, so plusargs work.
#
set -e -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/.." && pwd)

: "${XILINX_VIVADO:=/opt/Xilinx/2025.2/Vivado}"
: "${BOARD:=v1}"
: "${BOARD_MEM:=fast}"
: "${SUN2_CPU_HZ:=12500000}"

"$top/tools/patch_inputs.sh" Wish82586
"$top/tools/patch_inputs.sh" Wish5380
"$top/tools/patch_inputs.sh" Suska_Configware

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

# Per machine as well as per memory mode: two runs sharing a snapshot
# directory clobber each other and xsim dies with a kernel fatal that looks
# like a design fault.  Per CPU core too, for the same reason and one more: a
# run with the second core must never write over one that measured the machine
# as it is developed.  sim/Makefile's board-check builds the same name.
cputag=""
[ -n "${SUN2_CPU:-}" ] && [ "${SUN2_CPU}" != suska ] && cputag="-$SUN2_CPU"
rundir="$top/build/sim/board-$BOARD-$BOARD_MEM${SUN2_MACHINE:+-$SUN2_MACHINE}$cputag"
mkdir -p "$rundir"

make -s -C "$top/tools"

# SUN2_SIM: this is a simulation, so keep the tolog VCD hook.  SUN2_ILA is not
# set here -- the debug bus is fine, but wukong_top would then instantiate the
# ILA IP, which this flow does not build.
defargs=(-d SUN2_SIM)
for d in ${SUN2_DEFINES:-}; do
	defargs+=(-d "$d")
done

mig="$top/build/ip/$BOARD/sun2_mig/sun2_mig/user_design/rtl"
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
echo "== BOARD=$BOARD, BOARD_MEM=$BOARD_MEM, clock generation: $BOARD_CLKGEN =="

cd "$rundir"

# The MC68010 itself, and the define that says which one top_fpga.v builds.
# Shared with run_xsim.sh so the file lists exist once.
. "$here/compile_cpu.sh"
compile_cpu

echo "== compiling the Sun-2 gateware (Verilog) =="
xvlog --work sun2 "${defargs[@]}" \
	-i "$top/rtl/sun2-common" -i "$top/build/rom" \
	"$top/rtl/sun2-common/top_fpga.v" \
	"$top/rtl/sun2-common/sun2_fpga.v" \
	"$top/rtl/sun2-common/sun2_mmu.v" \
	"$top/rtl/sun2-common/ctx_reg.v" \
	"$top/rtl/sun2-common/pmap.v" \
	"$top/rtl/sun2-common/smap.v" \
	"$top/rtl/sun2-common/sram_sync.v" \
	"$top/rtl/sun2-common/sram_sync_16bits_bytewritable.v" \
	"$top/rtl/sun2-common/bootrom.v" \
	"$top/rtl/sun2-common/idprom.v" \
	"$top/rtl/sun2-common/gen8bit_reg.v" \
	"$top/rtl/sun2-vme/sun2_ether_ctl.v" \
	"$top/rtl/sun2-vme/sun2_phy_status.v" \
	"$top/rtl/sun2-common/sun2_fb_ctl.v" \
	"$top/rtl/sun2-vme/sun2_dvma.v" \
	"$top/rtl/sun2-common/ttl_am9513.v" \
	"$top/rtl/sun2-common/ttl_74F151.v" \
	"$top/rtl/sun2-common/ttl_74LS148.v" \
	"$top/rtl/sun2-common/sun2_wishbone_bridge.v" \
	"$top/rtl/sun2-common/tolog.v"

echo "== compiling the board layer and testbench (SystemVerilog) =="
board_src=("$top/boards/Wukong/wukong_clkgen.sv" "$top/boards/Wukong/reset_sync.sv" \
           "$top/boards/Wukong/hdmi_clkgen.sv" "$top/boards/Wukong/fb_scanout.sv" \
           "$top/boards/Wukong/wukong_top.sv")
tb_src=("$top/tb/wb_ram_model.sv" "$top/tb/uart_monitor.sv" "$top/tb/uart_console.sv" \
        "$top/tb/mii_peer.sv" "$top/tb/mdio_phy_model.sv" "$top/tb/tb_wukong.sv")

if [ "$BOARD_MEM" = "ddr3" ]; then
	board_src+=("$top/boards/Wukong/wb_to_mig_ui.sv" "$top/boards/Wukong/mig_arb.sv")

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
	ex="$top/build/ip/$BOARD/sun2_mig/sun2_mig/example_design/sim"
	tb_src+=("$ex/ddr3_model.sv")
	incargs=(-i "$ex" -i "$mig")
else
	incargs=()
fi

xvlog --sv --work sun2 "${defargs[@]}" "${incargs[@]}" \
	-i "$top/rtl/sun2-common" -i "$top/build/rom" \
	"$top/build/inputs/Wish82586/src/wish82586_pkg.sv" \
	"$top/build/inputs/Wish82586/src/async_fifo.sv" \
	"$top/build/inputs/Wish82586/src/sync_fifo.sv" \
	"$top/build/inputs/Wish82586/src/dp_ram.sv" \
	"$top/build/inputs/Wish82586/src/crc32_eth.sv" \
	"$top/build/inputs/Wish82586/src/mii_rx.sv" \
	"$top/build/inputs/Wish82586/src/mii_tx.sv" \
	"$top/build/inputs/Wish82586/src/wb_master.sv" \
	"$top/build/inputs/Wish82586/src/wb_arb.sv" \
	"$top/build/inputs/Wish82586/src/ie_core.sv" \
	"$top/build/inputs/Wish82586/src/ie_cu.sv" \
	"$top/build/inputs/Wish82586/src/ie_ru.sv" \
	"$top/build/inputs/Wish82586/src/wish82586.sv" \
	"$top/build/inputs/Wish82586/src/wb_mdio.sv" \
	"$top/boards/Wukong/phy_rtl8211_init.sv" \
	"$top/rtl/sun2-vme/sun2_ethernet.sv" \
	"$top/rtl/sun2-multibus/sun2_mb_ether.sv" \
	"$top/rtl/sun2-multibus/sun2_xy450.sv" \
	"$top/build/inputs/Wish5380/src/wish5380_pkg.sv" \
	"$top/build/inputs/Wish5380/src/sd_spi.sv" \
	"$top/build/inputs/Wish5380/src/blk_sd.sv" \
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
