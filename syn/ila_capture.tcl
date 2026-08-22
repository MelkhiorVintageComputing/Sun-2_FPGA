# Arm the MMU ILA, wait for it to trigger, and write what it captured.
#
#   vivado -mode batch -source syn/ila_capture.tcl -tclargs OUTDIR MODE [LTX] [URL] [MINUTES] [BIT]
#
# Give BIT to program the board and arm in the same session.  That matters
# when the thing being caught happens soon after the machine starts: arming
# from a second Vivado costs the best part of a minute of startup, and a
# failure that arrives a minute after the bitstream loads will already have
# happened by then.  Here the gap is a second.
#
# MODE picks the trigger:
#   err   any bus error at all -- which errors happen, and in what order
#   fc1   a bus error on a user-data access.  Every PROM device probe is FC 5,
#         so this is the kernel's own access and nothing else
#   as    any bus cycle, no error needed -- a sanity capture, and the way to
#         see what the machine is doing when it is not failing
#   reset the 68010 fetching its reset vector at address 0, which happens only
#         out of reset.  The point is not the trigger but the 2048 samples of
#         history in front of it: after a double bus fault the CPU halts and
#         the board resets it, so what killed the machine is sitting in the
#         pre-trigger half of the buffer.  A double fault cannot be described
#         to a basic trigger unit -- "two errors with no good cycle between"
#         needs the advanced one -- but its consequence can.
#   supw  a bus error on a supervisor data write.  A double bus fault -- what
#         the watchdog reset means -- is a bus error taken while the CPU is
#         stacking the frame for an earlier exception, and that stack push is
#         a supervisor data write.  So this catches the fatal one, and the
#         pre-trigger half of the buffer holds what led to it
#
# Writes OUTDIR/ila.csv (every sample, every field) and prints a decoded window
# round the trigger, because a capture nobody can read is not evidence.
#
# The field map is the comment beside dbg_bus in rtl/sun2-common/sun2_fpga.v.
# Vivado names the probes after the net, so probe0 is `dbg_bus' and probe1..7
# are `dbg_bus_1'..`dbg_bus_7'.

if {[llength $argv] < 2} {
    puts "ERROR: usage: ila_capture.tcl OUTDIR MODE \[LTX\] \[URL\]"
    exit 1
}
set outdir [file normalize [lindex $argv 0]]
set mode   [lindex $argv 1]
set ltx    ""
set url    localhost:3121
if {[llength $argv] > 2 && [lindex $argv 2] ne ""} { set ltx [file normalize [lindex $argv 2]] }
if {[llength $argv] > 3 && [lindex $argv 3] ne ""} { set url [lindex $argv 3] }
# How long to wait for the trigger.  A failure that only shows once init is
# running is minutes of boot away, and the default five is not enough.
set waitmin 5
if {[llength $argv] > 4 && [lindex $argv 4] ne ""} { set waitmin [lindex $argv 4] }
set bit ""
if {[llength $argv] > 5 && [lindex $argv 5] ne ""} { set bit [file normalize [lindex $argv 5]] }
file mkdir $outdir

open_hw_manager
connect_hw_server -url $url
set targets [get_hw_targets]
if {[llength $targets] == 0} { puts "ERROR: no JTAG target at $url"; exit 1 }
current_hw_target [lindex $targets 0]
set jtag_limit 20000000
set pick ""
foreach f [list_property_value PARAM.FREQUENCY [current_hw_target]] {
    if {$f <= $jtag_limit && ($pick eq "" || $f > $pick)} { set pick $f }
}
if {$pick ne ""} { set_property PARAM.FREQUENCY $pick [current_hw_target] }
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
if {$ltx ne ""} {
    set_property PROBES.FILE      $ltx $dev
    set_property FULL_PROBES.FILE $ltx $dev
}
refresh_hw_device $dev

# Program first if asked, so the machine starts with the ILA armed a moment
# later rather than a Vivado startup later.
if {$bit ne ""} {
    if {![file exists $bit]} { puts "ERROR: no such bitstream: $bit"; exit 1 }
    set_property PROGRAM.FILE $bit $dev
    puts "== programming $dev with $bit =="
    program_hw_devices $dev
    refresh_hw_device $dev
}

set ila [lindex [get_hw_ilas -quiet] 0]
if {$ila eq ""} {
    puts "ERROR: no ILA on the device.  Is this an ILA=1 bitstream?"
    exit 1
}

