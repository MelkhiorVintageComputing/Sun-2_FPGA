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
puts "bridge address integrity (the span no pattern check can cover)"
puts [format "  loads       %s   <- the control" [rd $vio wb_n_load]]
puts [format "  wrong addr  %s" [rd $vio wb_n_adrbad]]
puts [format "  half pat    %s   <- control for the line below" [rd $vio wb_n_outpat]]
puts [format "  wrong half  %s" [rd $vio wb_n_outbad]]
puts ""
puts "the last span: bridge word -> P_DOUT mux -> master capture"
puts [format "  mem reads   %s   <- the control" [rd $vio dv_n_mux]]
puts [format "  mux wrong   %s   <- P_DOUT was not the bridge word" [rd $vio dv_n_mux_bad]]
puts [format "  pattern     %s   <- ... of which were the pattern" [rd $vio dv_n_pat32]]
puts [format "  pattern bad %s" [rd $vio dv_n_pat32_bad]]
puts ""
puts "ARMED BY POSITION: was the word already wrong when it arrived?"
puts [format "  in a run    %s   <- the control" [rd $vio dv_n_arm32]]
puts [format "  ARRIVED BAD %s   <- wrong before it entered the disk path" [rd $vio dv_n_arm32_bad]]
puts ""
puts "does the disk controller hold its DVMA request still?"
puts [format "  transactions %s   <- the control" [rd $vio dv_n_xact]]
puts [format "  ADDR MOVED   %s   <- wb_adr_i changed mid-transaction" [rd $vio dv_n_adr_move]]
puts [format "  DATA MOVED   %s   <- wb_dat_i changed mid-write" [rd $vio dv_n_dat_move]]
puts ""
puts "DOUBLE READ: every read issued twice, the two answers compared"
puts [format "  compared     %s   <- the control" [rd $vio rr_n]]
puts [format "  DISAGREED    %s" [rd $vio rr_bad]]
puts ""
puts "Zero here, with ARRIVED BAD non-zero, means memory really did hold that"
puts "word at that moment and the right value arrived later -- a visibility or"
puts "ordering fault, not a read-path one.  Non-zero means the read path."
puts ""
puts "the sector buffer: what the disk controller stored"
puts [format "  bytes       %s   <- the control" [rd $vio xy_n_sb]]
puts [format "  wrong raw   %s   (includes runs: metadata, not the pattern)" [rd $vio xy_n_sb_bad]]
puts [format "  wrong iso   %s   <- isolated, the real corruptions" [rd $vio xy_n_sb_iso]]
puts [format "  DROPPED     %s   <- DMA writes the buffer port threw away" [rd $vio xy_n_drop]]
puts ""
puts "the same buffer, read back OUT to the card"
puts [format "  bytes       %s   <- the control" [rd $vio xy_n_rd]]
puts [format "  wrong       %s   <- written right, read back wrong" [rd $vio xy_n_rd_bad]]
puts ""
puts "Wrong here indicts sun2_dvma's assembly and the Wishbone handoff, which"
puts "the SCSI card shares.  Right here, with the card interface still wrong,"
puts "puts it in the sector buffer or blk_sd."
puts ""
puts "P_DATA_OUT is latched with the current P_ADR_IN, not the address the"
puts "request went out with.  Every pattern check predicts the expected word"
puts "FROM the address, so a response matched to the wrong address satisfies"
puts "all of them and still hands the master a word from somewhere else."
puts ""
close_hw_manager
