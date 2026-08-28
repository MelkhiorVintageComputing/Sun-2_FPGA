# Read the standalone DDR3 test's result over JTAG.
#
#   quartus_stp -t tools/deca_ddr3_probe.tcl
#
# The DECA has no serial port, and the JTAG console is a different subsystem
# with its own history -- a memory test that reported through it would be two
# experiments at once.  In-System Sources and Probes keeps them separate.
package require ::quartus::jtag
package require ::quartus::insystem_source_probe

proc b2i {s} { set v 0; foreach c [split $s ""] { set v [expr {$v*2 + ($c eq "1")}] }; return $v }

set hw [lindex [get_hardware_names] 0]
set dv [lindex [get_device_names -hardware_name $hw] 0]

# Instance info opens its own session and refuses if one is already up, so it
# must come before start_insystem_source_probe.  The error it gives when this is
# the wrong way round names the wrong call.
set info [get_insystem_source_probe_instance_info -device_name $dv -hardware_name $hw]
set idx -1
foreach inst $info { if {[lindex $inst 3] eq "DDR3"} { set idx [lindex $inst 0] } }
if {$idx < 0} { puts "no DDR3 probe instance; is the DDR3 test loaded?"; exit 1 }

start_insystem_source_probe -device_name $dv -hardware_name $hw
set raw [read_probe_data -instance_index $idx]
end_insystem_source_probe

# raw is MSB-first: done, PLL_LOCKED, SEQ_CAL_PASS, DDR3_READY, RDCAL[8],
# writes[20], reads[20], errors[12].
set done  [string index $raw 0]
set lock  [string index $raw 1]
set cal   [string index $raw 2]
set rdy   [string index $raw 3]
set rdcal [b2i [string range $raw  4 11]]
set wr    [b2i [string range $raw 12 31]]
set rd    [b2i [string range $raw 32 51]]
set err   [b2i [string range $raw 52 63]]

# How many lines the walk should cover.  Must match LINES in the test top.
set expect 65536

puts [format "PLL_LOCKED=%s  DDR3_READY=%s  SEQ_CAL_PASS=%s  done=%s" $lock $rdy $cal $done]
puts [format "RDCAL_data=0x%02x" $rdcal]
puts [format "writes=%d  reads=%d  errors=%d  (expected %d each)" $wr $rd $err $expect]

# "errors=0" is worthless on its own -- a walk that never started reports the
# same thing, and the first version of this script duly printed PASS on a pair
# of counters that had wrapped to zero.  The counts have to be right too.
if {$done eq "1" && $err == 0 && $wr == $expect && $rd == $expect} {
    puts "PASS"
} elseif {$done ne "1"} {
    puts "not finished yet -- read again in a moment"
} else {
    puts "FAIL"
}
