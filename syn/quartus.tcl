# Build the Sun-2 for an Altera board with Quartus Prime.
#
#   quartus_sh -t quartus.tcl -root <dir> [-name value ...]
#
# The twin of build.tcl, which does the same job under Vivado.  Everything
# below boards/ is shared between the two: rtl/ contains no vendor primitive
# and no vendor IP, and this script is one half of the evidence for that claim.
#
# Arguments, all optional except -root:
#
#   -root      the repository root (required)
#   -board     deca                     which Altera board
#   -machine   vme | multibus           which Sun-2
#   -cpu       rd68011 | suska          which MC68010
#   -topent    top | deca_top           entity to build; `top' is the machine
#                                       seam on its own, with no board around
#                                       it, which is how the RTL gets read by
#                                       Quartus before any board layer exists
#   -stage     map | fit | asm          how far to go
#   -mem_pages <n>                      2 KiB pages of main memory
#   -cpu_hz    <hz>                     CPU clock
#   -cpu_div   <n>                      ... or name the PLL divider directly.
#                                       Wins over -cpu_hz, which is then
#                                       derived from it.
#   -eth5      <n>                      last byte of the ID PROM MAC
#   -eram      0 | 1                    the assignment below.  It is a knob
#                                       ONLY so that its effect can be measured
#                                       rather than assumed; builds use 1.
#   -jobs      <n>                      parallel processors
#   -outdir    <dir>                    where to work
#
package require ::quartus::project
package require ::quartus::flow

set here [file dirname [file normalize [info script]]]
source $here/boards.tcl

# ---------------------------------------------------------------- arguments
array set opt {
    -board     deca
    -machine   vme
    -cpu       rd68011
    -topent    top
    -stage     map
    -mem_pages 32
    -cpu_hz    12500000
    -cpu_div   0
    -eth5      224
    -eram      1
    -jobs      8
    -root      ""
    -outdir    ""
}
foreach {k v} $argv {
    if {![info exists opt($k)]} {
        puts "ERROR: unknown argument '$k'"
        exit 1
    }
    set opt($k) $v
}
if {$opt(-root) eq ""} { puts "ERROR: -root is required"; exit 1 }
set top $opt(-root)

board_check $opt(-board)
if {[board_vendor $opt(-board)] ne "altera"} {
    puts "ERROR: BOARD=$opt(-board) is a [board_vendor $opt(-board)] board; this"
    puts "       is the Quartus flow.  Use: make -C syn bitstream BOARD=$opt(-board)"
    exit 1
}

# ------------------------------------------------------------------ defines
#
# Assembled the same way build.tcl:95-250 does, and deliberately in the same
# order, so the two flows can be diffed against each other by eye.
switch -- $opt(-machine) {
    multibus { set defines [list SUN2_MULTIBUS] }
    vme      { set defines [list SUN2_VME] }
    default  { puts "ERROR: MACHINE must be multibus or vme"; exit 1 }
}

# The Sun-2's $fatal guards on impossible configurations live in an initial
# block (sun2_fpga.v:135-183) and Quartus discards system tasks, so they are
# not enforced on this path.  The ones that matter are repeated here as Tcl,
# where they are enforced.  This is the same job build.tcl:133-189 does for
# Vivado, and arguably where the checks belonged in the first place.
if {$opt(-machine) ne "multibus" && [lsearch $defines SUN2_MB_ETHER] >= 0} {
    puts "ERROR: the MultiBus Ethernet card only exists on a 2/120"
    exit 1
}
if {$opt(-mem_pages) < 8 || $opt(-mem_pages) > 4096} {
    puts "ERROR: -mem_pages $opt(-mem_pages) is outside 8..4096"
    exit 1
}

# CPU_DIV wins over CPU_HZ, and the reported frequency is recomputed from it --
# the same rule build.tcl follows, and for the reason recorded there: a banner
# saying 20000000 Hz over a build running at VCO/51 is a lie that survives into
# every measurement taken from it.
if {$opt(-cpu_div) != 0} {
    set opt(-cpu_hz) [expr {1000000000 / $opt(-cpu_div)}]
}

lappend defines MEM_PAGES=$opt(-mem_pages)
lappend defines SUN2_QUARTUS
if {$opt(-eth5) != 224} { lappend defines SUN2_IDPROM_ETH5=$opt(-eth5) }
if {$opt(-cpu) eq "rd68011"} { lappend defines SUN2_CPU_RD68011 }

