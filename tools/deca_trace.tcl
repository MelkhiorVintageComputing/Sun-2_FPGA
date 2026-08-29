# Read the DECA's MMU trace recorder and decode it.
#
#     syn/altera.sh quartus_stp -t tools/deca_trace.tcl [> trace.csv]
#
# The Wukong reads the same 118-bit dbg_bus through a Vivado ILA and
# syn/ila_capture.tcl; this is the Quartus half.  SignalTap cannot stand in for
# it -- quartus_stp runs an acquisition but will not create one, so an .stp
# cannot come out of a scripted flow -- so the buffer is ordinary RTL
# (rtl/sun2-common/sun2_trace.v, unit-tested by `make -C sim trace') and this
# reads it out over In-System Sources and Probes.
#
# Build the bitstream with TRACE=1; without it the instance is absent and this
# says so rather than printing an empty capture.
#
#   source[7:0]  sample index      source[8]   which half of the 118 bits
#   source[21:9] trigger page      source[22]  hold (clears and holds capture)
#   probe        low half, or {done, triggered, wr_ptr[7:0], high 54 bits}
#
# Pass a page to retarget and re-arm:
#
#     quartus_stp -t tools/deca_trace.tcl 0x1DE0     the VME boot PROM
#     quartus_stp -t tools/deca_trace.tcl 0x1DC5     the SCSI registers
#
# With no argument it reads whatever the running capture holds, on the page the
# bitstream was built with.  Re-arming clears the buffer, so the machine has to
# reach the event again afterwards -- reset it, or just wait if the event
# repeats.
#
# The field names below are sun2_fpga.v's, whose map tb_sun2 checks against the
# signals it claims to carry on every clock edge of every simulated boot.  That
# is the only reason it is safe to slice a bus by bit number in a second file.

package require ::quartus::jtag
package require ::quartus::insystem_source_probe

proc b2i {s} { set v 0; foreach c [split $s ""] { set v [expr {$v*2 + ($c eq "1")}] }; return $v }

# probe data comes back MSB first, so bit N of a W-wide probe is at index W-1-N.
proc fld {raw w hi lo} { return [b2i [string range $raw [expr {$w-1-$hi}] [expr {$w-1-$lo}]]] }

set hw [lindex [get_hardware_names] 0]
set dv [lindex [get_device_names -hardware_name $hw] 0]

set info [get_insystem_source_probe_instance_info -device_name $dv -hardware_name $hw]
set idx -1
foreach inst $info { if {[lindex $inst 3] eq "TRAC"} { set idx [lindex $inst 0] } }
if {$idx < 0} {
    puts "no TRAC instance on this device."
    puts "Build with:  make -C syn quartus MACHINE=vme CPU_DIV=<n> TRACE=1"
    exit 1
}

start_insystem_source_probe -device_name $dv -hardware_name $hw

set DEPTH 256
set POST  192

# Retarget and re-arm, if asked.  Hold clears the capture; releasing it starts
# a fresh one on the new page.
set page 0
if {[llength $argv] > 0} {
    set page [expr {[lindex $argv 0]}]
    write_source_data -instance_index $idx -value [expr {(1 << 22) | ($page << 9)}]
    after 100
    write_source_data -instance_index $idx -value [expr {$page << 9}]
    puts [format "# re-armed on page A\[23:11\]=0x%04X (addresses 0x%06X..0x%06X)" \
            $page [expr {$page << 11}] [expr {($page << 11) + 0x7FF}]]
    puts "# the buffer is now empty; the machine must reach that page again."
}
set base [expr {$page << 9}]

# Status first.  It rides in the high half, so any address will do.
write_source_data -instance_index $idx -value [expr {$base | (1 << 8)}]
after 5
set hi [read_probe_data -instance_index $idx]
set done      [fld $hi 64 63 63]
set triggered [fld $hi 64 62 62]
set wrptr     [fld $hi 64 61 54]

puts "# triggered=$done/$triggered wr_ptr=$wrptr"
if {!$triggered} {
    puts "# the trigger never fired: no bus cycle reached the trigger page."
    puts "# That is itself an answer -- check the page against what the PROM touches."
}
if {!$done} { puts "# capture still running (triggered but POST samples not yet taken)" }

# Unwrap: the oldest sample is the one wr_ptr points at, and the trigger sample
# sits DEPTH-POST-1 later.
set trigrow [expr {$DEPTH - $POST - 1}]
puts "row,rel,A,FC,AS,RW,UDS,LDS,DTACK,BERR,C_S4,C_S6,C_S8,C_S24,smap,ps_pmap,ma_pmap,VALID,PROTERR_raw,PROTERR,TIMEOUT,ERR,MATCH_MEM,data,dvma"

for {set i 0} {$i < $DEPTH} {incr i} {
    set a [expr {($wrptr + $i) % $DEPTH}]

    write_source_data -instance_index $idx -value [expr {$base | $a}]
    after 2
    set lo [read_probe_data -instance_index $idx]
    write_source_data -instance_index $idx -value [expr {$base | (1 << 8) | $a}]
    after 2
    set hi [read_probe_data -instance_index $idx]

    # Reassemble the 118-bit sample: bits 63:0 from the low read, 117:64 from
    # the low 54 bits of the high read.
    set s [string range $hi 10 63][string range $lo 0 63]

    set A     [expr {[fld $s 118 73 51] << 1}]
    set rel   [expr {$i - $trigrow}]
    puts [format "%d,%+d,%06X,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%03X,%03X,%03X,%d,%d,%d,%d,%d,%d,%04X,%d" \
      $i $rel $A \
      [fld $s 118 50 48] \
      [fld $s 118 47 47] [fld $s 118 46 46] [fld $s 118 45 45] [fld $s 118 44 44] \
      [fld $s 118 43 43] [fld $s 118 42 42] \
      [fld $s 118 41 41] [fld $s 118 40 40] [fld $s 118 39 39] [fld $s 118 38 38] \
      [fld $s 118 37 30] [fld $s 118 29 18] [fld $s 118 17 6] \
      [fld $s 118 5 5] [fld $s 118 4 4] [fld $s 118 3 3] \
      [fld $s 118 2 2] [fld $s 118 1 1] [fld $s 118 0 0] \
      [fld $s 118 89 74] [fld $s 118 101 101]]
}

end_insystem_source_probe
