# Build the standalone DECA console test.
#
#   quartus_sh -t build.tcl <repo-root> <outdir> [cpu_div]
#
# Deliberately small: deca_clkgen, deca_jtag_console and its two UART halves,
# the JTAG UART IP, and a pattern generator.  No Sun-2 at all.
#
# It reads the *same* boards/DECA sources the real build reads, not copies.  If
# it read copies it would vouch for something other than the thing it is meant
# to vouch for -- the mistake test/hdmi's Makefile calls out for the HDMI
# library, where the test and the machine would otherwise drive two different
# versions of the block.

package require ::quartus::project
package require ::quartus::flow

set root   [lindex $argv 0]
set outdir [lindex $argv 1]
set cpudiv [expr {[llength $argv] > 2 ? [lindex $argv 2] : 80}]
set loop   [expr {[llength $argv] > 3 ? [lindex $argv 3] : 0}]

puts "== DECA console test: MAX 10 10M50DAF484C6GES, CPU_DIV $cpudiv, LOOPBACK $loop =="

project_new console_test -overwrite

set_global_assignment -name FAMILY           "MAX 10"
set_global_assignment -name DEVICE           10M50DAF484C6GES
set_global_assignment -name TOP_LEVEL_ENTITY deca_console_test_top
set_global_assignment -name NUM_PARALLEL_PROCESSORS 8

# Bank 8 at 1.2 V for the LEDs, so the configuration pins go.  Same as the real
# build -- if these differed, the test would not be testing the same board.
set_global_assignment -name USE_CONFIGURATION_DEVICE   OFF
set_global_assignment -name AUTO_RESTART_CONFIGURATION OFF
set_global_assignment -name ENABLE_CONFIGURATION_PINS  OFF
set_global_assignment -name ENABLE_BOOT_SEL_PIN        OFF
set_global_assignment -name SYNCHRONIZER_IDENTIFICATION "FORCED IF ASYNCHRONOUS"

# No INTERNAL_FLASH_UPDATE_MODE here: this design has no initialised memory in
# it at all, so the assignment would have nothing to act on.  Its absence is
# also a small independent check on the claim -- if this build somehow produced
# memory bits, the story about what that assignment gates would be wrong.

set_global_assignment -name SEARCH_PATH $root/rtl/sun2-common

set_parameter -name CPU_DIV  $cpudiv
set_parameter -name LOOPBACK $loop
if {$loop} { puts "== LOOPBACK: the console hears its own transmitter ==" }

foreach f [list $root/boards/DECA/deca_clkgen.sv \
                $root/boards/DECA/deca_uart_rx.sv \
                $root/boards/DECA/deca_uart_tx.sv \
                $root/boards/DECA/deca_jtag_console.sv \
                $root/rtl/sun2-common/reset_sync.sv \
                [file dirname [info script]]/deca_console_test_top.sv] {
    if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
    set_global_assignment -name SYSTEMVERILOG_FILE $f
}

set juart $::env(QUARTUS_ROOTDIR)/../ip/altera/sopc_builder_ip/altera_avalon_jtag_uart
foreach f [list altera_avalon_jtag_uart.sv altera_avalon_jtag_uart_scfifo_r.sv \
                altera_avalon_jtag_uart_scfifo_w.sv] {
    if {![file exists $juart/$f]} { puts "ERROR: JTAG UART IP missing: $juart/$f"; exit 1 }
    set_global_assignment -name SYSTEMVERILOG_FILE $juart/$f
}

set_global_assignment -name SDC_FILE [file dirname [info script]]/console_test.sdc
source [file dirname [info script]]/console_test_pins.qsf

export_assignments

foreach stage {map fit sta asm} {
    if {[catch {execute_module -tool $stage} err]} {
        puts "== $stage FAILED =="; puts $err; project_close; exit 1
    }
    puts "== $stage ok =="
}

# The whole point of this design is the console, so a build without one is
# worse than a build that fails: it would run, show nothing, and be blamed on
# the board.
set rpt [read [open console_test.map.rpt]]
if {![regexp {alt_jtag_atlantic} $rpt]} {
    puts "ERROR: no alt_jtag_atlantic in the netlist -- this design is nothing"
    puts "       but a console, so that is a total failure, not a warning."
    exit 1
}
puts "== console: alt_jtag_atlantic present =="

# What the PLLs actually got programmed with.
#
# deca_clkgen claims 4.915254 MHz from N=5/M=87/C=177, and a comment is not a
# measurement -- the solver is free to reduce the ratio, round it, or reject the
# parameters and pick its own.  quartus_sta has already written the answer, so
# read it rather than recomputing it.  This is the cheapest place in the whole
# project to check, because this design is 1% of the device.
#
# Note `load_package timing' does not exist in quartus_sh; the timing netlist
# lives in quartus_sta.  Parsing its report is the reliable way from here.
if {[file exists console_test.sta.rpt]} {
    set fh [open console_test.sta.rpt]
    set sta [read $fh]
    close $fh
    set found 0
    foreach line [split $sta "\n"] {
        if {[regexp {^; *([^;]*pll_[ab][^;]*) *; *Generated *; *([0-9.]+) *; *([0-9.]+ [Mk]Hz)} \
                 $line -> nm pd fq]} {
            puts "== clock [string trim $nm]: [string trim $pd] ns, [string trim $fq] =="
            set found 1
        }
    }
    if {!$found} {
        puts "== note: no generated PLL clock in the STA report.  A PLL output"
        puts "==       with no fan-out produces no clock, which is expected here"
        puts "==       for the CPU PLL: nothing in this design uses cpu_clk."
    }
}

project_close
