# Read sun2_dvma_probe: did the master ever latch data that was not its own?
#
#   quartus_stp -t tools/deca_dvmaprobe.tcl
#
# Built into any BLKTRACE=1 bitstream.  Halt the machine first, or at least stop
# it doing disk I/O -- ISSP and juart-terminal cannot both hold the JTAG chain.
#
# The invariant: sun2_wishbone_bridge loads P_DATA_OUT on `wb_ack_i & issued',
# and sun2_dvma captures dvma_din exactly one clock later.  Two registers in
# different modules with nothing but that convention between them.
#
#   no_load    the master captured with no load in the clock before, so it took
#              whatever P_DATA_OUT held from an earlier transaction
#   late_load  the bridge loaded on the same edge the master captured; both are
#              registered off it, so the master again took the earlier value
#
# Either is "the master latched somebody else's word", which is the shape of the
# corruption: one 16-bit half of a longword read, about one word in a hundred
# thousand.  A run of copies that corrupts with all three counters at zero
# clears this pairing and sends the search elsewhere.
package require ::quartus::jtag
package require ::quartus::insystem_source_probe

proc b2i {s} { set v 0; foreach c [split $s ""] { set v [expr {$v*2 + ($c eq "1")}] }; return $v }

set hw [lindex [get_hardware_names] 0]
set dv [lindex [get_device_names -hardware_name $hw] 0]

set info [get_insystem_source_probe_instance_info -device_name $dv -hardware_name $hw]
set idx -1
foreach inst $info { if {[lindex $inst 3] eq "DVMP"} { set idx [lindex $inst 0] } }
if {$idx < 0} { puts "no DVMP instance; was this built with BLKTRACE=1?"; exit 1 }

start_insystem_source_probe -device_name $dv -hardware_name $hw
set raw [read_probe_data -instance_index $idx]

# Anchor to the end: the tool pads the returned string up to a convenient
# multiple, and indexing from the front is only right when it happens not to.
set W 80
if {[string length $raw] > $W} {
    set raw [string range $raw [expr {[string length $raw] - $W}] end]
}
proc field {raw off len} { return [b2i [string range $raw $off [expr {$off + $len - 1}]]] }

set n_clk       [field $raw  0 16]
set n_latch     [field $raw 16 16]
set n_no_load   [field $raw 32 16]
set n_late_load [field $raw 48 16]
set n_load      [field $raw 64 16]
set seen        0

puts [format "heartbeat    %6d (mod 65536)  -- free-running; 0 means the probe is dead" $n_clk]
puts [format "bridge loads %6d (mod 65536)" $n_load]
puts [format "captures     %6d (mod 65536)" $n_latch]
puts [format "no_load      %6d   -- captured with nothing loaded the clock before" $n_no_load]
puts [format "late_load    %6d   -- bridge loaded on the capture edge itself" $n_late_load]
if {$n_latch == 0} {
    if {$n_load == 0} {
        puts "             and no bridge loads either -- the probe or its readout is dead"
    } else {
        puts "             but the bridge is loading, so the master's capture strobe is dead"
    }
}

end_insystem_source_probe
