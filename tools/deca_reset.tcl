# Pulse the Sun-2's reset over JTAG, and read its console event counters.
#
#   quartus_stp -t tools/deca_reset.tcl [reset]
#
# The DECA's only reset is a physical button, and configuring the FPGA tears
# down any open JTAG UART session -- so a terminal cannot be attached before the
# machine starts printing, and the boot banner is about the size of the JTAG
# UART's 64-byte write FIFO.  Attach the terminal first, then pulse this, and
# the boot is watched from its first byte.
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
    write_source_data -instance_index $idx -value 1
    after 50
    write_source_data -instance_index $idx -value 0
    puts "reset pulsed"
}

set raw [read_probe_data -instance_index $idx]
end_insystem_source_probe

puts [format "console: rx_valid=%d wr_data=%d rd_valid=%d tx_start=%d" \
        [b2i [string range $raw 48 63]] [b2i [string range $raw 32 47]] \
        [b2i [string range $raw 16 31]] [b2i [string range $raw 0 15]]]