# The eight probes, by PROBE_PORT and never by name.
#
# The names are off by one from the ports: every probe is a slice of the same
# net, so Vivado called the first one it met `dbg_bus' and numbered the rest
# from there -- and the one it met first is port 7, the verdict.  `dbg_bus_1'
# is port 0, the address.  Reading a capture by name gets every field wrong,
# and gets it wrong quietly, which is why this indexes by port.
foreach pr [get_hw_probes -of_objects $ila] {
    set byport([get_property PROBE_PORT $pr]) $pr
}
set P(addr) $byport(0)
set P(fc)   $byport(1)
set P(hand) $byport(2)
set P(cs)   $byport(3)
set P(smap) $byport(4)
set P(ps)   $byport(5)
set P(ma)   $byport(6)
set P(verd) $byport(7)
foreach k {addr fc hand cs smap ps ma verd} {
    puts "== probe $k: [get_property NAME $P($k)] port [get_property PROBE_PORT $P($k)] width [get_property WIDTH $P($k)] =="
}

set depth [get_property CONTROL.DATA_DEPTH $ila]
set_property CONTROL.TRIGGER_POSITION [expr {$depth / 2}] $ila
set_property CONTROL.WINDOW_COUNT 1 $ila

# Everything don't-care first, so a mode only has to say what it constrains.
foreach k [array names P] {
    set w [get_property WIDTH $P($k)]
    set_property TRIGGER_COMPARE_VALUE eq${w}'b[string repeat X $w] $P($k)
    set_property CAPTURE_COMPARE_VALUE eq${w}'b[string repeat X $w] $P($k)
}

# verd = {VALID, PROTERR_raw, PROTERR, TIMEOUT, ERR, MATCH_MEM}, so ERR is bit 1
# hand = {AS RW UDS LDS DTACK BERR}, all active low, so AS asserted is bit 5 = 0
switch -- $mode {
    err  { set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd) }
    reset { set_property TRIGGER_COMPARE_VALUE eq3'b110 $P(fc)
            set_property TRIGGER_COMPARE_VALUE eq23'b[string repeat 0 23] $P(addr) }
    supw { set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd)
           set_property TRIGGER_COMPARE_VALUE eq3'b101   $P(fc)
           # hand = {AS RW UDS LDS DTACK BERR}, active low, so RW low is a write
           set_property TRIGGER_COMPARE_VALUE eq6'bX0XXXX $P(hand) }
    fc1  { set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd)
           set_property TRIGGER_COMPARE_VALUE eq3'b001   $P(fc) }
    as   { set_property TRIGGER_COMPARE_VALUE eq6'b0XXXXX $P(hand) }
    default { puts "ERROR: MODE must be err, fc1, as, supw or reset, not '$mode'"; exit 1 }
}

# Capture control: keep bus cycles, drop the idle clocks between them.  4096
# samples is a few hundred cycles that way and a few microseconds otherwise.
set_property CONTROL.CAPTURE_MODE BASIC $ila
set_property CAPTURE_COMPARE_VALUE eq6'b0XXXXX $P(hand)

puts "== armed: mode $mode, depth $depth, trigger at [expr {$depth / 2}] =="
run_hw_ila $ila
wait_on_hw_ila -timeout $waitmin $ila
# STATUS.CORE_STATUS, not CORE_STATUS: the bare name is not a property of an
# hw_ila at all and asking for it is an error rather than an empty answer.
#
# FULL is the one that means success -- triggered, buffer filled, data waiting
# to be uploaded.  IDLE is the state of a core that was never armed.  A core
# still sitting in WAIT-TRIGGER or PRE-TRIGGER is the real "nothing matched".
set st [get_property STATUS.CORE_STATUS $ila]
if {$st ne "FULL"} {
    puts "== did not trigger in $waitmin minutes; core status $st =="
    puts "   Nothing matched.  With mode=err that means no bus error at all --"
    puts "   check the machine is running, then try mode=as."
    exit 1
}
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $outdir/ila.csv $data
puts "== wrote $outdir/ila.csv =="

# A decoded window round the trigger.  The CSV has everything; this is what can
# be read without leaving the terminal.
puts "== [get_property STATUS.SAMPLE_COUNT $ila] samples captured =="
