# Arm the MMU ILA, wait for it to trigger, and write what it captured.
#
#   vivado -mode batch -source syn/ila_capture.tcl -tclargs OUTDIR MODE [LTX] [URL] [MINUTES] [BIT] [ARMDELAY]
#
# ARMDELAY waits that many seconds after programming before arming.  A VME boot
# takes ten device-probe bus errors before it reaches the boot line, so a
# trigger on `any bus error' spends the buffer on the first probe and never
# sees the one that matters.  Waiting past the probes is the difference between
# catching a failure and catching a start-up.
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
#   ether the VME machine's Ethernet control register, device page 0xFE1 at
#         virtual 0xEE3000.  This is where the PROM kicks the 82586: the
#         RESET* bit its driver asserts on every ieinit, and the Channel
#         Attention that tells the chip to go and look at its SCP.  Nothing
#         else lives in that page, so every sample is the driver talking to
#         the chip.  Use it to answer "did the machine ever start the part"
#   dvma  any cycle driven by a bus master that is not the CPU -- the 82586 on
#         a VME machine, the Xylogics on a MultiBus one.  dbg_bus carries
#         dvma_active as bit 101 for exactly this: top_fpga muxes the master
#         onto the CPU's wires deliberately, so nothing else on the bus can
#         tell the two apart
#   dvmaseq  every DVMA cycle and nothing else, one sample each, trigger near
#         the front: 4096 master cycles of history with no CPU traffic in the
#         way.  This is the one to reach for when the question is what the
#         chip read and wrote, in order
#   scp   the 82586 fetching its System Configuration Pointer, at 0xFFFFF6.
#         That address is hard-wired in the part -- sun2_ethernet.sv ties
#         scp_addr_i to it -- so this is the chip's *first* bus cycle as a
#         master, and the cleanest possible answer to "did DVMA ever happen".
#         If `ether' fires and this does not, the driver started a chip that
#         never took the bus; if this fires, the DVMA path works and the
#         question moves to what it read
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
# Seconds to wait after programming before arming.  See ARMDELAY above.
set armdelay 0
if {[llength $argv] > 6 && [lindex $argv 6] ne ""} { set armdelay [lindex $argv 6] }
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
set P(dvma) $byport(11)
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
    iack { # an interrupt acknowledge: CPU space, FC 7, with the level the CPU
           # is acknowledging on A3-A1.  Nothing else uses FC 7, so every
           # sample is an IACK and dbg_addr[3:1] names the level.
           #
           # This is the free half of "which interrupts fire": it sees what the
           # CPU *took*.  A request that is never taken -- the level 5 clock on
           # the MultiBus machine -- shows up here only as an absence, so read
           # a capture with no level 5 in it as a question, not an answer.
           set_property TRIGGER_COMPARE_VALUE eq3'b111 $P(fc)
           set_property TRIGGER_COMPARE_VALUE eq6'b0XXXXX $P(hand) }
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
            #
            # KCX narrows the trigger to one context, which is how you get a
            # *particular* process rather than the first one to run.  Armed
            # from boot with no KCX the buffer fills with pid 1's own startup
            # and never reaches its children; KCX=3 skips to the first process
            # that is not init and shows it from its very first instruction.
            # The context number is whatever ctxalloc handed out, so read it
            # off an earlier capture (dbg_cx) rather than assuming.
            set_property TRIGGER_COMPARE_VALUE eq3'b010 $P(fc)
            if {[info exists ::env(KCX)]} {
                puts "== uprog: only context $::env(KCX) =="
                set_property TRIGGER_COMPARE_VALUE eq3'b[format %03b $::env(KCX)] $P(cx)
            }
            set qualify_prog 1 }
    uprogerr { # a bus error on a user *instruction* fetch: a process faulting on
               # its own text, which is what a child dying before it can exec
               # would look like.  Distinct from uerr/uerr2, which catch the
               # kernel's own MOVES into user space.
               set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd)
               set_property TRIGGER_COMPARE_VALUE eq3'b010   $P(fc) }
    kpc { # a supervisor instruction fetch of one named kernel routine, given
          # as a byte address in the KPC environment variable:
          #
          #   KPC=6958a vivado ... -tclargs OUTDIR kpc ...     (_setregs)
          #
          # tools/pcsym KERNEL --list is where the address comes from.  This is
          # the "did the kernel ever get here" question, which a symbolised
          # trace can only answer for the few hundred cycles a buffer holds --
          # a routine that runs once per process is not going to be in one.
          # P_A is A[23:1], so the byte address is shifted down by one.
          if {![info exists ::env(KPC)]} {
              error "mode kpc needs KPC=<kernel byte address in hex>"
          }
          set kaddr [expr {[scan $::env(KPC) %x] >> 1}]
          # KFC picks the function code (default 6, a supervisor instruction
          # fetch).  KFC=5 with KRW turns this into "any supervisor data access
          # to one address", which is how you ask what happened to a particular
          # word of memory rather than to a particular routine.
          set kfc 6
          if {[info exists ::env(KFC)]} { set kfc $::env(KFC) }
          puts "== kpc: FC $kfc at byte address 0x[format %x [scan $::env(KPC) %x]] =="
          set_property TRIGGER_COMPARE_VALUE eq3'b[format %03b $kfc] $P(fc)
          set_property TRIGGER_COMPARE_VALUE eq23'h[format %06x $kaddr] $P(addr)
          # KCX narrows to one context, which is how a capture picks out a
          # particular process: the parent and the child run the same code at
          # the same address, and only the context tells them apart.
          if {[info exists ::env(KCX)]} {
              puts "== kpc: only context $::env(KCX) =="
              set_property TRIGGER_COMPARE_VALUE eq3'b[format %03b $::env(KCX)] $P(cx)
          }
          # KQUSER stores only user-mode clocks, the way `uonly' does.  The
          # trigger is per *sample*, not per bus cycle, so it cannot be made to
          # skip a faulting access: ERR only asserts at the end of the cycle and
          # its early samples look error-free.  What works instead is to trigger
          # on the fault and let the buffer reach far enough forward to hold the
          # retry -- which it does once the kernel's fault handling, thousands of
          # supervisor cycles of it, is not being stored.
          if {[info exists ::env(KQUSER)]} { set qualify_user 1 }
          # KERR selects on the error terms: KERR=1 only the cycle that faults,
          # KERR=0 only one that does not.  That is how you catch the *retry*
          # of a faulted access rather than the fault -- the first matching
          # cycle is always the fault, and the interesting one is the read that
          # follows once the handler has fixed the mapping, because that is the
          # value the instruction actually gets.
          # verd = {VALID PROTERR_raw PROTERR TIMEOUT ERR MATCH_MEM}, ERR bit 1.
          if {[info exists ::env(KERR)]} {
              if {$::env(KERR)} { set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd) } \
              else              { set_property TRIGGER_COMPARE_VALUE eq6'bXXXX0X $P(verd) }
          }
          # hand = {AS RW UDS LDS DTACK BERR}, active low, so RW is bit 4 and a
          # read leaves it high.  KRW=1 reads only, KRW=0 writes only.
          if {[info exists ::env(KRW)]} {
              if {$::env(KRW)} { set_property TRIGGER_COMPARE_VALUE eq6'bX1XXXX $P(hand) } \
              else             { set_property TRIGGER_COMPARE_VALUE eq6'bX0XXXX $P(hand) }
          } }
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
    ether { # the VME Ethernet's control register: I/O page 0xFE1, reached as
            # supervisor data.  Keyed on the *physical* page out of the page
            # map rather than on a virtual address, which is both narrower and
            # immune to aliases -- and on FC 5, which is the correction that
            # matters.  Triggering on the virtual address alone caught the
            # PROM writing the page map *entry* for 0xEE3000 from FC 3
            # control space: same address, entirely different event, and the
            # map write happens long before the chip is ever touched.
            #
            # Every PROM device access is FC 5, so this is the driver poking
            # the chip and nothing else: the RESET* bit, and the Channel
            # Attention that sends the part off to fetch its SCP.
            set_property TRIGGER_COMPARE_VALUE eq12'b111111100001 $P(ma)
            set_property TRIGGER_COMPARE_VALUE eq3'b101 $P(fc) }

    dvma  { # any cycle a bus master other than the CPU is driving.
            #
            # This is the bit the debug bus lacked, and the reason it was
            # added: top_fpga muxes the master onto the CPU's own wires on
            # purpose, so an address and a function code cannot tell a chip's
            # cycle from the CPU's.  Chasing the VME Ethernet, that mattered
            # exactly where it hurt -- the 82586's first fetch is from
            # 0xFFFFF6 and so are the CPU's own writes while it builds the SCP
            # there, both FC 5.
            #
            # One hit says the master took the bus, and the address says what
            # it went for.  No hit, on a machine whose driver has raised
            # Channel Attention and seen INT come back, says the chip answered
            # without ever fetching anything -- which is a different fault
            # entirely, and not one any amount of staring at the CPU would
            # find.
            set_property TRIGGER_COMPARE_VALUE eq1'b1 $P(dvma) }

    iackseq { # every interrupt acknowledge and nothing else, one sample each,
            # trigger at the front.  This is the mode to use for "which
            # interrupts fire": capture is qualified on FC 7, so 4096 samples
            # are 4096 IACKs however far apart they are in time.
            #
            # Plain `iack' cannot answer that.  Its trigger fires on an IACK,
            # so the buffer always contains one, and the window is 4096 clocks
            # -- about 205 us at 20 MHz -- while a 100 Hz level 5 interrupt is
            # 200,000 clocks apart.  An absent level 5 there means nothing.
            set_property TRIGGER_COMPARE_VALUE eq3'b111 $P(fc)
            set qualify_iack 1
            set trigpos_override 64 }

    dvmaseq { # every DVMA cycle, one sample each, with the trigger at the
            # front: the master's whole conversation with memory rather than
            # its first word of it.  Capture is qualified on dvma_active, so
            # the buffer holds 4096 master cycles and no CPU traffic at all.
            set_property TRIGGER_COMPARE_VALUE eq1'b1 $P(dvma)
            set qualify_dvma 1
            set trigpos_override 64 }

    lateerr { # any bus error, but built for one that happens late: one sample
            # per completed cycle and the trigger near the end, so the buffer
            # holds about four thousand cycles of history in front of it.  Pair
            # it with ARMDELAY to skip the device probes, which would otherwise
            # trigger this instantly.
            #
            # For a failure that varies from run to run, which is what a race
            # looks like from outside: a VME netboot on RD68011 has ended in a
            # timeout at 0xFFFFFFFF inside the PROM's bcopy, and in a Line-F
            # exception reported at an address holding an ordinary branch.  A
            # trigger tuned to either misses the other; this catches whichever
            # happens.
            set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd)
            set qualify_done 1
            set trigpos_override 4032 }

    wildptr { # the bus error that ends a VME netboot on RD68011.
            #
            #   Boot: ie(0,0,0)vmunix
            #   Timeout Bus Error, addr: FFFFFFFF at EF2BC0
            #
            # ef2bc0 is the instruction after `moveb %a5@+,%a4@+' at ef2bbc,
            # the PROM's byte-copy loop, so one of its pointers came back
            # 0xFFFFFFFF and dereferencing it in bus space times out --
            # correctly.  The fault is the corrupted pointer, not the timeout.
            #
            # Triggering on ERR alone is no use: a VME boot takes ten device
            # probes that error first, and the buffer would be spent on the
            # first of them.  This wants ERR *and* an all-ones address, which
            # no probe uses -- the only legitimate traffic up there is the
            # 82586's SCP fetch at 0xFFFFF6..0xFFFFFE, which does not error.
            #
            # One sample per completed cycle and the trigger near the end, so
            # the buffer is almost all history: about four thousand cycles
            # before the fault, which is where the read that delivered the
            # pointer will be.
            set_property TRIGGER_COMPARE_VALUE eq23'b11111111111111111111111 $P(addr)
            set_property TRIGGER_COMPARE_VALUE eq6'bXXXX1X $P(verd)
            set qualify_done 1
            set trigpos_override 4032 }

    caseq { # the boot PROM's Channel Attention routine, from its first
            # instruction onwards.  Triggers on the supervisor-program fetch
            # of the `bset #5' at 0xEF431E and stores one sample per completed
            # cycle with the trigger near the front, so the buffer holds the
            # whole of what the CPU does next -- roughly four thousand cycles.
            #
            # The question it answers: the routine is
            #
            #     ef431e  bset #5,%a0@      raise CA
            #     ef4322  moveal %a5@(1118),%a0
            #     ef4326  bclr #5,%a0@      drop it
            #
            # and the board executes the bset twice against one bclr, so CA
            # never falls between the two attentions and the second makes no
            # edge.  Either the CPU leaves between ef431e and ef4326 -- and
            # this shows where it goes -- or it does not, and the doubling is
            # the core re-issuing a read-modify-write.  The instruction stream
            # tells the two apart, which no amount of watching the register
            # can.
            set_property TRIGGER_COMPARE_VALUE eq23'b11101111010000110001111 $P(addr)
            set_property TRIGGER_COMPARE_VALUE eq3'b110 $P(fc)
            set qualify_done 1
            set trigpos_override 128 }

    caclk { # the same trigger as `caseq', but every clock rather than one
            # sample per cycle: less reach, and the data timing visible.  For
            # reading what a CPU read actually returned, which one sample per
            # cycle cannot settle -- the ILA's two input pipeline stages delay
            # every probe equally, so the relationship holds, but a single
            # sample taken at DTACK may be earlier than the data is valid.
            set_property TRIGGER_COMPARE_VALUE eq23'b11101111010000110001111 $P(addr)
            set_property TRIGGER_COMPARE_VALUE eq3'b110 $P(fc)
            set trigpos_override 128 }

    etherseq { # the same trigger as `ether', built to follow a sequence rather
            # than to dissect a cycle.  Two changes, and they buy about eight
            # times the reach:
            #
            #   * one sample per *completed* cycle -- AS asserted and DTACK
            #     asserted -- instead of every clock AS is low.  A 68010 cycle
            #     spends four or more clocks with AS asserted, so the ordinary
            #     qualifier burns the buffer four-deep on each cycle.
            #   * the trigger near the front, because everything of interest
            #     here happens *after* the driver first touches the chip.
            #
            # Use it when the question is "and then what": the driver resets
            # the chip, waits, brings it out of reset, builds an SCP, and
            # somewhere after that raises Channel Attention.  Following that to
            # its end needs thousands of cycles, not hundreds.
            set_property TRIGGER_COMPARE_VALUE eq12'b111111100001 $P(ma)
            set_property TRIGGER_COMPARE_VALUE eq3'b101 $P(fc)
            set qualify_done 1
            set trigpos_override 128 }

    scp   { # the 82586's SCP fetch at 0xFFFFF6, its first cycle as a master.
            # Exact, not a page: A[23:1] of 0xFFFFF6 is 0x7FFFFB.  The chip
            # reads six bytes from here before it does anything else, so one
            # hit proves the DVMA path -- arbitration, sun2_dvma's cycle
            # generation, the MMU translation of a master that is not the CPU
            # -- and no hit proves none of it ran.
            #
            # dvma_active is part of the trigger, and has to be: the address
            # alone is not the chip.  The PROM reads 0xFFFFF6 itself -- from
            # 0xEF414A, two supervisor-data word reads -- and being earlier it
            # fires an address-only trigger every time, so the capture shows the
            # CPU and the comment above claims it showed the chip.  That cost a
            # capture here.  top_fpga muxes the master onto the CPU's wires on
            # purpose, so dbg_dvma is the only thing that separates them; probe
            # 11 exists for exactly this.
            set_property TRIGGER_COMPARE_VALUE eq23'b11111111111111111111011 $P(addr)
            set_property TRIGGER_COMPARE_VALUE eq1'b1 $P(dvma) }

    prot { # any cycle the MMU refuses on protection grounds, whether or not
           # anything came of it.  verd = {VALID PROTERR_raw PROTERR TIMEOUT
           # ERR MATCH_MEM}, so PROTERR is bit 3.
           #
           # This is the question "does gating the MATCH_* terms on ~PROTERR
           # suppress anything here at all".  A device probe that times out is
           # not this -- that is TIMEOUT, bit 2 -- so a boot full of probes
           # will not trigger it.
           set_property TRIGGER_COMPARE_VALUE eq6'bXX1XXX $P(verd) }

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
    default { puts "ERROR: MODE must be err, fc1, as, supw, scc, ether, etherseq, caseq, caclk, wildptr, lateerr, dvma, dvmaseq, iack, iackseq, scp, uerr, uerr2, uonly, uprog, uprogerr, ctxwr, ctxnz, fbprobe or reset, not '$mode'"; exit 1 }
}

# Capture control: keep bus cycles, drop the idle clocks between them.  4096
# samples is a few hundred cycles that way and a few microseconds otherwise.
# The trigger position, now that the mode is known.  A mode that qualifies the
# capture hard -- user instruction fetches only -- must not ask for a half
# buffer of history: the core collects the pre-trigger samples before it will
# even look at the trigger, and if qualified samples are rare it never arms.
# That is what "did not trigger, core status IDLE" meant the first time.
if {[info exists qualify_prog]} { set trigpos 16 }
# KPOS moves the trigger for any mode.  A `kpc' capture of a routine that is
# entered once and then runs for longer than a buffer wants almost all of its
# samples *after* the trigger -- the question is what the routine went on to
# do, not what called it.  KPOS=16 gives 4080 clocks of that.
if {[info exists ::env(KPOS)]} { set trigpos $::env(KPOS) }
if {[info exists trigpos_override]} { set trigpos $trigpos_override }
set_property CONTROL.TRIGGER_POSITION $trigpos $ila
puts "== trigger position $trigpos of $depth =="

set_property CONTROL.CAPTURE_MODE BASIC $ila
if {[info exists qualify_prog]} {
    set_property CAPTURE_COMPARE_VALUE eq3'b010 $P(fc)
} elseif {[info exists qualify_user]} {
    # user-mode clocks only: FC 1, 2 (and 3, which one comparator cannot
    # exclude and which barely occurs in user mode anyway)
    set_property CAPTURE_COMPARE_VALUE eq3'b0XX $P(fc)
} elseif {[info exists qualify_dvma]} {
    # only cycles a master other than the CPU is driving
    set_property CAPTURE_COMPARE_VALUE eq1'b1 $P(dvma)
} elseif {[info exists qualify_iack]} {
    # only CPU-space cycles: FC 7, which on this machine is nothing but an
    # interrupt acknowledge.  dbg_addr[2:0] is then A3-A1, the level.
    set_property CAPTURE_COMPARE_VALUE eq3'b111 $P(fc)
} elseif {[info exists qualify_done]} {
    # AS asserted *and* DTACK asserted: exactly one sample per completed bus
    # cycle.  hand is {AS RW UDS LDS DTACK BERR}, all active low.
    set_property CAPTURE_COMPARE_VALUE eq6'b0XXX0X $P(hand)
} else {
    set_property CAPTURE_COMPARE_VALUE eq6'b0XXXXX $P(hand)
}

if {$armdelay > 0} {
    puts "== waiting $armdelay s before arming, to get past the boot's probes =="
    after [expr {$armdelay * 1000}]
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
    puts "== core status $st after $waitmin minutes, not FULL =="
    #
    # A hung machine starves the ILA, and that is the case worth rescuing.
    # The core only reaches FULL once its post-trigger half has filled, and
    # filling needs bus cycles; if the machine has stopped issuing them there
    # will never be another sample.  So a trigger that fired into a hang
    # leaves the core part-filled for ever -- with the last cycles before
    # everything stopped sitting in it, which is the whole of what we came
    # for.  Throwing that away because a status string is not "FULL" is
    # exactly the wrong reflex.
    #
    # A frozen bus reads as a final sample with AS asserted and DTACK never
    # answering: memory is exempt from the twelve-clock timeout, so an
    # unanswered access up there hangs rather than raising a bus error.
    #
    if {[catch {set data [upload_hw_ila_data $ila]} err]} {
        puts "   and nothing could be uploaded: $err"
        puts "   Nothing matched at all.  With mode=err that means no bus"
        puts "   error; check the machine is running, then try mode=as."
        exit 1
    }
    write_hw_ila_data -force -csv_file $outdir/ila.csv $data
    puts "== wrote a PARTIAL capture to $outdir/ila.csv =="
    puts "   Read the last samples, not the first: if the bus froze, the tail"
    puts "   is the cycle that never completed."
    exit 0
}
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $outdir/ila.csv $data
puts "== wrote $outdir/ila.csv =="

# A decoded window round the trigger.  The CSV has everything; this is what can
# be read without leaving the terminal.
# Count the rows we actually wrote, not STATUS.SAMPLE_COUNT.  That property
# reads 0 once the data has been uploaded, so the script used to announce
# "0 samples captured" over a perfectly good 4096-sample CSV -- which reads as
# a failed capture and cost a session's worth of doubt about the ILA itself.
set nrows 0
if {![catch {set fh [open $outdir/ila.csv r]}]} {
    while {[gets $fh line] >= 0} { incr nrows }
    close $fh
    # two header rows: the column names and the radix line
    set nrows [expr {$nrows > 2 ? $nrows - 2 : 0}]
}
puts "== $nrows samples in $outdir/ila.csv =="
