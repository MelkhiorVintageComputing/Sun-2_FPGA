# Read the standalone micro-SD test's result over JTAG.
#
#   quartus_stp -t tools/deca_sdtest_probe.tcl
#
# The design writes NBLOCKS blocks of an address-derived pattern to an unused
# part of the card, reads them all back, and counts the bytes that differ.  It
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
foreach inst $info { if {[lindex $inst 3] eq "SDTS"} { set idx [lindex $inst 0] } }
if {$idx < 0} { puts "no SDTS probe instance; is the SD test loaded?"; exit 1 }

start_insystem_source_probe -device_name $dv -hardware_name $hw
set raw [read_probe_data -instance_index $idx]
end_insystem_source_probe

# The probe string arrives most-significant bit first, in the order the concat
# in deca_sdtest_top.sv builds it.  Adding a field at the top would shift every
# offset below it, which is why new ones go at the bottom.
set i 0
proc take {n} {
    upvar raw raw; upvar i i
    set s [string range $raw $i [expr {$i + $n - 1}]]
    incr i $n
    return [b2i $s]
}

set done   [take 1]
set ready  [take 1]
set pass2  [take 1]
set _pad   [take 1]
set count  [take 28]
set nerr   [take 16]
set nblke  [take 16]
set fbad   [take 32]
set fgot   [take 8]
set fwant  [take 8]

puts [format "card   : ready=%d blocks=%d (%.1f GiB)" \
          $ready $count [expr {$count * 512.0 / 1073741824.0}]]
puts [format "walk   : done=%d phase=%s" $done [expr {$pass2 ? "verify" : "write"}]]
puts [format "result : %d mismatched bytes, %d blocks reported an error" $nerr $nblke]
if {$nerr > 0} {
    # first_bad packs the block number in the top 23 bits and the byte offset
    # in the bottom nine.
    set blk [expr {($fbad >> 9) & 0x7FFFFF}]
    set off [expr {$fbad & 0x1FF}]
    puts [format "first  : block %d, byte %d: got %02x, wanted %02x" $blk $off $fgot $fwant]
} elseif {$done} {
    puts "         every byte of every block came back as written."
}
