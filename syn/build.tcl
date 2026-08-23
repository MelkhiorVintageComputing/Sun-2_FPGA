# Non-project Vivado build for the Sun-2 on a QMTech Wukong V1.
#
#   vivado -mode batch -source syn/build.tcl [-tclargs CPU_HZ MACHINE MB_ETHER BOARD FB XY450 CPU ILA]
#
# MACHINE is multibus (default) or vme; see "Which machine" in the README.
# MB_ETHER=1 fits the Sun-2 Ethernet card in the MultiBus cage.
# BOARD is v1 (default) or v3, the QMTech Wukong revision; see syn/boards.tcl.
# FB=1 fits the frame buffer and its HDMI output -- the 2/50's on-board one, or
#      the 2/120's video board, which also carries the keyboard/mouse SCC.
# XY450=1 fits the Xylogics 450 disk controller in the MultiBus cage.
# CPU is suska (default) or rd68011.
# ILA=1 fits the integrated logic analyser on the MMU's debug bus and writes
#      the .ltx the Hardware Manager needs; see BRINGUP.md.
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
set xy450    0
set cpu      suska
set ila      0
set hdmi30   0
if {[llength $argv] > 0} { set cpu_hz   [lindex $argv 0] }
if {[llength $argv] > 1} { set machine  [lindex $argv 1] }
if {[llength $argv] > 2} { set mb_ether [lindex $argv 2] }
if {[llength $argv] > 3} { set board    [lindex $argv 3] }
if {[llength $argv] > 4} { set fb       [lindex $argv 4] }
if {[llength $argv] > 5} { set xy450    [lindex $argv 5] }
if {[llength $argv] > 6} { set cpu      [lindex $argv 6] }
if {[llength $argv] > 7} { set ila      [lindex $argv 7] }
if {[llength $argv] > 8} { set hdmi30   [lindex $argv 8] }
if {$cpu ne "suska" && $cpu ne "rd68011"} {
    puts "ERROR: CPU must be suska or rd68011, not '$cpu'"
    exit 1
}
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

# Both machines have a frame buffer; they differ only in where it decodes.  On
# a MultiBus machine this also brings in the keyboard/mouse SCC, which lives on
# the video board.
if {$fb == 1} {
    lappend defines SUN2_FB
}

# HDMI30=1: drive the display at 1080p30 rather than 1080p60.  The picture is
# identical; what halves is the TMDS serial rate, from 742 MHz to 371.  The
# faster one is out of specification for an Artix-7 global buffer and is what
# QMTech's own reference design does, so it works on some parts and sinks and
# not others -- a monitor reporting the signal out of range is the symptom.
if {$hdmi30 == 1} {
    if {$fb != 1} {
        puts "ERROR: HDMI30 needs FB=1; there is no display without it"
        exit 1
    }
    lappend defines SUN2_HDMI_30HZ
}

# The Xylogics 450 is a MultiBus card; a 2/50 takes a 451 on the VME bus, which
# is a different card in a different address space.
if {$xy450 == 1} {
    if {$machine ne "multibus"} {
        puts "ERROR: XY450 is MultiBus only: a 2/50 takes a Xylogics 451 on the VME bus"
        exit 1
    }
    lappend defines SUN2_XY450
}

# Which MC68010 to build.  top_fpga.v instantiates both cores and this define
# picks; the file list further down supplies the sources for the one chosen.
if {$cpu eq "rd68011"} {
    lappend defines SUN2_CPU_RD68011
}

# The ILA.  Its own output directory, because a bitstream with a debug hub in
# it is not the same artefact as one without and the two must never be
# confused on a bench.
if {$ila == 1} {
    lappend defines SUN2_ILA
}

set part    [board_part $board]
set ipdir   $top/build/ip/$board
set outdir  $top/build/syn/$board-$machine[expr {$mb_ether == 1 ? "-mbether" : ""}][expr {$fb == 1 ? "-fb" : ""}][expr {$xy450 == 1 ? "-xy450" : ""}]-cpu[expr {$cpu_hz / 1000000}][expr {$cpu ne "suska" ? "-$cpu" : ""}][expr {$ila == 1 ? "-ila" : ""}][expr {$hdmi30 == 1 ? "-hdmi30" : ""}]
set migrtl  $ipdir/sun2_mig/sun2_mig/user_design/rtl

