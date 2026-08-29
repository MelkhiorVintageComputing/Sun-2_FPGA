# Pulse the Sun-2's reset over JTAG, and read its console event counters.
#
#   quartus_stp -t tools/deca_reset.tcl [reset]
#
# The DECA's only reset is a physical button, and configuring the FPGA tears
# down any open JTAG UART session -- so a terminal cannot be attached before the
# machine starts printing, and the boot banner is about the size of the JTAG
# UART's 64-byte write FIFO.
#
# **Pulse this FIRST, then attach the terminal.**  That ordering matters and is
# the whole trick:
#
#     quartus_stp -t tools/deca_reset.tcl reset
#     juart-terminal
#
# ISSP and juart-terminal cannot both hold the JTAG chain, so attaching first
# and pulsing second kills the terminal and captures nothing -- which was once
# mistaken here for the two being unusable together at all, and a redundant
# "hold the machine until a console attaches" mechanism was built and then
# thrown away on the strength of it.  Reset first works because the PROM spends
# seconds testing 7 MiB before it prints anything worth reading.
#
# With no argument it only reads the counters, which is non-disturbing.
package require ::quartus::jtag
package require ::quartus::insystem_source_probe

proc b2i {s} { set v 0; foreach c [split $s ""] { set v [expr {$v*2 + ($c eq "1")}] }; return $v }

set hw [lindex [get_hardware_names] 0]
set dv [lindex [get_device_names -hardware_name $hw] 0]

# NOTE: instance info must be fetched BEFORE a session is opened -- it opens its
# own and refuses if one is already up.  The error it gives ("already an active
# session") names the wrong call.
set info [get_insystem_source_probe_instance_info -device_name $dv -hardware_name $hw]
set idx -1
foreach inst $info { if {[lindex $inst 3] eq "SUN2"} { set idx [lindex $inst 0] } }
if {$idx < 0} { puts "no SUN2 probe instance found; is this the DECA machine build?"; exit 1 }

start_insystem_source_probe -device_name $dv -hardware_name $hw

if {[lindex $argv 0] eq "reset"} {
    # -value_in_hex, because write_source_data silently ignores a decimal
    # value -- no error, no warning, the source simply keeps what it had.
    # Found with the wider source on the trace recorder, where read_source_data
    # could show it; a 1-bit source gives no such hint, so whether this reset
    # ever actually pulsed before now is not something the old code could say.
    write_source_data -instance_index $idx -value 1 -value_in_hex
    after 50
    write_source_data -instance_index $idx -value 0 -value_in_hex
    puts "reset pulsed (a warm reset: the PROM takes its non-power-up path and"
    puts "  prints `Watchdog reset!' and goes straight to the prompt, skipping the"
    puts "  device probes.  Re-program the device for a cold boot.)"
}

set raw [read_probe_data -instance_index $idx]
end_insystem_source_probe

# Bit order, MSB first, matching deca_top's altsource_probe:
#   63:56 RDCAL  55 cal_pass  54 ddr3_ready  53 link  52 phy_present
#   51 cfg_done  50:49 speed  48 full_duplex
#   47:40 todebug  39:32 diag_leds  31:24 wr  23:16 rd  15:8 rx  7:0 tx
# then, appended below those (so nothing above moves):
#   blk_ready  blk_err  blk_count[31:0]   -- string indices 64, 65, 66..97
set rdcal   [b2i [string range $raw  0  7]]
set calpass [string index $raw  8]
set ready   [string index $raw  9]
set link    [string index $raw 10]
set present [string index $raw 11]
set cfgdone [string index $raw 12]
set speed   [b2i [string range $raw 13 14]]
set fd      [string index $raw 15]
set todbg   [b2i [string range $raw 16 23]]
set diag    [b2i [string range $raw 24 31]]

puts [format "DDR3   : ready=%s cal_pass=%s rdcal=0x%02x" $ready $calpass $rdcal]
puts [format "PHY    : present=%s cfg_done=%s link=%s speed=%s duplex=%s" \
        $present $cfgdone $link [expr {$speed == 0 ? "10" : ($speed == 1 ? "100" : "1000")}] \
        [expr {$fd eq "1" ? "full" : "half"}]]
puts [format "front  : diag_leds = 0x%02x" $diag]

# The console bridge's event counters.  Each counts one stage of the byte path,
# so differencing two readings across a known input says which stage loses or
# duplicates a byte -- rx and wr are the machine->host direction, rd and tx the
# host->machine one.  They were on the probe and in the comment above from the
# start and never printed, which is the same shape as a knob that reaches the
# build and not the logic: an instrument whose output is discarded is not an
# instrument.
set c_wr [b2i [string range $raw 32 39]]
set c_rd [b2i [string range $raw 40 47]]
set c_rx [b2i [string range $raw 48 55]]
set c_tx [b2i [string range $raw 56 63]]
puts [format "console: machine->host rx=%d wr=%d   host->machine rd=%d tx=%d (mod 256)" \
        $c_rx $c_wr $c_rd $c_tx]

# The disk, if one is fitted.  Meaningful with any card, blank or not: ready is
# blk_sd having completed the SPI init handshake and count is the capacity out
# of the card's CSD, neither of which needs a valid disk image.  A build with no
# Xylogics reports ready=0 count=0, which is also what a missing card gives --
# the DECA brings no card-detect line to the FPGA, so those two cannot be told
# apart here.
if {[string length $raw] >= 98} {
    set d_ready [string index $raw 64]
    set d_err   [string index $raw 65]
    set d_count [b2i [string range $raw 66 97]]
    set gib     [expr {$d_count * 512.0 / 1073741824.0}]
    puts [format "disk   : ready=%s err=%s blocks=%d (%.1f GiB)" \
            $d_ready $d_err $d_count $gib]
    if {$d_ready eq "0" && $d_count == 0} {
        puts "         ^ no media: either no card, a card that never finished"
        puts "           its SPI init, or a build without SUN2_XY450."
    }
}

# todebug, decoded.  This is the panel BRINGUP.md says to read first.
puts [format "todebug: 0x%02x  heartbeat=%d reset=%d seen_err=%d fc_err=%d diag_wr=%d seen_stall=%d" \
        $todbg [expr {($todbg >> 7) & 1}] [expr {($todbg >> 6) & 1}] \
        [expr {($todbg >> 5) & 1}] [expr {($todbg >> 2) & 7}] \
        [expr {($todbg >> 1) & 1}] [expr {$todbg & 1}]]
if {[expr {$todbg & 1}]} {
    puts "         ^ seen_stall: a bus cycle was never answered -- no DTACK and"
    puts "           no timeout.  That is the memory path, and nothing else."
} elseif {[expr {($todbg >> 5) & 1}]} {
    puts [format "         ^ seen_err: a cycle ended in a bus error, first one at FC=%d" \
            [expr {($todbg >> 2) & 7}]]
    puts "           FC 5 or 6 on a healthy boot is just the PROM probing devices."
}
