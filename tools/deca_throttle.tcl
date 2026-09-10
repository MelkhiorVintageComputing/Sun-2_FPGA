# Set the master-traffic throttle on a DECA build, over In-System Sources
# and Probes.
#
#   quartus_stp -t tools/deca_throttle.tcl              # report what is set
#   quartus_stp -t tools/deca_throttle.tcl <mask> [rand]
#
# <mask> is THR_MASK and [rand] is THR_RAND (0 or 1, default 0).  The gap
# sun2_dvma leaves between Wishbone transactions is
#
#     fixed  (rand 0):  mask >> 1 clocks, every time
#     random (rand 1):  uniform over [0, mask], so the same mean
#
# The two modes exist to separate two things a single knob conflates.  A gap
# changes both how *often* the master asks for memory and the phase
# relationship between its cycles and the CPU's.  Fixed and random at equal
# mean differ only in the second, so if a fixed gap is clean and a random gap
# of the same mean is not, the variable is alignment and not rate.
#
# mask 0 disables the throttle entirely and is exactly the behaviour of a
# build without it.
#
# NOTE this holds the JTAG chain: juart-terminal must be stopped first, and
# restarted afterwards to see the console again.

package require ::quartus::jtag
package require ::quartus::insystem_source_probe

proc b2i {s} { set v 0; foreach c [split $s ""] { set v [expr {$v*2 + ($c eq "1")}] }; return $v }

set hw [lindex [get_hardware_names] 0]
set dv [lindex [get_device_names -hardware_name $hw] 0]

# Instance info opens its own session and refuses if one is already up, so it
# has to come before start_insystem_source_probe.
set info [get_insystem_source_probe_instance_info -device_name $dv -hardware_name $hw]
set idx -1
foreach inst $info { if {[lindex $inst 3] eq "THRT"} { set idx [lindex $inst 0] } }
if {$idx < 0} {
    puts "no THRT instance in this bitstream."
    exit 1
}

start_insystem_source_probe -device_name $dv -hardware_name $hw

# write_source_data takes a DECIMAL value and silently ignores it -- not an
# error, not a warning, the source simply keeps its old contents.  Only
# -value_in_hex and a hex string land.  tools/deca_blktrace.tcl and
# tools/deca_trace.tcl both carry this note, having been bitten first.
proc wsrc {idx v} {
    write_source_data -instance_index $idx -value [format %X $v] -value_in_hex
}

proc show {idx} {
    set raw [read_source_data -instance_index $idx]
    set v   [b2i $raw]
    set m   [expr {$v & 0xFF}]
    set r   [expr {($v >> 8) & 1}]
    if {$m == 0} {
        puts "throttle: OFF (mask 0)"
    } elseif {$r} {
        puts [format "throttle: mask 0x%02x, RANDOM, gap uniform \[0,%d\], mean %.1f clocks" \
                  $m $m [expr {$m / 2.0}]]
    } else {
        puts [format "throttle: mask 0x%02x, FIXED, gap %d clocks" $m [expr {$m >> 1}]]
    }
    return $v
}

if {[llength $argv] == 0} {
    show $idx
    exit 0
}

set mask [expr {[lindex $argv 0] & 0xFF}]
set rand [expr {[llength $argv] > 1 ? ([lindex $argv 1] & 1) : 0}]
set val  [expr {($rand << 8) | $mask}]

wsrc $idx $val

# A knob that reaches no logic is this project's most repeated failure -- it
# has shipped three of them -- so the source is read back rather than trusted.
# The probe on this instance is wired straight to the source for that purpose.
set back [b2i [read_source_data -instance_index $idx]]
if {$back != $val} {
    puts [format "FAILED: wrote 0x%03x, reads back 0x%03x" $val $back]
    exit 1
}
show $idx
