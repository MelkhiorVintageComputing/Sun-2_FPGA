# Non-project Vivado build for the Sun-2 on a QMTech Wukong V1.
#
#   vivado -mode batch -source syn/build.tcl [-tclargs CPU_HZ MACHINE MB_ETHER BOARD FB]
#
# MACHINE is multibus (default) or vme; see "Which machine" in the README.
# MB_ETHER=1 fits the Sun-2 Ethernet card in the MultiBus cage.
# BOARD is v1 (default) or v3, the QMTech Wukong revision; see syn/boards.tcl.
# FB=1 fits the 2/50's frame buffer and its HDMI output.
#
# Nothing generated is committed: the MIG IP comes from syn/mig/sun2_mig.prj
# via syn/generate_ip.tcl, and everything lands in build/.
#
# The build fails on negative slack rather than quietly writing a bitstream
# that will not work.

set here [file normalize [file dirname [info script]]]
set top  [file normalize $here/..]

source $here/boards.tcl

set cpu_hz   12500000
set machine  multibus
set mb_ether 0
set board    v1
set fb       0
if {[llength $argv] > 0} { set cpu_hz   [lindex $argv 0] }
if {[llength $argv] > 1} { set machine  [lindex $argv 1] }
if {[llength $argv] > 2} { set mb_ether [lindex $argv 2] }
if {[llength $argv] > 3} { set board    [lindex $argv 3] }
if {[llength $argv] > 4} { set fb       [lindex $argv 4] }
board_check $board

switch -- $machine {
    multibus { set defines [list SUN2_MULTIBUS] }
    vme      { set defines [list SUN2_VME] }
    default  { puts "ERROR: MACHINE must be multibus or vme, not '$machine'"; exit 1 }
}

if {$mb_ether == 1} {
    if {$machine ne "multibus"} {
        puts "ERROR: MB_ETHER is MultiBus only: a 2/50 has its Ethernet on board"
        exit 1
    }
    lappend defines SUN2_MB_ETHER
}

if {$fb == 1} {
    if {$machine ne "vme"} {
        puts "ERROR: FB is VME only: the 2/120's frame buffer is a different device"
        exit 1
    }
    lappend defines SUN2_FB
}

set part    [board_part $board]
set ipdir   $top/build/ip/$board
set outdir  $top/build/syn/$board-$machine[expr {$mb_ether == 1 ? "-mbether" : ""}][expr {$fb == 1 ? "-fb" : ""}]-cpu[expr {$cpu_hz / 1000000}]
set migrtl  $ipdir/sun2_mig/sun2_mig/user_design/rtl

file mkdir $outdir

if {![file isdirectory $migrtl]} {
    puts "ERROR: MIG has not been generated. Run:"
    puts "    vivado -mode batch -source syn/generate_ip.tcl"
    exit 1
}

puts "== Sun-2 for Wukong $board ($part), $machine, CPU clock $cpu_hz Hz =="

# Set the part before reading anything.  read_ip validates the IP against the
# current part, and in non-project mode that defaults to a Kintex device until
# told otherwise -- which locks the MIG core and then fails synthesis with the
# unhelpful "module 'sun2_mig' not found".
set_part $part

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
# The MC68010 is VHDL, and needs -2008: it connects `buffer` formals to `out`
# actuals, which VHDL-93 forbids.
read_vhdl -vhdl2008 [list \
    $top/Inputs/Suska_Configware/68K10/wf68k10_pkg.vhd \
    $top/Inputs/Suska_Configware/68K10/wf68k10_address_registers.vhd \
    $top/Inputs/Suska_Configware/68K10/wf68k10_alu.vhd \
    $top/Inputs/Suska_Configware/68K10/wf68k10_bus_interface.vhd \
    $top/Inputs/Suska_Configware/68K10/wf68k10_control.vhd \
    $top/Inputs/Suska_Configware/68K10/wf68k10_data_registers.vhd \
    $top/Inputs/Suska_Configware/68K10/wf68k10_exception_handler.vhd \
    $top/Inputs/Suska_Configware/68K10/wf68k10_opcode_decoder.vhd \
    $top/Inputs/Suska_Configware/68K10/wf68k10_top.vhd \
]

# The Sun-2 gateware is Verilog-2001 and must not be read as SystemVerilog:
# it relies on a couple of constructs SV rejects.
read_verilog [list \
    $top/rtl/sun2-common/top_fpga.v \
    $top/rtl/sun2-common/sun2_fpga.v \
    $top/rtl/sun2-common/sun2_mmu.v \
    $top/rtl/sun2-common/ctx_reg.v \
    $top/rtl/sun2-common/pmap.v \
    $top/rtl/sun2-common/smap.v \
    $top/rtl/sun2-common/sram_sync.v \
    $top/rtl/sun2-common/sram_sync_16bits_bytewritable.v \
    $top/rtl/sun2-common/bootrom.v \
    $top/rtl/sun2-common/idprom.v \
    $top/rtl/sun2-common/gen8bit_reg.v \
    $top/rtl/sun2-vme/sun2_ether_ctl.v \
    $top/rtl/sun2-vme/sun2_phy_status.v \
    $top/rtl/sun2-vme/sun2_fb_ctl.v \
    $top/rtl/sun2-vme/sun2_dvma.v \
    $top/rtl/sun2-common/ttl_am9513.v \
    $top/rtl/sun2-common/ttl_74F151.v \
    $top/rtl/sun2-common/ttl_74LS148.v \
    $top/rtl/sun2-common/sun2_wishbone_bridge.v \
    $top/rtl/sun2-common/tolog.v \
]

