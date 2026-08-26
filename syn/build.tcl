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
set hdmimode 1280x1024
set fbdebug  0
set allowpw  0
set fbprobe  0
set fbforce  0
set eth5     224
set cpu_div  0
if {[llength $argv] > 0} { set cpu_hz   [lindex $argv 0] }
if {[llength $argv] > 1} { set machine  [lindex $argv 1] }
if {[llength $argv] > 2} { set mb_ether [lindex $argv 2] }
if {[llength $argv] > 3} { set board    [lindex $argv 3] }
if {[llength $argv] > 4} { set fb       [lindex $argv 4] }
if {[llength $argv] > 5} { set xy450    [lindex $argv 5] }
if {[llength $argv] > 6} { set cpu      [lindex $argv 6] }
if {[llength $argv] > 7} { set ila      [lindex $argv 7] }
if {[llength $argv] > 8} { set hdmimode [lindex $argv 8] }
if {[llength $argv] > 9} { set fbdebug  [lindex $argv 9] }
if {[llength $argv] > 10} { set allowpw [lindex $argv 10] }
if {[llength $argv] > 11} { set fbprobe [lindex $argv 11] }
if {[llength $argv] > 12} { set fbforce [lindex $argv 12] }
if {[llength $argv] > 13} { set eth5    [lindex $argv 13] }
if {[llength $argv] > 14} { set cpu_div [lindex $argv 14] }
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

# The last byte of the ID PROM's Ethernet address.  224 (0xe0) is the identity
# this project has always presented; a different one is how the board asks a
# boot server for a different root.  The ID PROM checksum follows from it
# automatically, so only this one byte moves.
if {$eth5 != 224} {
    lappend defines SUN2_IDPROM_ETH5=$eth5
}