# The RTC's power-up date, pinned by RTC_DATE when a build has to be
# reproducible -- the same escape hatch build.tcl:110-113 offers, and the one
# that makes "did this change alter the netlist?" answerable.
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
foreach {n v} [list SUN2_RTC_MON  [lindex $rtc 0] SUN2_RTC_DAY  [lindex $rtc 1] \
                    SUN2_RTC_WDAY [lindex $rtc 2] SUN2_RTC_HOUR [lindex $rtc 3] \
                    SUN2_RTC_MIN  [lindex $rtc 4] SUN2_RTC_SEC  [lindex $rtc 5]] {
    lappend defines $n=$v
}

# Echo the resolved configuration, for the reason build.tcl:455 gives: what was
# passed on a command line and what the logic was built with are different
# facts, and this project has shipped three builds where they disagreed.
puts "== Sun-2 for [board_family $opt(-board)] [board_device $opt(-board)] ([board_vendor $opt(-board)]) =="
puts "== board $opt(-board), machine $opt(-machine), core $opt(-cpu), entity $opt(-topent) =="
puts "== memory $opt(-mem_pages) pages = [expr {$opt(-mem_pages) * 2}] KiB =="
if {$opt(-cpu_div) != 0} {
    puts "== CPU clock $opt(-cpu_hz) Hz (VCO/$opt(-cpu_div)) =="
} else {
    puts "== CPU clock $opt(-cpu_hz) Hz =="
}
puts "== defines: $defines =="
puts "== eram: $opt(-eram) =="

# ------------------------------------------------------------------ project
project_new sun2 -overwrite

set_global_assignment -name FAMILY               [board_family $opt(-board)]
set_global_assignment -name DEVICE               [board_device $opt(-board)]
set_global_assignment -name TOP_LEVEL_ENTITY     $opt(-topent)

# The knob has to reach the logic, not just the build.  This project has shipped
# three builds whose banner and whose gateware disagreed -- fb_video_en never
# connected, HDMI30=1 read by no file, CPU_DIV declared on the clkgen and not
# forwarded past the top -- and this flow accepted -cpu_hz and passed it to
# nothing at all for the whole of the port.  set_parameter reaches the top-level
# entity's parameters; deca_top forwards both to deca_clkgen.
if {$opt(-topent) ne "top"} {
    set_parameter -name CPU_CLK_HZ $opt(-cpu_hz)
    set_parameter -name CPU_DIV    $opt(-cpu_div)
}
set_global_assignment -name NUM_PARALLEL_PROCESSORS $opt(-jobs)

# --- the trap that emits no warning ---------------------------------------
#
# MAX 10 loads its embedded RAM from the configuration flash, and only does so
# when the image is built to carry the contents.  Without this assignment
# Quartus silently implements every *initialised* memory in logic: RD68011's
# microcode store came out at 23,696 logic elements and 0 memory bits with no
# complaint at all, and no attribute -- ramstyle, romstyle, M9K -- changed it.
# Here the exposure is rtl/sun2-common/bootrom.v, a 16384-entry case inside an
# always @(posedge CLK), which is 262,144 bits and will not fit in logic.
#
# sram_sync.v is *uninitialised* RAM and infers either way; the boot PROM is
# the whole risk, and its failure mode is a fit that simply does not close
# rather than anything that says what went wrong.
#
# The knob exists so the effect can be measured.  Build once with -eram 0 and
# once with 1 and compare the memory-bit count: an assignment whose effect has
# never been observed is decoration.
if {$opt(-eram)} {
    set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE COMP IMAGE WITH ERAM"
}

# Bank 8 runs at 1.2 V for the LEDs, which requires the configuration pins to
# be given up (Inputs/doc/DECA_board/Templates/deca-template-full/deca_top.qsf).
# The board is then JTAG-only, which is what the plan assumes anyway.
set_global_assignment -name USE_CONFIGURATION_DEVICE   OFF
set_global_assignment -name AUTO_RESTART_CONFIGURATION OFF
set_global_assignment -name ENABLE_CONFIGURATION_PINS  OFF
set_global_assignment -name ENABLE_BOOT_SEL_PIN        OFF

# Quartus has no per-register ASYNC_REG; this is the global equivalent and it
# is what rtl/sun2-common/sun2_attr.vh's Quartus arm relies on.
set_global_assignment -name SYNCHRONIZER_IDENTIFICATION "FORCED IF ASYNCHRONOUS"

# `include search path -- Vivado's -include_dirs.  build/rom holds the
# generated boot PROM body, which bootrom.v includes by macro.
set_global_assignment -name SEARCH_PATH $top/rtl/sun2-common
set_global_assignment -name SEARCH_PATH $top/build/rom

