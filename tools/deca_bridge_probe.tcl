# Read the standalone bridge->DDR3 test's result over JTAG.
#
#   quartus_stp -t tools/deca_bridge_probe.tcl
#
# The design drives sun2_wishbone_bridge with 68010-style cycles, through
# deca_wb_to_ddr3 into real DDR3, writing an address-derived pattern over
# 128 KiB and reading every word back.  It
# reports here rather than through the JTAG console for the reason the DDR3 test
# gives: a media test that reported through the console would be two experiments
# at once.
package require ::quartus::jtag
package require ::quartus::insystem_source_probe

proc b2i {s} { set v 0; foreach c [split $s ""] { set v [expr {$v*2 + ($c eq "1")}] }; return $v }

set hw [lindex [get_hardware_names] 0]
set dv [lindex [get_device_names -hardware_name $hw] 0]

# Instance info opens its own session and refuses if one is already up, so it
# has to come before start_insystem_source_probe.
set info [get_insystem_source_probe_instance_info -device_name $dv -hardware_name $hw]
set idx -1
foreach inst $info { if {[lindex $inst 3] eq "BRDG"} { set idx [lindex $inst 0] } }
if {$idx < 0} { puts "no BRDG probe instance; is the bridge test loaded?"; exit 1 }

start_insystem_source_probe -device_name $dv -hardware_name $hw
set raw [read_probe_data -instance_index $idx]
end_insystem_source_probe

# The probe string arrives most-significant bit first, in the order the concat
# in deca_sdtest_top.sv builds it.  Adding a field at the top would shift every
# offset below it, which is why new ones go at the bottom.
# The tool pads the returned bit string up to a convenient multiple, so the
# real fields sit at the *end* of it.  Indexing from the front works only when
# the width happens to be a multiple of eight -- 86 is not, and decoding from
# offset zero reported a first-bad word of 0x40000, which the walker cannot
# produce at all.  An impossible value is the tell.
set W 86
if {[string length $raw] > $W} {
    set raw [string range $raw [expr {[string length $raw] - $W}] end]
}
set i 0
proc take {n} {
    upvar raw raw; upvar i i
    set s [string range $raw $i [expr {$i + $n - 1}]]
    incr i $n
    return [b2i $s]
}

set done   [take 1]
set phase  [take 2]
set ready  [take 1]
set calpas [take 1]
set locked [take 1]
set nerr   [take 16]
set fbad   [take 32]
set fgot   [take 16]
set fwant  [take 16]

puts [format "ddr3   : ready=%d cal_pass=%d pll=%d" $ready $calpas $locked]
puts [format "walk   : done=%d phase=%s" $done [lindex {bulk-write bulk-verify interleaved byte-lanes} $phase]]
puts [format "result : %d words differed" $nerr]
if {$nerr > 0} {
    puts [format "first  : word %08x: got %04x, wanted %04x" $fbad $fgot $fwant]
} elseif {$done} {
    puts "         every 16-bit word came back through the bridge as written."
}
