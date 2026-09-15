# Put a bitstream on the board over JTAG.
#
#   vivado -mode batch -source syn/program.tcl -tclargs BIT [URL]
#
# URL defaults to localhost:3121, which is where a locally started hw_server
# listens; point it elsewhere for a board on another machine.
#
# There was no programming path in this repo before this -- the bitstream was
# carried to the board by other means -- so `make program' is it.

if {[llength $argv] < 1} {
    puts "ERROR: usage: program.tcl BIT \[URL\]"
    exit 1
}

set bit [file normalize [lindex $argv 0]]
set url localhost:3121
if {[llength $argv] > 1 && [lindex $argv 1] ne ""} { set url [lindex $argv 1] }

if {![file exists $bit]} {
    puts "ERROR: no such bitstream: $bit"
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

# Before opening it, the JTAG clock.  A cable takes only the discrete rates it
# was built for, and setting one it does not have is a hard error rather than a
# rounding -- the Wukong's offers 750 kHz to 12 MHz and starts at 6.  So ask it
# what it has and take the fastest at or below 20 MHz.
set jtag_limit 20000000
set valid [list_property_value PARAM.FREQUENCY [current_hw_target]]
set pick ""
foreach f $valid {
    if {$f <= $jtag_limit && ($pick eq "" || $f > $pick)} { set pick $f }
}
if {$pick ne ""} {
    set_property PARAM.FREQUENCY $pick [current_hw_target]
    puts "== JTAG at $pick Hz (cable offers: $valid) =="
} else {
    puts "WARNING: no JTAG rate at or below $jtag_limit Hz; the cable offers $valid"
}
open_hw_target

# The Wukong has one FPGA on its chain; take the Artix by name rather than by
# position, so a cable that also sees something else does not get programmed.
set devs [get_hw_devices xc7a100t*]
if {[llength $devs] == 0} {
    puts "ERROR: no xc7a100t on the chain; found [get_hw_devices]"
    exit 1
}
set dev [lindex $devs 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $bit $dev

puts "== programming $dev with $bit =="
program_hw_devices $dev
refresh_hw_device $dev

puts "== programmed =="
