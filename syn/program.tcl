# Put a bitstream on the board over JTAG, and tell the Hardware Manager about
# the ILA in it.
#
#   vivado -mode batch -source syn/program.tcl -tclargs BIT [LTX] [URL]
#   vivado -mode gui   -source syn/program.tcl -tclargs BIT [LTX] [URL]
#
# LTX is the probe file syn/build.tcl writes beside an ILA=1 bitstream; without
# it the Hardware Manager finds the debug hub but has no names for anything on
# it.  URL defaults to localhost:3121, which is where a locally started
# hw_server listens; point it elsewhere for a board on another machine.
#
# In -mode gui this programs and then leaves the Hardware Manager open on the
# device, which is the ILA session: set the trigger, arm, capture, repeat.  In
# -mode batch it programs and exits, which is what a rebuild-and-retry loop
# wants.
#
# There was no programming path in this repo at all before the ILA -- the
# bitstream was carried to the board by other means -- so this is new
# scaffolding rather than a change to how anything worked.

if {[llength $argv] < 1} {
    puts "ERROR: usage: program.tcl BIT \[LTX\] \[URL\]"
    exit 1
}

set bit [file normalize [lindex $argv 0]]
set ltx ""
set url localhost:3121
if {[llength $argv] > 1 && [lindex $argv 1] ne ""} {
    set ltx [file normalize [lindex $argv 1]]
}
if {[llength $argv] > 2 && [lindex $argv 2] ne ""} { set url [lindex $argv 2] }

if {![file exists $bit]} {
    puts "ERROR: no such bitstream: $bit"
    exit 1
}
if {$ltx ne "" && ![file exists $ltx]} {
    puts "ERROR: no such probe file: $ltx"
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

# Before opening it, the JTAG clock.  The debug hub runs on clk50 (see
# syn/build.tcl) and wants to be at least 2.5x TCK, so anything up to 20 MHz is
# legal here -- but a cable takes only the discrete rates it was built for, and
# setting one it does not have is a hard error rather than a rounding.  The
# Wukong's offers 750 kHz to 12 MHz and starts at 6.  So ask it what it has and
# take the fastest that is within the hub's limit, which needs no editing when
# the cable or the hub's clock changes.
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
    puts "         the debug hub may enumerate and then never answer"
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
if {$ltx ne ""} {
    set_property PROBES.FILE      $ltx $dev
    set_property FULL_PROBES.FILE $ltx $dev
}

puts "== programming $dev with $bit =="
program_hw_devices $dev
refresh_hw_device $dev

set ilas [get_hw_ilas -quiet]
if {[llength $ilas]} {
    puts "== ILA cores on the device: $ilas =="
    puts "== probes: [get_hw_probes -quiet -of_objects [lindex $ilas 0]] =="
} elseif {$ltx ne ""} {
    puts "WARNING: an .ltx was given but the device reports no ILA core."
}

puts "== programmed =="