read_verilog -sv [list \
    $top/build/inputs/Wish82586/src/wish82586_pkg.sv \
    $top/build/inputs/Wish82586/src/async_fifo.sv \
    $top/build/inputs/Wish82586/src/sync_fifo.sv \
    $top/build/inputs/Wish82586/src/dp_ram.sv \
    $top/build/inputs/Wish82586/src/crc32_eth.sv \
    $top/build/inputs/Wish82586/src/mii_rx.sv \
    $top/build/inputs/Wish82586/src/mii_tx.sv \
    $top/build/inputs/Wish82586/src/wb_master.sv \
    $top/build/inputs/Wish82586/src/wb_arb.sv \
    $top/build/inputs/Wish82586/src/ie_core.sv \
    $top/build/inputs/Wish82586/src/ie_cu.sv \
    $top/build/inputs/Wish82586/src/ie_ru.sv \
    $top/build/inputs/Wish82586/src/wish82586.sv \
    $top/build/inputs/Wish82586/src/wb_mdio.sv \
    $top/rtl/sun2-vme/sun2_ethernet.sv \
    $top/rtl/sun2-multibus/sun2_mb_ether.sv \
    $top/boards/Wukong/phy_rtl8211_init.sv \
    $top/Inputs/z8530_scc/z8530_scc.sv \
    $top/boards/Wukong/wukong_clkgen.sv \
    $top/boards/Wukong/hdmi_clkgen.sv \
    $top/boards/Wukong/reset_sync.sv \
    $top/boards/Wukong/wb_to_mig_ui.sv \
    $top/boards/Wukong/mig_arb.sv \
    $top/boards/Wukong/fb_scanout.sv \
    $top/Inputs/hdmi/src/tmds_channel.sv \
    $top/Inputs/hdmi/src/serializer.sv \
    $top/Inputs/hdmi/src/packet_assembler.sv \
    $top/Inputs/hdmi/src/packet_picker.sv \
    $top/Inputs/hdmi/src/audio_clock_regeneration_packet.sv \
    $top/Inputs/hdmi/src/audio_info_frame.sv \
    $top/Inputs/hdmi/src/audio_sample_packet.sv \
    $top/Inputs/hdmi/src/auxiliary_video_information_info_frame.sv \
    $top/Inputs/hdmi/src/source_product_description_info_frame.sv \
    $top/Inputs/hdmi/src/hdmi.sv \
    $top/boards/Wukong/wukong_top.sv \
]

# MIG, as generated.  In a non-project flow read_ip only registers the core --
# it has to be synthesised out-of-context before synth_design can link it, or
# the top fails with "module 'sun2_mig' not found".
read_ip $ipdir/sun2_mig/sun2_mig.xci
if {[llength [get_ips sun2_mig]] == 0} {
    puts "ERROR: sun2_mig.xci did not load"
    exit 1
}
synth_ip [get_ips sun2_mig]

# Revision file first, then the shared one: common creates the MII clocks and
# then groups them, and a get_clocks for a clock that does not exist yet
# returns nothing and drops the group silently.
read_xdc $here/wukong_$board.xdc
read_xdc $here/wukong_common.xdc

# Only when there is a frame buffer: the clocks it names exist only then.
if {$fb == 1} {
    read_xdc $here/wukong_hdmi.xdc
    puts "== read wukong_hdmi.xdc =="
}

# ---------------------------------------------------------------------------
# Synthesis and implementation
# ---------------------------------------------------------------------------
synth_design -top wukong_top -part $part \
    -include_dirs [list $top/rtl/sun2-common $top/build/rom] \
    -verilog_define $defines \
    -generic CPU_CLK_HZ=$cpu_hz \
    -directive Default

write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/post_synth_utilization.rpt
report_clocks      -file $outdir/clocks.rpt

opt_design
place_design -directive Explore
phys_opt_design
route_design -directive Explore

write_checkpoint -force $outdir/post_route.dcp
report_utilization       -file $outdir/utilization.rpt
report_timing_summary    -file $outdir/timing.rpt
report_drc               -file $outdir/drc.rpt

# ---------------------------------------------------------------------------
# Only write a bitstream if it would actually work
# ---------------------------------------------------------------------------
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "== worst setup slack $wns ns, worst hold slack $whs ns =="

if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met (WNS $wns, WHS $whs); see $outdir/timing.rpt"
    exit 1
}

write_bitstream -force $outdir/sun2_wukong_$board.bit
puts "== wrote $outdir/sun2_wukong_$board.bit =="
