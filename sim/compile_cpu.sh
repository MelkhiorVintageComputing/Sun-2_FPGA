# Compile the MC68010 into the `sun2' xsim library, and set the define that
# tells top_fpga.v which of its two instantiations to build.
#
# Sourced by run_xsim.sh and run_xsim_board.sh -- the core file lists exist
# here once, because a second copy of a fourteen-file list is a copy that
# drifts, and dropping one file from it is a link error a long way from its
# cause.
#
# Expects `top' to be set and a `defargs' array to append to; call compile_cpu
# after the run directory exists and before the Sun-2 gateware is compiled,
# since the define has to reach that xvlog.
#
#   SUN2_CPU=suska     the Suska VHDL core (default): what every measured
#                      fingerprint in this project was taken against
#   SUN2_CPU=rd68011   the SystemVerilog core in Inputs/RD68011
#
# SUSKA_DIR builds the VHDL core from somewhere other than Inputs/ -- a patched
# copy under build/inputs/, say.  Nothing sets it by default, and Inputs/
# itself is never modified.

compile_cpu() {
	case "${SUN2_CPU:-suska}" in
	rd68011)
		local rd="$top/Inputs/RD68011"
		if [ ! -d "$rd/rtl" ]; then
			echo "RD68011 not found at $rd" >&2
			echo "run: git submodule update --init Inputs/RD68011" >&2
			return 1
		fi
		defargs+=(-d SUN2_CPU_RD68011)
		echo "== compiling the RD68011 MC68010 (SystemVerilog) =="
		# Order from that project's own Makefile: the two packages first,
		# then the generated microcode, then the hand-written RTL.
		xvlog --sv --work sun2 \
			"$rd/rtl/rd68011_pkg.sv" \
			"$rd/rtl/gen/rd68011_ucode_pkg.sv" \
			"$rd/rtl/gen/rd68011_decode_rom.sv" \
			"$rd/rtl/gen/rd68011_loop_rom.sv" \
			"$rd/rtl/gen/rd68011_ucode_rom.sv" \
			"$rd/rtl/gen/rd68011_uctl_rom.sv" \
			"$rd/rtl/gen/rd68011_urq_rom.sv" \
			"$rd/rtl/rd68011_dedge_ff.sv" \
			"$rd/rtl/rd68011_sync.sv" \
			"$rd/rtl/rd68011_alu.sv" \
			"$rd/rtl/rd68011_shifter.sv" \
			"$rd/rtl/rd68011_mul.sv" \
			"$rd/rtl/rd68011_divider.sv" \
			"$rd/rtl/rd68011_biu.sv" \
			"$rd/rtl/rd68011_seq.sv" \
			"$rd/rtl/rd68011_top.sv"
		;;
	suska)
		# From the patched copy under build/inputs/, never from Inputs/
		# itself: patches/Suska_Configware/ carries the fixes this
		# machine needs, and tools/patch_inputs.sh rebuilds the copy
		# whenever a patch or a source file moves.
		"$top/tools/patch_inputs.sh" Suska_Configware
		local sk="${SUSKA_DIR:-$top/build/inputs/Suska_Configware/68K10}"
		if [ ! -e "$sk/wf68k10_top.vhd" ]; then
			echo "no Suska MC68010 at $sk" >&2
			return 1
		fi
		if [ -n "${SUSKA_DIR:-}" ]; then
			echo "== compiling the Suska MC68010 (VHDL, from $sk) =="
		else
			echo "== compiling the Suska MC68010 (VHDL) =="
		fi
		# wf68k10_pkg first: everything else depends on it.
		# -2008 is required: the core connects `buffer' formals to `out'
		# actuals, which only VHDL-2008 allows.
		xvhdl -2008 --work sun2 \
			"$sk/wf68k10_pkg.vhd" \
			"$sk/wf68k10_address_registers.vhd" \
			"$sk/wf68k10_alu.vhd" \
			"$sk/wf68k10_bus_interface.vhd" \
			"$sk/wf68k10_control.vhd" \
			"$sk/wf68k10_data_registers.vhd" \
			"$sk/wf68k10_exception_handler.vhd" \
			"$sk/wf68k10_opcode_decoder.vhd" \
			"$sk/wf68k10_top.vhd"
		;;
	*)
		echo "SUN2_CPU must be suska or rd68011, not '$SUN2_CPU'" >&2
		return 1
		;;
	esac
}
