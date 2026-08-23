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
set P(data) $byport(8)
set P(ctx)  $byport(9)
set P(cx)   $byport(10)
foreach k {addr fc hand cs smap ps ma verd data ctx cx} {
    puts "== probe $k: [get_property NAME $P($k)] port [get_property PROBE_PORT $P($k)] width [get_property WIDTH $P($k)] =="
}

set depth [get_property CONTROL.DATA_DEPTH $ila]
# Half way by default, so the cycles before the trigger are kept.  A mode that
# qualifies the capture hard -- user instruction fetches only -- must not ask
# for that: the core collects the pre-trigger samples before it will even look
# at the trigger, and if qualified samples are rare it never arms at all.  That
# is what "did not trigger, core status IDLE" meant the first time.
set trigpos [expr {$depth / 2}]
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
    uerr { # any bus error on a user-mode access: FC 1 or 2, and FC 3 too,
           # which one comparator cannot exclude -- the decode sorts it out.
           set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd)
           set_property TRIGGER_COMPARE_VALUE eq3'b0XX   $P(fc) }
    uerr2 { # a user-mode bus error that is NOT the stack-growth probe.
            # Every new process faults at USRSTACK-1 on purpose so the kernel
            # can grow its stack, and that recoverable fault fires this trigger
            # first every time.  Excluding the one address gets past it to
            # whatever else is going wrong.
            set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X  $P(verd)
            set_property TRIGGER_COMPARE_VALUE eq3'b0XX    $P(fc)
            set_property TRIGGER_COMPARE_VALUE neq23'h7fffff $P(addr) }
    uonly { # Trigger on a user-mode fault that is not the stack-growth probe,
            # and -- the point of this mode -- keep only user-mode clocks in
            # the buffer.  With the qualifier on ~AS the window is a few tens
            # of microseconds and almost all of it is kernel; qualified on the
            # function code instead, 4096 samples are 4096 clocks of user
            # execution, which is the whole life of a short-lived process.
            # The post-trigger half then shows whether it resumed after the
            # fault or never ran again.
            set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X  $P(verd)
            set_property TRIGGER_COMPARE_VALUE eq3'b0XX    $P(fc)
            set_property TRIGGER_COMPARE_VALUE neq23'h7fffff $P(addr)
            set qualify_user 1 }
    uprog { # User instruction fetches only -- FC 2 -- as both the trigger and
            # the capture qualifier.  The buffer then holds 4096 clocks of
            # actual user-mode execution and nothing else: which addresses ran,
            # and how far each process got before it stopped running.
            set_property TRIGGER_COMPARE_VALUE eq3'b010 $P(fc)
            set qualify_prog 1 }
    uprogerr { # a bus error on a user *instruction* fetch: a process faulting on
               # its own text, which is what a child dying before it can exec
               # would look like.  Distinct from uerr/uerr2, which catch the
               # kernel's own MOVES into user space.
               set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd)
               set_property TRIGGER_COMPARE_VALUE eq3'b010   $P(fc) }
    ctxwr { # a write to either context register.  They live in one word at
            # FC_MAP offset 6 -- supervisor in the even byte, user in the odd
            # -- so P_A[23:1] is 3 for both and UDS/LDS says which.  A context
            # switch writes the user byte; if this never fires, every process
            # is sharing one context.
            set_property TRIGGER_COMPARE_VALUE eq3'b011      $P(fc)
            set_property TRIGGER_COMPARE_VALUE eq23'h000003  $P(addr)
            set_property TRIGGER_COMPARE_VALUE eq6'bX0XXXX   $P(hand) }
    ctxnz { # a context register write with a NON-ZERO value.  The PROM sets
            # both contexts to zero early in every boot and would otherwise
            # take the trigger every time; SunOS hands a process a context of
            # its own, 1..7, so a nonzero value is the kernel and not the
            # monitor.  A byte write drives the value on both halves of the
            # bus, so the data word is 0x0101 for context 1 and so on.
            set_property TRIGGER_COMPARE_VALUE eq3'b011      $P(fc)
            set_property TRIGGER_COMPARE_VALUE eq23'h000003  $P(addr)
            set_property TRIGGER_COMPARE_VALUE eq6'bX0XXXX   $P(hand)
            set_property TRIGGER_COMPARE_VALUE neq16'h0000   $P(data) }
    fbprobe { # the monitor's display probe.  msun's sunmon.c probes
              # MBMEM_BASE+0xC0000 = 0xEC0000 with bus errors caught, and sets
              # g_fbthere from whether it faulted; that one bit decides whether
              # the console goes to the screen or stays on the serial port.
              # Triggering on the address rather than on an error catches the
              # cycle either way, which is the point: it says whether the probe
              # faulted and, if it did, whether by timeout or protection.
              # FC 5, supervisor data: the probe itself.  Without that, the
              # trigger catches the PROM writing the page map for the same
              # address in control space, which is FC 3 and not the question.
              set_property TRIGGER_COMPARE_VALUE eq23'h760000 $P(addr)
              set_property TRIGGER_COMPARE_VALUE eq3'b101     $P(fc) }
    scc  { # any access in the console SCC's device page, 0xEEC800..0xEECFFF.
           # dbg_addr is P_A[23:1], so the page is the top 13 bits of 0x776400
           # and the low ten are don't-care.
           set_property TRIGGER_COMPARE_VALUE eq23'b1110111011001XXXXXXXXXX $P(addr) }
    supw { set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd)
           set_property TRIGGER_COMPARE_VALUE eq3'b101   $P(fc)
           # hand = {AS RW UDS LDS DTACK BERR}, active low, so RW low is a write
           set_property TRIGGER_COMPARE_VALUE eq6'bX0XXXX $P(hand) }
    fc1  { set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd)
           set_property TRIGGER_COMPARE_VALUE eq3'b001   $P(fc) }
    as   { set_property TRIGGER_COMPARE_VALUE eq6'b0XXXXX $P(hand) }
    default { puts "ERROR: MODE must be err, fc1, as, supw, scc, uerr, uerr2, uonly, uprog, uprogerr, ctxwr, ctxnz, fbprobe or reset, not '$mode'"; exit 1 }
}

# Capture control: keep bus cycles, drop the idle clocks between them.  4096
# samples is a few hundred cycles that way and a few microseconds otherwise.
# The trigger position, now that the mode is known.  A mode that qualifies the
# capture hard -- user instruction fetches only -- must not ask for a half
# buffer of history: the core collects the pre-trigger samples before it will
# even look at the trigger, and if qualified samples are rare it never arms.
# That is what "did not trigger, core status IDLE" meant the first time.
if {[info exists qualify_prog]} { set trigpos 16 }
set_property CONTROL.TRIGGER_POSITION $trigpos $ila
puts "== trigger position $trigpos of $depth =="

set_property CONTROL.CAPTURE_MODE BASIC $ila
if {[info exists qualify_prog]} {
    set_property CAPTURE_COMPARE_VALUE eq3'b010 $P(fc)
} elseif {[info exists qualify_user]} {
    # user-mode clocks only: FC 1, 2 (and 3, which one comparator cannot
    # exclude and which barely occurs in user mode anyway)
    set_property CAPTURE_COMPARE_VALUE eq3'b0XX $P(fc)
} else {
    set_property CAPTURE_COMPARE_VALUE eq6'b0XXXXX $P(hand)
}

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
