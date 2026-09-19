# Write a bitstream into the Wukong's SPI configuration flash over JTAG.
#
#   vivado -mode batch -source syn/program_flash.tcl -tclargs BIN BOARD [URL]
#
# BIN is the header-less image `make bitstream' writes beside the .bit; BOARD
# (v1, v1s1 or v3) picks the flash part from syn/boards.tcl.  URL defaults to
# localhost:3121, as for program.tcl.
#
# Vivado first loads its own indirect-programming bitstream into the FPGA, so
# whatever the board was running is gone the moment this starts -- halt the
# Sun-2 before running it, exactly as before `make program'.  Then it erases,
# writes and verifies the flash, and finally pulses PROG so the FPGA configures
# itself from what it just wrote: the board comes up as it would at power-on.

if {[llength $argv] < 2} {
    puts "ERROR: usage: program_flash.tcl BIN BOARD \[URL\]"
    exit 1
}

set here  [file dirname [file normalize [info script]]]
source $here/boards.tcl

set bin   [file normalize [lindex $argv 0]]
set board [lindex $argv 1]
set url   localhost:3121
if {[llength $argv] > 2 && [lindex $argv 2] ne ""} { set url [lindex $argv 2] }

set part [board_flash_part $board]
if {$part eq ""} {
    puts "ERROR: no configuration flash known for BOARD '$board' (v1, v1s1 or v3)"
    exit 1
}
if {![file exists $bin]} {
    puts "ERROR: no such flash image: $bin"
    puts "       make bitstream writes it beside the .bit; build first."
    exit 1
}

open_hw_manager
connect_hw_server -url $url

set targets [get_hw_targets]
if {[llength $targets] == 0} {
    puts "ERROR: hw_server at $url sees no JTAG target."
    puts "       Is the board powered and the programming cable plugged in?"
    puts "       Is hw_server running?  \$XILINX_VIVADO/bin/hw_server &"
    exit 1
}
if {[llength $targets] > 1} {
    puts "== [llength $targets] JTAG targets, taking the first: $targets =="
}
current_hw_target [lindex $targets 0]

# The fastest JTAG rate the cable offers at or below 20 MHz; see program.tcl.
set jtag_limit 20000000
set valid [list_property_value PARAM.FREQUENCY [current_hw_target]]
set pick ""
foreach f $valid {
    if {$f <= $jtag_limit && ($pick eq "" || $f > $pick)} { set pick $f }
}
if {$pick ne ""} {
    set_property PARAM.FREQUENCY $pick [current_hw_target]
    puts "== JTAG at $pick Hz (cable offers: $valid) =="
}
open_hw_target

set devs [get_hw_devices xc7a100t*]
if {[llength $devs] == 0} {
    puts "ERROR: no xc7a100t on the chain; found [get_hw_devices]"
    exit 1
}
set dev [lindex $devs 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set cfgparts [get_cfgmem_parts $part]
if {[llength $cfgparts] == 0} {
    puts "ERROR: this Vivado does not know the flash part $part"
    exit 1
}
create_hw_cfgmem -hw_device $dev [lindex $cfgparts 0]
set mem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.ADDRESS_RANGE           {use_file}  $mem
set_property PROGRAM.FILES                   [list $bin] $mem
set_property PROGRAM.UNUSED_PIN_TERMINATION  {pull-none} $mem
set_property PROGRAM.BLANK_CHECK             0 $mem
set_property PROGRAM.ERASE                   1 $mem
set_property PROGRAM.CFG_PROGRAM             1 $mem
set_property PROGRAM.VERIFY                  1 $mem
set_property PROGRAM.CHECKSUM                0 $mem

# Vivado's own bridge from JTAG to the flash pins, for this part.
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev

puts "== writing $bin to $part on $dev =="
program_hw_cfgmem -hw_cfgmem $mem

puts "== written and verified; reconfiguring from flash =="
boot_hw_device $dev
puts "== done =="