file mkdir $outdir

if {![file isdirectory $migrtl]} {
    puts "ERROR: MIG has not been generated. Run:"
    puts "    vivado -mode batch -source syn/generate_ip.tcl"
    exit 1
}

puts "== Sun-2 for Wukong $board ($part), $machine, CPU clock $cpu_hz Hz, core $cpu =="

# Set the part before reading anything.  read_ip validates the IP against the
# current part, and in non-project mode that defaults to a Kintex device until
# told otherwise -- which locks the MIG core and then fails synthesis with the
# unhelpful "module 'sun2_mig' not found".
set_part $part

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
# The MC68010.  Suska is VHDL and needs -2008: it connects `buffer` formals to
# `out` actuals, which VHDL-93 forbids.  RD68011 is the SystemVerilog core in
# Inputs/RD68011.  top_fpga.v carries both instantiations and picks between
# them on SUN2_CPU_RD68011, added to the defines above, so this is a file list
# and one define -- every other Sun-2 source is the one the Suska build uses.
# It gets its own output directory.
if {$cpu eq "rd68011"} {
    set rd68011 $top/Inputs/RD68011
    if {![file isdirectory $rd68011/rtl]} {
        puts "ERROR: RD68011 not found at $rd68011"
        puts "       run: git submodule update --init Inputs/RD68011"
        exit 1
    }
    puts "== building with the RD68011 core from $rd68011 =="
    # Order from that project's own Makefile: the two packages first, then the
    # generated microcode, then the hand-written RTL.
    read_verilog -sv [list \
        $rd68011/rtl/rd68011_pkg.sv \
        $rd68011/rtl/gen/rd68011_ucode_pkg.sv \
        $rd68011/rtl/gen/rd68011_decode_rom.sv \
        $rd68011/rtl/gen/rd68011_loop_rom.sv \
        $rd68011/rtl/gen/rd68011_ucode_rom.sv \
        $rd68011/rtl/rd68011_dedge_ff.sv \
        $rd68011/rtl/rd68011_sync.sv \
        $rd68011/rtl/rd68011_alu.sv \
        $rd68011/rtl/rd68011_shifter.sv \
        $rd68011/rtl/rd68011_mul.sv \
        $rd68011/rtl/rd68011_divider.sv \
        $rd68011/rtl/rd68011_biu.sv \
        $rd68011/rtl/rd68011_seq.sv \
        $rd68011/rtl/rd68011_top.sv \
    ]
} else {
    read_vhdl -vhdl2008 [list \
        $top/build/inputs/Suska_Configware/68K10/wf68k10_pkg.vhd \
        $top/build/inputs/Suska_Configware/68K10/wf68k10_address_registers.vhd \
        $top/build/inputs/Suska_Configware/68K10/wf68k10_alu.vhd \
        $top/build/inputs/Suska_Configware/68K10/wf68k10_bus_interface.vhd \
        $top/build/inputs/Suska_Configware/68K10/wf68k10_control.vhd \
        $top/build/inputs/Suska_Configware/68K10/wf68k10_data_registers.vhd \
        $top/build/inputs/Suska_Configware/68K10/wf68k10_exception_handler.vhd \
        $top/build/inputs/Suska_Configware/68K10/wf68k10_opcode_decoder.vhd \
        $top/build/inputs/Suska_Configware/68K10/wf68k10_top.vhd \
    ]
}

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
    $top/rtl/sun2-common/sun2_fb_ctl.v \
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
    $top/rtl/sun2-multibus/sun2_xy450.sv \
    $top/build/inputs/Wish5380/src/wish5380_pkg.sv \
    $top/build/inputs/Wish5380/src/sd_spi.sv \
    $top/build/inputs/Wish5380/src/blk_sd.sv \
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

# The ILA, the same way and for the same reason.
if {$ila == 1} {
    set ilaxci $ipdir/sun2_ila/sun2_ila.xci
    if {![file exists $ilaxci]} {
        puts "ERROR: the ILA has not been generated. Run:"
        puts "    make -C syn ip-ila BOARD=$board"
        exit 1
    }
    read_ip $ilaxci
    if {[llength [get_ips sun2_ila]] == 0} {
        puts "ERROR: sun2_ila.xci did not load"
        exit 1
    }
    synth_ip [get_ips sun2_ila]
    puts "== ILA fitted on the MMU debug bus =="
}

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

