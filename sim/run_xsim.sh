#!/bin/bash
#
# Run the Sun-2 simulation under Vivado's xsim.
#
# xsim is the primary flow because the design is mixed-language: the Suska
# MC68010 is VHDL, everything else is Verilog / SystemVerilog.
#
# Environment:
#   XILINX_VIVADO   Vivado install (default /opt/Xilinx/2025.2/Vivado)
#   SUN2_DEFINES    extra `define's, e.g. "MEM_SIM_ONLY ROM_PRISTINE"
#   SUN2_BAUD       console decode rate (default 9600)
#   SUN2_MEM_LATENCY  memory wait states (default 0; 7 is what MIG measures at)
#
# Any arguments are passed through to xsim, so plusargs work:
#   ./run_xsim.sh -testplusarg timeout_ms=500
#
set -e -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/.." && pwd)

: "${XILINX_VIVADO:=/opt/Xilinx/2025.2/Vivado}"
"$top/tools/patch_inputs.sh" Wish82586

if [ ! -x "$XILINX_VIVADO/bin/xvlog" ]; then
	echo "xsim not found under $XILINX_VIVADO -- set XILINX_VIVADO" >&2
	exit 1
fi
export PATH="$XILINX_VIVADO/bin:$PATH"

# xelab links the snapshot with Vivado's bundled gcc, which does not know about
# Debian/Ubuntu multiarch paths and so cannot find crt1.o on its own.
if [ -z "$LIBRARY_PATH" ] && [ -e /usr/lib/x86_64-linux-gnu/crt1.o ]; then
	export LIBRARY_PATH=/usr/lib/x86_64-linux-gnu
fi

# One directory per machine.  Two runs sharing a snapshot directory clobber
# each other -- the second recompiles it while the first is executing, and xsim
# dies with a kernel fatal that looks like a design fault rather than a race.
# That cost a wrong diagnosis once.
# One directory per configuration, not per machine: two runs sharing a
# directory recompile the snapshot underneath each other and the second dies
# with a kernel fatal that looks like a design fault.  The MultiBus machine
# with and without its Ethernet card are two configurations of one machine, and
# both get run.
# The tags compose rather than choose: a 2/120 with both an Ethernet card and a
# video board is a real machine, and if the two options shared a directory the
# second run would recompile the snapshot under the first.
rundir_tag=""
case " $SUN2_DEFINES " in *" SUN2_MB_ETHER "*) rundir_tag="$rundir_tag-mbether" ;; esac
case " $SUN2_DEFINES " in *" SUN2_FB "*)       rundir_tag="$rundir_tag-fb" ;; esac
case " $SUN2_DEFINES " in *" SUN2_XY450 "*)    rundir_tag="$rundir_tag-xy450" ;; esac
rundir="$top/build/sim/xsim${SUN2_MACHINE:+-$SUN2_MACHINE}$rundir_tag"
mkdir -p "$rundir"

# The boot PROM include lives in build/rom; generate it if it isn't there yet.
make -s -C "$top/tools"

defargs=()
for d in $SUN2_DEFINES; do
	defargs+=(-d "$d")
done

cd "$rundir"

echo "== compiling the Suska MC68010 (VHDL) =="
# wf68k10_pkg first: everything else depends on it.
# -2008 is required: the core connects `buffer` formals to `out` actuals, which
# only VHDL-2008 allows.
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

# The Sun-2 gateware is plain Verilog-2001 and relies on a couple of
# use-before-declare wires that SystemVerilog rejects, so it is compiled in
# Verilog mode; only the SCC and the testbench are SystemVerilog.
echo "== compiling the Sun-2 gateware (Verilog) =="
xvlog --work sun2 \
	"${defargs[@]}" \
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

echo "== compiling the SCC and testbench (SystemVerilog) =="
xvlog --sv --work sun2 \
	"${defargs[@]}" \
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
	"$top/rtl/sun2-vme/sun2_ethernet.sv" \
	"$top/rtl/sun2-multibus/sun2_mb_ether.sv" \
	"$top/rtl/sun2-multibus/sun2_xy450.sv" \
	"$top/Inputs/z8530_scc/z8530_scc.sv" \
	"$top/tb/wb_ram_model.sv" \
	"$top/tb/blk_file.sv" \
	"$top/tb/mii_peer.sv" \
	"$top/tb/uart_monitor.sv" \
	"$top/tb/tb_sun2.sv"

# Signal visibility for $dumpvars costs a lot of run time, so it is opt-in.
# Set SUN2_VCD=1 alongside the +vcd / +vcd_full plusargs.
debug=off
[ -n "${SUN2_VCD:-}" ] && debug=typical

echo "== elaborating (debug=$debug) =="
xelab -debug $debug -O3 --timescale 1ns/1ps \
	-L sun2 -L unisim \
	-generic_top "BAUD=${SUN2_BAUD:-9600}" \
	-generic_top "MEM_LATENCY=${SUN2_MEM_LATENCY:-0}" \
	sun2.tb_sun2 -s sun2_sim

echo "== running =="
exec xsim sun2_sim -R "$@"
