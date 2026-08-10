# Generate the Xilinx IP the board build needs.
#
#   vivado -mode batch -source syn/generate_ip.tcl
#
# Only one core: the MIG 7 Series DDR3 controller, configured from
# syn/mig/sun2_mig.prj.  The .prj is the source of truth and is committed;
# everything MIG emits from it lands in build/ip and is not.
#
# MIG 7 Series is Production in Vivado 2025.2 for Artix-7 and needs no licence.

set here   [file normalize [file dirname [info script]]]
set top    [file normalize $here/..]
set ipdir  $top/build/ip
set part   xc7a100tfgg676-2

file mkdir $ipdir

create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_property ip_output_repo $ipdir [current_project]

puts "== generating sun2_mig from syn/mig/sun2_mig.prj =="

create_ip -name mig_7series -vendor xilinx.com -library ip \
          -module_name sun2_mig -dir $ipdir

set_property -dict [list \
    CONFIG.XML_INPUT_FILE  [file normalize $here/mig/sun2_mig.prj] \
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
