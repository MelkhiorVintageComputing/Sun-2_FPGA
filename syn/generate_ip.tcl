# Generate the Xilinx IP the board build needs.
#
#   vivado -mode batch -source syn/generate_ip.tcl [-tclargs BOARD]
#
# BOARD is v1 (default) or v3; see syn/boards.tcl.
#
# Only one core: the MIG 7 Series DDR3 controller, configured from
# syn/mig/sun2_mig.prj.  The .prj is the source of truth and is committed;
# everything MIG emits from it lands in build/ip/<board> and is not.
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
if {[llength $argv] > 0} { set board [lindex $argv 0] }
board_check $board

set part      [board_part $board]
set mig_part  [board_mig_part $board]
set ipdir     $top/build/ip/$board

file mkdir $ipdir

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
