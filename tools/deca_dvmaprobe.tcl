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
set W 469
if {[string length $raw] > $W} {
    set raw [string range $raw [expr {[string length $raw] - $W}] end]
}
proc field {raw off len} { return [b2i [string range $raw $off [expr {$off + $len - 1}]]] }

set pat_a       [field $raw   0 16]
set pat_b       [field $raw  16 16]
set pat_bad     [field $raw  32 16]
set pat_first   [field $raw  48 16]
set pat_faddr   [field $raw  64 23]
set n_half_bad  [field $raw  87 16]
set n_clk       [field $raw 103 16]
set n_latch     [field $raw 119 16]
set n_no_load   [field $raw 135 16]
set n_late_load [field $raw 151 16]
set n_load      [field $raw 167 16]
# Appended below dvma_probe, so the offsets above are unchanged.
set rd_unexp    [field $raw  183 16]
set rd_ready    [field $raw 199 16]
set rd_issued   [field $raw 215 16]
set lane_bad    [field $raw 231 16]
set reread_bad  [field $raw 247 16]
set wv_bad      [field $raw 263 16]
set rr_adr      [field $raw 279 30]
set rr_v1       [field $raw 309 32]
set rr_v2       [field $raw 341 32]
set pat_sectors [field $raw 373 16]
set pat_bad     [field $raw 389 16]
set pat_lba     [field $raw 405 32]
set pat_off     [field $raw 437 16]
set pat_exp     [field $raw 453 8]
set pat_got     [field $raw 461 8]
set seen        0

puts [format "heartbeat    %6d (mod 65536)  -- free-running; 0 means the probe is dead" $n_clk]
puts [format "bridge loads %6d (mod 65536)" $n_load]
puts [format "captures     %6d (mod 65536)" $n_latch]
puts [format "no_load      %6d   -- captured with nothing loaded the clock before" $n_no_load]
puts [format "late_load    %6d   -- more than one load inside one cycle" $n_late_load]
puts [format "wrong half   %6d   -- load took the other 16 bits of the 32-bit word" $n_half_bad]
puts ""
puts ""
puts "Pattern check at the master's capture (tools/patwr -u)"
puts [format "  matches        %6d  (other byte order: %d)" $pat_a $pat_b]
puts [format "  wrong words    %6d" $pat_bad]
if {$pat_bad > 0} {
    puts [format "  first: word address %06x took %04x" [expr {$pat_faddr * 2}] $pat_first]
    puts        "  ^ already wrong when the master captured it, so the fault is"
    puts        "    at or below DDR3 -- not in sun2_dvma or the sector buffer."
} elseif {$pat_a > 1000} {
    puts        "  the master captured every pattern word correctly, so the"
    puts        "  corruption seen at the card happened after this point."
}
puts ""
puts "DDR3 adapter (cmd_clk domain, counts may tear on a read; zero is still zero)"
puts [format "  reads issued   %6d" $rd_issued]
puts [format "  responses      %6d   -- should track reads issued" $rd_ready]
puts [format "  unexpected     %6d   -- CMD_read_ready outside D_READ: a response" $rd_unexp]
puts        "                          with no request to answer, which the next"
puts        "                          read could take as its own"
puts [format "  wrong lane     %6d   -- the 32-bit quarter of the 128-bit line" $lane_bad]
puts        "                          changed between issue and response"
puts ""
puts "Pattern check, in flight at the block seam (tools/patwr -u)"
puts [format "  sectors seen   %6d" $pat_sectors]
puts [format "  bytes wrong    %6d" $pat_bad]
if {$pat_bad > 0} {
    puts [format "  first: LBA %08x byte %d, wanted %02x got %02x" \
              $pat_lba $pat_off $pat_exp $pat_got]
    puts        "  ^ the data was ALREADY wrong when it reached the card"
    puts        "    interface, so the fault is upstream of blk_sd and the SD"
    puts        "    bus entirely."
} elseif {$pat_sectors > 0} {
    puts        "  every pattern sector reached the card interface intact, so"
    puts        "  anything wrong on the medium happened below this point."
}
puts ""
puts "Write verify (every write read straight back and compared)"
puts [format "  writes wrong   %6d" $wv_bad]
if {$wv_bad > 0} {
    puts [format "  first at word address %08x: wrote %08x, read back %08x  (xor %08x)" \
              $rr_adr $rr_v1 $rr_v2 [expr {$rr_v1 ^ $rr_v2}]]
    puts        "  ^ a write was not visible to the read that followed it."
} else {
    puts        "  none.  Meaningful only if this run still corrupted, and only"
    puts        "  with PORT_CACHE_SMART off -- with it on the read-back is"
    puts        "  answered from the write cache and confirms itself."
}
puts ""
puts "Double read (every read issued twice and the answers compared)"
puts [format "  disagreements  %6d" $reread_bad]
if {$reread_bad > 0} {
    puts [format "  first at word address %08x: %08x then %08x  (xor %08x)" \
              $rr_adr $rr_v1 $rr_v2 [expr {$rr_v1 ^ $rr_v2}]]
    puts        "  ^ the controller answered the same address two different ways."
} else {
    puts        "  none -- but a zero here only means something if the run that"
    puts        "  produced it still corrupted; reading twice changes timing."
}
if {$n_latch == 0} {
    if {$n_load == 0} {
        puts "             and no bridge loads either -- the probe or its readout is dead"
    } else {
        puts "             but the bridge is loading, so the master's capture strobe is dead"
    }
}

end_insystem_source_probe