# Only when there is a disk: the sd_* ports on wukong_top exist only then, and
# where they go differs by board -- J9 on a V3, a PMOD on a V1, which has no
# card slot of its own.
if {$xy450 == 1} {
    read_xdc $here/wukong_sd_$board.xdc
    puts "== read wukong_sd_$board.xdc =="
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

# The debug hub is inserted here, not by anything above: an IP-instantiated ILA
# has no hub of its own, and opt_design adds one and connects it to the ILA's
# clock.  That is the wrong clock.  cpu_clk is 20 MHz and a hub wants at least
# 2.5x the JTAG clock, and it will not even be told 20 MHz -- the property
# takes 25 MHz to 650 MHz and rejects anything slower outright.
#
# So the hub is moved onto clk50, which the board oscillator drives through an
# explicit BUFG and which exists in every configuration.  A hub and the cores
# it serves are allowed to be in different clock domains -- that is what the
# per-core clock is for -- so the ILA goes on sampling cpu_clk, one sample per
# CPU clock, which is the whole point of it.
#
# Declaring 25 MHz and leaving the hub on cpu_clk would also have built.  It
# would also have been a lie, and the thing it lies about is exactly what
# decides whether the hub answers JTAG at all.
if {$ila == 1} {
    set hub [get_debug_cores -quiet dbg_hub]
    if {[llength $hub] == 0} {
        puts "ERROR: ILA=1 but opt_design inserted no dbg_hub"
        exit 1
    }
    set hubclk [get_nets -quiet -hierarchical clk50_g]
    if {[llength $hubclk] == 0} {
        puts "ERROR: no clk50_g net to clock the debug hub from"
        exit 1
    }
    disconnect_debug_port dbg_hub/clk
    connect_debug_port dbg_hub/clk [lindex $hubclk 0]
    set_property C_CLK_INPUT_FREQ_HZ  50000000 $hub
    set_property C_ENABLE_CLK_DIVIDER false    $hub
    # opt_design generated the hub before any of that; re-run the step that
    # generates it, or place_design stops with "debug core instances ... needs
    # to be (re)generated" and names dbg_hub.
    implement_debug_core
    puts "== dbg_hub on clk50_g at 50 MHz; the ILA still samples cpu_clk =="
}

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

# Setup and hold are not the whole of timing, and this gate used to think they
# were.  A clock can be inside every data path's budget and still be faster
# than the buffer carrying it: the HDMI 5x clock ran a BUFG at 742 MHz against
# its rated 628, reported as a pulse width violation -- Min Period, slack
# -0.245 ns, nine endpoints -- and sailed through a check that only looked at
# WNS and WHS.  The board showed it as a monitor that would not lock.
set pwbad {}
foreach line [split [report_pulse_width -all_violators -return_string] "\n"] {
    if {[regexp {^\s*(Min Period|Max Period|Low Pulse Width|High Pulse Width|Max Skew)\s} $line] &&
        [regexp {\s(-\d+\.\d+)\s} $line -> sl]} {
        lappend pwbad [string trim $line]
    }
}
if {[llength $pwbad]} {
    puts "ERROR: pulse width / period violations -- a clock is faster than the"
    puts "       resource carrying it, whatever the data paths say:"
    foreach l $pwbad { puts "         $l" }
    exit 1
}
puts "== pulse width and period checks clean =="

if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met (WNS $wns, WHS $whs); see $outdir/timing.rpt"
    exit 1
}

write_bitstream -force $outdir/sun2_wukong_$board.bit
puts "== wrote $outdir/sun2_wukong_$board.bit =="

# The probe file.  Without it the Hardware Manager finds the debug hub, cannot
# name anything on it, and shows probe0..probe7 as anonymous buses -- so this
# is not optional, it is half the instrument.
if {$ila == 1} {
    write_debug_probes -force $outdir/sun2_wukong_$board.ltx
    puts "== wrote $outdir/sun2_wukong_$board.ltx =="
}