foreach d $defines { set_global_assignment -name VERILOG_MACRO $d }

# -------------------------------------------------------------------- files
#
# NOTE: this list duplicates build.tcl's, which duplicates the three in sim/.
# That is five copies and it is a known debt -- the plan is to factor them into
# one syn/sources.tcl once this flow is green, as its own change with its own
# gate.  Doing it first would mean debugging a refactor and a new toolchain at
# the same time.

# The Sun-2 gateware is Verilog-2001 and must not be read as SystemVerilog.
set v2001 [list \
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
]

set sv [list \
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
    $top/build/inputs/z8530_scc/z8530_scc.sv \
]

# tolog.v is a VCD hook with no body -- an empty module, which Vivado calls a
# black box and opt_design refuses to run on (CLAUDE.md records this costing an
# ILA build).  It is behind SUN2_SIM there; here it is simply not read.

if {$opt(-machine) eq "multibus"} {
    lappend sv $top/rtl/sun2-multibus/sun2_mb_ether.sv \
               $top/rtl/sun2-multibus/sun2_xy450.sv
}

# The CPU core.
if {$opt(-cpu) eq "rd68011"} {
    set rd $top/Inputs/RD68011
    foreach f [list rtl/rd68011_pkg.sv rtl/gen/rd68011_ucode_pkg.sv \
                    rtl/gen/rd68011_decode_rom.sv rtl/gen/rd68011_loop_rom.sv \
                    rtl/gen/rd68011_ucode_rom.sv rtl/gen/rd68011_uctl_rom.sv \
                    rtl/gen/rd68011_urq_rom.sv rtl/rd68011_dedge_ff.sv \
                    rtl/rd68011_sync.sv rtl/rd68011_alu.sv rtl/rd68011_shifter.sv \
                    rtl/rd68011_mul.sv rtl/rd68011_divider.sv rtl/rd68011_biu.sv \
                    rtl/rd68011_seq.sv rtl/rd68011_top.sv] {
        lappend sv $rd/$f
    }
} else {
    puts "ERROR: only -cpu rd68011 is supported on Altera so far."
    puts "       Suska is VHDL and needs its own file list; RD68011 is also"
    puts "       the only core with measured MAX 10 numbers."
    exit 1
}

