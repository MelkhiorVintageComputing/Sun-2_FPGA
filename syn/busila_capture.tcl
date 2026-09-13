# Capture the bus history: every value on the 68010 bus and the memory side of
# the bridge before the master reads a wrong word.
#
#   vivado -mode batch -source syn/busila_capture.tcl \
#          -tclargs OUTDIR LTX [MINUTES] [QUAL] [TRIGPOS] [URL]
#
#   QUAL     chg  (default) store a sample only when anything probed changed:
#                 every distinct bus state, idle clocks dropped, several times
#                 the reach of 8192 plain samples
#            all  every clock, literally -- 8192 samples is 410 us at 20 MHz
#   TRIGPOS  sample index of the trigger, default 7/8 of the depth: the event
#            is what comes *before* it
#
# The trigger is dv_arrived_bad, which fires on the word after an isolated
# wrong one in a pattern run, so the wrong read itself is in the history.  It
# is the one trigger in this tree proven one-for-one against patwr's count.
#
# Arm it BEFORE patwr starts.  patwr writes the whole file and only then
# verifies, so every damaging read happens in the first half of a run; armed
# half-way, a capture waits for events that have already happened.
#
# Probe ports (sun2_busila, boards/Wukong/wukong_top.sv):
#   0 addr[22:0] P_A[23:1]   1 fc   2 hand {AS RW UDS LDS DTACK BERR} active low
#   3 cs {C_S4 C_S6 C_S8 C_S24}  4 data   5 dvma   6 ma (physical page)
#   7 bw_dat  the 32-bit word DDR3 returned   8 bw_ctl {cyc stb we ack sel[3:0]}
#   9 bw_adr  Wishbone word address   10 arrived_bad   11 cl_trig   12 chg

if {[llength $argv] < 2} {
    puts "ERROR: usage: busila_capture.tcl OUTDIR LTX \[MINUTES\] \[chg|all\] \[TRIGPOS\] \[URL\]"
    exit 1
}
set outdir  [file normalize [lindex $argv 0]]
set ltx     [file normalize [lindex $argv 1]]
set waitmin [expr {[llength $argv] > 2 ? [lindex $argv 2] : 90}]
set qual    [expr {[llength $argv] > 3 ? [lindex $argv 3] : "chg"}]
set tpos    [expr {[llength $argv] > 4 ? [lindex $argv 4] : ""}]
set url     [expr {[llength $argv] > 5 ? [lindex $argv 5] : "localhost:3121"}]
file mkdir $outdir

open_hw_manager
connect_hw_server -url $url
set targets [get_hw_targets]
if {[llength $targets] == 0} { puts "ERROR: no JTAG target at $url"; exit 1 }
current_hw_target [lindex $targets 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev

set ila ""
foreach i [get_hw_ilas -quiet] {
    if {[string match "*u_busila*" [get_property CELL_NAME $i]]} { set ila $i }
}
if {$ila eq ""} {
    puts "ERROR: no u_busila ILA in this bitstream (cores: [get_hw_ilas -quiet])"
    exit 1
}

foreach pr [get_hw_probes -of_objects $ila] {
    set byport([get_property PROBE_PORT $pr]) $pr
}
if {![info exists byport(12)]} { puts "ERROR: u_busila has no probe 12"; exit 1 }
foreach k [array names byport] {
    set w [get_property WIDTH $byport($k)]
    set_property TRIGGER_COMPARE_VALUE eq${w}'b[string repeat X $w] $byport($k)
    set_property CAPTURE_COMPARE_VALUE eq${w}'b[string repeat X $w] $byport($k)
}

set depth [get_property CONTROL.DATA_DEPTH $ila]
if {$tpos eq ""} { set tpos [expr {$depth - $depth / 8}] }
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property CONTROL.TRIGGER_POSITION $tpos $ila
set_property CONTROL.CAPTURE_MODE BASIC $ila

set_property TRIGGER_COMPARE_VALUE eq1'b1 $byport(10)
if {$qual eq "chg"} {
    set_property CAPTURE_COMPARE_VALUE eq1'b1 $byport(12)
} elseif {$qual ne "all"} {
    puts "ERROR: QUAL must be chg or all, not '$qual'"; exit 1
}

puts "== armed: u_busila, depth $depth, trigger at $tpos, qualifier $qual =="
run_hw_ila $ila
wait_on_hw_ila -timeout $waitmin $ila
set st [get_property STATUS.CORE_STATUS $ila]
if {$st ne "FULL"} {
    puts "== core status $st after $waitmin minutes, not FULL =="
    if {[catch {set data [upload_hw_ila_data $ila]} err]} {
        puts "   nothing to upload: $err"
        exit 1
    }
    write_hw_ila_data -force -csv_file $outdir/busila.csv $data
    puts "== wrote a PARTIAL capture to $outdir/busila.csv =="
    exit 0
}
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $outdir/busila.csv $data
puts "== wrote $outdir/busila.csv =="
close_hw_manager
