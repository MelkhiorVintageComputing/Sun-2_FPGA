# Read the block trace: the last 1024 transfers the machine asked its disk for.
#
#   quartus_stp -t tools/deca_blktrace.tcl [count]
#
# Built with `make -C syn quartus ... BLKTRACE=1'.  Halt the machine first --
# ISSP and juart-terminal cannot both hold the JTAG chain, and the trace
# free-runs precisely so that nothing has to be armed while the console is up.
#
# Output is one line per transfer, oldest first, ending at the most recent:
#
#   #0003  W  lba 00760a41  sig 4e2c
#
# `sig' is a rotate-and-add fold of the 512 bytes that moved.  It is what makes
# a block identifiable: if block N of a file turns up at an LBA the inode does
# not list, the signature says it really was that block rather than leaving it
# to be inferred from ordering.
#
# To compare against where the data *should* have gone, take the filesystem off
# the card and read the file's inode block list; the chain is
#
#   inode block pointer -> fragment -> sector (superblock fs_fsize)
#                       -> + partition start -> + DISK_LBA_OFFSET
#
# so these LBAs are absolute on the card, which is what an image dumped from it
# can be indexed by directly.
package require ::quartus::jtag
package require ::quartus::insystem_source_probe

proc b2i {s} { set v 0; foreach c [split $s ""] { set v [expr {$v*2 + ($c eq "1")}] }; return $v }

set want [expr {[llength $argv] > 0 ? [lindex $argv 0] : 64}]

set hw [lindex [get_hardware_names] 0]
set dv [lindex [get_device_names -hardware_name $hw] 0]

# Instance info opens its own session and refuses if one is already up, so it
# has to come before start_insystem_source_probe.
set info [get_insystem_source_probe_instance_info -device_name $dv -hardware_name $hw]
set idx -1
foreach inst $info { if {[lindex $inst 3] eq "BLKT"} { set idx [lindex $inst 0] } }
if {$idx < 0} { puts "no BLKT instance; was this built with BLKTRACE=1?"; exit 1 }

start_insystem_source_probe -device_name $dv -hardware_name $hw

proc field {raw off len} {
    # The probe is 64 bits: data[31:0], wr_ptr[15:0], n_xfer[15:0], most
    # significant first.  Anchor to the end of the returned string, because the
    # tool pads it up to a convenient multiple and indexing from the front is
    # only right when the width happens to be one.
    set W 64
    if {[string length $raw] > $W} {
        set raw [string range $raw [expr {[string length $raw] - $W}] end]
    }
    return [b2i [string range $raw $off [expr {$off + $len - 1}]]]
}

# write_source_data takes a DECIMAL value and silently ignores it.
#
# Not an error, not a warning: the source keeps its old contents.  This tool's
# first readout showed all 1024 entries identical with the signature equal to
# the low half of the LBA -- which is what a source stuck at zero looks like,
# both halves returning the key.  tools/deca_trace.tcl carries the same note,
# having been bitten first; only -value_in_hex and a hex string land.
proc wsrc {idx v} {
    write_source_data -instance_index $idx -value [format %X $v] -value_in_hex
}

proc read_at {idx index half} {
    wsrc $idx [expr {($half << 10) | $index}]
    # One read to settle the registered path, one to take.
    read_probe_data -instance_index $idx
    return [read_probe_data -instance_index $idx]
}

# An instrument whose controls cannot be read back cannot be told from a broken
# machine, so check the source lands before reading a single entry.
wsrc $idx 0x2A5
set back [b2i [read_source_data -instance_index $idx]]
if {$back != 0x2A5} {
    puts [format "the index source does not take: wrote 2a5, reads %x" $back]
    puts "nothing below this line would mean anything; stopping."
    end_insystem_source_probe
    exit 1
}

set raw   [read_at $idx 0 0]
set wp    [field $raw 32 16]
set nx    [field $raw 48 16]

puts [format "trace: %d transfers seen (mod 65536), write pointer at %d" $nx $wp]
if {$nx == 0} { puts "       nothing captured -- has the machine touched its disk?"; }

# Oldest first: the buffer is circular and wp is where the *next* entry goes.
set depth 1024
if {$want > $depth} { set want $depth }
if {$nx < $want}    { set want $nx }

for {set k $want} {$k > 0} {incr k -1} {
    set i [expr {($wp - $k + $depth) % $depth}]
    set key [read_at $idx $i 0]
    set sg  [read_at $idx $i 1]
    set kv  [field $key 0 32]
    set sv  [expr {[field $sg 0 32] & 0xFFFF}]
    set we  [expr {($kv >> 31) & 1}]
    set lba [expr {$kv & 0x7FFFFFFF}]
    puts [format "#%04d  %s  lba %08x  sig %04x" \
              [expr {$want - $k}] [expr {$we ? "W" : "R"}] $lba $sv]
}

end_insystem_source_probe