# The board layer, when building a whole board rather than the bare seam.
if {$opt(-topent) ne "top"} {
    foreach f [lsort [glob -nocomplain $top/boards/DECA/*.sv]] { lappend sv $f }

    # The JTAG UART, straight out of the Quartus installation.  No Platform
    # Designer, no .qsys, no qsys-generate: it is a plain Avalon-MM slave in
    # SystemVerilog, and the alt_jtag_atlantic primitive and its two scfifos
    # sit behind Quartus's own "read_comments_as_HDL" directive, which the
    # compiler resolves from its megafunction library at analysis time.
    #
    # This file must therefore NEVER enter the Vivado or xsim file lists --
    # read_comments_as_HDL is Quartus-only, and elsewhere it elaborates to a
    # UART whose Atlantic port is tied off, i.e. a console that compiles and
    # cannot work.  deca_jtag_console.sv guards the instance with SUN2_SIM for
    # the same reason.
    # The DDR3 controller.  Read from Inputs/ directly: it is immutable and
    # unpatched.  If it ever needs a change that goes in patches/BrianHG-DDR3/
    # and this reads build/inputs/ instead, the rule the whole tree follows.
    set bhg $top/Inputs/BrianHG-DDR3/BrianHG_DDR3
    foreach f [list BrianHG_DDR3_CONTROLLER_v16_top.sv BrianHG_DDR3_COMMANDER_v16.sv \
                    BrianHG_DDR3_CMD_SEQUENCER_v16.sv BrianHG_DDR3_PHY_SEQ_v16.sv \
                    BrianHG_DDR3_PLL.sv BrianHG_DDR3_GEN_tCK.sv \
                    BrianHG_DDR3_FIFOs.sv BrianHG_DDR3_IO_PORT_ALTERA.sv \
                    altera_gpio_lite.sv] {
        if {![file exists $bhg/$f]} {
            puts "ERROR: the DDR3 controller is missing: $bhg/$f"
            puts "       run: git submodule update --init Inputs/BrianHG-DDR3"
            exit 1
        }
        lappend sv $bhg/$f
    }
    set_global_assignment -name SEARCH_PATH $bhg

    set juart $::env(QUARTUS_ROOTDIR)/../ip/altera/sopc_builder_ip/altera_avalon_jtag_uart
    foreach f [list altera_avalon_jtag_uart.sv \
                    altera_avalon_jtag_uart_scfifo_r.sv \
                    altera_avalon_jtag_uart_scfifo_w.sv] {
        if {![file exists $juart/$f]} {
            puts "ERROR: the JTAG UART IP is missing: $juart/$f"
            puts "       That is the console; a build without it has none."
            exit 1
        }
        lappend sv $juart/$f
    }
}

foreach f $v2001 {
    if {![file exists $f]} { puts "ERROR: missing source $f"; exit 1 }
    set_global_assignment -name VERILOG_FILE $f
}
foreach f $sv {
    if {![file exists $f]} { puts "ERROR: missing source $f"; exit 1 }
    set_global_assignment -name SYSTEMVERILOG_FILE $f
}

# Pins and timing only make sense for a real board top.  Building the bare seam
# leaves every port unplaced, which is what we want: it is a syntax and
# inference check, not a fit.
if {$opt(-topent) ne "top"} {
    set_global_assignment -name SDC_FILE $here/deca.sdc
    source $here/deca_pins.qsf
    source $here/deca_ddr3_pins.qsf
}

export_assignments

# ------------------------------------------------------------------- stages
if {[catch {execute_module -tool map} err]} {
    puts "== analysis & synthesis FAILED =="
    puts $err
    project_close
    exit 1
}
puts "== analysis & synthesis ok =="

# The console is the only instrument this board has: no serial port, no display
# yet.  A build where SUN2_SIM leaked, or where the IP silently failed to come
# in, is a clean build with no way to talk to the machine -- the same shape as
# the vanished frame buffer that build.tcl now guards against.  So assert the
# primitive is really there.
if {$opt(-topent) ne "top"} {
    set n [llength [get_names -filter *alt_jtag_atlantic* -node_type comb]]
    if {$n == 0} {
        # get_names needs a compiled netlist; fall back to the report, which is
        # written by this point either way.
        set rpt [glob -nocomplain sun2.map.rpt]
        if {[llength $rpt] && ![regexp {alt_jtag_atlantic} [read [open [lindex $rpt 0]]]]} {
            puts "ERROR: no alt_jtag_atlantic in the netlist -- the console is"
            puts "       missing.  Check SUN2_SIM did not leak into this build."
            exit 1
        }
    }
    puts "== console: alt_jtag_atlantic present =="
}

if {$opt(-stage) eq "map"} { project_close; exit 0 }

if {[catch {execute_module -tool fit} err]} {
    puts "== fit FAILED =="; puts $err; project_close; exit 1
}
puts "== fit ok =="

if {[catch {execute_module -tool sta} err]} {
    puts "== timing analysis FAILED =="; puts $err; project_close; exit 1
}
puts "== sta ok =="

# What the PLLs were actually programmed with, and what the design closes at.
# A comment claiming 12.5 MHz and 4.915254 MHz is not a measurement -- and this
# is the flow where CPU_HZ finally reaches something, so it is the first build
# in which that knob can be wrong in a way that matters.
if {[file exists sun2.sta.rpt]} {
    set fh [open sun2.sta.rpt]; set sta [read $fh]; close $fh
    foreach line [split $sta "\n"] {
        if {[regexp {^; *([^;]*pll_[ab][^;]*) *; *Generated *; *([0-9.]+) *; *([0-9.]+ [Mk]Hz)} \
                 $line -> nm pd fq]} {
            puts "== clock [string trim $nm]: [string trim $pd] ns, [string trim $fq] =="
        }
    }
    # Fmax and the worst slack, which is the number this whole port has been
    # heading towards: a MAX 10 running a 68010 at all.
    set inf 0
    foreach line [split $sta "\n"] {
        if {[regexp {Slow 1200mV 85C Model Fmax Summary} $line]} { set inf 1 }
        if {$inf && [regexp {^; *([0-9.]+ MHz) *; *([0-9.]+ MHz) *; *([^;]+) *;} $line -> f rf cn]} {
            puts "== Fmax [string trim $cn]: [string trim $f] (restricted [string trim $rf]) =="
        }
    }
}

if {$opt(-stage) eq "fit"} { project_close; exit 0 }

# The assembler is run even with no cable attached: it is the only end-to-end
# check that the configuration image can actually carry the initialised RAM
# contents, which is what INTERNAL_FLASH_UPDATE_MODE above is for.
if {[catch {execute_module -tool asm} err]} {
    puts "== assembler FAILED =="; puts $err; project_close; exit 1
}
puts "== assembler ok =="

project_close
