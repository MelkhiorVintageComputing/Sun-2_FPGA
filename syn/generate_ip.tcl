# Generate the Xilinx IP the board build needs.
#
#   vivado -mode batch -source syn/generate_ip.tcl [-tclargs BOARD [WHICH]]
#
# BOARD is v1 (default) or v3; see syn/boards.tcl.
# WHICH is all (default), mig, or ila -- MIG takes minutes to generate and the
# ILA seconds, so they are separable.
#
# Two cores.  The MIG 7 Series DDR3 controller, configured from
# syn/mig/sun2_mig.prj, is in every build; the ILA is the debug instrument,
# fitted only by ILA=1 and sampling the bus described in
# rtl/sun2-common/sun2_fpga.v's dbg_bus.
#
# MIG's .prj is the source of truth for it and is committed; everything MIG
# emits from it lands in build/ip/<board> and is not.  The ILA has no .prj --
# an ILA is configured entirely through CONFIG.* properties, so this file is
# its source of truth.
#
# The two Wukong revisions want the same DDR3 in every respect -- same
# MT41K128M16, same 47 pins, same 3000 ps -- and differ only in the FPGA speed
# grade.  Rather than keep two 146-line .prj files that must be edited in
# lockstep and would inevitably drift, the one committed file is copied per
# board with its <TargetFPGA> line rewritten.  MIG is generated per part
# regardless, so the output has to be per-board either way.
#
# MIG 7 Series is Production in Vivado 2025.2 for Artix-7 and needs no licence.

set here [file normalize [file dirname [info script]]]
set top  [file normalize $here/..]

source $here/boards.tcl

set board v1
set which all
if {[llength $argv] > 0} { set board [lindex $argv 0] }
if {[llength $argv] > 1} { set which [lindex $argv 1] }
board_check $board
if {[board_vendor $board] ne "xilinx"} {
    puts "ERROR: BOARD=$board is an [board_vendor $board] board; this is the"
    puts "       Vivado flow.  Use: make -C syn quartus BOARD=$board"
    exit 1
}
if {$which ne "all" && $which ne "mig" && $which ne "ila"} {
    puts "ERROR: WHICH must be all, mig or ila, not '$which'"
    exit 1
}

set part      [board_part $board]
set mig_part  [board_mig_part $board]
set ipdir     $top/build/ip/$board

file mkdir $ipdir

