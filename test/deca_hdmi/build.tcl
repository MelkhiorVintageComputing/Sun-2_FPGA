# Build the standalone DECA HDMI test.
#
#   quartus_sh -t build.tcl <repo-root> <outdir> [clk_invert]
#
# The pixel PLL, the raster, the ADV7513 configuration, a test pattern, and
# nothing else.  No Sun-2, no DDR3, no console.
#
# It reads the *same* boards/DECA and rtl/sun2-common sources the real build
# reads, never copies -- the rule test/deca_console states and test/hdmi's
# Makefile explains: a test that reads its own copy vouches for the copy.

package require ::quartus::project
package require ::quartus::flow

set root   [lindex $argv 0]
set outdir [lindex $argv 1]
set invert [expr {[llength $argv] > 2 ? [lindex $argv 2] : 1}]

puts "== DECA HDMI test: MAX 10 10M50DAF484C6GES, CLK_INVERT $invert =="

project_new hdmi_test -overwrite

set_global_assignment -name FAMILY           "MAX 10"
set_global_assignment -name DEVICE           10M50DAF484C6GES
set_global_assignment -name TOP_LEVEL_ENTITY deca_hdmi_test_top
set_global_assignment -name NUM_PARALLEL_PROCESSORS 8

# Bank 8 is at 1.2 V for the LEDs, so the configuration pins have to go.  Same
# as the real build; if these differed the test would not be testing the same
# board.
set_global_assignment -name USE_CONFIGURATION_DEVICE   OFF
set_global_assignment -name AUTO_RESTART_CONFIGURATION OFF
set_global_assignment -name ENABLE_CONFIGURATION_PINS  OFF
set_global_assignment -name ENABLE_BOOT_SEL_PIN        OFF
set_global_assignment -name SYNCHRONIZER_IDENTIFICATION "FORCED IF ASYNCHRONOUS"

set_global_assignment -name SEARCH_PATH $root/rtl/sun2-common

set_parameter -name CLK_INVERT $invert

foreach f [list $root/boards/DECA/deca_vidclk.sv \
                $root/boards/DECA/deca_hdmi_out.sv \
                $root/boards/DECA/deca_adv7513_init.sv \
                $root/rtl/sun2-common/video_timing.sv \
                $root/rtl/sun2-common/reset_sync.sv \
                [file dirname [info script]]/deca_hdmi_test_top.sv] {
    if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
    set_global_assignment -name SYSTEMVERILOG_FILE $f
}

set_global_assignment -name SDC_FILE [file dirname [info script]]/hdmi_test.sdc
source [file dirname [info script]]/hdmi_test_pins.qsf

export_assignments

foreach stage {map fit sta asm} {
    if {[catch {execute_module -tool $stage} err]} {
        puts "== $stage FAILED =="; puts $err; project_close; exit 1
    }
    puts "== $stage ok =="
}

# This design is a transmitter configurator and a raster.  A build missing
# either would program, show nothing, and be blamed on the cable.
set rpt [read [open hdmi_test.map.rpt]]
foreach {needle what} {deca_adv7513_init "the I2C configuration sequencer"
                       video_timing       "the raster generator"} {
    if {![regexp $needle $rpt]} {
        puts "ERROR: $what is not in the netlist -- this design is nothing without it"
        exit 1
    }
}
puts "== netlist: sequencer and raster both present =="

# What the PLL was actually programmed with.  deca_vidclk asks for 54/25 from
# 50 MHz and claims 108.000 MHz; the solver is free to round or reject that, and
# a comment is not a measurement.  quartus_sta has already written the answer.
if {[file exists hdmi_test.sta.rpt]} {
    set fh [open hdmi_test.sta.rpt]; set sta [read $fh]; close $fh
    set found 0
    foreach line [split $sta "\n"] {
        if {[regexp {^; *([^;]*pll_v[^;]*) *; *Generated *; *([0-9.]+) *; *([0-9.]+ [Mk]Hz)} \
                 $line -> nm pd fq]} {
            puts "== pixel clock [string trim $nm]: [string trim $pd] ns, [string trim $fq] =="
            set found 1
        }
    }
    if {!$found} { puts "== WARNING: no generated pixel clock found in the STA report ==" }
}

project_close