# The time-of-day clock's power-up value.  A real MM58167 has a battery; this
# one starts at whatever is baked in, so bake in the build date and a board
# comes up roughly right with no network.  Note this makes two bitstreams built
# from identical sources differ, in the RTC's reset constants only -- set
# RTC_DATE to a fixed "MM DD WD HH MM SS" to defeat that.
if {[info exists ::env(RTC_DATE)]} {
    set rtc [split $::env(RTC_DATE)]
} else {
    set now [clock seconds]
    set rtc [list [scan [clock format $now -format %m] %d] \
		 [scan [clock format $now -format %d] %d] \
		 [expr {[clock format $now -format %w] + 1}] \
		 [scan [clock format $now -format %H] %d] \
		 [scan [clock format $now -format %M] %d] \
		 [scan [clock format $now -format %S] %d]]
}
foreach {n v} [list SUN2_RTC_MON  [lindex $rtc 0] \
		   SUN2_RTC_DAY  [lindex $rtc 1] \
		   SUN2_RTC_WDAY [lindex $rtc 2] \
		   SUN2_RTC_HOUR [lindex $rtc 3] \
		   SUN2_RTC_MIN  [lindex $rtc 4] \
		   SUN2_RTC_SEC  [lindex $rtc 5]] {
    lappend defines $n=$v
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

# The video mode, which on this part is a question about the TMDS serial clock
# and not about the picture.  1080p60 needs 742 MHz out of a global buffer that
# is rated for 628 and an OSERDESE2 rated for 680; it works with little else in
# the die -- test/hdmi proves that on this board and monitor -- and it does not
# work in the full machine, which drives 720p60's 371 MHz perfectly on the same
# bench.  So the default is the mode the board is wired for, and the working
# answer is the one that fits 1152x900 inside every rating:
#
#   1280x1024  1688x1066, 108.125 / 540.625 MHz, VESA DMT rather than CEA.
#              **The default.**  Inside every rating, and 1152x900 fits with a
#              64x62 border.
#   1080p60    2200x1125, 148.4375 / 742.1875 MHz.  Needs ALLOW_PW=1, and does
#              not work in the full design; see the trap in CLAUDE.md.
#   1080p30    the *same* raster at half the clock.  Not every sink takes it:
#              the monitor on this bench rejects 30 Hz outright.
#   720p60     1650x750 at the same half clock, a raster more sinks accept.
#              Diagnostic only -- 900 lines do not fit in 720 -- so FBDEBUG=1.
#
# Only when there is a display to apply it to.  Without FB=1 the mode is not a
# question at all -- every consumer of these defines is inside `ifdef SUN2_FB --
# and the check this replaces was "you asked for a mode with no display to put
# it on", which was fair while the default was 1080p60 and became a refusal to
# build anything without FB=1 the moment the default became 1280x1024.  That is
# every regression bitstream this tree makes, and it broke them all.
if {$fb == 1} {
 switch -- $hdmimode {
    1080p60   { }
    1080p30   { lappend defines SUN2_HDMI_HALFRATE }
    1280x1024 { lappend defines SUN2_HDMI_SXGA }
    720p60    {
        if {$fbdebug != 1} {
            puts "ERROR: HDMI_MODE=720p60 needs FBDEBUG=1 -- 1152x900 does not"
            puts "       fit in 720 lines, so there is no honest way to show"
            puts "       the frame buffer at that raster"
            exit 1
        }
        lappend defines SUN2_HDMI_HALFRATE
        lappend defines SUN2_HDMI_720P
    }
    default {
        puts "ERROR: HDMI_MODE must be 1080p60, 1080p30, 720p60 or 1280x1024,"
        puts "       not '$hdmimode'"
        exit 1
    }
 }
}

# FBDEBUG=1: drive the display from a test pattern rather than fb_scanout, and
# put the video domain on the LED header in place of todebug.  For finding out
# why a display that test/hdmi drives happily shows nothing from the Sun-2.
if {$fbdebug == 1} {
    if {$fb != 1} {
        puts "ERROR: FBDEBUG needs FB=1"
        exit 1
    }
    lappend defines SUN2_FB_DEBUG
}

# FBPROBE=1: the real display, with the path to it on the LED header instead
# of todebug.  For a screen that is black inside a raster the monitor accepts,
# which is what every link in the chain looks like from outside -- DISPEN, the
# fetch, the answer, the data, the pixel.  One latch each; see wukong_top.sv.
if {$fbprobe == 1} {
    if {$fb != 1} {
        puts "ERROR: FBPROBE needs FB=1"
        exit 1
    }
    if {$fbdebug == 1} {
        puts "ERROR: FBPROBE and FBDEBUG both drive extra_leds0; pick one"
        exit 1
    }
    lappend defines SUN2_FB_PROBE
}

# FBFORCE=1: tie the scan-out's DISPEN high, leaving the video control
# register itself alone.  Diagnostic: it asks whether everything downstream of
# DISPEN works, without waiting to find out why the machine has not set it.
if {$fbforce == 1} {
    if {$fb != 1} {
        puts "ERROR: FBFORCE needs FB=1"
        exit 1
    }
    lappend defines SUN2_FB_FORCE_EN
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
# NOTE: this expression is duplicated in syn/Makefile as OUTDIR, and the two
# MUST agree.  When they disagreed -- a knob added to the Makefile and not here
# -- make reported one path while Vivado wrote to another, quietly overwriting
# the bitstream the new knob existed to leave alone.  Add to both, or to
# neither.
set outdir  $top/build/syn/$board-$machine[expr {$mb_ether == 1 ? "-mbether" : ""}][expr {$fb == 1 ? "-fb" : ""}][expr {$xy450 == 1 ? "-xy450" : ""}]-cpu[expr {$cpu_hz / 1000000}][expr {$cpu ne "suska" ? "-$cpu" : ""}][expr {$ila == 1 ? "-ila" : ""}][expr {$fb == 1 ? "-$hdmimode" : ""}][expr {$fbdebug == 1 ? "-fbdbg" : ""}][expr {$fbprobe == 1 ? "-fbprobe" : ""}][expr {$fbforce == 1 ? "-fbforce" : ""}][expr {$eth5 != 224 ? [format "-eth%02x" $eth5] : ""}][expr {$cpu_div != 0 ? "-div$cpu_div" : ""}]
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
    $top/rtl/sun2-common/mm58167.v \
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
    $top/build/inputs/z8530_scc/z8530_scc.sv \
    $top/boards/Wukong/wukong_clkgen.sv \
    $top/boards/Wukong/hdmi_clkgen.sv \
    $top/boards/Wukong/reset_sync.sv \
    $top/boards/Wukong/wb_to_mig_ui.sv \
    $top/boards/Wukong/mig_arb.sv \
    $top/boards/Wukong/fb_scanout.sv \
    $top/build/inputs/hdmi/src/tmds_channel.sv \
    $top/build/inputs/hdmi/src/serializer.sv \
    $top/build/inputs/hdmi/src/packet_assembler.sv \
    $top/build/inputs/hdmi/src/packet_picker.sv \
    $top/build/inputs/hdmi/src/audio_clock_regeneration_packet.sv \
    $top/build/inputs/hdmi/src/audio_info_frame.sv \
    $top/build/inputs/hdmi/src/audio_sample_packet.sv \
    $top/build/inputs/hdmi/src/auxiliary_video_information_info_frame.sv \
    $top/build/inputs/hdmi/src/source_product_description_info_frame.sv \
    $top/build/inputs/hdmi/src/hdmi.sv \
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
# Echo what the knobs actually resolved to.  A define that is appended and read
# by nothing, or -- worse -- one that is *not* appended, produces a bitstream
# that builds cleanly, passes every gate below and quietly has a whole
# subsystem missing.  Both have happened here: SUN2_HDMI_30HZ was consumed by
# no file for the life of the knob, and a refactor of this block once dropped
# SUN2_FB, giving a build with no frame buffer, no HDMI, no keyboard SCC and no
# driver at all on extra_leds0 -- which read on the bench as three unrelated
# faults.  One line makes it visible in the log.
puts "== defines: $defines =="

# An implicit net is how a whole feature reaches a board dead.  Vivado's
# default for an undeclared identifier is to invent a one-bit undriven wire and
# warn; `fb_video_en' was never connected at the machine instantiation, so the
# frame buffer's DISPEN was a constant 0 in every bitstream ever built, and the
# only symptom was a black screen.  Simulation could not catch it -- tb_sun2
# drives top_fpga directly, below the layer with the mistake in it.  Make it an
# error: a signal worth naming is worth declaring.
set_msg_config -id {Synth 8-6901} -new_severity ERROR

synth_design -top wukong_top -part $part \
    -include_dirs [list $top/rtl/sun2-common $top/build/rom] \
    -verilog_define $defines \
    -generic CPU_CLK_HZ=$cpu_hz \
    -generic CPU_DIV=$cpu_div \
    -directive Default

write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/post_synth_utilization.rpt
report_clocks      -file $outdir/clocks.rpt

# ... and check the headline feature is actually in the netlist, because the
# echo above only proves what was passed, not what was read.  The pulse width
# gate below cannot catch this: with no HDMI clock in the design there is
# nothing to violate, so a frame buffer that vanished reports "clean".
if {$fb == 1 && [llength [get_cells -quiet -hier -filter {NAME =~ *hdmiclk*}]] == 0} {
    puts "ERROR: FB=1 but the netlist has no HDMI clock generator."
    puts "       SUN2_FB did not reach the RTL, or hdmi_clkgen was optimised"
    puts "       away.  A bitstream from here has no display in it."
    exit 1
}

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
    if {$allowpw == 1} {
        # Knowingly, and only ever knowingly.  test/hdmi drives this same
        # block on this same board at 1080p60, violating the BUFG minimum
        # period by 245 ps, and a monitor synchronises on it and displays the
        # picture -- so the rating is conservative here and refusing the build
        # would cost the machine its display for no measured reason.  What
        # must not happen is that being forgotten, so it is a knob rather than
        # a deletion, and the violations are printed either way.
        puts "== pulse width / period violations, ALLOWED by ALLOW_PW=1 =="
        foreach l $pwbad { puts "     $l" }
        puts "== see test/hdmi/README.md for what was measured on the bench =="
    } else {
        puts "ERROR: pulse width / period violations -- a clock is faster than the"
        puts "       resource carrying it, whatever the data paths say:"
        foreach l $pwbad { puts "         $l" }
        puts "       ALLOW_PW=1 builds anyway, if you know why that is safe."
        exit 1
    }
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
