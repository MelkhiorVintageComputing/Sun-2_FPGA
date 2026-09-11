# Set the master-traffic throttle on a Wukong build, over the VIO.
#
#   vivado -mode batch -nojournal -nolog -source syn/vio_throttle.tcl \
#          -tclargs <mask> [rand] [ltx] [url]
#
# <mask> is THR_MASK and [rand] is THR_RAND (0 or 1, default 0).  The gap
# sun2_dvma leaves between Wishbone transactions is
#
#     fixed  (rand 0):  mask >> 1 clocks, every time
#     random (rand 1):  uniform over [0, mask], so the same mean
#
# mask 0 disables it and is exactly a build without the throttle.
#
# The two modes exist to separate what one knob conflates: a gap changes both
# how often the master asks for memory and the phase relationship between its
# cycles and the CPU's.  Equal means differ only in the second.
#
# Needs ILA=1 -- the VIO rides with the ILA.

if {[llength $argv] < 1} {
    puts "usage: vio_throttle.tcl <mask> \[rand\] \[url\]"
    exit 1
}
set mask [expr {int([lindex $argv 0]) & 0xFF}]
set rand [expr {[llength $argv] > 1 ? (int([lindex $argv 1]) & 1) : 0}]
set url  [expr {[llength $argv] > 3 ? [lindex $argv 3] : "localhost:3121"}]
# The probe file is what names the probes.  Without it refresh_hw_device finds
# the VIO but none of its probes, and the tool reports "no output probe" about
# a device the programmer has just said carries one.
set ltx  [expr {[llength $argv] > 2 ? [file normalize [lindex $argv 2]] : ""}]
set val  [expr {($rand << 8) | $mask}]

open_hw_manager
connect_hw_server -url $url
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
if {$ltx ne ""} { set_property PROBES.FILE $ltx [current_hw_device] }
refresh_hw_device [current_hw_device]

set vio [lindex [get_hw_vios -of_objects [current_hw_device]] 0]
if {$vio eq ""} {
    puts "no VIO in this bitstream -- was it built with ILA=1?"
    exit 1
}

set p [get_hw_probes -of_objects $vio -filter {TYPE == vio_output}]
if {[llength $p] == 0} {
    puts "the VIO has no output probe -- regenerate it: make -C syn ip-ila"
    exit 1
}
set p [lindex $p 0]

set_property OUTPUT_VALUE_RADIX UNSIGNED $p
set_property OUTPUT_VALUE $val $p
commit_hw_vio $p

# A knob that reaches no logic is this project's most repeated failure -- it
# has shipped three of them -- so read it back rather than trust it.
refresh_hw_vio $vio
set back [get_property OUTPUT_VALUE $p]
if {$back != $val} {
    puts [format "FAILED: wrote %d, reads back %s" $val $back]
    exit 1
}

if {$mask == 0} {
    puts "throttle: OFF (mask 0)"
} elseif {$rand} {
    puts [format "throttle: mask 0x%02x, RANDOM, gap uniform \[0,%d\], mean %.1f clocks" \
              $mask $mask [expr {$mask / 2.0}]]
} else {
    puts [format "throttle: mask 0x%02x, FIXED, gap %d clocks" $mask [expr {$mask >> 1}]]
}
close_hw_manager