if {$which eq "all" || $which eq "mig"} {

# The committed .prj with the target substituted.  Keep this free of XML
# comments: MIG's parser fails on them, reports the target device as empty and
# then segfaults -- see syn/mig/README.md.
set src [open $here/mig/sun2_mig.prj r]
set prj [read $src]
close $src

if {![regsub {<TargetFPGA>[^<]*</TargetFPGA>} $prj \
         "<TargetFPGA>$mig_part</TargetFPGA>" prj]} {
    puts "ERROR: no <TargetFPGA> element in syn/mig/sun2_mig.prj"
    exit 1
}

set prjfile $ipdir/sun2_mig.prj
set dst [open $prjfile w]
puts -nonewline $dst $prj
close $dst

create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_property ip_output_repo $ipdir [current_project]

puts "== generating sun2_mig for Wukong $board ($part), target $mig_part =="

create_ip -name mig_7series -vendor xilinx.com -library ip \
          -module_name sun2_mig -dir $ipdir

set_property -dict [list \
    CONFIG.XML_INPUT_FILE  $prjfile \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
    CONFIG.MIG_DONT_TOUCH_PARAM {Custom} \
    CONFIG.BOARD_MIG_PARAM {Custom} \
] [get_ips sun2_mig]

generate_target {instantiation_template synthesis simulation} [get_ips sun2_mig]

# The datasheet MIG writes out is the authoritative statement of the user
# interface for this exact configuration -- app_addr granularity, data width,
# latencies.  Surface where it is rather than making anyone hunt for it.
set ds [glob -nocomplain $ipdir/sun2_mig/docs/*datasheet*.txt]
if {[llength $ds]} {
    puts "== MIG datasheet: [lindex $ds 0] =="
}

puts "== done; generated under $ipdir/sun2_mig =="

}

if {$which eq "all" || $which eq "ila"} {

if {![llength [current_project -quiet]]} {
    create_project -in_memory -part $part
    set_property target_language Verilog [current_project]
    set_property ip_output_repo $ipdir [current_project]
}

puts "== generating sun2_ila for Wukong $board ($part) =="

# The instrument for the MMU.  Unlike MIG there is no .prj: an ILA is
# configured entirely through CONFIG.* properties, so this is the source of
# truth for it and there is nothing else to keep in step.
#
# Eight probes, because the field boundaries are what make a capture readable
# and the basic trigger unit ANDs one comparator per probe -- ERR and FC == 1
# in one condition, without the advanced trigger unit.  Widths must match the
# slices in boards/Wukong/wukong_top.sv; Vivado checks them at elaboration.
#
# Capture control (C_EN_STRG_QUAL) is what makes 4096 samples enough: the
# machine is idle between bus cycles, so the interesting window is a few
# hundred clocks spread over millions.  The qualifier is set at run time from
# the Hardware Manager -- ~P_AS_n to keep only bus cycles.
#
# Two input pipeline stages, because this samples wide combinational cones --
# the map outputs and the protection terms -- and the ILA must not be what
# fails timing.  It costs two clocks of latency, uniformly across every probe,
# so the relative timing a capture shows is unaffected.

# Delete any previous copy first.  create_ip over an existing IP of the same
# name reuses it, and then only some of the properties below take: changing the
# probe count from 11 to 12 left C_NUM_OF_PROBES at 11 while C_PROBE11_WIDTH
# was accepted, so the core kept eleven probes, this script printed "done", and
# synthesis failed much later with "named port connection 'probe11' does not
# exist" against a stale stub.  Regenerating from nothing costs seconds.
file delete -force $ipdir/sun2_ila

create_ip -name ila -vendor xilinx.com -library ip \
          -module_name sun2_ila -dir $ipdir

# The probe count first, on its own.  set_property -dict is atomic and
# validated as a whole, so naming C_PROBE8_WIDTH while the core still has eight
# probes invalidates the entire dict -- silently: the IP keeps its old
# configuration and only the generated .xci shows it.
set_property CONFIG.C_NUM_OF_PROBES {13} [get_ips sun2_ila]

set_property -dict [list \
    CONFIG.C_DATA_DEPTH        {4096} \
    CONFIG.C_INPUT_PIPE_STAGES {2} \
    CONFIG.C_EN_STRG_QUAL      {1} \
    CONFIG.C_ADV_TRIGGER       {false} \
    CONFIG.C_TRIGOUT_EN        {false} \
    CONFIG.C_TRIGIN_EN         {false} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
    CONFIG.C_PROBE0_WIDTH {23} \
    CONFIG.C_PROBE1_WIDTH {3} \
    CONFIG.C_PROBE2_WIDTH {6} \
    CONFIG.C_PROBE3_WIDTH {4} \
    CONFIG.C_PROBE4_WIDTH {8} \
    CONFIG.C_PROBE5_WIDTH {12} \
    CONFIG.C_PROBE6_WIDTH {12} \
    CONFIG.C_PROBE7_WIDTH {6} \
    CONFIG.C_PROBE8_WIDTH {16} \
    CONFIG.C_PROBE9_WIDTH {8} \
    CONFIG.C_PROBE10_WIDTH {3} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {16} \
] [get_ips sun2_ila]

# And check it took.  The properties above are validated as a whole and can be
# rejected in silence, so read the one that matters back rather than trusting
# that setting it worked -- the failure mode is a bitstream that cannot be
# built and a message that points at the wrong file.
set got [get_property CONFIG.C_NUM_OF_PROBES [get_ips sun2_ila]]
if {$got != 13} {
    puts "ERROR: sun2_ila has $got probes, not the 13 asked for -- the"
    puts "       configuration was rejected.  wukong_top.sv drives probe12,"
    puts "       so synthesis would fail on a stale stub instead."
    exit 1
}
puts "== sun2_ila: $got probes =="

generate_target {instantiation_template synthesis simulation} [get_ips sun2_ila]

puts "== done; generated under $ipdir/sun2_ila =="

}
