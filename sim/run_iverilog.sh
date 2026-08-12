#!/bin/bash
#
# Open-source simulation flow: GHDL converts the Suska MC68010 from VHDL to
# Verilog, then Icarus simulates the whole design.
#
# STATUS: does not work today.  `ghdl --synth` rejects
#
#   wf68k10_bus_interface.vhd:286: error: non matching bounds
#     SSW <= To_StdLogicVector(RMC & '0' & OPCODE_REQ & RD_REQ & RMC)
#            & SIZEVAR & RW_In & "00000" & FC_IN;
#
# The concatenation is 16 bits wide, exactly matching SSW, so the VHDL itself
# is fine (xsim and Vivado both accept it) -- GHDL's synthesis front end is
# stricter about the index ranges of a concatenation than the language is.
# The script is kept because the rest of the recipe is right; use the xsim
# flow (sim/run_xsim.sh) for actual work.
#
set -e -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/.." && pwd)

rundir="$top/build/sim/iverilog"
mkdir -p "$rundir"

make -s -C "$top/tools"

defargs=()
for d in $SUN2_DEFINES; do
	defargs+=(-D "$d")
done

cd "$rundir"

suska="$top/Inputs/Suska_Configware/68K10"

echo "== analysing the Suska MC68010 (GHDL) =="
# -fsynopsys: the core uses ieee.std_logic_unsigned/_arith.
ghdl -a --std=08 -fsynopsys --workdir=. \
	"$suska/wf68k10_pkg.vhd" \
	"$suska/wf68k10_address_registers.vhd" \
	"$suska/wf68k10_alu.vhd" \
	"$suska/wf68k10_bus_interface.vhd" \
	"$suska/wf68k10_control.vhd" \
	"$suska/wf68k10_data_registers.vhd" \
	"$suska/wf68k10_exception_handler.vhd" \
	"$suska/wf68k10_opcode_decoder.vhd" \
	"$suska/wf68k10_top.vhd"

echo "== converting it to Verilog =="
ghdl --synth --std=08 -fsynopsys --workdir=. --out=verilog wf68k10_top > wf68k10_top.v

echo "== compiling everything (Icarus) =="
iverilog -g2012 -o sun2_sim \
	"${defargs[@]}" \
	-I "$top/rtl" -I "$top/build/rom" \
	-s tb_sun2 \
	wf68k10_top.v \
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
	"$top/rtl/tolog.v" \
	"$top/Inputs/z8530_scc/z8530_scc.sv" \
	"$top/tb/wb_ram_model.sv" \
	"$top/tb/uart_monitor.sv" \
	"$top/tb/tb_sun2.sv"

echo "== running =="
exec vvp sun2_sim "$@"
