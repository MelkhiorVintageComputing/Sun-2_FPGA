# Build the standalone DECA DDR3 test.
#
#   quartus_sh -t build.tcl <repo-root> <outdir>
#
# BrianHG's controller, the DECA's own DDR3, and a write/read/verify walk.
# No Sun-2.  See README.md.

package require ::quartus::project
package require ::quartus::flow

set root   [lindex $argv 0]
set outdir [lindex $argv 1]
set here   [file dirname [info script]]

puts "== DECA DDR3 test: MAX 10 10M50DAF484C6GES =="

project_new ddr3_test -overwrite

set_global_assignment -name FAMILY           "MAX 10"
set_global_assignment -name DEVICE           10M50DAF484C6GES
set_global_assignment -name TOP_LEVEL_ENTITY deca_ddr3_test_top
set_global_assignment -name NUM_PARALLEL_PROCESSORS 8

# Same device options as the machine build: bank 8 at 1.2 V for the LEDs costs
# the configuration pins, and the board is JTAG-only as a result.
set_global_assignment -name USE_CONFIGURATION_DEVICE   OFF
set_global_assignment -name AUTO_RESTART_CONFIGURATION OFF
set_global_assignment -name ENABLE_CONFIGURATION_PINS  OFF
set_global_assignment -name ENABLE_BOOT_SEL_PIN        OFF
set_global_assignment -name SYNCHRONIZER_IDENTIFICATION "FORCED IF ASYNCHRONOUS"

# MAX 10 loads embedded RAM from configuration flash and only does so when the
# image is built to carry it.  The DDR3 controller's FIFOs are initialised
# memory, so without this the assembler stops with
#
#   Error (14703): Invalid internal configuration mode for design with memory
#   initialization
#
# I first wrote this file asserting the opposite -- "this design has no
# initialised memory in it at all" -- and quartus_asm disproved it in one run.
# Which is the argument for running the assembler even with no cable attached:
# it is the only stage that tests the configuration image end to end, and it is
# the stage this project's biggest silent trap lives in.
set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE COMP IMAGE WITH ERAM"

# The controller's own sources, read from Inputs/ directly.  It is immutable and
# unpatched so far; if it ever needs a change, that goes in patches/BrianHG-DDR3/
# and this reads build/inputs/ instead -- the rule the whole tree follows.
set bhg $root/Inputs/BrianHG-DDR3/BrianHG_DDR3
foreach f [list BrianHG_DDR3_CONTROLLER_v16_top.sv \
                BrianHG_DDR3_COMMANDER_v16.sv \
                BrianHG_DDR3_CMD_SEQUENCER_v16.sv \
                BrianHG_DDR3_PHY_SEQ_v16.sv \
                BrianHG_DDR3_PLL.sv \
                BrianHG_DDR3_GEN_tCK.sv \
                BrianHG_DDR3_FIFOs.sv \
                BrianHG_DDR3_IO_PORT_ALTERA.sv \
                altera_gpio_lite.sv] {
    if {![file exists $bhg/$f]} { puts "ERROR: missing $bhg/$f"; exit 1 }
    set_global_assignment -name SYSTEMVERILOG_FILE $bhg/$f
}
set_global_assignment -name SEARCH_PATH $bhg

set_global_assignment -name SYSTEMVERILOG_FILE $here/deca_ddr3_test_top.sv
set_global_assignment -name SDC_FILE           $here/ddr3_test.sdc
source $here/ddr3_pins.qsf

export_assignments

foreach stage {map fit sta asm} {
    if {[catch {execute_module -tool $stage} err]} {
        puts "== $stage FAILED =="; puts $err; project_close; exit 1
    }
    puts "== $stage ok =="
}

# The DDR3 clock is the whole point; report what the PLL was actually given.
if {[file exists ddr3_test.sta.rpt]} {
    set fh [open ddr3_test.sta.rpt]; set sta [read $fh]; close $fh
    foreach line [split $sta "\n"] {
        if {[regexp {^; *([^;]*pll[^;]*) *; *Generated *; *([0-9.]+) *; *([0-9.]+ [Mk]Hz)} \
                 $line -> nm pd fq]} {
            puts "== clock [string trim $nm]: [string trim $pd] ns, [string trim $fq] =="
        }
    }
}

project_close
