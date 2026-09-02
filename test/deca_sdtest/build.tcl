# Build the standalone DECA micro-SD test.
#
#   quartus_sh -t build.tcl <repo-root> <outdir>
#
# blk_sd, a pattern generator and a sector buffer.  No Sun-2, no CPU, no DVMA,
# no DDR3 -- which is the point: it removes everything above blk_sd from the
# experiment.  See the header of deca_sdtest_top.sv.

package require ::quartus::project
package require ::quartus::flow

set root   [lindex $argv 0]
set outdir [lindex $argv 1]
set here   [file dirname [info script]]

puts "== DECA micro-SD test: MAX 10 10M50DAF484C6GES =="

project_new sdtest -overwrite

set_global_assignment -name FAMILY           "MAX 10"
set_global_assignment -name DEVICE           10M50DAF484C6GES
set_global_assignment -name TOP_LEVEL_ENTITY deca_sdtest_top
set_global_assignment -name NUM_PARALLEL_PROCESSORS 8

# Bank 8 at 1.2 V for the LEDs costs the configuration pins, so the board is
# JTAG-only.  Same device options as the machine build.
set_global_assignment -name USE_CONFIGURATION_DEVICE   OFF
set_global_assignment -name AUTO_RESTART_CONFIGURATION OFF
set_global_assignment -name ENABLE_CONFIGURATION_PINS  OFF
set_global_assignment -name ENABLE_BOOT_SEL_PIN        OFF
set_global_assignment -name SYNCHRONIZER_IDENTIFICATION "FORCED IF ASYNCHRONOUS"

# The sector buffer is inferred memory and MAX 10 loads embedded RAM from
# configuration flash only when the image is built to carry it.  Without this
# the assembler stops with Error (14703).
set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE COMP IMAGE WITH ERAM"

# blk_req_t and blk_rsp_t are declared at file scope in wish5380_pkg.sv, not in
# a package, so file order is load-bearing -- the same rule syn/quartus.tcl
# records for the machine build.
set w5 $root/build/inputs/Wish5380/src
if {![file exists $w5/blk_sd.sv]} {
    puts "ERROR: $w5 missing -- run tools/patch_inputs.sh Wish5380 first"
    exit 1
}
foreach f [list wish5380_pkg.sv sd_spi.sv blk_sd.sv] {
    set_global_assignment -name SYSTEMVERILOG_FILE $w5/$f
}

set_global_assignment -name SYSTEMVERILOG_FILE $here/deca_sdtest_top.sv
set_global_assignment -name SDC_FILE           $here/sdtest.sdc
source $here/sd_pins.qsf

export_assignments

foreach stage {map fit sta asm} {
    if {[catch {execute_module -tool $stage} err]} {
        puts "== $stage FAILED =="; puts $err; project_close; exit 1
    }
    puts "== $stage ok =="
}

project_close
