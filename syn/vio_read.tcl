# Read the adapter's clock-crossing counters over the VIO.
#
#   vivado -mode batch -source syn/vio_read.tcl -tclargs [LTX] [URL]
#
# Built into any ILA=1 bitstream.  Unlike an ILA this needs no trigger and no
# arming: run the workload, then read the counts.  A capture window is 205 us
# against a workload of minutes, which is why the ILA could never answer this.
#
#   reads   read acknowledgements the adapter returned, mod 65536
#   pattern ... whose word matched tools/patwr -u's pattern *before* the
#           crossing.  This is the control: a zero in `corrupted' means nothing
#           unless this is large, because the check can only fire on a word it
#           recognised in the first place.
#   corrupted  ... and did not match after crossing into the CPU's domain.
#
# Non-zero `corrupted' is the clock crossing damaging data.  Zero, with
# `pattern' large and patwr reporting bad words in software, clears the
# crossing and sends the search below the adapter.
set ltx ""
set url "localhost:3121"
if {[llength $argv] > 0 && [lindex $argv 0] ne ""} { set ltx [file normalize [lindex $argv 0]] }
if {[llength $argv] > 1 && [lindex $argv 1] ne ""} { set url [lindex $argv 1] }

open_hw_manager
connect_hw_server -url $url
set targets [get_hw_targets]
if {[llength $targets] == 0} { puts "ERROR: no JTAG target at $url"; exit 1 }
current_hw_target [lindex $targets 0]
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
if {$ltx ne ""} { set_property PROBES.FILE $ltx [current_hw_device] }
refresh_hw_device [current_hw_device]

set vios [get_hw_vios -quiet]
if {[llength $vios] == 0} {
    puts "ERROR: no VIO on the device.  Is this an ILA=1 bitstream?"
    exit 1
}
set vio [lindex $vios 0]
refresh_hw_vio $vio

proc rd {vio name} {
    set p [get_hw_probes -quiet -of_objects $vio $name]
    if {$p eq ""} { return "?" }
    return [get_property INPUT_VALUE $p]
}

set r [rd $vio xchk_n_read]
set p [rd $vio xchk_n_pat]
set b [rd $vio xchk_n_bad]
puts ""
puts "adapter clock crossing (rd_lane in ui_clk -> wb_dat_o in cpu_clk)"
puts [format "  reads       %s" $r]
puts [format "  pattern     %s   <- the control: must be large to believe the next line" $p]
puts [format "  corrupted   %s" $b]
puts [format "  last got    %s   exp %s" [rd $vio xchk_got] [rd $vio xchk_exp]]
puts ""
puts "the write crossing (req_dat latched in cpu_clk -> read in ui_clk)"
puts [format "  pattern     %s   <- the control for the line below" [rd $vio xchk_n_wpat]]
puts [format "  corrupted   %s" [rd $vio xchk_n_wbad]]
puts ""
puts "Run tools/patwr with -u: only the uniform pattern is predictable from"
puts "the address alone.  Without it most words are not checkable and both"
puts "pattern controls stay small, which makes a zero meaningless."
puts ""
close_hw_manager
