# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A replica of a Sun-2 workstation in an FPGA: MC68010, the Sun-2 MMU, an Am9513
timer, Zilog 8530 SCCs and (on VME machines) an Intel 82586 Ethernet, booting
the real boot PROMs to the monitor prompt and SunOS 4.0.3 to a login prompt.

**Two boards, two vendors.** A QMTech Wukong V1 or V3 (Xilinx XC7A100T, FGG676)
built with Vivado, and an Arrow DECA (Altera MAX 10 10M50DAF484C6GES) built with
Quartus. Both boot SunOS from the same `rtl/`, which contains no vendor
primitive and no vendor IP -- the two flows are the evidence for that claim
rather than an assertion about it. Everything vendor-specific lives in
`boards/<name>/` and `syn/`.

## Commands

```sh
make sim                                  # boot the MultiBus 2/120 (= make -C sim xsim)
make -C sim xsim MACHINE=vme              # boot the VME 2/50 instead
make -C sim check MACHINE=vme             # pass/fail on the console log
make -C sim board [BOARD_MEM=ddr3] [CPU=rd68011]   # as it will be on the Wukong
make -C syn ip [BOARD=v3]                 # generate the MIG DDR3 controller (once per board)
make -C syn bitstream [MACHINE=vme] [CPU_HZ=40000000] [BOARD=v3] [XY450=1] [CPU=rd68011]
make -C syn bitstream FB=1 HDMI_MODE=1280x1024      # the display mode this board can drive
make -C syn ip-ila; make -C syn bitstream ILA=1  # fit the ILA on the MMU's debug bus
make -C syn program ILA=1 [same knobs]    # JTAG; `hw' leaves the Hardware Manager open
tools/mkxydisk -o build/disk/xy0.img       # a labelled, bootable disk image
tools/ufsread IMG cat /vmunix -o OUT      # pull a file out of a 4.2BSD image
tools/pcsym OUT 63c8e 40b6                # 68010 PCs -> kernel symbols
tools/fbshot                              # render the screen mid-run (FB=1)
make -C tools beprobe                     # a boot block that measures a bus error frame
make -C tools clkprobe                    # ... and one that arms the level 5 clock SunOS uses
```

Simulation knobs that matter, all on `make -C sim xsim`:

| knob | effect |
|---|---|
| `MEM_MIB=1` | the first one to reach for — the PROM writes every installed byte, so 7 MiB costs seconds of simulated time and 1 MiB costs under half of one |
| `ROM=fast` | shortens the PROM's RAM-init pass 64-fold (MultiBus only) |
| `MEM_LATENCY=7` | memory as slow as the real DDR3 path; 0 (the default) is a one-cycle memory |
| `MB_ETHER=1` | MultiBus only: fit the Sun-2 Ethernet card in the cage. Off by default, because the 22-error fingerprint is the machine *without* it |
| `FB=1` | fit the frame buffer, either machine. Changes what the machine looks like — with a display the console goes to the screen and the serial port falls silent. On MultiBus it also builds the keyboard/mouse SCC, which is on the video board |
| `XY450=1` | MultiBus only: fit the Xylogics 450 disk controller. Needs `MEM_MIB=1` or more and `-testplusarg blk_image=<abs path>`; `tools/mkxydisk` writes one |
| `CPU_HZ=40000000` | run the CPU faster. Correct, and *slower* to simulate — see the trap below |
| `CPU=rd68011` | build with the RD68011 core from `Inputs/RD68011` instead of Suska. Same machine, one define — see below |
| `TIMEOUT_MS=` | simulated milliseconds before giving up |
| `XSIMARGS="-testplusarg trace_dvma=16"` | also `trace_irq`, `heartbeat_ms`, `crs_stuck`, `vcd_full` |
| `XSIMARGS="-testplusarg watch_addr=5b6"` | print every bus cycle, CPU or DVMA, touching one address |
| `XSIMARGS="-testplusarg trace_abort=1"` | ring the SCC accesses and dump them when the monitor aborts; `=2` prints them live |
| `XSIMARGS="-testplusarg cycle_from=5600 -testplusarg cycle_to=6900"` | every clock edge between two times — **both** edges, since the 68000 bus uses both and sampling only posedges hides the half-cycle where DTACK is taken |
| `EXTRA_DEFINES=SUSKA_PEEK` | adds Suska's own `DTACK_In`, `WAITSTATES`, `SLICE_CNT_P` and `RESET_OUT_I` to that trace (`CPU=suska` only) |
| `MAPS_ZERO=1` | power the segment and page maps up as zeros, the way a block RAM does, instead of X — the difference between simulation and a board at time zero |

Unit tests (seconds to minutes, unlike a boot):

```sh
make -C sim dvma       # sun2_dvma: Wishbone master -> 68010 bus cycles
make -C sim adapter    # wb_to_mig_ui against a reference model
make -C sim migddr3    # the adapter against the real MIG + Micron DDR3, reports bus latency
make -C sim clkgen     # measures what the MMCMs actually generate
make -C sim phy        # phy_rtl8211_init against an independent clause-22 PHY model
make -C sim mbether    # the MultiBus Ethernet card, driven as the boot PROM drives it
make -C sim xy450      # the Xylogics 450 disk controller, against a real disk image
make -C sim xychain    # boots a 68010 program that drives chained IOPBs and takes the interrupt
make -C sim scc        # the Z8530's interrupts, driven the way SunOS drives them
make -C sim scanout    # fb_scanout: every pixel of a frame, against a known pattern
```

A boot with `FB=1` writes `build/sim/xsim-vme-fb/fb.mem` — the aperture as raw
32-bit Wishbone words. `make -C sim screenshot` replays it through the real
`fb_scanout` and writes `build/sim/unit-scanout/screen.ppm`, which is the only
thing that renders what the machine actually drew rather than reading it out of
the memory model. The PPM is the whole 1920x1080 HDMI frame; the Sun's
1152x900 screen is centred in it, at offset (384, 90).

**With a display fitted there is no serial console to read.** The PROM sets
`g_outsink = OUTSCREEN` whenever `s2fbthere()` succeeds (`sunmon.c:396-401`)
and there is no way to ask for both, so `console.log` stays empty and the only
artefact is `fb.mem` — which `$finish` writes at the *end* of the run. For a
SunOS boot that is a day of wall clock away, and killing the run loses it
entirely, because the screen only ever existed inside the simulator.
`+fb_dump_ms=<real>` rewrites the capture on a timer instead, rotating over
`fb-live0.mem`..`fb-live2.mem` so a run of any length costs three files:

```sh
make -C sim xsim XY450=1 MB_ETHER=1 FB=1 MEM_MIB=4 ROM=fast \
     XSIMARGS="-testplusarg fb_dump_ms=250 -testplusarg blk_image=$PWD/build/disk/small.img"
make -C sim screenshot MACHINE=multibus MB_ETHER=1 FB=1 XY450=1 \
     FBIMAGE=$PWD/build/sim/<rundir>/fb-live1.mem
```

`tools/fbshot` does the rendering, and gets two things right that are easy to
get wrong by hand: it picks the newest *complete* capture, by mtime rather than
by parsing the log (the log lags the file, so reading it can select the oldest
of the three, which renders blank and looks exactly like "nothing drawn yet");
and it crops correctly. With no argument it finds the most recently written
capture on its own.

```sh
tools/fbshot                                  # newest run, cropped PNG
tools/fbshot <rundir> -o shot.png --ppm shot.ppm
tools/fbshot --full                           # the whole HDMI frame
```

The PPM lands at `build/sim/unit-scanout/screen.ppm` and is overwritten by the
next render, so pass `--ppm` to keep one.

The board testbench can also type at the monitor prompt (`tb/uart_console.sv`),
which is how the PHY status register in device page 0xFE7 is checked
end-to-end — a full boot first, so it is an hour of wall clock, not minutes:

```sh
make -C sim board-phy   # boot, then map 0xFE7 and read it from the prompt
```

Expect a full boot to take roughly 0.5 s of wall clock per simulated
millisecond. `make -C sim board BOARD_MEM=ddr3` is ~1500x slower again and
cannot reach the prompt — it is only good for showing MIG calibrate.

**Two cores, one machine.** `top_fpga.v` instantiates Suska
(`Inputs/Suska_Configware/68K10`, VHDL) and RD68011 (`Inputs/RD68011`,
SystemVerilog) as alternatives under `` `ifdef SUN2_CPU_RD68011 ``, and
`CPU=rd68011` on `make -C sim xsim`, `make -C sim board` or `make -C syn
bitstream` sets that define and reads that core's file list —
`sim/compile_cpu.sh` holds both lists for the two simulation flows, so adding
a file to a core is one edit. Everything else — every other Sun-2
source, and the whole of `top_fpga.v` below the instantiation — is shared, so
there is no second copy of the top to drift. Each core gets its own `build/sim`
and `build/syn` directory so a result from one can never be read as the other.

The two disagree on exactly two things, both reconciled at the instantiation.
**VPA**: RD68011 models the real single pin, Suska splits it into
`VPAn`/`AVECn`, which is why the Suska arm has to put the Sun-2's VPA on
`AVECn` and tie `VPAn` high while the RD68011 arm just connects it. **Pin
enables**: `_oe` per group against one `BUS_EN`, and since the groups assert
and release together the address enable stands for all of them. There used to
be a shim in `rtl/experimental/` presenting Suska's interface; it is gone, and
the reconciliation now lives where the wiring does.

**Short experiments run on both cores.** Neither is a reference for the other:
Suska gets instruction restart wrong -- the bus error frame it pushes does not
describe the cycle -- and RD68011 gets further into the kernel because of it,
so a result from one alone says as much about the core as about the machine.
Anything cheap enough to repeat -- a boot block like `tools/beprobe` or
`tools/clkprobe`, a unit test, a probe of one device -- is run with
`CPU=suska` *and* `CPU=rd68011`, and both numbers are reported. Where they
disagree, that disagreement is the finding and neither number is thrown away.

The disagreement this file carried for months — **the VME machine on RD68011
taking 11 bus errors and 319 characters where Suska takes 10 and 312**, the
extra one a protection violation on an instruction fetch at `A=a04370`, a wild
PC, "unchased" — **was a bug in the core, and it is fixed** (`8e8a1b4`). It was
never a spurious interrupt, which is why surviving `a44b71a` told us nothing.

A 68010 longword read is two bus cycles and a master may legally be granted the
bus between them. RD68011's bus unit decided whether to hand over from
`arb_bus_released`, built from the arbitration unit's *current* state, while its
output enables were registered from `arb_bus_released_nxt`, built from the
*next* one — so the two disagreed for a clock and the word read before the
grant was lost. `a04370` and `664370`, two runs of the same failure, differ only
above their low word: that is a longword with its first half replaced.

It only bites when something else masters the bus, which is why a MultiBus boot
with no cards never showed it and a VME netboot — the 82586 streaming a kernel
in by DVMA while the CPU runs the PROM — died three different ways from one
bitstream: a timeout at a wild address, an illegal instruction at a PC holding
ordinary code, and a double bus fault with the watchdog. Three failures, one
race. `Inputs/rd68011-longword-read-across-a-bus-grant.md` is the report.

**Both cores now take 10 bus errors and 312 characters on a VME boot**, and the
two agree for the first time. That is the confirmation rather than the
inference: 7,621,331 longword reads on that boot, 94 of them split by a
master's cycle, all assembled correctly, and `tb_sun2`'s memory check clean at
3,527,559 reads. So a VME disagreement between the cores is a finding again,
not a known quantity to be waved past.

`a44b71a` also moved RD68011's level-7 acknowledgements down by a factor of
about 2.5 — 37 to 14 over an identical `xychain` run, with level 2 unchanged at
6 — so **RD68011 level-7 counts recorded before it are inflated** and must not
be compared with ones taken after. Level 5 is unaffected.

**There is an ILA, and it is aimed at the MMU.** `ILA=1` fits one on `dbg_bus`
-- 102 bits of address, function code, both map lookup stages, the protection
and timeout terms, the bus handshake, the data, both context registers, and
`dvma_active`, which is the one thing `sun2_fpga` cannot work out for itself:
`top_fpga` muxes the master onto the same wires on purpose, so no combination
of address and function code separates a master's cycle from the CPU's. It is
packed in `sun2_fpga.v` with its field
map beside it and sampled every clock rather than once per cycle. It exists
because SunOS panics creating pid 1 with a protection violation reported as a
bus timeout, `tools/mmuprobe` cannot reproduce that from a boot block, and a
bitstream costs ten minutes where the simulation that would show it costs ten
hours. Simulation always builds the bus and `tb_sun2.sv` checks every field
against the signal it claims to carry, on every clock edge of every boot, so a
field cannot silently drift from its map; a bitstream builds it only under
`ILA=1`, because the bare port cost 8 LUTs and 17 ps of hold margin in a build
with no ILA in it. `BRINGUP.md` has the triggers and the diagnostic.

What has not changed is the regression baseline: the MultiBus fingerprint of
22 bus errors and a byte-identical console is measured with Suska, because
that is what every recorded number was taken against, and a full boot is too
expensive to duplicate for every change.

It is nevertheless the only thing that has taken SunOS past `startup()`. With
`XY450=1` and no video board it boots 4.0.3 to the VM page-pool
initialisation, and its 138 bus errors decompose as ten device probes plus 128
repeats of `A=701000` — `poke()` walking every page of the DVMA bus window and
recovering from each fault, which is exactly what the kernel asks for and what
Suska does not do -- an observation about the cores, and the reason neither is
trusted alone: the machine below the instantiation is the same file in both
builds.

**It does not clock anywhere near 40 MHz.** A full MultiBus V3 bitstream
(Ethernet, frame buffer, disk) meets timing at **20 MHz with WNS 0.060 ns** and
the critical path is inside the core, not in anything the Sun-2 contributes —
`clk50` has 15.9 ns of slack and every MIG domain is comfortable. The path is
`u_seq/upc_reg[2]_replica` to `u_biu/d_o_reg[4]`, rising edge to *falling*
edge, so its requirement is a **half period**: 24.774 ns of delay against
25.000 ns, 29 logic levels, 71% of it routing. The core is already being asked
to do that stretch at 40 MHz at a 20 MHz clock. Suska on the same board and
the same cards passed 40 MHz. 60 ps is inside the noise of a placement seed,
so 16.667 MHz (VCO/60) is the next exact divisor to reach for if a number has
to be dependable; `wukong_clkgen` `$fatal`s at elaboration on a `CPU_HZ` that
does not divide the 1 GHz VCO exactly, so there is no silent rounding.

Vivado is expected at `/opt/Xilinx/2025.2/Vivado`; override `XILINX_VIVADO`.
Neither `make` in `sim/` nor `syn/` needs `settings64.sh` sourced.

**The screen works on a board.** A MultiBus build with `CPU=rd68011`, `FB=1`
and `HDMI_MODE=1280x1024` on a Wukong V1 puts the boot PROM's banner, the
bootloader and a netbooting SunOS kernel on a real monitor -- CPU, MMU,
Wishbone bridge, DDR3, `fb_scanout`, TMDS, sink. The serial port is silent
while it does, which is correct and not a fault: `sunmon.c:396` sets
`g_outsink = OUTSCREEN` whenever `s2fbthere()` succeeds and offers no way to
ask for both.

Two things had to be true at once and neither was. **1080p60 is more than the
full design can clock** -- see the trap below -- and **`fb_video_en` was never
connected**, so DISPEN was a constant 0 in every bitstream ever built. Each
alone shows a black screen, which is why they took a session to separate.

**SunOS runs on the VME machine too, over the network.** A 2/50 on a Wukong V1
at 20 MHz with `CPU=rd68011` netboots SunOS 4.0.3 to a full autoconfig: RARP,
120936 bytes of bootloader over TFTP, NFS root and swap, then `zs0`, `zs1` and
`ie0` attached. It needed two fixes a long way apart — the memory bridge below,
and the core's bus-grant handover above — and neither could be found without the
other, because the first one hung the machine before the second could show.

**There is an interactive root shell on the serial console.** A MultiBus
`BOARD=v1s1` build with `CPU=rd68011` at 20 MHz netboots SunOS 4.0.3, runs
`/sbin/init` through `rc.boot` and `rc`, and puts a `#` prompt on
`/dev/ttyUSB0` that echoes what is typed and runs what is entered. That is the
first time anything the machine's *userspace* wrote has reached the outside
world, and the first time a keystroke has reached a process.

What stood in the way was `patches/z8530_scc/0001` -- see the trap below. Two
things about the measurement are worth keeping:

* **Userspace output ends its lines with a single `\r`, kernel output with
  three.** `\r\r\r\n` is the PROM path (`cnputc` adds one, the monitor's
  `putchar` adds another); a lone `\r` is the `zs` driver's own ONLCR. So the
  line terminator alone says which path a line came out of, which is a free
  check that a console fix is real rather than a coincidence.
* **A short typed line looks exactly like dead input.** `zsa_rxint`
  (`zs_async.c:670-676`) only raises the level-3 soft interrupt every 20
  characters, so 19 characters and a return produce *nothing at all* -- no
  echo, no prompt. 48 characters echo instantly. A first attempt with a short
  command was nearly recorded here as "input still broken".

The old logs' last byte was the proof, unread at the time. Every board capture
before the fix ended with a lone `-` after the final kernel line. That `-` is
`sh`'s own `argv[0]` for a login shell, the first character of
`-: 51 Memory fault - core dumped`: `zsstart` primed it into the transmit
buffer directly and the transmit interrupt that would have sent the rest never
came. One stray character at the end of a log was the whole symptom.

**Every command it forks now runs, and what stood in the way was the CPU
core.** This paragraph used to end "every child the shell forks then dies with
`Memory fault - core dumped`". The cause was RD68011 `252f0d7`, and the report
this project filed named the wrong variable. It is not the predecrement
addressing mode: it is `ea_latch`, which the addressing modes that prefetch
before they access use to carry their address once `ir` has moved on. The frame
has a word for that latch and the frame build destroyed it before writing it --
every frame word goes out through an `aupd` on the stack pointer, and an `aupd`
is exactly what loads the latch -- so the word recorded a stack address ten
writes later and `RTE` repeated the mistake in reverse. **A faulted access
resumed at whatever address the frame walk had reached.**

The affected set is every access addressing through that latch: `MOVE` to
`-(An)` in all its forms, every read-modify-write on `(An)`, `(An)+` and
`-(An)`, the `-(Ay),-(Ax)` group, and **the return-address pushes of `JSR`,
`BSR`, `PEA` and `LINK`** -- 257 microcode labels, which is every subroutine
call in every program. `MOVE.L -(A0),D1`, predecrement as a *source*, resumes
correctly, which is why "the predecrement itself" was the wrong thing to name.

It only bites when the push itself faults, and that is the entire asymmetry a
session was spent trying to explain. A fresh process's stack is fill-on-demand
beyond the page `execve`'s `copyout` of argv/env touched, so its first `jsr`
into new stack faults, `grow()` repairs it, and the `rte` resumes wrong. A
long-lived shell's stack is already resident and never faults on a push. So the
parent lived and every child died.

**Nothing announced it, and that is worth remembering.** `trap.c`'s user
bus-error path is silent -- `tudebug` is a compile-time 0 in `GENERIC`, so
`showregs()` is unreachable -- and a corrupted return address is simply not the
one that was pushed. The only symptom available was `sh` printing SIGSEGV.
Note also that on sun2 a bus error can *only* ever produce SIGSEGV: `trap.c`
`T_BUSERR+USER` never examines `BE_PROTERR` or `BE_VALID`, and SIGBUS comes
only from `T_ADDRERR`. And `u.u_code` is never set on that path, so the faulted
address is **not** in the core file -- only `r_pc` and the user SP are.

`tools/ctxprobe` case E is the regression test: it now reads `E: -(An)
restarted correctly` with controls C, F, G and H still passing. Suska still
stops at case C, which is its own known instruction-restart defect and not a
regression -- it never reaches E, so it says nothing about this bug either way.

On the board, a `BOARD=v1s1` MultiBus build at 20 MHz: `/bin/ls -la /`, a
`/bin/ls | /bin/sed` pipeline, `awk` running a 2000-iteration loop, and a
ten-iteration `/bin/echo` fork loop all run correctly, with **no `Memory
fault`, no core dump and no `stropen: out of streams`** anywhere in the boot.

**What that exposed: nothing the machine writes ever reaches the NFS server.**
Trying to compile `dhrystone.c` on the board fails with `ld: dhrystone.o:
premature EOF`, and the object file is zero bytes. The minimal case is three
commands:

```
# /bin/echo hello-write-test > /tmp/t1
# /bin/ls -l /tmp/t1          ->  17 bytes
# /usr/bin/od -c /tmp/t1      ->  0000000     (zero length)
```

`ls` reports 17 from locally cached attributes; the file reads back empty, and
**the NFS server sees no WRITE RPC at all** -- confirmed on the server, not
inferred. `sync` does not flush it. Reads are fine: `cat` of an existing file
works, and the boot pulls a 604 KB kernel over the same path.

That rules out the obvious suspects. A 17-byte file is one small WRITE RPC,
well inside a single Ethernet frame, so it is not fragmentation, not a large
transmit, and not the 82586 -- the client never generates the request.

**The suspect is the page-map MOD bit, and it is a real gap whatever the
outcome.** `sun2_fpga.v:404-405` decodes `ACC` (referenced) and `MOD`
(modified) and *nothing else in the tree reads or writes them*; the page map's
`ps` SRAM is written only by software. Real hardware maintains them --
`s2map.h:96-98`, "If access is denied, the page referenced and modified bits
will not be changed", which is only meaningful if a granted access does change
them -- and the running 4.0.3 kernel carries `_hat_pagesync` and
`_hat_ptesync`, whose whole job is harvesting them. A page that can never
report itself modified is never pushed: `seg_vn.c:2088` is
`if (pp->p_mod && pp->p_vnode) VOP_PUTPAGE(...)` and otherwise discards, and
`vm_pageout.c:324` likewise sees every page as unreferenced, so the clock
algorithm degenerates and everything looks stealable. The kernel's own `XXX`
comment there says it has no software fallback for machines without reference
bits.

This was ranked in the plan as "needs memory pressure, would be intermittent".
That was wrong, and the error is worth keeping: the modified bit gates *every*
writeback, not just paging under pressure, which is why it presents as a
totally silent failure to write anything rather than as occasional corruption.
It also explains why every `core` file on the netboot root is zero bytes --
the `CREATE` reaches the server and the data never does -- and so why the core
files this project has been trying to read were never going to say anything.

**Fixed, and the machine now compiles and runs a benchmark.** The MMU
maintains both bits: `sun2_mmu.v` gives the page map's `ps` half a second
writer, and `sun2_fpga.v` builds the qualifier beside the protection verdict it
depends on. The one design choice worth knowing is that the enable is a
*level*, terminated by its own idempotence gate, and not a one-shot on
`C_S6 & ~C_S8`. A 68010 read-modify-write holds `AS` across both halves, so the
`C_S` chain runs once for the pair; a one-shot would set accessed on the read
half and never set modified on the write half. The real machine has the same
requirement and solves it the same way -- `A103.pal`'s `WR.UPDATE` closes on
`Q.S7`, which is DTACK-derived and negates between the halves.

`tools/refmodprobe` is the regression test, and it exists as its own boot block
because `ctxprobe` is 7549 bytes of the 7680 a boot block gets. Measured before
and after, on both cores:

```
                 before      after
  cleared       fe000181    fe000181
  granted read  fe000181    fe200181     accessed set, modified not
  granted write fe000181    fe300181     both set
  denied access 80000181    80000181     neither changed, and it faulted
```

The denied case is the one that catches an over-eager qualifier, and it is not
a formality: Manual 5.6.3 says the fields of a denied entry are not used, and
SunOS keeps its own data in the page number and type fields of an entry it has
invalidated.

On the board: a file written on the machine reads back correctly where `od`
used to show `0000000`, the NFS server sees the whole compiler toolchain write
about 40 KB across five files, and `cc -O` builds and runs dhrystone.

**The machine does about 850 dhrystones/second at 20 MHz, and every figure
this file used to quote was wrong twice over.**  It said "1298 dhrystones/
second at 20 MHz, 1508 with `-DREG=register`", which was what the benchmark
printed.  Two independent errors sat under that:

* **dhrystone.c divides by the wrong `HZ`.**  It has `#define HZ 100` with the
  comment `times(2) returns 1/60 second (most)` beside it, and the comment is
  the correct half.  `sys/h/param.h:30` is `#define HZ 60 /* ticks/second
  according to syscalls that return values in ticks */` and `kern_xxx.c:249`
  is `atms.tms_utime = scale60(&u.u_ru.ru_utime)` -- `times()` scales to
  sixtieths, by a function actually called `scale60`.  So everything the
  benchmark prints is inflated by exactly 100/60.
* **A runaway `cron` was taking 70% of the machine.**  `ps -aux` showed it in
  state R with 7:56 of CPU accumulated.  It cost nothing in the benchmark's own
  `sys` -- another process never appears there, only in `real` -- so it was
  invisible to every wall-clock measurement and inflated all of them.

Measured with `/bin/time` and cron killed, 50000 passes cost **58.9 s of user,
62.8 s of real, 0.8 s of sys**, and 50000/58.9 = **849/s**, which agrees with
the printed 1433 once the 1.667 is taken out (860).  For calibration a real
10 MHz 2/120 managed about 700, so the replica is roughly 60% of the original
per clock -- a believable price for DDR3 at 7 to 13 clocks an access where the
real machine had static RAM.

**Quote `user`, not `real`, and never the benchmark's own figure.**  `user` is
the only one of the three that held steady when cron was killed (60.0 to 58.9)
while `real` halved.

The TOD is not involved in any of it: `sun/sys/sun2/clock.c`'s
`start_level5_clock()` arms Am9513 counter 2 at level 5, and that interrupt is
what advances `lbolt`; the MM58167 is read once by `inittodr()` for the date and
never ticks anything.  `tools/clkprobe` measures the counter from a boot block
with no kernel in the way, and netbooted it takes a minute on real hardware. Nothing here
could write a byte to a filesystem before this.

Regressions all held: MultiBus 22/274 and VME 10/312 on both cores with
byte-identical consoles, `xychain` PASS, and the bitstream came out at WNS
0.667 ns / WHS 0.067 ns with pulse width clean -- both *better* than the
0.597/0.034 of the build before it, which is placement variance rather than the
change being free.

**Three of the failures met along the way were the NFS server's, not the
machine's**, and each looked like a machine fault first: an unhandled
`FileNotFoundError` in the server left a call unanswered so the client wedged in
`NFS server not responding still trying` (a Python exception sends no reply at
all); `ESTALE` on the linker's sparse write, `l.outa00023` seeking from offset
3072 to 16384; and `SETATTR` silently ignoring a mode change, so a freshly
linked binary was not executable. Worth remembering before the next
write-shaped symptom is blamed on the MMU.

**Confirmed at the software end, against the running kernel.** `hat_pagesync`
(`0x65446` in the netbooted `vmunix`) walks the mappings calling `hat_ptesync`
(`0x65bfc`), which reads the raw page-map entry through control space and then
does exactly this -- the entry longword is at `fp@(-16)`, so `fp@(-15)` is
entry bits 23..16:

```
moveb %fp@(-15),%d1 ; lsrl #5,%d1 ; andib #1,%d1    entry bit 21 -> p_ref
moveb %fp@(-15),%d1 ; lsrl #4,%d1 ; andib #1,%d1    entry bit 20 -> p_mod
bclr #4,%fp@(-15) ; bclr #5,%fp@(-15)               clear both, write back
```

Those are the same two bits `sun2_fpga.v:404-405` decodes as `ACC` and `MOD`
and never sets.  So the kernel's only source of "this page is dirty" is entry
bit 20, it clears the bit after reading it, and the hardware never puts it
back -- `pp->p_mod` is permanently 0 and the page is discarded rather than
written.  No simulation was needed for this; it is a disassembly of the kernel
that is actually running.

Still to do before writing RTL: confirm the hardware half with a boot block on
the `ctxprobe` harness -- grant a page, write it, read the entry back through FC 3
and test entry bits 21 and 20 -- on both cores. Implementing it means a second
writer into a single-port read-first SRAM currently written only by software at
`C_S6`, so it touches MMU timing: it must not fire when access is denied, nor
for FC 3 or FC 7, and it must fire for DVMA cycles too.

**SunOS runs on a board.** A MultiBus V3 build with `CPU=rd68011` at 20 MHz
netboots SunOS 4.0.3 on a Wukong V1, past the creation of process 1 and into
the scheduler -- `_swtch+0x18`, seen on the ILA, with the stack-growth fault
taken and recovered from silently. What stood in the way was the bus error
register, not the MMU; see the trap above. `tools/pcsym` against the
netbooted `vmunix` is what turns an ILA address into that answer.

**It runs on a board.** A MultiBus V3 build with `CPU=rd68011` and the Ethernet
card auto-boots on a Wukong and puts correctly formed ND packets on a real
network — nothing answers them yet, so the boot times out, but the whole chain
from the CPU through the MMU, the boot PROM, the MultiBus Ethernet card, the
82586, the MII path and the PHY is proved in hardware rather than in
simulation. A minimalist VME build with Suska, on the same gateware, halts
before it writes its front panel; that is the RESET-instruction stall
`patches/Suska_Configware/0001` fixes, diagnosed from the LED panel and
confirmed by simulation.

What the board has taught, and how: the `todebug` LED ladder in `sun2_fpga.v`
is the instrument, and it works — it predicted `seen_err` with function code 6
for the VME failure before the bitstream was built, and the board returned
exactly that. Every bit on it is a level or a latch, because a signal moving at
`cpu_clk` is invisible on an LED and "too fast to see" cannot be told from
"never happened". `BRINGUP.md` holds the staged procedure and the debugging
tooling deferred until something misbehaves — the ILA among it. Add to that
list rather than building diagnostics speculatively.

**SunOS boots to a login prompt on the DECA too, and the port is what tested
the vendor-neutrality claim.** A MAX 10 at 12.5 MHz with 7 MiB of DDR3 netboots
SunOS 4.0.3 through RARP, TFTP, an NFS root and a 604688-byte kernel to
`sun2_f_m login:`. 56% of the logic, 39% of the memory, 3 of 4 PLLs, timing met
with Fmax 15.7 MHz against the 12.5 asked for.

The claim held, but not for free: a second front-end found three defects in
shared RTL that had survived the life of the project, each of which Vivado
tolerates silently. They are in the traps section below.

**The ceiling was a stale read cache in the DDR3 controller, and with it gone
the DECA netboots SunOS to a login prompt at 17.857 MHz -- 43% faster than the
12.5 MHz this file called the ceiling.**

| clock | duty | what happens |
|---|---|---|
| 13.889 MHz (VCO/72) | 50/50 | full boot, `rc`, daemons |
| 16.667 MHz (VCO/60) | 50/50 | full boot to `sun2_f_m login:` |
| 17.857 MHz (VCO/56) | 50/50 | correct `Boot: ie(0,0,0)`, then `can't open ethernet` |
| 17.857 MHz (VCO/56) | **53/47** | **full boot to `sun2_f_m login:`** |

Two independent fixes, and the order matters. The cache was the bug; the duty
cycle is the remaining *limit*. With the cache still in, splitting the period
correctly bought margin and no frequency, because the thing failing was not
timing. With the cache out, the half-period path in the CPU core becomes the
real limit and the same knob turns a clock that fails into one that boots --
which is the experiment that finally tells the two apart. Everything below in
this section was measured honestly and interpreted wrongly: the failures above
12.5 MHz were never timing. `boards/DECA/deca_top.sv` now sets
`PORT_W_CACHE_TOUT`, `PORT_R_CACHE_TOUT` and `PORT_CACHE_SMART` to zero on
BrianHG's controller, and `Probing I/O bus: sd ie` becomes `ie`, `Boot:
sd(2,0,0)` becomes `Boot: ie(0,0,0)`, and the machine boots.

`sun2_trace` caught the fault directly: the PROM's `sdprobe` wrote 2 to its loop
counter at 0x000F28, and the `cmpi.l #2` forty-seven clocks later read the same
address back as **1**, with a read forty-one clocks after that returning 2. So
the bound check failed, the loop indexed one past the end of `sdstd[]`, read the
terminating zero, added `dma_count`'s offset of 12 and probed **address 0x0C** --
low RAM, which reads, stores 0x6789 and reads it back. That is where the
impossible `sd(2,0,0)` came from.

**Why it looked like a clock problem.** A cache whose freshness is a timeout
counted in *clocks*, against a CPU whose access spacing is also fixed in clocks,
gives a fault that is frequency-dependent, deterministic and insensitive to
placement -- which is every property this section recorded and could not
account for. The half-period path below is real and is now the actual limit;
it simply was not what was failing.

**12.5 MHz was the ceiling, the limit is a half-period path inside the CPU
core, and every cheaper explanation was measured and rejected.** The knob to
ask the question with did not exist until recently -- `-cpu_hz` reached no
parameter in the Quartus flow, so every DECA build ran at `deca_top`'s default
whatever the banner said. With it wired through, the board says:

| clock | what the PROM does |
|---|---|
| 12.5 MHz (VCO/80) | `Probing I/O bus: ie`, `Boot: ie(0,0,0)vmunix` -- correct |
| 13.889 MHz (VCO/72) | `Probing I/O bus: sd ie`, boots `sd(2,0,0)`, `scsi: cannot select` x20, `Giving up...` |
| 14.286 MHz (VCO/70) | `sd ie` again, boots `sd(0,0,0)`, `Timeout Bus Error, addr: 00EE2804` |
| 16.667 MHz (VCO/60) | `ie` alone, but `Boot: mt(FFFFFFFF,0,0)` / `No controller at mbio FFFFFFFF` |

**Every one of those is a device-probe verdict, decided before a single packet
leaves the machine**, so the comparison stands whether or not a netboot server
is listening. `sdprobe` (`rsun/sys/sunstand/sd.c`) reports a controller present
only if reading `dma_count` does *not* bus-error **and** a written `0x6789`
reads back -- so above 12.5 MHz an address that must time out is being
acknowledged *and* is storing data. At 16.667 MHz it is the other way round:
`ieprobe` on a VME machine touches no Ethernet hardware at all, it reads the ID
PROM and checks a 16-byte XOR checksum, and it fails.

**It is deterministic and it is not placement.** Three runs at 16.667 MHz are
byte-identical, and `QSEED=3` -- a different fitter seed, Fmax 17.88 -> 17.98
MHz, so the placement really moved -- fails identically twice more. That is the
opposite of the Wukong, where placement flipped outcomes twice, and it is worth
knowing that the same instrument gives the opposite answer here.

**Timing is clean and says nothing.** At 16.667 MHz the design meets setup at
every corner (2.042 ns at 85 C, 4.552 at 0 C) and hold at all three (0.097 ns
fast); `report_ucp` finds no unconstrained *internal* path, only I/O pads. The
worst path in the whole design is 0.682 ns and it is inside the DDR3 PHY at
250 MHz, not in the machine at all.

**What the critical path actually is, and why WNS flatters it.** The machine's
worst path is
`u_seq|u_urom|...porta_address_reg0` -> `u_biu|d_o[7]` -- the microcode ROM's
address register to the bus interface's data output, which is the same seq->biu
path that caps the Wukong at 20 MHz. Its **Relationship is half the clock
period** in every build measured:

```
  12.5   MHz   requirement 40.000   data delay 31.401   slack 8.147
  14.286 MHz   requirement 35.000   data delay 29.277   slack 5.257
  15.625 MHz   requirement 32.000   data delay 29.093   slack 2.504
  16.667 MHz   requirement 30.000   data delay 27.510   slack 2.042
```

Rising edge to falling edge, so **the requirement is the PLL output's high
time, and STA models that as exactly 50% of the period.** `derive_clock_uncertainty`
adds jitter; it does not add duty-cycle distortion, because for a full-period
path there is none to add. On a half-period path there is, and it comes
straight off a margin of 2.042 ns on 30 ns -- 6.8%. That is a principled reason
why the reported slack overstates the real one *on exactly the class of path
that limits this design*, and it applies to the Wukong's 40 MHz ambition too.

Note also the data delay only compresses from 31.4 to 27.5 ns across a 2.7x
range of constraint: the router works as hard as it is asked and no harder, so
"Fmax" rises as you demand more (15.70 at 12.5 MHz, 17.44 at 16.667) and none
of those numbers predicted the board.

**Rejected, each by measurement rather than argument**, and recorded because
each was plausible enough to spend a build on:

* *DDR3 placement variance.* Its worst slack is flat across all four builds --
  0.68, 0.85, 0.85, 1.14 ns -- including the working one. Not the discriminator.
* *PLL duty-cycle distortion from an odd divider.* Every build's C0 counter is
  **even** with an exact 50/50 split (24/24, 21/21, 16/16, 18/18); ALTPLL picks
  a VCO that makes it so. A good theory, and simply not what the hardware does.
* *Metastability.* `report_metastability` -- Quartus's `report_cdc` -- gives a
  worst-case design MTBF of 5.28e3 s over 1472 chains, dominated by BrianHG's
  `DDR3_READY` fanning into the commander with a shortest chain of **one**
  register. Real, worth fixing, and not this: metastability is random and this
  failure is 5-for-5 identical.

  **It is not the cause of the random single-word corruption either, and the
  reason is worth keeping because the headline number is alarming and
  meaningless.** On the MultiBus SCSI build the same report says worst-case
  MTBF **85.2 seconds**, typical 7.4 days, over 857 chains -- which looks like
  exactly the right order for one bad word per ten-minute copy. Sorting the
  chains by MTBF shows every one of the low values is `DDR3_PHY -> DDR3_COMMANDER`,
  i.e. `DDR3_READY`, **which goes high once at calibration and never changes
  again**. A signal that does not toggle cannot resolve badly at runtime, so it
  contributes nothing to the failure rate however short its chain. The rest of
  the low-MTBF population is instrumentation -- JTAG's `altera_reserved_tms`,
  the `altsource_probe` chains, `blk_sd|card_ready` into the probe -- none of it
  in a data path. The chains that *are* in the data path, `rd68011_biu|a_o[3]`
  into `sun2_dvma`'s `rd_lo`/`rd_hi` latches, come out at **greater than one
  billion years**. Run the report by all means; sort by MTBF and then ask of
  each offender whether it toggles.
* *A stale Wishbone acknowledgement answering a device cycle* -- the Wukong trap
  in this file. `sun2_wishbone_bridge.v` is `W_ACK = (wb_ack_i & issued) | done`
  with both cleared when `MATCH_ANY` drops, so a late ack cannot acknowledge a
  device cycle. Read the RTL rather than rebuilding.

**The duty cycle is a knob now, and it buys margin but not frequency.** Both
worst paths are half-period ones and they are *not equal* -- at 16.667 MHz
rising-to-falling needs 27.96 ns and falling-to-rising 25.35 ns, and a 50/50
clock hands both 30 ns. `clk0_duty_cycle` was hardcoded to 50 in
`deca_clkgen.sv`; it is `CPU_DUTY` now, so `make -C syn quartus CPU_DUTY=53`
splits the period the way the paths want it. The duty is the C counter's high
count, so the achievable values are k/N and ALTPLL rounds -- 53 lands on 17/32
at 15.625 MHz and 19/36 at 13.889 -- and `derive_pll_clocks` reads it back, so
STA re-times both halves against the real waveform:

```
                     R->F     F->R    worst
  15.625  50/50     2.504    6.380   2.504
  15.625  53/47     3.968    5.545   3.968     +58%
  13.889  50/50     4.883    8.524   4.883
  13.889  53/47     7.533    8.266   7.533     +54%
```

Free -- no logic, no area, no frequency change. **What it cannot do is raise
the ceiling**, because the two halves share one period: the constraint is their
*sum*, 53.3 ns at best, which caps cpu_clk near 18.8 MHz however it is split.

**And the experiment split the problem in two, which is the useful part.** At
15.625 MHz the better split visibly helped -- one run of three got past the
third-stage loader's ID PROM check, `Downloaded 120936 bytes`, its own RARP and
`hostname: sun2_f_m`, where 50/50 never did -- so *that* failure really was the
half-period path, and it moved from deterministic to intermittent, which is
what running near a real timing edge looks like.

**The spurious `sd` probe did not move at all.** 13.889 MHz at 53/47 has 7.533
ns on a 38 ns half period -- 19.8%, the same proportion 12.5 MHz has at 50/50
(8.147 on 40, 20.4%) -- and it still finds a SCSI controller that does not
exist. So it is not a timing-margin fault: it tracks *absolute frequency* and
nothing else, which is the signature of something counted in clocks against
something fixed in time. `C_S24` is twelve clocks; the DDR3 round trip is a
fixed number of nanoseconds. That is the pair to look at.

**There is a logic analyser on the DECA now, and its first capture exonerated
the bus.** `rtl/sun2-common/sun2_trace.v` is a 256-sample circular buffer on the
same 118-bit `dbg_bus` the Wukong's ILA taps, read out over In-System Sources
and Probes by `tools/deca_trace.tcl`, fitted with `make -C syn quartus TRACE=1`.
It is ordinary RTL rather than SignalTap because **SignalTap cannot be
scripted** -- `quartus_stp`'s `::quartus::stp` runs an acquisition and offers
nothing at all for creating one -- and being ordinary RTL means it is
unit-tested (`make -C sim trace`, 22 checks, both mutations caught) before a
bitstream is spent on it.

Triggering on page 0xEE2800 at **FC 5** on a 13.889 MHz cold boot, the run that
prints `Probing I/O bus: sd ie`, catches the probe itself:

```
 rel  A       FC AS RW DTACK BERR C_S4 C_S6 C_S8 C_S24 ps_pmap TIMEOUT ERR MATCH_MEM
  +0  EE280C   5  0  1   1     1    0    0    0    0     FE6      0     0      0
  +1  EE280C   5  0  1   1     1    1    0    0    0     EC8      0     0      0
  +3  EE280C   5  0  1   1     1    1    1    1    0     EC8      0     0      0
 +11  EE280C   5  0  1   1     1    1    1    1    1     ECA      0     0      0
 +12  EE280C   5  0  1   1     0    1    1    1    1     ECA      1     1      0
 +13  EE280C   5  1  1   1     1    1    1    1    1     ECA      1     1      0
```

**That is a perfect timeout, and it is the only thing the hardware could do.**
There was no SCSI anywhere in *that* design -- so no `MATCH_*` term covered the
page, nothing sourced DTACK, and the cycle had to time out. (That is no longer
true of the tree in general: `MB_SCSI=1` and `VME_SCSI=1` both decode a host
adapter now, and a MultiBus build answers at `0x80000`. The reasoning below is
about the build the capture came from, where the cage really was empty.) That is the documented contract for TYPE 2 space
and it is how the PROM discovers empty addresses at all.

Decoding `ps_pmap` (`ps_pmap2devices`, entry bits 31..20) says where the cycle
actually went: **0xEC8 is VALID, TYPE 2 -- the system bus**, not on-board I/O.
So although `SCSI_BASE` sits in `s2addrs.h`'s "on-board and off-board I/O"
block between the parallel port at 0xEE2000 and the *on-board* Ethernet at
0xEE3000, the PROM maps that page out to the bus, where on this machine nothing
is plugged in. The genuinely off-board controller is the other entry,
`sdstd[1] = MBMEM_BASE+0x84000 = 0xF84000`.

The page is VALID, `PROTERR` is clear,
`MATCH_MEM` is 0 so the memory exemption correctly does not apply, DTACK never
asserts, `C_S24` fires 11 clocks after `AS`, and `BERR` is asserted on the next
one with `TIMEOUT` and `ERR` both set. As a free corroboration that the field
map is being read correctly, `ps_pmap` goes 0xEC8 -> 0xECA *during* the cycle:
bit 1 is ACC, and that is the MMU's accessed-bit writer doing its job, caught
in the act. The MMU, the device decode, the `C_S`
chain and the bus timeout are all doing exactly the right thing at the
frequency that fails.

**And the trace then found it: an array bound that fails to stop the loop.**
`sdprobe` walks `sdstd[] = { 0xEE2800, 0xF84000, 0 }` for `i < 2`. Both real
entries probe correctly -- 0xEE280C and 0xF8400C each time out, each raises a
textbook 68010 bus error, and the handler returns -1 both times, all visible in
the capture. Then, with `i` just written to memory as **2**:

```
 +455  000F28 FC5 WR 0002        i = 2
 +482  EF5682 FC6 RD 6C44        bges 0xEF56C8   (the loop exit)
 +508  EF5684 ...                ... and execution continues HERE
 +585  EF7944 FC5 RD             sdstd[2] -- the terminator, 0x00000000
 +681  000F24 FC5 WR 000C        peek(0x0000000C)
```

**`cmpi.l #2` against an `i` of 2 did not take its `bge`.** The loop runs a
third time, indexes one past the end of the table, reads the terminating zero,
adds `dma_count`'s offset of 12, and probes **address 0x0C** -- which is low
RAM, so it reads, it takes `0x6789`, it reads `0x6789` back, and `sdprobe`
returns **2**.

That is the whole failure, and it explains the thing that made no sense:
`Boot: sd(2,0,0)`. `sdprobe` can only ever return 0, 1 or -1, so a controller
number of 2 was impossible -- unless the loop ran with `i` = 2, which is exactly
what it did. `Probing I/O bus: sd ie` is the same wrong verdict one call
earlier, and the `scsi: timeout` / `cannot select` that follow are the driver
talking to address 0x0C.

**Two candidates remain for the wrong branch and they are cleanly separable.**
`cmpi.l #2,%fp@(-8)` is a *longword* read, two bus cycles, and this project has
history there: RD68011's fixed bug was a longword read losing its first half
across a bus grant. Either the core's condition codes are wrong for that
compare, or the compare read a stale `i` -- note the index computation a few
instructions later read the same location and got 2, which is what makes the
stale-read case interesting rather than obvious. Reading the value the CPU
actually latched needs care: `dbg_data` lags by one *memory* transaction and
PROM fetches do not go through the bridge, so the shift cannot be applied
naively across a mixed sequence.

**So the fault is above the bus, not on it.** `sdprobe`
(`rsun/sys/sunstand/sd.c`) reports a controller present only if
`peek(&har->dma_count)` does *not* return -1; the hardware raises the bus error
that should make it return -1, and the machine still prints `sd`. That moves the
search to bus-error *delivery and recovery* -- the exception frame, the restart,
and the bus error register -- and away from everything this file spent four
builds suspecting. Note also `Boot: sd(2,0,0)`: `sdprobe` can only ever return 0
or 1, so the controller number the PROM ends up with did not come from it.

So the next move is not another frequency. It is SignalTap on the `C_S` chain
and the DTACK terms at the SCSI probe address -- the DECA's equivalent of the
ILA that found the Wukong's frame-buffer timeout race, which was this same
shape: `C_S24` firing on clock 12 against a DTACK on clock 13.

**A capture that starts 65 bytes in is the JTAG FIFO, not the machine.** Every
board capture this project has taken loses a run of the banner and resumes
mid-word, and the resume point moves between runs, which reads exactly like
corruption. It is not. The prefix that survives is
`Self Test completed successfully.\r\n\r\nSun Workstation, Model Sun-2` --
**65 bytes, every time, at every clock**: the JTAG UART's 64-byte write FIFO
plus one in flight, filled before `juart-terminal` finishes attaching, after
which the bridge drops until someone drains it. Programming the device is
itself a reset, so attaching immediately after `quartus_pgm` and skipping the
separate reset step buys back most of it. Do not read a mangled banner as a
machine fault: compare the drop against a known-good clock first, which is what
turned this from a finding into an artefact.

**The DECA boots SunOS from a micro-SD card, with no network anywhere in it.**
`make -C syn quartus MACHINE=multibus CPU_DIV=60 XY450=1` builds a MultiBus
2/120 -- the first non-VME build for this board -- with the Xylogics 450's four
SMD drives replaced by the slot on the edge of the board:

```
  Sun Workstation, Model Sun-2/120 or Sun-2/170, Sun-2 keyboard
  Probing Multibus: xy      Boot: xy(0,0,0)vmunix
  xyc0 at mbio 0xee40 pri 2
  xy0: <Fujitsu-M2351 Eagle cyl 840 alt 2 hd 20 sec 46>
  root on xy0a fstype 4.2   swap on xy0b fstype spec size 46000K
  sun2# /bin/df
  /dev/xy0a   327599  29667  265172   10%   /
```

`fsck` reads and writes the card on the way past (`2721 files, 29559 used`), so
this is not a read-only demonstration.

**It is smaller than the VME machine it replaces** -- 24,788 LE (50%) against
27,563 (55%), 660,640 memory bits against 676,768, Fmax 17.85 MHz against the
16.667 asked for -- because dropping the on-board 82586 gives back more than the
disk path costs. It has to be MultiBus (`sun2_fpga.v` `$fatal`s on `SUN2_XY450`
under `SUN2_VME`), and MultiBus means **no Ethernet at all**: the card's 256 KiB
is four banks of 65536x8, which is 256 M9K on a device that has 182.

**The level shifter is the whole of what is new here.** The FPGA does not reach
the card. Between them is U22, an `SN74AVCA406L`, whose A side sits on the 1.5 V
DDR3 rail -- which is why the SD pins live in bank 4 -- and whose B side is
powered through load switches. So four of the eight pins carry no data at all;
they steer the translator, and in SPI mode they are constants: `SD_SEL=0` puts
3.3 V on the card, and `CMD_DIR=1`, `D0_DIR=0`, `D123_DIR=1` point MOSI out,
MISO in and DAT3-as-chip-select out. Pinout is Table 3-21 of the board manual,
polarities are the board's own porting guide; nothing is inferred. `SD_SEL` is
the one pin that is not 1.5 V, and the board's own template assigns its location
while commenting its I/O standard out -- the manual says 3.3 V and the fitter
agrees.

**DAT1 and DAT2 are driven high rather than left unassigned**, because
`SD_D123_DIR` is one pin for all three of DAT1/2/3 and Quartus's default for a
reserved pin is to drive ground -- which would hold the card's DAT1/DAT2 low
through the translator. A card in SPI mode ignores them either way, but that is
not a thing to leave implicit on the far side of a level shifter.

**The acceptance test needs no disk image, and that is deliberate.**
`tools/deca_reset.tcl` prints `disk: ready=1 err=0 blocks=7626752 (3.6 GiB)` --
`blk_ready` is `blk_sd` having completed CMD0/CMD8/ACMD41/CMD58/CMD9, and the
count is what it read out of the card's CSD. Both are true of a blank card, so
the pins, the translator, the direction constants and the 8.3 MHz SPI clock are
all provable before any content exists. With an empty slot the same line reads
`ready=0 blocks=0` and the console says `Waiting for disk to spin up...` -- two
instruments, one answer. The fields are appended at the **bottom** of the ISSP
probe: adding them at the top would shift every existing offset and silently
invalidate a decode that indexes the returned bit string MSB-first.

**No card detect reaches the FPGA on this board**, unlike the Wukong's `sd_cd`.
So "no card" and "a card that never initialised" are the same reading, and the
only way to tell them apart is to try another card.

**Resolved 2026-09-13 -- read this first.** The single-word disk corruption
that everything below chases was a *bus-errored memory access issuing a phantom
DDR3 request*: in the clock after a refused cycle's AS negates, `MATCH_MEM` was
true for one clock, the adapter ran that orphan read, and the next memory cycle
-- typically a master's first halfword -- took its acknowledge and its data.
Found with a bus-history ILA, reproduced by `tb/tb_orphan_ack.sv`, fixed in
`sun2_fpga.v` by holding the MMU's refusal for the rest of the cycle, and
measured on the board at **0 of 8,388,608** where the same setup gave 140, 149
and 177. See "Found and fixed" near the end of this investigation. The history
below is kept because the eliminations in it are real, but several of its
theories (retention, write visibility, DM pins) are superseded by that result.

**Writing to the card corrupts files, the blocks go to the right places, and
what it needs is concurrency rather than volume.** A copy is byte-perfect on
its own and three copies back to back all come back wrong -- measured on a
freshly written filesystem in single user, so it is neither the medium's
history nor a busy multi-user machine:

```
  /usr/bin/adb -> /wa   copied alone            50905 -> 50905   intact
  /vmunix      -> /wb   three copies back to    22308 -> 12922   corrupt
  /usr/bin/csh -> /wc   back, same session      34435 -> 29822   corrupt
  /usr/bin/adb -> /wd                           50905 -> 46503   corrupt
```

`fsck` is clean afterwards, so the damage is inside files and not in the
structure, and `cmp` puts `/wd`'s first difference at byte 4385 -- past several
blocks that are byte-identical, so it is not a transfer that goes wrong from
the start.

**Misdirection is dead, and that was the open question.** `sun2_blktrace`
(`BLKTRACE=1`, read out by `tools/deca_blktrace.tcl`) recorded the copies:
every block landed at exactly the LBA its position in the file predicts --
partition sector 2400 + 32k for block k, which is 4.2BSD's rotational layout --
in order and self-consistent, for all thirteen blocks of a file that came back
corrupt. So "the hardware writes at the wrong address" is finished, and the
fault is in the data path between memory and the card.

Four layers were already cleared by test and none of them was it: the media, the
SD path on real hardware (`test/deca_sdtest`), `blk_sd` in simulation (`make -C
sim blksd`), and the SCSI engine and `sun2_dvma` (`make -C sim mbscsi`, `dvma`)
including at DDR3-like latency with several commands back to back. The XY450
corrupts identically, which exonerates every line of the SCSI work; what the
three controllers share below them is `sun2_dvma`, `sun2_wishbone_bridge` and
BrianHG's controller. `tools/wrprobe` puts a CPU in a spin loop while the
master streams, which is the one condition no testbench here reproduces, and it
passes -- so whatever it is, a boot block driving the same path does not
provoke it.

**What it is: exactly one 16-bit word per damaged sector, at an even offset.**
Not a burst, not a whole sector, not another file's block:

```
  adb sector  89, byte 136:   660c -> ffff
  csh sector  73, byte 500:   0000 -> 4ef8
```

`4ef8` is ordinary 68010 code (`JMP`), so the `ffff` is not a bus-idle pattern
either -- both look like data from somewhere else. One word in roughly a hundred
thousand. A DVMA longword is two 68010 cycles, so **one wrong 16-bit word is one
half of one longword read**, which is the shape of two bugs this tree has already
fixed (RD68011's bus-grant handover, and the bridge serving two masters).

**The trace predicts the medium, twice over.** On a pristine filesystem it named
`csh` sector 8 and `adb` sector 13 as the damaged ones; `cmp` on the rebooted
machine put the first differences at bytes 4121 and 7145 -- sectors 8 and 13.
That is the instrument checked against ground truth rather than trusted.

**Two candidates eliminated by measurement, both cheap and both plausible:**

* *BrianHG's `PORT_CACHE_SMART`.* With it zero, a read whose address matches a
  write still sitting in the write cache (`WC_ready` set, `WC_DDR3_ack` not yet
  seen) goes to DRAM and returns the previous contents -- the exact shape of the
  fault. `deca_top` had it zero. Set to 1 (`DDR3_SMART`, +460 LE, timing met)
  the corruption is unchanged. It also sits in the path the **CPU** uses, and
  the machine's own survival argues against that path: the CPU issues orders of
  magnitude more traffic through the bridge than any master, and a fault there
  at this rate would be fatal long before it showed up in a file.
* *A stale bus grant in `sun2_dvma`.* `P_BG_n` was tested as a level, and the
  module negates `P_BR_n` for only two clocks (`S_ACK`, `S_IDLE`), so during a
  streaming transfer it can re-request inside the CPU's spec-#36 window and read
  the *previous* transaction's grant as an answer. Real, and **fixed** -- it now
  waits in `S_IDLE` until the grant is withdrawn, which also buys spec #39 by
  construction. But it cannot be the cause: `D_FETCH` returns only after
  `D_OUT`/`D_OUTACK` have handed all four bytes to the target one at a time, so
  the gap between Wishbone fetches is far longer than the 1.5-3.5 clock window.
  Measured: with the fix in and a pristine filesystem, 5 sectors of ~600 still
  corrupt.
* *AS timing.* `sun2_dvma` drove AS from a posedge state machine, so both edges
  landed on rising ones and the asserted width was a whole number of clocks --
  minimum 2.0, where a 68010 never gives less than 2.5 and releases on a falling
  edge (spec #14). That matters in principle because `sun2_fpga`'s chain is
  edge-faithful. **Fixed** (`09ecfe2`), and the corruption is unchanged: 5
  sectors of ~600 again, at the same rate. The 2.0-clock floor was unreachable
  anyway -- memory DTACK cannot arrive before `C_S6`, two clocks after AS, so a
  DVMA memory cycle's AS is nine to fifteen clocks wide in practice.

  Note what the fix is *not*. A "BG was seen negated" flag deadlocks: it still
  re-asserts BR after two clocks, and a core deciding from the current BR level
  may then never negate BG, leaving the flag clear for ever. Holding BR negated
  is what makes the CPU withdraw the grant.

**Both directions corrupt, and the read side had been wrongly cleared.** A file
pristine on the medium came back wrong *in memory*, and a file correct in memory
landed wrong on the medium, in the same session:

```
                       on disk (cold)   in memory (warm)
  /usr/bin/adb            50905            55306
  /usr/bin/csh            34435            34435
  /za  (copy of csh)      49861            34435
  /zb  (copy of adb)      01370            55306
```

`/usr/bin/adb` is byte-perfect on the card and was read into the buffer cache
wrong; `/za` was correct in the buffer cache and reached the card wrong. So this
is not a memory-to-device transfer bug, and the paragraph below -- which
concluded reads were clean from `dd if=/dev/rsd0a | sum` agreeing twice -- was
measuring the *raw* path, which bypasses the buffer cache, and does not
generalise.

**That reframes the whole search, and suggests one mechanism for all of it.**
Data is correct when written and wrong when read back later, in both directions,
while every handshake, response and lane check in between reads zero and a
double read of the same address agrees with itself. What fits all of that is
data decaying *while resident in DDR3* -- a refresh or retention problem in
`Inputs/BrianHG-DDR3` -- rather than anything about the transfer. It would also
explain why `test/deca_ddr3` passes (it writes and reads straight back, with no
dwell) and why the CPU survives (its text pages are re-read from disk, and a
decayed instruction shows up as the `lpd` cores and `ld` SIGILLs this file
already records).

**Retention was measured and it is not that.** `tools/memdwell` fills memory
with a self-describing pattern, leaves it alone, and reads it back; on 2 MiB in
single user, three dwells of 600 s each plus a zero-dwell control gave **0 wrong
of 3,145,728 halfwords**. Idle memory does not rot, so the decay story is dead
as stated.

**What fits instead is a write that a later read does not see, and it explains
both directions with one mechanism.** A disk write is: the CPU writes the buffer
into DDR3, then DVMA reads that buffer out. If the CPU's write has not become
visible when the master reads, the card gets the *previous* contents while a
later CPU read sees the landed write -- which is exactly `/za`, correct in
memory at 34435 and wrong on the card at 49861. A disk read is the mirror: DVMA
writes the buffer, the CPU reads it, and a write not yet visible gives the CPU
stale data while the card holds the truth -- exactly `/usr/bin/adb`, 50905 on
the card and 55306 in memory. `patwr`'s bad word decoding to *old-generation
content from another position* is the same thing seen a third way.

**And the double read cannot see it, by construction.** It issues the same
address twice back to back and compares; if a write has not landed, both reads
return the same stale value and agree. Every counter stays zero. So the zero it
reported is consistent with this and never excluded it.

**Measured, and writes are visible.** `WRITE_VERIFY` in `deca_wb_to_ddr3` reads
every write straight back and compares it against what was written, byte-masked
by `wb_sel`, with `PORT_CACHE_SMART` held at 0 so the read-back cannot be
answered out of the write cache and confirm itself. `tb_deca_wb_ddr3` runs the
arm and injects a dropped write to prove the check can see one. On the board,
across a boot: **0 wrong**. The counter is demonstrably live -- responses exceed
`reads issued` by about 19,895, which are the read-backs themselves, since that
counter only counts `CMD_ena && !req_we`.

**So every layer this project owns is now measured clean, and the fault is still
there.** Handshake, response accounting, lane, half, capture, read consistency
and write visibility all read zero on runs that corrupt.

**Qualified 2026-09-13: the write-visibility zero above was one boot, not a run
that corrupted.** About 20,000 verified writes, against a fault of roughly one
word in 60,000 to 130,000 pattern writes, cannot tell a lost write from none.
It has since been repeated on a real corrupting pass (the "sun2_clobber" results
further down): `patwr` 90 wrong, 88 wrong at the master's capture, **write
verify still 0** over the whole 16 MiB. But the check compares **only the bytes
the write itself enabled**, so it proves each halfword was right *immediately
after its own write* and says nothing about the other half of the same 32-bit
word afterwards.

**It is not the DECA, and it is not BrianHG's controller.** A Wukong V3 --
Xilinx, Vivado, MIG, a MultiBus machine with the **Xylogics 450** rather than
SCSI, at 20 MHz -- boots SunOS from the same micro-SD card and corrupts at the
same rate. `tools/patwr`, 512 KiB, written and verified cold after a reboot:

```
  BAD  sector  69 word 132  want c584  got 6d08
  BAD  sector 215 word 114  want d772  got 281c
  BAD  sector 326 word 158  want c69e  got 6d08
  BAD  sector 853 word  44  want d52c  got 281c
  patwr: 4 of 262144 words wrong
```

Four in 262,144, against three to six on the DECA. So the fault survives a
change of FPGA vendor, toolchain, DDR3 controller, board and disk controller,
which eliminates every DECA-specific suspect at once -- BrianHG's controller
above all, after several sessions spent narrowing onto it.

**What both machines share is this project's own RTL**: `sun2_wishbone_bridge`,
`sun2_dvma`, the MMU and bus in `sun2_fpga`, `blk_sd`, and the RD68011 core.
The DECA measurements already put the damage *before* the master's capture --
the word is wrong as it comes out of the bridge -- and the bridge is shared
while the two memory controllers under it are not. That is the place to look.

**Two distinct wrong values, each appearing twice**, is the other lead: `6d08`
at two file offsets 9834 words apart and `281c` at two more. A fault that
returns the *same* wrong word at unrelated addresses is not random decay; it
looks like a stale register or a buffer read twice.

**Caught in flight: the data is already wrong when it reaches the card.**
`tools/patwr -u` writes a pattern that is the same in every sector -- halfword i
is `0x8000 | i`, so byte 2i is `0x80` and byte 2i+1 is `i` -- which the FPGA can
predict from the buffer address alone. `sun2_blktrace` checks every byte against
that as it goes out, gated on the sector's first two bytes so ordinary traffic
is ignored. On a freshly written filesystem, 256 KiB:

```
  sectors seen      512
  bytes wrong         6
  first: LBA 00100644 byte 432, wanted 80 got 53
```

Six bytes in 262,144 -- the familiar rate -- and **the fault is now localised in
hardware, at the moment it happens**, rather than inferred from a checksum after
a reboot. It is upstream of `blk_sd`, the SPI bus, the card and the medium,
because it is already present at the last point inside the FPGA before them.
`wanted 80 got 53` is also informative: `0x80` is the *even* byte of every
halfword, so the damaged byte is the high half of a 16-bit word, and `0x53` is
neither a neighbouring pattern byte nor zero.

**The same check at the master's capture closes the span.** `sun2_dvma_probe`
predicts the pattern from `dvma_a[8:1]` -- a buffer-cache block is 512-byte
aligned, so the halfword index within a sector is in the address -- and counts
only an *isolated* miss, one with matching words on both sides. On the same run:

```
  at the master's capture   wrong words 4, first took 53d2 (wanted 80xx)
  at the card interface     byte 432, wanted 80 got 53
```

**The "4" above is not the master-capture count** -- found and fixed
2026-09-13. `tools/deca_dvmaprobe.tcl` assigned `pat_bad` twice, the
master-capture count (offset 32) and then the block-seam count (offset 389), in
the same commit that recorded this table (`d075d7f`), so "wrong words" has
always printed the block-seam figure. `first took 53d2` is a separate field
(offset 48), set only by a real master-capture miss, so the conclusion drawn
from it stands; the count does not. The fixed tool read **88** at the master's
capture against `patwr`'s 90 on the first run after the fix.

**`0x53` replacing `0x80` at both ends.** So the word is already wrong when the
master captures it from the bridge, and `sun2_dvma`, the SCSI engine, the sector
buffer, `blk_sd` and the card are all downstream of the damage. The fault is at
or below DDR3.

**And that is not retention, because the same memory is provably good when
written.** `WRITE_VERIFY` reads every write straight back and finds 0 wrong;
`DOUBLE_READ` finds the controller self-consistent; `memdwell` finds no decay in
600 s of idle. What is left is a value that changes between the write and a
later read **while other traffic is in flight** -- disturbance under load rather
than decay at rest, which is why every quiet test passes. `0x80` to `0x53` is
five bits, so it is not a bit flip; it is a different byte, from somewhere else.

Two things about reading these counters. `matches` is 16 bits and a 512-sector
pass is 131,072 words, so it wraps: the first run of this check read `matches 0`
and looked dead when it was exactly two wraps. And the check must count only
isolated misses -- the first version armed on a run and then flagged everything,
reporting 1018, because a master reads plenty that is not the pattern.

**Everything from DDR3 up to and including the bridge is now measured clean on
a run that demonstrably corrupted.** That last clause is the whole point: the
counters had read zero twice before on runs that turned out not to have
corrupted at all, which proves nothing. A `patwr -u` pass followed by a reboot
and a cold verify gave **5 of 262,144 words wrong**, the familiar signature, and
the VIO on the same run read:

```
  read crossing    pattern 3,653,604     corrupted  0
  write crossing   pattern 2,095,307     corrupted  0
  bridge address   loads   741,868,089   wrong addr 0
  bridge half      pattern 1,826,787     wrong half 0
```

So on a corrupting run, with controls in the millions: both adapter clock
crossings are clean, every response is matched to the address its request went
out with, and the half the bridge selects and latches is the right one. The
fault is **not** in DDR3, not in either crossing, and not in the bridge.

**The wrong values are ASCII, and that is the lead.** `2e2e` is `..`, `2f2d` is
`/-` -- two characters of the bootloader's own `|/-\` spinner -- and `584f` is
`XO`. Not decayed bits and not another position in the pattern: content from
somewhere else entirely, which is what a stale bus value or a mux selecting the
wrong source looks like.

**Which leaves one span, and it is narrow.** `P_DATA_OUT` is proven correct as
it is latched; the DECA measured `dvma_din` already wrong at the master's
capture. Between them lie only `sun2_fpga`'s read mux onto `P_DOUT` and
`top_fpga`'s muxing of CPU against DVMA -- both shared by the two boards, and
neither instrumented.

**Two traps from the tooling, both of which produced confident nonsense.**
`tools/patwr`'s flags used to be mutually exclusive, so a `-u` file could not be
verified after a reboot at all -- the cold check that anchors every hardware
counter was impossible to run. Making them combine introduced the second: the
new parsing loop assigned `vonly` and `fill` only inside its branches, and they
are auto locals, so a plain write ran as **"verify only"** against a zero-filled
file and reported 5531 bad words. A run of consecutive `got 0000` is that, or an
interrupted write; the single-word fault is always isolated. Read the banner --
it says which mode actually ran.

**The mux is clean, the master's capture is correct, and that moves the fault
*downstream* of everything instrumented so far.** On a run that corrupted 2 of
262,144 words:

```
  mem reads   585,496   the master's memory captures
  mux wrong         0   P_DOUT was always the bridge's registered word
  pattern     524,283   ... of which were the pattern
  pattern bad       0   ... and every one of them was right
```

So `sun2_fpga`'s 20-way `P_DOUT` mux and the CPU/DVMA routing are exonerated,
and -- the stronger half -- **the word `sun2_dvma` captures is correct**. The
damage happens after the capture.

**That contradicts the DECA's earlier reading, and the Wukong's is the one to
believe.** `sun2_dvma_probe`'s original check predicted the pattern from
`dvma_a[8:1]` and counted *isolated misses* after arming on a run -- a heuristic
that had already produced 1018 false positives once and needed rewriting. The
check here compares `dvma_din` against `brg_dout`, the bridge's own registered
word, on the capture edge: a direct comparison with no arming and no
prediction, with a 585,496 control on a corrupting run. Where a heuristic and a
direct comparison disagree, the direct one wins.

**Which leaves `sun2_dvma`'s assembly, and it fits the evidence exactly.**
`sun2_dvma.v:379` builds the Wishbone word from two halves latched in
*different* 68010 bus cycles:

```verilog
   wb_dat_o <= {rd_hi[7:0], rd_hi[15:8], rd_lo[7:0], rd_lo[15:8]};
```

If one cycle's latch is missed, that half keeps the **previous transaction's**
value and the assembly writes it out -- one wrong 16-bit word at an even offset,
carrying content from somewhere else entirely. That is the whole signature, and
`2e2e` (`..`) and `2f2d` (`/-`) are what a stale half from an earlier sector
looks like. It is also below the point where the XY450 and the SCSI card
diverge, which is why both corrupt identically.

The check is a flag per half, cleared when a transaction starts and set at each
`S_LATCH`: count any assembly where both were not set.

**The sector buffer is written correctly, nothing is dropped, and the fault is
now inside one RAM.** Three runs, each anchored by a cold verify that the run
really did corrupt (1, 3 and 5 wrong words):

```
  sbuf bytes offered   1,048,776   the control
  wrong, isolated              0   every byte offered was the right one
  DROPPED                      0   no DMA write lost to the buffer port
```

`sun2_xy450.sv`'s buffer is one port shared by two masters --
`buf_we = blk_busy ? blk_buf_we : dma_buf_we` -- so a DMA write offered while
`blk_sd` holds the port is discarded silently, and `E_IN_PUT`'s own comment
argues from timing that the last one "lands". **It does: the counter is zero.**
A good hypothesis, cheap to test, and wrong.

So the byte is right when offered and right when stored, while `sun2_blktrace`
on the DECA sees it wrong as it is *read out* at the `blk_*` seam. What is left
between those two points is the `sbuf` RAM itself and its read port:

```verilog
   if (buf_we) sbuf[buf_addr] <= buf_wdata;
   buf_q <= sbuf[buf_addr];
```

a single-port read-first RAM whose address is muxed by `blk_busy`, answering one
cycle late (`Inputs/Wish5380/doc/block.md:58`). That is a very small piece of
RTL, and it is shared with the SCSI card only through `blk_sd`'s side of the
seam -- which is the part both cards do have in common.

**The raw-versus-isolated split is what made the number readable.** The first
board run of this check read **214 wrong bytes** against a disk that took 5
wrong words -- forty times too many. Every one of them was a *run*: a sector
that is not the pattern, still being checked because the arming flag was set by
the sector before. Counting only isolated misses takes it to zero and leaves the
raw figure beside it for comparison. This is the third instrument in this file
to need that rule; assume any new one does too.

**The byte is correct entering the sector buffer and correct leaving it.** With
the check counting once per byte -- on the clock `blk_buf_addr` moves, which is
when `blk_sd` loads `spi_tx` and `crc16` from the same expression -- the control
lands within two of the write side, which is what says the instrument is right:

```
  offered into the buffer   1,048,776   wrong 0   dropped 0
  read back out of it       1,048,778   wrong 0
```

on a run whose cold verify found 3 of 262,144 words wrong. So the buffer stores
and returns exactly what it was given, and the sample taken is provably the byte
`blk_sd` consumed: `byte_done` is high the clock after the address moves, and
`ok_q` is the comparison registered from the clock before, which is the value
that was on `buf_rdata` when it was captured.

**What is left is very small, and one part of it argues against itself.**
Between `spi_tx` and the card there is only the SPI shifter and the wire -- but
`crc16` is computed from the *same* `blk_i.buf_rdata` in the *same* clock, so a
byte damaged after that point would go out with a CRC that does not match it,
and the card would reject the block rather than store it wrong. A whole sector
would keep its old contents, not one word.

**The card was read on a host and it settles it: the medium is wrong, and the
three damaged sectors are exactly the three the machine reported.** 400 MiB
dumped from the card and scanned for `patwr -u`'s pattern, which is
unmistakable (`80 00 80 01 80 02 ...`) and needs no filesystem walk:

```
  pattern sectors 1040   clean 1037   damaged 3
  LBA  2405 byte  4   want 80 02   got 2e 2e     (file sector 101 word  2)
  LBA 30678 byte 28   want 80 0e   got 2e 2e     (file sector 358 word 14)
  LBA 31285 byte 76   want 80 26   got 58 4f     (file sector 661 word 38)
```

The machine's own cold verify named those three word indices with those three
values. So the read path is faithful -- it reported exactly what is on the card
-- and the damage happened on the way out.

**And that produces a contradiction which is itself the finding.** On the run
that wrote them, the byte was measured correct entering the sector buffer
(1,048,776, none wrong, none dropped) and correct leaving it (1,048,778, none
wrong). `blk_sd` loads `spi_tx` **and** `crc16` from that same `buf_rdata` in
the same clock, so a byte damaged after the CRC was computed would go out with a
CRC that does not match and the card would **reject the block** -- losing a
whole sector, not two bytes. No logic fault after the buffer fits.

**What fits is a glitch on `buf_rdata` at the capture edge.** Both `spi_tx` and
`crc16` sample that net, so both take the same wrong value: the CRC agrees with
the corrupted data, the card accepts it, and one byte is wrong on the medium.
The checker in `sun2_xy450` reads the same *logical* net through different
*physical* routing, so a marginal path to one load and not the other is
invisible to it by construction.

That makes this a timing problem rather than an RTL one, and it accounts for
every property this investigation has recorded: **simulation can never reproduce
it**, because zero-delay logic cannot glitch; every RTL-level check reads zero;
both boards show it while sitting near their limits; and it is rare,
single-byte, and placement-sensitive. This build meets timing at **WNS 0.039
ns**.

**The clock was changed and the account above is wrong.** Same RTL at
`CPU_DIV=80` -- 12.5 MHz, WNS **1.228 ns** against 0.039, thirty-one times the
margin -- corrupts at exactly the same rate: 3 of 262,144, where 20 MHz gave 1,
2, 3, 3 and 5 across runs. **It is not a setup-time glitch**, and the neat
story about `spi_tx` and `crc16` sampling a glitching net is retracted.

**The wrong values are 68010 instructions, and that is the lead.** They were
read here as ASCII -- `2e2e` as `..`, `584f` as `XO`, `2f2d` as `/-` -- and that
was wrong. Searched in context on the card:

```
  584f   101,968 occurrences   addqw #4,%sp     -- stack cleanup after a call
  2f2d    14,529               movel %a5@(d16),%sp@-
  2e2e    10,250
```

`584f` is one of the most common words in any compiled 68010 program. So the
corrupting source is **program text**, the same few opcodes every time because
those are the commonest ones, appearing at random positions.

**And that explains why every check in the disk path reads zero, by
construction.** `n_pat32` counts a word only when `brg_dout` already matched the
pattern; `xchk_n_wpat` counts a write only when it was the pattern in the
Wishbone domain; the `sbuf` checks arm on a sector whose byte 0 is `0x80`. A
word that is *already wrong in memory* matches none of those conditions, so it
is never counted -- the whole instrumented path faithfully carries a word that
was corrupt before it started.

So the suspicion moves off the disk path entirely and onto the buffer-cache page
in DDR3: something is putting program text into it between the CPU's write and
the master's read. `patwr`'s own read-back is clean, but it reads from the
buffer cache and runs *before* the kernel flushes, so it cannot see a page
contaminated after that.

**The inverse check was built and it is the first non-zero in the whole
investigation.** `sun2_dvma_probe`'s original run-armed counters -- armed by a
run of words matching what their *address* predicts, not by the word already
being the pattern -- widened to 32 bits and put on the VIO:

```
  in a run     524,286   the control, essentially every pattern word
  ARRIVED BAD        2   wrong before it entered the disk path
```

Two passes, two bad arrivals; the cold verify of the final state found **1**,
which is the last pass's share. Consistent, and anchored.

**So the word is already wrong when the master captures it from the bridge** --
which is exactly what the DECA's `sun2_dvma_probe` said, and which this file
retracted in favour of the content-gated check. **That retraction was wrong**:
the content-gated comparison cannot see this fault by construction, and the
heuristic it was said to beat was measuring the right thing all along. A direct
comparison is not automatically better than a heuristic if it is gated on the
very condition the fault violates.

**Which means memory held program text where the pattern belonged.** The write
crossing says the CPU's write landed, the bridge says the response matches the
address it was requested for, and the master says it read that address and got
`584f`. Something wrote into that DDR3 location between the two.

**The controller holds its request perfectly still, so that is not it either.**
`sun2_dvma` now latches `wb_adr_i` and `wb_dat_i` when a transaction is taken
and compares them for as long as it runs -- `dvma_a` is `{wb_adr_i, half}`,
combinational with no latch of its own, so a moving `wb_adr_i` would put the
access on a different page:

```
  transactions  728,901
  ADDR MOVED          0
  DATA MOVED          0
  ARRIVED BAD         7   (same run, so the fault was present)
```

**The ILA caught the failing cycle, and the address the bridge is given is
built from a page-map output that lags.** With `arrived_bad` as the trigger --
the first trigger in this investigation that was *known* to fire, because the
counter behind it reads 2 and 7 on runs whose cold verify finds the corruption
-- one capture shows the whole thing:

```
  -38  A=7815d3 FC=5 ps=f02  data=80d2  dvma=1
  -27  A=7815d3 FC=5 ps=f02  data=80d3  dvma=1
  -26  A=01235e FC=1 ps=d03  data=dead  dvma=0   <- a CPU cycle interleaves
  -22  A=7815d4 FC=5 ps=d03  data=dead  dvma=1   <- ps is still the CPU's page
  -20  A=7815d4 FC=5 ps=f02  data=80d3  dvma=1
  -14  A=7815d4 FC=5 ps=f02  data=584f  dvma=1   <- the wrong word
    0  A=7815d5 FC=5 ps=f02  data=80d5  dvma=1   <== trigger
```

Three consecutive addresses return `80d3`, **`584f`**, `80d5`: the wrong word
sits exactly where `80d4` belongs, in an otherwise perfect run, and the cycle
that fetched it **began carrying the previous CPU cycle's page-map entry**.

**And the address handed to the bridge is made of that entry:**

```verilog
   .P_ADR_IN({1'h0, ma_pmap2devices[11:0], P_A[10:1]})   // full physical
```

`ma_pmap2devices` is the page map's registered read, so it is valid a cycle
after the lookup; `MATCH_MEM` is `... & (ma_pmap2devices[11:0] < MEM_PAGES) &
C_S6`, using it combinationally. A request issued while it still holds the
previous cycle's page reads **the wrong physical page**, and DDR3 returns that
page's contents perfectly -- which is why every check downstream is clean and
why the wrong values are always common 68010 opcodes.

It accounts for every property recorded here. The word is wrong before the
master captures it; the bridge's own address check compares `P_ADR_IN` at issue
against `P_ADR_IN` at load and they *agree*, because both are stale; the rate is
unchanged by clock frequency, because it is a logic race and not a setup
violation; it needs a CPU cycle interleaved with a DVMA cycle, which is why a
disk transfer under load provokes it and a quiet memory test never does; and it
is in `sun2_fpga.v`, shared by both boards.

**An extra settling cycle before AS was tried and does not fix it.** The
hypothesis was that the MMU chain is a cycle late when `FC[2]` changes, because
the context register selects a different half and everything downstream shifts.
`sun2_dvma` grew an `S_SETTLE` state between `S_ADDR` and `S_STROBE`, giving the
address and function code **two** clocks before AS instead of one. Measured:

```
  in a run     524,282
  ARRIVED BAD        6      unchanged
```

with the MultiBus fingerprint still 22/274, so the change was harmless and
useless. It has been reverted.

Three things came out of it that narrow the search rather than widen it:

* **The chain really is two clocks.** `smap_sram` is synchronous, so
  `ia_smap2pmap` is valid a clock after `P_A` and `cx` move; `pmap_sram` indexes
  on *that*, so `ma_pmap2devices` is valid a clock later again. `S_SETTLE`
  supplied exactly the missing clock, and the fault did not move.
* **So the transient is not what reaches the bridge.** `MATCH_MEM` is gated on
  `C_S6`, which the captures show arriving several clocks after the map has
  settled -- the `048 -> 045 -> aca` transient is real but has gone by then.
* **The context register is not involved at all.** In all three captures both
  halves held the same value and `cx` never moved, so no context selection
  changed. The user-mode-precedes-fault correlation (3 of 3) is a property of
  the workload -- `patwr` is a user program, so interleaved CPU cycles are
  user-mode as a matter of course -- and not the mechanism.

**And the physical page is correct at the moment the request is issued.**
Reading `ma_pmap2devices` at the clock `C_S6` rises, in all three captures:

```
  ev1  C_S6 at -20: A=781674 FC=5 dvma=1  ma=b26
  ev2  C_S6 at -20: A=78152a FC=5 dvma=1  ma=aca
  ev3  C_S6 at -20: A=78152e FC=5 dvma=1  ma=b6e
```

Every one is the right page for that cycle. `MATCH_MEM` is gated on `C_S6`, so
that is the value the bridge uses -- the transient has settled several clocks
earlier. **The stale-page-map account is dead**, and the `S_SETTLE` null result
was telling us so before this confirmed it.

**DOUBLE_READ and ARRIVED BAD on the same run resolve it.** `DOUBLE_READ` is
ported to `wb_to_mig_ui` now and issues every read twice, comparing the answers:

```
  in a run       524,279
  ARRIVED BAD          9      the fault was present on this run
  compared   195,547,866      every read doubled
  DISAGREED            0
```

195 million comparisons, none disagreeing, while nine words arrived wrong. So
the read is **not** a transient: memory really did hold program text at the
instant the master read it, and the pattern appeared there later -- which is why
`patwr`'s own read-back, minutes afterwards, is clean every time.

**That makes it a write-visibility fault, and the mechanism is already named in
this file.** "One transaction in flight on the whole interface, because MIG's
`ORDERING = "NORM"` is not established here and the read path has no tag."
The adapter serialises its *own* requests, but a write is finished from its
point of view when the controller accepts it, not when it reaches DRAM. A read
issued afterwards -- by the other master, for the buffer the CPU has just
filled -- can be answered from memory before that write drains, and it gets the
page's previous contents: program text.

It fits every measurement. The word is wrong before the master captures it; the
physical page is right at `C_S6`; both crossings, the lane, the half and the
response matching are clean, because every one of them faithfully carries a
value the controller really returned; the rate does not move with clock
frequency; and it needs a CPU write and a master read of the same page close
together, which is exactly a disk flush of a buffer the CPU has just written and
nothing a quiet memory test ever does. `WRITE_VERIFY` passes because it reads
back through the same port, which *is* ordered against its own write.

**MIG's strict ordering does not fix it, and that matters.** `syn/mig/sun2_mig.prj`
carried `<Ordering>Normal</Ordering>` -- the mode that explicitly lets the
controller reorder for efficiency -- which looked like the whole answer.
Rebuilt with `Strict`, confirmed as `ORDERING = "STRICT"` in the generated
`sun2_mig_mig.v`:

```
  in a run     524,282
  ARRIVED BAD        6      unchanged
  compared 205,049,131
  DISAGREED          0
```

So the controller is not reordering a read ahead of a write. Reverted to
`Normal`.

**The contradiction was an artefact of file size, and the account built on it is
withdrawn.** `patwr`'s in-pass read-back is ordinary buffered I/O -- `write()`
then `read()` on the same descriptor -- so with a 512 KiB file on a 7 MiB
machine it is served entirely from the pages the CPU just wrote. It compared
memory against memory and could not fail. The tool's own header says exactly
this and prescribes the fix ("make the file far larger than the cache"), and
512 KiB does not meet it.

Rerun at **8 MiB**, larger than RAM, the read-back misses the cache and reports
the corruption **in the same pass, with no reboot**:

```
  BAD  sector 217 word 172  want 80ac  got 584f
  BAD  sector 361 word 126  want 807e  got 2e2e
  BAD  sector 783 word  20  want 8014  got 2f2d
```

So there was never any evidence that memory held the right word at the master's
address. Everything is consistent with the simplest reading: **memory holds
program text there, and always did.** The master reads it faithfully
(`ARRIVED BAD`), the controller agrees with itself (`DISAGREED 0` over 205
million pairs), strict ordering changes nothing because there is nothing to
reorder, and the disk gets what memory held.

**A write-coverage check on the CPU's side, and its first reading needs
refining.** `tools/patwr -u` makes every write self-identifying, so
`sun2_wishbone_bridge` keeps 256 bits -- one per halfword offset -- for the
512-byte block being written, and when the address moves to another block asks
whether every bit was set. Counting could never answer this: the pattern-write
counter already *exceeds* the file it wrote, so a shortfall of six in half a
million is invisible. Completeness can.

On an 8 MiB pass, with the read-back now missing the cache and reporting the
corruption in-pass:

```
  in a run     4,194,221   = the 4,194,304 halfwords in the file
  ARRIVED BAD         83
  blocks          15,448   near-full pattern blocks closed
  INCOMPLETE       1,191   ... missing at least one write
```

The two controls are as good as they get -- both land on the workload's own
size. **`INCOMPLETE` does not**: 1,191 is 7.7% of blocks against a corruption
rate near 0.5%, fourteen times too many, and `first miss offset 0` is the
signature of a block closed before it was filled rather than a lost write. The
kernel interleaves metadata and writeback with the copy, so a block is left and
returned to, and every such departure closes it early.

**Counting the shape of the miss rather than the fact of it answers the
question: the CPU's writes are not missing.** A lost write leaves a block
missing *exactly one* halfword; an interleaved block misses many. Gated on 255
of 256:

```
  in a run     4,194,211   control = the file's halfwords
  ARRIVED BAD         93
  blocks          14,289   control
  INCOMPLETE           1   one block, missing one write
```

**One, against ninety-three corrupted words.** So a missing CPU write accounts
for at most one of them and is not the mechanism -- and the single hit may
itself be a boundary artefact of the same kind the unrefined check produced in
quantity.

**And `ARRIVED BAD` is now calibrated one-for-one against the fault.** `patwr`
reported **93 of 4,194,304 words wrong** on that same run, in-pass, against the
detector's 93. The two are measured at opposite ends of the machine -- one in
the bridge's clock domain, the other by software reading the file back from
disk -- and they agree exactly. That is the strongest validation any instrument
in this investigation has had, and it means a hypothesis can now be tested
against a count that *is* the corruption rather than a proxy for it.

**And the DVMA side is clean too, so the last writer of memory is exonerated.**
The mirror check watches every data access the disk controller makes and asks
whether it lands inside the sector it is moving. On an 8 MiB pass:

```
  ARRIVED BAD          92      patwr: 92 of 4,194,304 -- exact, a second time
  blocks           14,266
  INCOMPLETE            0      every CPU write present
  DVMA accesses 6,867,712
  OUTSIDE               0      none outside its sector
```

`INCOMPLETE 0` also retires the single hit the previous run showed: it was the
boundary artefact it looked like, not a lost write.

**So both writers of memory are now measured clean on a run that corrupted 92
words.** The CPU writes every word of every buffer; the disk controller never
addresses outside the sector it is moving; memory is self-consistent across 205
million read-pairs; nothing is reordered; the physical page is right at `C_S6`;
and the read path from DDR3 to the card is clean end to end. The corruption
persists at exactly the same rate through all of it.

**The CPU alone does not corrupt memory, and the same machine corrupts a disk
write minutes later.** `tools/memchk.c` with `tools/memloop.s` fills 3 MiB with
a constant and reads every longword back, both loops in the 68010's **loop
mode** -- one one-word instruction plus `DBcc`, cached inside the chip, so the
bus carries operand traffic and no instruction fetches. Six constants, three
passes, about 108 MiB of read and write traffic from the heaviest memory client
the machine has:

```
  memchk, 3 MiB x 6 constants x 3 passes      0 wrong
  patwr -u, 16 MiB, same boot, same machine   corrupting
```

So it is not simply "memory under load". A disk transfer differs from this in
one respect that matters: it interleaves a DVMA master with the CPU, where
`memchk` is the CPU alone at full rate. That is consistent with everything else
here -- the fault has always needed a master.

**A rewritten card was needed to run it at all, and the reason is worth
keeping.** `ld` failed to link even `main(){printf("hi\n");}` on the 512 MiB
copy and again on the 1536 MiB one, with the failure moving between SIGSEGV and
SIGILL. Two filesystems and a moving failure reads as the machine, and it was
not: with every copy rewritten, `cc` links and runs first time. **The toolchain
had been corrupted on disk by the very fault under investigation.** A machine
that cannot build its own instruments is the end state of leaving a filesystem
in service after it has been written by a corrupting path.

**What a constant cannot see**, recorded beside the zero: a word fetched from
elsewhere *in the same buffer* holds the same constant and is invisible. Program
text intruding -- what the disk tests actually find -- is caught, and varying the
constant catches a value surviving from the previous pass. A position-derived
pattern is strictly stronger and is the next step.

**The Ethernet's DVMA is clean, over 33.5 MB, in both directions.** A VME 2/50
with no storage -- so the 82586 is the only master -- netbooted, with
`tools/netchk.c` on the machine and `tools/netchk_host.py` on a host on the same
subnet, streaming `patwr -u`'s pattern over TCP so that no filesystem, buffer
cache, disk driver or controller is in the path at all:

```
  host -> board   16,777,216 + 67,108,864 bytes, 0 wrong   DMA writing memory
  board -> host   16,777,216 + 67,108,864 bytes, 0 wrong   DMA reading memory
```

**160 MiB in total, not one wrong byte.** The disk path corrupts about one word
per 45 KB, so the same fault would have shown on the order of 3,700 bad words
across those passes. The CPU was busy throughout, so CPU and DVMA cycles were
interleaved exactly as they are during a disk transfer.

**The first version of this test was its own bottleneck, which is worth
recording.** It built and checked the pattern a byte at a time, which on a
20 MHz 68010 runs at a few hundred KB/s -- the program, not the machine, was the
limit, and the Ethernet and the DMA were barely troubled. Because the pattern
repeats every 512 bytes, a buffer whose length is a multiple of 512 is valid at
*every* aligned offset in the stream: build it once and the send side does no
per-byte work at all, while the check side is one longword compare per four
bytes. Same coverage, four times the volume, and the load lands where it is
supposed to.

**And on one bitstream with both masters, the Ethernet *and* the disk are
clean -- which moves the fault onto the machine rather than the controller.**
A VME 2/50 built with `VME_SCSI=1`, so the 82586 and the SCSI card are both
fitted and both master the bus, reading the same micro-SD card the MultiBus
builds corrupt:

```
  network, 32 MiB   0 wrong          82586 DMA
  SCSI disk, 16 MiB 0 of 8,388,608   SCSI DMA, read-back missing an 8 MB cache
```

**That "it follows the machine" reading was wrong, and holding the machine
fixed is what showed it.** The comparison behind it changed *two* variables at
once -- MultiBus+XY450 against VME+SCSI -- so it could not tell a machine apart
from a controller. A MultiBus 2/120 with the **SCSI** card, on the very
filesystem the VME+SCSI run had just verified, is clean twice over:

```
  MultiBus + XY450, offset 0    196 of 8,388,608   16 MiB, same protocol
  MultiBus + XY450, offset 0     92 of 4,194,304   8 MiB, earlier build
  MultiBus + XY450, offset 1024  81 of 4,194,304
  MultiBus + SCSI,  offset 512    0 of 8,388,608   two passes, 32 MiB
  VME      + SCSI,  offset 512    0 of 8,388,608
  VME      + SCSI,  offset 0      0 of 8,388,608
```

The first line is the positive control repeated **at the same 16 MiB and from
the same tree as the SCSI runs**, so the comparison no longer spans two
protocols: 196 wrong against 0, on one board, one machine, one card, with only
the controller changed. The rate is consistent with the 8 MiB figures --
196 in 8.4 million is 92 in 4.2 million doubled -- so nothing about the newer
build or the larger file moved it.

Same machine, same board, same card, same `blk_sd`, same bridge and DDR3 --
**only the disk controller differs, and only `sun2_xy450` corrupts.** The
control holds: 7 MiB of RAM against a 16 MiB file, so the in-pass read-back
genuinely misses the buffer cache, and the XY450 rate predicts about 170 bad
words per pass where zero were seen.

**The DECA settles it, and "only the XY450" is wrong too.** The same MultiBus
SCSI build on the DECA, at the same 512 MiB offset, on the same filesystem the
Wukong had just verified clean, corrupts: **83 of 8,388,608**.

**Confirmed on a card rewritten from scratch, which removes the last confound.**
That first DECA figure was taken on a filesystem this investigation had been
writing to for weeks -- the one whose `ld` could no longer link a hello-world --
so "the medium is worn out" was still available as an explanation. With every
copy on the card rewritten, the same bitstream on the same offset gives
**102 of 8,388,608**: the same rate, on a filesystem hours old. The DECA
MultiBus+SCSI result is real.

The full matrix, every cell a 16 MiB pass with the read-back missing the cache:

| board | machine | controller | memory | result |
|---|---|---|---|---|
| Wukong | MultiBus | XY450 | MIG | **196** of 8,388,608 |
| Wukong | MultiBus | SCSI | MIG | 0, twice |
| Wukong | VME | SCSI | MIG | 0, twice |
| DECA | MultiBus | SCSI | BrianHG | **83**, then **102** of 8,388,608 |
| DECA | VME | SCSI | BrianHG | **120** of 8,388,608 |

**The DECA's VME machine corrupts too, and that fills the last corner.** Same
board, same controller, same memory, same 16.667 MHz, same `patwr.c` by
checksum, on a pristine `eagle-sd.img` at 1536 MiB -- only the machine changed,
MultiBus 2/120 to VME 2/50: **120 against 102**. Those are the same rate.

So **the machine is not the variable on either board.** The Wukong is clean on
MultiBus+SCSI *and* VME+SCSI; the DECA corrupts on MultiBus+SCSI *and*
VME+SCSI. What is left standing is the board, and -- on the Wukong alone -- the
controller.

**Which is what the stimulus-rate hypothesis predicted, and it is now the
reading the whole table supports.** Sort the five cells by how hard the master
drives memory relative to how fast that memory answers:

```
  Wukong  MIG      + SCSI  (sparse master, fast memory)     0, 0, 0, 0
  Wukong  MIG      + XY450 (dense  master, fast memory)   196
  DECA    BrianHG  + SCSI  (sparse master, slow memory)    83, 102, 120
```

One threshold orders every measurement. The XY450 moves four bytes per DVMA
transaction back to back; the SCSI card stages a longword and walks it out a
byte at a time through `scsi_fabric`, so it asks for memory far less often.
MIG answers faster than BrianHG's controller. A fault that needs master traffic
above some rate *relative to the memory path* is clean in exactly one of those
three cells and present in the other two -- which no "it is the machine" or "it
is the controller" reading can produce, because both of those have now been
held fixed and varied in both directions.

**What this does not settle** is what the threshold is a threshold *on*. Rate
is one candidate; so is anything else that tracks it, such as how often a
master's cycle lands close to a CPU cycle, or how long a request is outstanding.
The next experiment is to vary the rate with board and controller held fixed --
slow the XY450's DVMA on the Wukong until it corrupts less, or clock the DECA
down -- because that is the one axis the five cells above never varied on its
own.

Two caveats on the VME cell, stated because they are real. A 2/50 fits the
82586, so this machine has a second potential master the MultiBus build does
not -- the machines differ by more than the bus, and the Ethernet was idle but
present. And it is a fresh place-and-route, which has flipped outcomes twice in
this file; the DECA has now corrupted across three independent builds, so the
*direction* is safe, but the exact rate is one pass.

**And the wrong values follow the filesystem, not the board -- which is a
correction.** The 83-word run was recorded here as showing `53d2`, `281c` and
`6d08`, "the three this file recorded for the DECA long ago, and not the
Wukong's, because each board's memory holds its own program text". That
reasoning was wrong. On the rewritten card the DECA's 102 wrong words are
`2f2d` (36), `2e2e` (31) and `584f` (26) -- **the Wukong's three**, in the same
order of frequency, with a tail of `0000`, `4ef8`, `7572`, `2f64`, `2f2e`,
`005f` and `0006` at one each.

The intruding content is whatever program text the *filesystem* has resident,
so two boards reading identical images produce identical values and the same
board reading a different image produces different ones. The board was never
the variable; the card's contents were. That also means the value histogram is
a property of the workload and cannot be used to tell two boards' faults apart,
which is what the retracted sentence tried to do.

**So it is neither the machine nor the controller alone.** MultiBus is not the
variable -- Wukong MultiBus+SCSI is clean, and neither is VME, which is clean on
the Wukong and corrupts on the DECA. The XY450 is not the variable -- DECA SCSI
corrupts without one. The disk controller is not even the variable in itself:
the *same* card is clean on one board and corrupts on the other.

**What survives is that the controller sets the stimulus rate.** The XY450 moves
four bytes per DVMA transaction back to back, while the SCSI card stages a
longword and walks it out a byte at a time across `scsi_fabric` -- far fewer
memory accesses per unit time. So SCSI on MIG may simply be too slow to provoke
what XY450 on MIG does, while SCSI on the slower BrianHG path is fast enough
relative to *its* memory. That restores the shared path as the suspect, with the
controller acting as a knob on how hard it is driven rather than as the fault.

It is a hypothesis, and it is testable: the rate is the thing to vary next,
holding board and controller fixed.

**The XY450 drivers were audited for timing assumptions, and none of them can
produce this fault.** Every layer was read -- the 3.4 and 4.1.4 kernel drivers,
`sunstand/xy.c`, `prom_monitor/{msun,rsun}/mon/prom2/xy.c` (the PROM this board
actually runs), and `stand/src/diag/xy.c`. Every timing requirement found is a
**control-path** one: command start, command completion, reset, interrupt
delivery. Violating any of them produces a loud failure -- a panic, a lost
interrupt, a timed-out probe, a whole sector read early -- **not a silent
single-word substitution in the middle of a correctly-addressed sector**. No
driver anywhere imposes a rate, a spacing, or a bus-hold limit on the DMA
itself; `xy_throttle` (32 words/transfer) is advisory to the controller and is
the only thing said about it at all.

**Both were checked against the RTL and both are honoured.** `sun2_xy450` sets
`csr_gbsy` on the same clock edge that decodes the GO write -- the decode is
`wr_lo & sel_ctl & mbio_din[7]`, where `wr_lo` is qualified by
`first = mbio_hit & (phase == 2'd0)`, a genuine one-shot rather than a level, so
BUSY is asserted **one clock into the GO write cycle** against the 30 us the
driver allows. And it is cleared in exactly one place in normal operation,
`E_FINISH`, which is reachable only through `E_WB_W`; every DVMA access in the
engine -- `E_IN_W`, `E_OUT_W`, `E_WB_W` -- advances only on `wb_ack_i`. So BUSY
does not drop at IOPB-fetch completion, and the interrupt (`csr_ipnd`, set in
`E_IOPB_END` and `E_FINISH`) is raised strictly after the last DVMA write has
been acknowledged. Reset behaves too: `csr_gbsy` is held for `RESET_CLOCKS = 64`
(3.8 us at 16.7 MHz) against a 100 us boot-path wait.

**What "acknowledged" resolves to is the one thing worth writing down.** The
chain is `sun2_xy450` -> `sun2_dvma` -> a 68010 cycle -> `sun2_wishbone_bridge`
(`W_ACK = (wb_ack_i & issued) | done`) -> `wb_to_mig_ui`, whose `wb_ack_o` fires
on `ack_pulse` from the memory domain, which `mig_arb` raises when **MIG accepts
the write**:

```verilog
   wire cmd_ok = cmd_done | (app_en       & app_rdy);
   wire dat_ok = dat_done | (app_wdf_wren & app_wdf_rdy);
```

MIG's UI has no write-completion response -- writes are posted -- so the whole
ack chain means *accepted by the controller*, never *committed to DRAM*. The
driver's only synchronisation for "everything the controller wrote is visible"
is that interrupt, and the interrupt is gated on acceptance. **That window is
real and it is already closed by measurement rather than by argument**: it would
only bite if the controller could answer a read from DRAM ahead of a pending
write in its own queue, which is exactly what `Strict` against `Normal`
ordering governs, and rebuilding with `ORDERING = "STRICT"` changed nothing.
`WRITE_VERIFY` reads every write straight back at 0 wrong (checking only the
bytes each write enables -- see the qualification above), and it is the
device->memory direction, which the cold reads show clean.

The two hits, kept because the reasoning above is what retires them:

* **When does BUSY assert relative to the GO write?** The boot path is
  `xy_csr = XY_GO;` then `do { DELAY(30); } while (xy_csr & XY_BUSY);`
  (`sunstand/xy.c:268-272`, identical in `prom2/xy.c:207-210`). The `DELAY`
  runs *first*, so this reads "wait 30 us, and if BUSY is clear the command is
  finished" -- and the boot path has no other completion test, it never looks at
  `xy_complete`. If the replica raises BUSY a few clocks late, or drops it at
  IOPB-fetch completion rather than at data completion, the PROM proceeds while
  DVMA is still in flight. Note `XY_GO` (write, 0x80) and `XY_BUSY` (read, 0x80)
  are the same bit (`xycreg.h:43-44`).
* **Is the interrupt raised before or after the last DVMA write retires?** With
  `xy_autoup = 1` and `xy_intrall = 0` the driver takes one interrupt and then
  reads `xy_complete` *out of DVMA memory* for every IOPB, with no register
  re-read and no flush. Everything the controller wrote must be visible when the
  interrupt lands. This would corrupt device->memory, and the measurements put
  this fault in memory->device, so it is not the cause -- but it is free to
  check.

**The strongest historical evidence, and it cuts against the replica being at
fault.** Every 4.1.4 change in this area is a *wait added* -- `xycsrvalid`,
`xywait`, `xyintwait` -- and one carries the rationale in the source:

```
 * make sure the busy bit goes ON before we wait until it clears..
 * This is a problem with faster machines where the controller does
 * not have enough time to react to the command.
 * Changed by EK 9/10/89
```

So Sun found that a faster CPU could outrun this controller in the interrupt
path and patched around it with polls. **The kernel booting here is 4.0.3, which
predates that annotation**, so the running driver behaves like 3.4 and does
*not* wait -- which makes the replica's BUSY and interrupt timing more load-
bearing, not less.

**The kernel and the PROM contradict each other about register spacing, which
bounds what the replica must support.** The kernel says a 15 us delay and a
readback are needed after every register write, "due to a bug in the 450"
(`xy.c:159-163`, `1349-1352`), and `panic`s on a double miscompare. The
standalone and PROM drivers write all five registers **back to back with no
delay and no readback** (`sunstand/xy.c:263-268`). Both cannot be true of the
same chip. For the replica: the minimum inter-register spacing that must work is
one 68010 bus cycle, and the kernel's 15 us is slack it should not need.

Two smaller things the audit settled. `XY_ATTN`/`XY_ACK` are used by **no**
driver in either tree -- only the header defines them, confirming what this file
already recorded. And the SCSI driver carries materially fewer timing
assumptions than xy: three `DELAY` sites against eighteen, every one a back-off
inside a loop testing a real handshake bit, with no write-then-read-back, no
fixed-delay-then-assume, no device-rewritten structure in host memory, and no
chain. That asymmetry is *consistent with* SCSI being clean where the XY450 is
not, but it is about control-path robustness and explains no single wrong word.

**`report_cdc` does not separate a corrupting build from a clean one.**
Vivado's CDC report was run on the routed checkpoints of all three Wukong
builds -- MultiBus+XY450, which corrupts 196 words, and MultiBus+SCSI and
VME+SCSI, which are both clean. The populations are *structurally identical*:

```
  build      CDC-1   CDC-10   CDC-15   CDC-10 outside the ILA/VIO
  xy450        637       28      367       5      <- corrupts
  mbscsi       637       26      367       5      <- clean
  vmescsi      848       40      587      10      <- clean
```

The 28-against-26 looked like a real difference and is not: filtering the
debug-core rows leaves five in each, and diffing them shows the same five nets
with a different bit of the same counter named as the launch flop
(`hold_ctr_reg[4]` against `[0]`, `serial/rst_a_cnt_reg[3]` against `[1]`). The
rest of the diff is the instance name of the one `sun2_dvma` -- `xy_dvma`
against `sc_dvma`. **Nothing structural distinguishes them.** And VME+SCSI
carries nearly *twice* the CDC population, from the 82586's `phy_rx_clk` and
`phy_tx_clk` domains, while corrupting nothing at all -- so the count does not
even correlate in the right direction.

**One real data-path crossing it does name, present in every build.** The
`z8530_scc`'s receive FIFO, in `mmcm_b_serial`, reaches `sun2_dvma`'s `rd_lo`
and `rd_hi` latches in `mmcm_a_cpu` -- eight endpoints, **CDC-15 "Clock enable
controlled CDC structure", Warning**, across an `Asynch Clock Groups` exception,
which means it is deliberately untimed:

```
  machine/sun2/serial/u_rx_fifo_a/mem_reg[2][2]/C -> machine/xy_dvma/rd_hi_reg[10]/D
```

Those are exactly the two latches whose assembly
`wb_dat_o <= {rd_hi[7:0], rd_hi[15:8], rd_lo[7:0], rd_lo[15:8]}` produces the
16-bit granule the fault has. The path exists because **`P_DOUT` is a 20-way
read mux and the SCC is one of its arms**, so structurally a DVMA latch can
capture a word launched in the serial domain. Functionally it should never
happen -- a DVMA memory read selects the memory arm, never the SCC's -- and it
is in the two clean builds identically, so it cannot be what separates them.
Worth knowing anyway, because this file already records one bug of exactly this
shape (the raw `X2` oscillator reaching the Am9513's clock enables) and because
an untimed path is one placement away from behaving differently.

The five non-debug CDC-10s are the ones this file already listed as left
undone: MIG's `init_calib_complete` and `hold_ctr` into `rst_cpu/chain_reg[0]`'s
preset, the SCC's own two soft-reset synchronisers, and `rst_cpu/chain_reg[2]`
into `serial/sreset_b_sync_reg[0]`'s clear. All reset assembly, none in a data
path, all present in corrupting and clean alike.

**So CDC is not the discriminator on this board**, which is a real elimination
rather than an absence of evidence: the instrument that found the `P_RESET_n`
bug in one run was pointed at a corrupting build and a clean one and reports
the same thing about both.

**A clean cell can be made to corrupt, and what does it is *irregular* master
timing rather than a slower one.** The Wukong VME+SCSI machine at 20 MHz has
read zero five times running -- twice before the throttle existed, and three
times in one session on a freshly written card, with an interleaved control.
With the throttle in **random** mode it corrupts:

```
  bitstream        setting              mean gap   result        elapsed
  normal (no THR)  --                      --      0 of 8,388,608   42m
  throttle         mask 0                   0      0                42m
  throttle         FIXED gap 63            63      0                42m
  throttle         mask 0 (control)         0      0                42m
  throttle         RANDOM mean 63.5      63.5      **43**           42m
```

**Fixed and random have the same mean rate by construction** -- `THR_MASK>>1`
against a uniform draw over `[0, THR_MASK]` -- and differ only in the
regularity of the master's request spacing. Fixed is clean; random is not. So
on this cell the variable is **jitter, not rate**, and the throttle's two modes
were built for exactly this comparison.

**The signature is the fault, not a new one.** The 43 wrong values are
`2e2e` (20), `2f2d` (15), `584f` (4) and `0000` (2) -- the same three common
68010 opcodes that every corrupting run in this file reports, which is program
text intruding into the buffer. Word offsets split 23 even to 20 odd, so it is
not confined to one half of a longword.

**This is the first knob that turns the fault ON in a configuration that is
otherwise clean**, which is worth more than one that halves it in a
configuration that is already dirty: it is a positive control. Every previous
experiment could only ask "did the rate go down"; this one can ask "did the
fault appear", against a cell with a perfect record and no Poisson spread to
hide in.

**It also supersedes the DECA reading, which was confounded.** That sweep had
fixed-63 at 81 and random-63.5 at 85 and was read as "rate is the variable,
alignment is not". Its baseline drifted 163 -> 140 -> 109 across the session,
the sigma figures were computed against a baseline assumed constant, and the
whole thing is retracted below. This experiment has a flat baseline -- four
consecutive 42-minute passes at zero, control included -- so where the two
disagree, this one is the measurement.

**Confirmed, three for three.** The repeats put it beyond a single sample:

```
  off / normal bitstream   0, 0, 0, 0      mean  0
  FIXED  gap 63            0, 1            mean  0.5
  RANDOM mean 63.5         43, 38, 44      mean 41.7
```

Every pass 42 minutes, so the knob changes neither throughput nor total work --
only the regularity of the master's request spacing -- and the separation is
about eighty to one. **Random provokes the fault every time; fixed does not.**

One correction to the first write-up: **fixed is not a perfect zero.** Its
repeat returned 1 wrong word where the first returned 0. That is either this
cell's own very low background rate or a slight perturbation from the fixed
gap; against 38 to 44 it does not trouble the result, but "fixed is clean" is
better stated as "fixed is at baseline, within one word of it".

**And the obvious alternative was tested and is dead: it is not the long-gap
tail.** Random over `[0, 127]` contains delays up to 127 that a fixed gap of 63
never produces, so the whole effect might have been that small fraction of long
delays rather than the irregularity. Running the fixed maximum settles it:

```
  off / normal bitstream            0, 0, 0, 0      mean   0
  FIXED  gap  63                    0, 1            mean   0.5
  FIXED  gap 127  (the maximum)     0               mean   0
  RANDOM mean  63.5  range 0-127    43, 38, 44      mean  41.7
  RANDOM mean 127.5  range 0-255    34
```

**A fixed 127-clock gap reaches the same maximum delay as random `[0,127]`,
carries twice its mean, and corrupts nothing.** So long delays are not the
mechanism. And doubling the jitter range changes nothing measurable -- 34
against 38 to 44, all inside Poisson noise -- so the effect does not scale with
how large the jitter is either.

**And it is not the parity of the gap either.** Both fixed points tested so far
were *odd* -- 63 and 127 -- while random draws both parities, so "even gaps are
the dangerous ones" explained every result without invoking jitter at all. A
68010 bus cycle is an even number of clocks and `sun2_dvma` drives AS on one
edge and releases it on the other, so a gap shifting the next request by an odd
number of clocks lands it on the opposite phase from an even one; with a
half-period path and an untimed CDC-15 into `rd_lo`/`rd_hi` already on record,
that was physically plausible. Measured, it is wrong:

```
  FIXED gap 62  (even)             0
```

The full set:

```
  off / normal bitstream            0, 0, 0, 0      mean   0
  FIXED  gap  62  (even)            0               mean   0
  FIXED  gap  63  (odd)             0, 1            mean   0.5
  FIXED  gap 127  (odd, maximum)    0               mean   0
  RANDOM mean  63.5  range 0-127    43, 38, 44      mean  41.7
  RANDOM mean 127.5  range 0-255    34
```

**Every fixed gap is at baseline whatever its size or parity; every random gap
corrupts whatever its mean.** Four readings are excluded by measurement rather
than argument:

* **not rate** -- fixed 62, 63 and 127 are three different rates, all clean;
* **not the long-gap tail** -- fixed 127 matches random's maximum, clean;
* **not jitter magnitude** -- mean 63.5 and mean 127.5 agree;
* **not gap parity** -- fixed 62 is even and clean.

What is left is the *irregularity itself*: the master's requests arriving at
unpredictable intervals, whatever their mean, extreme or parity. That is a
narrow and unusual property for a fault to key on -- most hardware faults key
on a threshold, not on unpredictability -- and it is what any explanation now
has to account for.

**A capture machine whose disk carries nothing but the test.** A MultiBus
2/120 with the XY450 *and* the Sun MultiBus Ethernet, netbooted, so root, swap
and every binary come over NFS through the Ethernet card's own 256 KiB and the
XY450 is the only bus master -- its DVMA buffers hold `patwr` traffic and
nothing else. `xy0a` is mounted on `/mnt` for the test alone. It still corrupts:
**164 of 8,388,608** in 79 minutes (`2e2e` 57, `584f` 55, `2f2d` 52), the same
three values as ever, so the intruding text is not the disk's own program text
being paged in through the buffers under test. The build is
`v3-multibus-mbether-xy450-cpu20-rd68011-ila-div50-off1024m`, 23,960 LUTs and
106.5 of 135 BRAM tiles before the instrument below.

Netbooting it takes one thing that is not obvious. The PROM's `boottab` lists
`xy` before `ie`, so it always autoboots the disk and BREAK loses the race: let
it boot, `sync`, `/etc/halt`, then `b ie()vmunix -a`. **Answer the `-a` prompts
twice** -- the bootloader's (root fstype `nfs`, an empty root name, which
bootparams fills in as `x11spl:/home/dolbeau2/Sun3_BootDir/nfsroot/sun2_f_m`)
and then the kernel's own root and swap prompts, `nfs` and empty names again.
Answering only the first set boots an NFS-loaded kernel that still mounts
`xy0a` as root, which is exactly the traffic this machine exists to exclude.
Root's shell is csh, so `$?` is `Variable syntax.` and the whole line is
rejected unexecuted.

**`sun2_clobber`: the history of a buffer, which no transfer check can give.**
Every instrument so far asks a question of one transfer, and every one reads
zero while `ARRIVED BAD` counts the corruption one for one. So memory really
holds text where the pattern went, and the open question is *how it got
there* -- a question of history. `rtl/sun2-common/sun2_clobber.v`, inside the
bridge, keeps one bit per 512-byte block (14,336 blocks, one RAMB18): "the last
write here was the pattern". Against it, a non-pattern write into a pattern
block is resolved by the next write into that block as *reuse* (not the pattern
either), *iso* (the pattern again -- one foreign word inside a copy, *behind*
if below the copy head), or *lone* (nothing more before a timeout); a
non-pattern *read* from a pattern block is a *ghost*. Iso-behind plus lone near
`ARRIVED BAD` would say a write put the text there, and the record names
whether the CPU or the master wrote it; ghosts near it with those at zero would
say no write of text was ever seen. `make -C sim clobber` is 166 checks, and
eleven mutations are each caught by the scenario aimed at them. It reaches the
VIO as `cl_*` (`syn/vio_read.tcl`, "WRITE HISTORY") and the ILA as probe 17,
with capture modes `clob`, `clobiso`, `clobcand`, `ghost`, `ghostdvma` and
`arrivedx`, all qualified one sample per memory transaction.

**It also closes a gap every earlier write check had: the lanes.**
`wb_to_mig_ui` latches `wb_sel` on the same clock as address and data, and the
write-coverage check tested address and data only; DECA's `WRITE_VERIFY` masked
its comparison *by* `wb_sel`. A pattern write issued with one strobe missing
would leave the old text in place under both. `PARTIAL` counts exactly that.

**Its first bitstream was flooded by coincidence, and the numbers are the
lesson.** It marked a block on any single pattern-shaped word. On the board,
before `patwr` had written a byte, SunOS's own boot had counted **33,776
ghosts, 63 lones and 381 partials**: `{0x80, index}` is not a rare word, and one
chance match marked a block of kernel data whose every later access then
counted against it -- the `clob` trigger would have fired on noise. A block is
now marked only by a *run*, a pattern write whose previous write was the
pattern at the word before (or word 255 of the block below, for word 0), and
`PARTIAL` is gated the same way. Every instrument in this file has needed such
a rule; this one shipped without it for one build. With the rule, a full disk
boot, halt and netboot leaves **every** counter at 0.

**The results: the damage is a ghost, and the "foreign write" is its copy.**
Three 16 MiB `patwr -u` passes on the netbooted capture machine, the last on the
run-gated bitstream with a zero baseline:

```
                          run 1 (v1)   run 2 (v1)   run 3 (v2)
  patwr, words wrong          140          149          132
  ARRIVED BAD                +140         +149         +132
  ghost, read by the master  +140         +149         +132
  iso-behind, by the master  +140         +149         +132
  lone                          .            .            0
  PARTIAL (run-gated)           .            .            0   of 16,849,362 pattern writes
  DISAGREED / OUTSIDE           0            0          0 / 0
```

Four counters in two modules are identical to `patwr` on every run. Reading them
took one wrong turn, recorded because it looked right: the iso count was read at
first as "a master writes text into the buffer". The first capture (`clobiso`)
showed what it is -- the XY450 writing `2f2d` at word 78 of a sector *during
patwr's verify*, which patwr then reported as `sector 14 word 78 got 2f2d`: the
faithful **read-back of a sector already wrong on the medium**. The damage is
the ghost: at the disk write, the master reads text out of a block whose last
bridge-visible write was the pattern, while write coverage says every word of it
was written. **No write of text into those blocks is ever seen at the bridge**,
and none is issued with a lane missing.

**The window cannot reach the write that matters.** `arrivedx` (trigger on
`dv_arrived_bad`, armed *before* patwr -- patwr writes the whole file before it
verifies, so every damaging read is in the first ~40 minutes, and `ghostdvma`
armed half-way through run 2 waited an hour for events that had all happened)
caught the master reading `584f` at word 180 of block 0x392e00 in an otherwise
perfect stream, and **no write into that block anywhere in the ~3,500 prior
transactions**. The CPU's copy into it is older than a 4,096-deep ILA can hold.

**Every damaged word is the first halfword of its 32-bit word: 511 of 511**
(140 + 149 + 132 on the Wukong, 90 on the DECA). That is also the **first bus
cycle** of each longword: the kernel fills the buffer in `_copyin` (0x4804,
reached from `_uiomove`) with `movesl %a0@+,%d1 ; movel %d1,%a1@+`, and a long
write to `(An)+` goes high word first; long reads go high word first; and
`sun2_dvma` does half 0 before half 1 in both directions (384 back-to-back
even-then-odd master reads in one capture). Only `-(An)` writes the low word
first, and `copyin` does not use it. Buffer blocks are 512-byte aligned, so each
longword is exactly one 32-bit DDR3 word.

**Both memory controllers mask sub-word writes with the DDR3 chip's own DM
balls, and simulation hides that.** MIG with `DATA_MASK=1` sends `app_wdf_mask`
nowhere but the DM pins -- output-only bitlanes in the data byte groups, FPGA
A22/C22, which the Wukong V3 schematic routes as DDR_DQM0/1 to the part's
UDM/LDM -- while `wb_to_mig_ui` drives the same word into all four lanes. Micron's
DDR3L x16 has functional UDM/LDM. BrianHG does the same ("DDR3_DM[0] drives
write DQ[7:0]"). The Micron simulation model implements `dm_tdqs` as a byte mask
(`ddr3_model.sv` `bit_mask`), which is why `make -C sim migddr3`'s partial write
passes; and MIG's calibration holds the mask at 0 throughout
(`mux_wrdata_mask = ... ? mc_wrdata_mask : 'b0`), so DM is never exercised
until the machine runs. On Artix-7 there is no ODELAY, so DM gets the same
per-byte-group write alignment as DQ -- a plain timing gap is less likely than
something specific to those two traces or to the isolated one-word DM pulse a
halfword write produces.

**The DECA's write-verify, on a corrupting pass, says the halfword *was*
written.** `deca-multibus-...-mbscsi-blktrace-off512m-lb16` (09-10, `434d207`,
`WRITE_VERIFY=1`): `patwr` 90 of 8,388,608, all even, the same three values;
88 wrong at the master's capture (first at 0xF03568, word 180, `2e2e`); **write
verify 0**, with every write of the run routed through the read-back and the
`responses - reads issued` control advancing. The read-back really reached
DDR3: `PORT_R_CACHE_TOUT` is 0 with `PORT_R_CACHE_TOUT_ENA` left at its default,
which reloads the timeout with bit 8 set so the read cache never hits, and
`PORT_CACHE_SMART` is 0. So "the first write never lands" -- a missed DM pulse on
its own write -- is **falsified on the DECA**.

**What that check cannot see is the next cycle.** It compares only the bytes the
write enabled: after the even write it checks the even half, after the odd write
only the odd half. The second write of the pair, or anything later, could undo
the even half invisibly. But a plain mask failure on that second write does not
produce *old text* on either controller -- MIG would put the odd word's value
in the even half (`80xx+1`), BrianHG the even value it had just written -- so the
old contents must come from something that carries the page's *previous* state,
and that path is not identified. On the Wukong the same counters cannot tell
"never landed" from "landed and reverted"; there is no write-verify there.

(The follow-up proposed here -- make the DECA's write-verify re-check the first
halfword after the second write -- was overtaken: memory was never wrong.)

**Found and fixed: a refused memory access issued a phantom DDR3 request, and
the next memory cycle took its answer.**

*The instrument.* A second ILA core, `u_busila` (`syn/generate_ip.tcl`,
`boards/Wukong/wukong_top.sv`), 13 probes and 8,192 samples: the 68010 bus
(address, FC, strobes, the C_S chain, data, `dvma_active`, physical page) *and*
the memory side of the bridge -- the whole 32-bit word DDR3 returned, the
Wishbone control lines and address -- triggered on `dv_arrived_bad` and
storage-qualified by a "bus changed" strobe. `sun2_ila` went to 1,024 samples to
free the BRAM (`ila_capture.tcl` now picks it by cell name and scales its trigger
positions). `syn/busila_capture.tcl` arms it; `tools/busila_dec.py` decodes. The
capture must be armed before `patwr` starts. Vivado suffixes probes that share a
net with the other core (`dbg_addr_1`), which the decoder accepts.

*What it showed* (netbooted XY450 machine, first capture):

```
  -22..-20  cpu FC1 read phys 0246bc: AS, C_S4, C_S6
  -19       BERR, no DTACK                         the MMU refused it
  -18       AS negated, C_S6 still 1, wb_cyc=1 for word 0091af, no ack
  -13       master read halfword 94 of word 148d2f: wb_cyc
  -10       ack arrives with 23ed584f              -- 0091af's contents
   -9       master latches 584f
   -4..-1   halfword 95, same DDR3 word, re-issued: 805f805e, correct
```

The only request dropped without an acknowledge in 8,192 samples, immediately
before the bad read.

*The mechanism.* `MMU_REFUSE` is gated by `~P_AS_n`; the C_S chain clears on the
posedge *after* AS negates. So in that one clock `MMU_OK` read 1 while `C_S6` was
still 1, and `MATCH_MEM` -- and every other `MATCH_*` -- came true for a cycle
the MMU had refused. The bridge had issued nothing in that cycle, so it issued a
fresh request; both DDR3 adapters latch a request on its first clock and run it
to completion, and ignore a new request while busy; and the bridge accepts
`wb_ack_i & issued` from whatever cycle is on the bus. A memory cycle starting
within the orphan's latency therefore got the refused page's word and never
issued its own read. That is every property this file recorded: one halfword,
the first of a pair (the master takes the bus straight after the CPU's fault),
program text (the faulting process's memory), memory itself never wrong (why
DOUBLE_READ, WRITE_VERIFY and every DDR3 check were clean and the ghost counter
fired), timing-dependent (the random-throttle result), and both boards (shared
`sun2_fpga`, same adapter shape). A refused *write* issued a write with
`wb_sel` = 0 -- harmless to data, but equally able to steal an acknowledge.

*The reproduction.* `make -C sim orphan` (`tb/tb_orphan_ack.sv`) drives the real
`sun2_fpga` with a 68010 bus-functional driver into the real `wb_to_mig_ui`,
`mig_arb` and `mig_ui_model`. `tb_sun2` can never show this: `wb_ram_model`
forgets a request whose CYC drops, and the real adapters do not. On the unfixed
RTL, 3 of 8 checks fail: one refused read issues a request; a valid read 0 or
1 clocks later is wrong 32 of 32 times at each gap, **all 64 returning the
refused page's word**; refused writes issue write requests. A valid-then-valid
control is clean at every gap.

*The fix* (`sun2_fpga.v`, `MMU_REFUSED`): the refusal is latched on any posedge
where `MMU_REFUSE` is true and cleared on the posedge with AS negated -- the edge
that clears the C_S chain -- and `MMU_OK = ~MMU_REFUSE & ~MMU_REFUSED`. Chosen
over re-gating the decode with AS as the change least likely to disturb anything:
nothing differs while AS is asserted.

*Measured.* Simulation: `orphan` 8/8; `bridge` PASS; MultiBus 22/274 and VME
10/312 with bus-error sequences identical to the unfixed RTL *including
timestamps*; `xychain` PASS. Board, same netbooted MultiBus+XY450+Ethernet
Wukong and the same 1024 MiB copy:

```
                           unfixed (3 runs)     fixed
  patwr, words wrong       140, 149, 177         0 of 8,388,608
  ARRIVED BAD              = patwr               0 of 8,388,608 master pattern reads
  ghost (by the master)    = patwr               0
  iso / lone / PARTIAL     -                     0 / 0 / 0
```

*Left open.* The DECA shares the RTL and has not been rebuilt or tested with
the fix. Filesystems written by unfixed bitstreams can carry silent damage in
metadata as well as data -- the 1024 MiB copy failed its boot fsck with an
unknown inode type on the first fixed boot and needed `fsck -y`; any copy used
for a pristine source should be checked or rewritten. The fixed Wukong build met
hold by only 0.008 ns (WHS). Hardening the bridge/adapter handshake so a cycle
can only accept its own request's acknowledge -- defence in depth against any
future phantom request -- is not done. Bitstreams are archived in
`build/archive/` (`…-busila-v1`, `…-fixB`, `…-off2048m-fixB`) with the run notes.

Two tools met on the way: `pkill -f <pattern>` kills the shell running it when
the pattern is in its own command line (exit 144, twice in this investigation --
select by PID with a bracketed pattern such as `[d]eca_console`); and the DECA
console and ISSP cannot share the chain, so a probe read means stopping
`juart-terminal` and re-attaching after.

**The corruption rate is not stable over a session, and that invalidates every
single-pass comparison in a long sweep -- including the one below.**
`sun2_dvma` gained a throttle (`THR_MASK`/`THR_RAND`, gating only the *entry*
to `S_IDLE`, driven from a dedicated `THRT` ISSP source so one bitstream covers
a whole sweep and placement cannot vary between points). Nine 16 MiB `patwr -u`
passes on the DECA, VME 2/50 + VME SCSI at 1536 MiB, in time order:

```
  pos  setting        wrong   trend   delta
   1   off (mask 0)    163     163      0
   2   fixed  3        137     156    -19
   3   fixed 15        123     150    -27
   4   fixed 63         81     143    -62
   5   off (mask 0)    140     136     +4
   6   random 63.5      85     129    -44
   7   random 15.5      58     123    -65
   8   fixed 127        89     116    -27
   9   off (mask 0)    109     109      0
```

**The three unthrottled controls read 163, 140, 109** -- monotonically down,
3.3 sigma end to end, with nothing changed between them. The baseline fell about
a third over four and a half hours.

**A claim was made here and is retracted.** This file briefly recorded the
fixed-mode points as "monotonic, a 46% fall, about 4.6 sigma, drift excluded".
The exclusion rested on the position-5 control coming back *up* to 140 after the
81 at position 4. That was not a return to baseline; it was the baseline's own
downward slope passing through, and one point was read as evidence of stability
when it was a point on a line. The sigma figures were computed against a
baseline assumed constant and are meaningless.

**What survives.** Detrended against the three controls, every throttled point
sits below the local baseline by 19 to 65 words while the controls sit on it to
within 4. So a throttle effect is probably real. But the drift is the same order
as the effect and there is one pass per setting, so it cannot be quantified from
this data, and the interesting features -- the apparent saturation between gap
63 and gap 127, and fixed-15 (123) disagreeing with random-15.5 (58) at 4.8
sigma where fixed-63 and random-63.5 agreed to 0.3 -- are all inside the
confound.

**The design error is the lesson.** A sweep whose points are 32 minutes apart
needs its control *interleaved with every point*, or the order randomised, not
one control in the middle and one at each end. Three controls were enough to
detect the drift and not enough to correct for it. Paired A/B -- control, point,
control, point -- costs twice the runs and is the only version of this
experiment worth running.

**The drift's cause is unknown and is its own finding.** It is not the knob:
the controls have the throttle off. Candidates, none established -- the SD
card's flash translation layer remapping after repeated rewrites of the same
LBAs, thermal drift over hours, or filesystem free-list state evolving across
nine rewrites of the same 16 MiB file. Anything that reads this machine's
corruption rate as a stable quantity should measure it three times first.

**What the sweep does establish, independent of the drift**, is that the knob
works and is honest: `make -C sim dvma` times identical traffic in three modes
and requires the gap to slow it (29 clocks per access unthrottled, 40.5 at fixed
gap 15); `tools/deca_throttle.tcl` reads the source back and refuses a point if
it did not take; total pass time is constant at 32m00s to 32m21s across all
nine, so every point moved the same data in the same time. And the regressions
hold -- MultiBus 22/274 and VME 10/312, byte-exact, with `check_console` clean.

**Elapsed time is the wrong control for this knob, and the arithmetic says
why.** A pass moves 32 MiB in 1920 s, which is 29 ms per sector; a 15-clock gap
across a sector's 128 longword transactions adds 115 us, 0.4% of that. The pass
is SPI- and filesystem-bound, so total duration cannot see the throttle however
well it works. What it changes is spacing *inside* a gather burst. A first
reading of the flat elapsed time as "the knob is not biting" was also wrong.

**And it is not the card region, which the Wukong could not previously rule
out.** `DISK_OFF_MIB` was Quartus-only -- it appears in `syn/Makefile` and not
once in `syn/build.tcl` -- so every measurement the Wukong has ever produced was
taken at sector 0. It reaches the Vivado flow now, applied at the media in
`wukong_top` exactly as `deca_top` does it, with the `outdir` tag added to
*both* expressions. Same machine, same controller, same bitstream logic, only
the region of the card different:

```
  offset 0     92 of 4,194,304 words wrong
  offset 1024  81 of 4,194,304
```

So the medium is not the variable. That matters because this project has been
caught by it before -- `351e320` found a create/delete stress damaging inode
2140 every time at sector 0 and cleanly at 512 MiB -- but that was a different
card, replaced since, and the rate here does not move.

**The offsets are not interchangeable, and picking the wrong one wastes a
boot.** Even multiples of 512 MiB (0, 1024, 2048) hold `eagle.img`, whose
`/etc/fstab` names `xy0`; odd ones (512, 1536, 2560, 3584) hold `eagle-sd.img`,
naming `sd0`. A machine pointed at the other kind boots and then cannot mount
its root read-write: the VME SCSI test above ran at offset 0 and came up on an
`xy0` fstab, which read exactly like a broken NFS root and cost a diagnosis.

**Confirmed on a second pass, with the filesystem the build is meant for.** The
first VME+SCSI run predated `DISK_OFF_MIB` on this flow and therefore sat at
offset 0, on an `eagle.img` whose fstab names `xy0` -- it booted, but its root
came up read-only and had to be hand-remounted. Rebuilt at **512 MiB**, it finds
`eagle-sd.img`, mounts `root on sd0a fstype 4.2` against a matching fstab, and
comes up clean:

```
  VME + SCSI, offset 0     0 of 8,388,608 words wrong
  VME + SCSI, offset 512   0 of 8,388,608
  MultiBus + XY450, off 0     92 of 4,194,304
  MultiBus + XY450, off 1024  81 of 4,194,304
```

32 MiB through the SCSI path across two builds and two regions of the card,
where the MultiBus rate predicts about 370 bad words. So the comparison no
longer rests on a single pass, and neither side depends on which copy of the
image it used.

**That exonerates the whole shared path under a different master.** The VME
Ethernet reaches memory through the same `sun2_dvma`, the same
`sun2_wishbone_bridge`, the same MMU and `C_S` chain, the same `wb_to_mig_ui`
and the same MIG and DDR3 -- all of it carrying 33.5 MB without a single wrong
byte. Whatever the fault is, it is **not** in the machinery every DVMA master
shares.

What differs between the two cases is the disk controllers and what sits under
them: `sun2_xy450` and `sun2_scsi_core`, and the `blk_sd` seam and SD card both
of them use. `blk_sd` is the one piece the XY450 and the SCSI card have in
common, which is what makes both boards corrupt identically while the Ethernet
does not.

**Two cautions about the comparison, stated because they are real.** It is a
different machine (VME, not MultiBus) and therefore a different bitstream and
device decode, and it is a different `sun2_dvma` instance. So this is not
literally the same logic exercised two ways; it is the same *shared modules*
exercised by a different master, which is weaker but still decisive at a rate
ratio above 700 to 1.

**A third caution, about the instrument itself.** Transferring the source over
the 9600-baud console dropped a run of text on the first attempt and the compile
failed; `sum` caught it. The console has no flow control and every write on a
diskless machine blocks on NFS, so a transfer must be paced and its checksum
checked before anything built from it is believed.

**What has not been compared, and is the only pairing left:** the *physical*
address of a failing read against the physical addresses the CPU actually wrote.
Every check here predicts from the address it is handed -- the coverage check
proves *a* block was fully written, and `ARRIVED BAD` proves *a* read came back
wrong, and nothing establishes that the two are the same block. A 2 KiB mapping
error cannot produce an isolated word, so that is excluded; what is not excluded
is a block written at one physical address and read from another for reasons
that are not the page map.

**Which moves the fault to the CPU's write.** A word the CPU wrote into the
buffer never reached that location. The write-side crossing check counts writes
that *arrived at the adapter* carrying the right data and finds none wrong -- it
cannot see a write that never reached the bridge, or one issued to a different
address. That is the mirror of every instrument built so far, and it is where
this now points.

**The old note, kept because the reasoning was sound given what was believed:** The adapter is
single-transaction-in-flight and is the only client on this build, so every
request reaches MIG in the order the machine issued it; with `Strict` they are
also *executed* in that order. A read that still returns the location's previous
contents therefore had its write issued **after** it, in real time -- not
reordered underneath. The question is no longer "did the controller reorder?"
but "why was that word not yet written when the master read it?", and that is a
question about the machine above the adapter, not about DDR3.

**What it predicts, and how to test it without a rebuild:** anything that
separates the CPU's write from the master's read in time should suppress it.
The cheapest is `sync` between filling and flushing; the real fix is to make the
adapter hold a read until prior writes are known committed, or to establish
strict ordering in the controller.

**What is not yet pinned down** is the exact window -- whether `C_S6` can be
true for a cycle before the map output settles, or whether the bridge latches
early -- and that is what the fix has to be built on.

**The old note on the address the bridge asks DDR3 for.** Every address
check so far compares a signal with itself at two moments: the bridge's
`P_ADR_IN` at issue against `P_ADR_IN` at load, and now `wb_adr_i` at issue
against `wb_adr_i` during. **Nothing checks `P_ADR_IN -> wb_adr_o`** -- the
translation from the 68010 address to the Wishbone word address the adapter
actually fetches. A read that goes to the wrong DDR3 word returns another
page's contents faithfully, satisfies every self-consistency check in the path,
and hands the master program text. That is the one link in the chain where the
address is *transformed* rather than merely held, and it is the only untested
one left.

**On this build there is only one other writer: the disk itself.** A
MultiBus XY450 machine has the CPU and one DVMA master. During a *disk write*
the master only reads -- but the kernel interleaves disk *reads*, and a DVMA
write is disk content going into memory. Disk content on this card is binaries,
which is precisely what `584f` (`addqw #4,%sp`) and `2f2d` are. **A DVMA write
landing one word outside its buffer would drop program text into the page being
written.** That is a different code path from everything instrumented so far,
all of which was the memory-to-device direction.

**The old question about the read direction is closed by the host read.**
The two identical cold reads above were read as proof that the medium is wrong.
That inference assumed a read-path fault would be *random*; a deterministic one
-- the same address mangled the same way every time -- fits the evidence
equally. The disk-to-memory direction is uninstrumented on this board, and it
shares the same `sbuf`, with `blk_sd` writing and the DMA reading. **The
decisive test needs no bitstream: read the card on a host and compare the
sectors against the pattern.** If the card is right, everything above is
correct and the fault is in the read path.

**The refinement that got there, and why `2046` was not a finding.** On a run that corrupted 3 words, the byte read back out of the
sector buffer was flagged 2046 times against a control of 42,480,549 -- and
1024 sectors x 2 passes is **2048**. One flag per sector write is a boundary
artefact, not a fault, almost certainly the arming clock or the `blk_busy` edge
being counted. The control is inflated the same way: it increments every clock
while `blk_busy & blk_we`, and `blk_buf_addr` only moves once per SPI byte, so
each byte is counted about forty times.

Neither is fatal to the design of the check -- `rq_addr` and `buf_q` are both
one clock behind `blk_buf_addr`, so they are aligned and the steady state does
compare correctly -- but a number that lands within two of the sector count is
an artefact until proven otherwise. **Count once per byte, on the clock
`blk_buf_addr` changes, and exclude the first and last of a transfer.**

Recorded because the alternative was to report 2046 as a finding, and it is the
same shape as the 214 that turned out to be metadata runs and the 1018 that
turned out to be non-pattern traffic.

**The medium really is wrong, so the read path is not the corrupter.** That had
never been established on the Wukong: `patwr -v` proves only that a file written
and read back differs, and the in-flight evidence at the card interface came
from the DECA's `sun2_blktrace` -- on the SCSI card, not this one. Two cold
reads of the same file, each after its own reboot so nothing is served from the
buffer cache, name **the same three sectors with the same three wrong values**:

```
  sector 277 word  38   want 8026  got 584f
  sector 329 word 154   want 809a  got 2f2d
  sector 805 word  24   want 8018  got 2e2e
```

A read path that corrupted would give a different list each time. So the damage
happened once, on the way out, and is now on the card. It costs one reboot and
it removes half the search space.

**Which makes the remaining list short.** Every byte *offered* into the sector
buffer is proven correct -- 1,048,776 of them, 0 isolated wrong, 0 dropped --
and that covers `sun2_dvma`'s assembly, the Wishbone handoff and the XY450's
staging transitively, because `dma_buf_wdata` is extracted from `rd_stage` which
comes straight from `wb_dat_i`. What is left between a correct byte entering the
buffer and a wrong byte on the card is only:

* the `sbuf` RAM itself,
* `buf_q`, its registered read port -- the check is written but counts per
  clock rather than per byte, see the artefact above,
* `blk_sd`'s SPI shift and CRC, uninstrumented on this board.

**The gap that remains is the write *data* path above the adapter.** Everything
built so far checks reads, or checks a write against `req_dat` -- what the
adapter was handed. Nothing checks that `req_dat` is what the CPU or the master
actually put on the bus. `sun2_wishbone_bridge`'s write path
(`P_DATA_IN` -> `wb_dat_o`) and `sun2_dvma`'s write staging have never been
instrumented, and a word corrupted there would satisfy every check listed above:
the adapter would faithfully store, and faithfully read back, the wrong value.

**A caution about the machine as an instrument.** After many corrupting runs the
2560 MiB filesystem degraded to the point where `/usr/bin/adb` and
`/usr/bin/csh` both read wrong on a *cold* boot (54248 and 61295 against 50905
and 34435), and `ld` began failing deterministically until a reboot. Rewrite the
card before any run whose conclusion depends on a source being pristine.

**The asymmetry claim below is therefore withdrawn.**

**The asymmetry was measured and interpreted too narrowly.** The
suspicion here used to be that it was observational -- writes are verifiable
because the source is in hand, reads are not, and a corrupted word arriving in a
page read from disk is invisible until it is executed, which this machine does
plenty of (`lpd` cores, `ld` SIGILL, `halt` with `Illegal instruction`, `fsck`
with `Emulator trap`). Measured, it is not: **`dd if=/dev/rsd0a bs=8k count=256
| sum` twice gives `22901` both times.** The raw device bypasses the buffer
cache, so that is two million words fetched from the medium into memory by DVMA
with no caching in between; at the write side's rate of roughly one bad sector
in a hundred and twenty the two sums could not agree. And `sum /usr/bin/adb`
returns the reference image's `50905` on every boot, which is ground truth
rather than self-consistency.

So the fault is specifically **memory to device** -- the master's *read* of
memory -- and not device to memory. The direction that works is the one where
DVMA writes memory and the CPU reads it back.

**A used filesystem stops being an instrument.** After several corrupting runs
the machine's own `/usr/bin/csh` and `/usr/bin/adb` no longer matched their
pristine checksums, while `/usr/bin/sum` and `/usr/bin/od` still did -- so
copies made from them looked corrupt against the reference image while being
faithful copies of a damaged source. Verify the *sources* on the machine before
each run; the card carries pristine copies at several offsets for this reason.

**The bridge-to-master handoff is clean, including which half of the word it
took.** `sun2_dvma_probe` (`BLKTRACE=1`, read by `tools/deca_dvmaprobe.tcl`)
watches the one pairing that exists only in the failing direction:
`sun2_wishbone_bridge` loads `P_DATA_OUT` on `wb_ack_i & issued`, and
`sun2_dvma` captures `dvma_din` at the end of `S_LATCH`. Over a run of three
copies it counted **33,280 memory-read captures with exactly one bridge load
inside every one**, none with none, none with two, and **none that took the
wrong half** -- while the same run corrupted `csh` at sector 45 and `adb` at
sector 157, both confirmed by `cmp` after a reboot with the sources verified
pristine beforehand.

The half check matters because of the granule. A DVMA longword is two 68010
cycles, each of which fetches a 32-bit word from DDR3 and takes 16 bits of it by
`P_ADR_IN[1]`; the corruption is 16 bits wide, so a wrong half-select was the
natural fit and is now excluded by measurement. **What is left is the value**:
the master got exactly one load, from the half it asked for, and the data in
that half was wrong. That points below the bridge -- `deca_wb_to_ddr3` and
BrianHG's controller -- and not at the handshake above it.

**The two controllers agreeing is what makes that argument tight.** After
`sun2_dvma` the paths share nothing: the XY450 unpacks `wb_dat_i` straight into
its own `sbuf` through one muxed write port (`sun2_xy450.sv:851,320`), while the
SCSI card stages the longword, walks it out a byte at a time across the SCSI bus
through `scsi_fabric`, and lands it in `scsi_targ`'s dual-ported `mem`
(`sun2_scsi_core.sv:618,193`, `scsi_targ.sv:154`). Both corrupt identically, so
the fault is in what they share, and everything shared above the data itself has
now been measured clean.

**And the whole chain below it accounts perfectly, which puts the fault in the
data BrianHG's controller returns.** `deca_wb_to_ddr3` counts the reads it
issues, the responses it receives, responses arriving outside `D_READ`, and
reads whose 32-bit lane changed between issue and response -- the last being the
one *value* selection in the path, since BrianHG returns a 128-bit line and the
adapter takes a quarter of it by `req_adr[1:0]`. Measured on a run that
corrupted `csh` at sector 13 and `adb` at sector 171:

```
  captures      33280   no_load 0   late_load 0   wrong half 0
  reads issued  38592   responses 38592   unexpected 0   wrong lane 0
```

So every request has exactly one response, no response arrives unbidden, the
right quarter of the line is taken, the right half of that word is taken, and
the master captures it exactly once -- and sixteen bits still arrive wrong. The
memory holds the right data at that moment (a copy read back from the buffer
cache before any reboot checksums correctly), so what is left is that the read
returned the wrong contents. That is inside `Inputs/BrianHG-DDR3`, not in
anything this project wrote above it.

Worth knowing before chasing it there: the CPU uses the same controller and the
machine runs for hours, so whatever it is has to be far rarer for the CPU's
access pattern than for a master's, or invisible to it. `test/deca_ddr3` walks a
mebibyte and passes, which is the pattern *least* like a disk transfer.

**The corrupted word is stale data, not a failed write, and `tools/patwr`
is what said so.** It writes a pattern that describes its own position -- bit 15
a generation tag, bits 14:8 the sector modulo 128, bits 7:0 the word offset --
in two generations differing only in the tag, so a bad word decodes to a
position *and* says which generation it belongs to. Filling with zeros first
could not do that: zero carries no position, and the first run's bad words came
back `0000`, `0001`, `00ef` with nothing in them to read.

With a fill generation underneath, on a freshly written card:

```
  sector 293 word 210   want a5d2  got 0096
  OLD gen, sector 0 word 150, -9532 words (-19064 bytes)
```

One word in 262,144, the rate files show. The tag is clear, so it is
**fill-generation content** -- what the medium and the buffer cache held before
this write -- and it is at a *different* offset, so it is not the "this word was
never written" case either. It is old data fetched from somewhere else.

That matters because the address checks are all clean: `sun2_dvma_probe` and the
adapter's counters say one load per cycle, the right 32-bit lane, the right
16-bit half. What none of them checks is that the data a response carries
*belongs to the address that was requested* -- BrianHG's controller could answer
with a previous read's contents and every counter above would still read zero.
That is the gap the next instrument should close, and the read vector the
controller carries (`READ_ID`, `DDR3_VECTOR_SIZE`) is the handle for it.

Two cautions for anyone repeating this. The sector index is modulo 128, so a
file longer than 128 sectors makes the displacement ambiguous by multiples of
64 KiB -- the -19064 bytes above is the smallest candidate, not a certainty, and
a run of 128 sectors or fewer would be exact. And a verify is meaningless unless
the *write* pass printed its summary: an interrupted write leaves a half-written
file that reads as catastrophic corruption.

**Getting that instrument to read anything took five separate fixes to the same
signal, and the lesson is about `ifdef` rather than about DVMA.** The port on
`sun2_fpga`, its connection in `top_fpga`, the port on `top_fpga`, and the
declaration *and* connection in `deca_top` were each inside `` `ifdef SUN2_ILA ``,
which is only defined under `TRACE=1`. In an ordinary build every one of them
vanished, and the readout showed a healthy machine with all counters zero. The
declaration was the worst of them: with it compiled out, `dvma_probe` became an
**implicit one-bit net**, so bit 0 had a path and bits 79..1 did not -- which is
why the probe returned a fixed `...0001` whatever was wired to it, including a
hardcoded constant.

Quartus reports that, and in exactly one place: the map report's port
connectivity check, `Output port (80 bits) is wider than the port expression
(1 bits) it drives`. Nothing appears in the console log, and binding a
connection to a port that does not exist produces no message at all. `grep -A6
'Port Connectivity Checks' build/syn/quartus/*/sun2.map.rpt` is the check to run
after adding any signal that crosses a module boundary.

Two probe design rules came out of it, both cheap and both load-bearing:

* **A free-running heartbeat counter.** It proves clock, counter, module
  crossing and readout in one number, so a zero anywhere else is a fact about
  the machine rather than a question about the probe.
* **A counter for something that must be busy.** Bridge loads happen on every
  CPU memory read, so zero there can only be the instrument. Without it, "all
  counters zero" has two explanations and no way to choose -- which is precisely
  where this sat for four builds.

And two wrong models the board corrected, neither of which reading the RTL had
caught. The first invariant was "a load in the clock before the capture", which
flagged 11282 of 11282 captures: `W_ACK` is `(wb_ack_i & issued) | done` and the
DTACK the master waits on is gated further by the `C_S` chain, so the load lands
somewhere inside the cycle. The second was counting *every* `S_LATCH`, which
flagged everything again -- `S_LATCH` runs on writes too, and a write produces no
load at all, so a boot streaming a disk into memory looks like total failure.
100% of anything is a broken model, not a broken machine.

**Do not read a signature out of a trace without checking the instrument
first.** The signature half of `sun2_blktrace` was wrong on its first outing --
see the trap below -- and it named two sectors of other files as the intruders
in a corrupted block. Both were chance collisions in a 16-bit fold.
`tools/blktrace_match` prints the expected number of those, `W*S/65536`, above
its own output for that reason.

**The DECA has a network again, and it is a 3Com 3C400.** `MB_3C400=1` fits
`rtl/sun2-multibus/sun2_mb_3c400.sv`, the *other* MultiBus Ethernet -- three
2 KiB buffers and two registers in an 8 KiB window, against the Sun card's
256 KiB, which is 256 M9K on a device that has 182 and therefore cannot be
built here at any clock. Mutually exclusive with `SUN2_MB_ETHER`: one card
cage, one MII port, and `top_fpga.v`'s two arms both drive `mii_txd`, so
`sun2_fpga.v` `$fatal`s on the pair rather than leaving a multiply-driven net
to synthesis.

It costs **+1,234 LE and +52,224 memory bits** over the disk-only build at the
same clock (24,788 -> 26,022 LE, 50% -> 52%), and the memory decomposes exactly:
six 1024x8 buffer halves (49,152 = 6 M9K) plus the 256x12 receive FIFO (3,072).
Timing came out *better* than the build without it -- 0.854 ns against 0.637 --
which is placement variance, not the card being free. **So the DECA can now have
disk and network at once**, which no machine in this project has had.

Measured: MultiBus with the card is **20 bus errors and 279 characters**,
decomposing exactly as 22 - 2, the two removed being both probes of `0xFE0000`
= `MBMEM_BASE + 0xE0000`, the card's own address. The empty-cage reference
(22/274), VME (10/312) and `mbether` are all unchanged. `make -C sim mb3c400`
is 58 checks; eight mutations were tried and all eight caught, each by the
check that names it.

**On hardware it netboots.** A DECA at 16.667 MHz runs `Probing Multibus: ec`,
`Boot: ec(0,0,0)vmunix`, RARP, 120936 bytes of bootloader over TFTP, an NFS
root and swap, and a 604688-byte kernel -- all of it through the card, so the
receive path is proved at volume and not merely in simulation. With the disk
fitted too, SunOS attaches **`ec0 at mbmem 0xe0000 pri 3`** beside `xy0`.

**What stops it short of a login is IP fragmentation, and the card has two
receive buffers.** A 4096-byte NFS read reply is three Ethernet frames; buffers
A and B take the first two and the third has nowhere to go, so IP never
reassembles and the kernel retries `READ init 0+4096` for ever. Counted on the
machine, five three-fragment datagrams: **+10 `fragments received`, +5
`fragments dropped after timeout`** -- exactly two of every three arrive. Two
fragments are reliable, 60 consecutive at 0% loss.

Confirmed through NFS itself rather than inferred, same file and same mount
with only `rsize` varied:

```
  rsize 1024   1 fragment    sum 63736   48
  rsize 2048   2 fragments   sum 63736   48     identical
  rsize 4096   3 fragments   NFS read failed ... RPC: Timed out
```

**Two traps met on the way there, both of which produced confident nonsense
first.** `ec0`'s `Ipkts` looked like it proved all three fragments arrive; it
counts *every* frame including background broadcast, which on this LAN is about
13 per 40 s, and subtracting it leaves exactly the 10 IP saw. And SunOS's
`ping` cannot send more than 2048 bytes -- its raw socket's send buffer, not
the card -- so `ping -s 4000` from the Sun fails with `ret=-1` at a size
threshold that looks exactly like a fragment threshold. Driving the sweep from
another host is what separated them: 2000 *and* 2900 bytes pass, 3000 fails, so
it tracks fragment count and not size.

**It is inherent to the card, and Sun documented it.** *Installing the SunOS
4.0.3 Release* says outright that "diskless Sun-2 machines and Sun 100U machines
with 3Com Ethernet interface (ec0) will have trouble booting from fast servers
such as a Sun-3 or Sun-4", and offers two remedies: patch the kernel and mount
with smaller `rsize`/`wsize`, or replace the board with the Sun MultiBus
Ethernet. Both are exactly what the measurements above arrived at
independently, before the document was found -- which is the strongest evidence
available that this replica is faithful rather than defective, and it is
evidence of a kind no simulation could have produced.

Note what "fast server" means here: a server that emits the fragments of a reply
back to back with minimal spacing. A modern Linux box is far faster than the
Sun-3 the manual warns about, so this bench sits well inside the documented
failure regime and would be expected to fail even with a period-correct card.

**So the remaining question is a narrower one than it looks.** The behaviour is
reproduced; what is still unmeasured is whether *this* card's buffer turnaround
matches a real 2/120's, since ours runs `ecread`'s 1500-byte copy through the
MMU to DDR3 where the original had static RAM. A drop counter in the card --
frames rejected for want of a free buffer -- would say, and it is worth having
if the card is ever pushed further. It is no longer needed to decide whether the
card is right.

**The root mount's transfer size is a compile-time constant**, so there is no
knob: `nfs_mountroot`/`nfsrootvp` build the mount themselves, no fstab, no
bootparams field, and nothing in the kernel's data or bss symbols carries a
size. It is set once, at `_nfsrootvp+0x1a2`, `movel #8192,%a3@(34)`, whose
immediate is four bytes at file offset `0x14170` in the 4.0.3 GENERIC a.out
(text base 0x4000, header 0x20, so file = vaddr - 16352). Recorded because it
was expensive to find, not because anything here patches it.

**The DECA drives a monitor, on both machines.** `FB=1` fits the Sun-2 frame
buffer and a 1280x1024 display. A MultiBus 2/120 boots SunOS 4.0.3 from the SD
card with its console on the screen and autoconfig reporting **`bwtwo0` beside
`zs1`**; a VME 2/50 shows the 2/50 banner and netboots to a login prompt. Those
two device names are the point on MultiBus: `bwtwo0` is the kernel recognising
the frame buffer, and `zs1` is the keyboard/mouse SCC that `SUN2_FB` builds
because on a real 2/120 that SCC is on the video board.

**Almost none of the Wukong's video ported, and almost all of the Sun-2's did.**
The Wukong makes HDMI itself -- an MMCM, a 5x bit clock, eight OSERDESE2 and
four OBUFDS. The DECA has an **ADV7513**: a transmitter chip taking parallel
24-bit RGB with CLK/DE/HS/VS, configured over I2C. So `Inputs/hdmi`'s TMDS
encoder, serialiser and packet files are all useless here, and what replaced
them is `rtl/sun2-common/video_timing.sv` (the raster, sixty lines of VESA
arithmetic) and `boards/DECA/deca_adv7513_init.sv` (an I2C sequencer, the third
of its kind after the two PHY ones, tested against an independent target by
`make -C sim adv7513`). Nothing in `rtl/sun2-common/` had to change except
`fb_scanout.sv` moving into it, with `sun2_attr.vh`'s macros in place of raw
Xilinx attributes.

| | MultiBus + disk + 3C400 | VME |
|---|---|---|
| logic | 28,347 (57%) | 28,840 (58%) |
| memory bits | 716,960 | 680,864 |
| Fmax cpu_clk | 17.65 MHz | 17.58 MHz, against 16.667 |

Both are their own base **+4,096 memory bits exactly** -- `fb_scanout`'s 32x128
line buffer. The logic costs differ, +2,327 against +1,260, and that asymmetry
is the shared decode behaving correctly: `SUN2_FB` brings the keyboard SCC on a
2/120 and not on a 2/50, where it arrives through `MATCH_PARALLEL` instead. All
four PLLs are now used.

**Two bugs, both found on a monitor and neither reachable any other way.**

`deca_wb_to_ddr3.sv` took `req_adr[PORT_ADDR_SIZE-5:2]` where its own header
comment said `[26:2]` -- two bits short, silently capping the adapter at
128 MiB. Nothing noticed for the life of the port because main memory is 7 MiB.
The frame buffer is the first thing ever placed high (`FB_WB_BASE` is 248 MiB),
so the CPU's pixel writes landed at 120 MiB with bit 25 lost while scan-out read
248 MiB and found uninitialised DDR3. **On a correctly-synced raster that is
noise**, which implicates the display and is an address fault.
`tb_deca_wb_ddr3` passed with the bug present because it only used addresses 0
to 31; it now writes two addresses differing solely in bit 25 and requires them
not to alias.

And **`fb_scanout` speaks MIG's protocol**: `c_req` is a *level*, held for a
whole line, advancing one beat per `c_done`, which `mig_arb` consumes on the
Wukong. BrianHG's `CMD_ena` is a single-clock *command strobe*. Wired straight
through, the port took a fresh command every clock at 125 MHz for the address of
the beat still in flight, and every returned beat carried beat 0's data -- the
screen showed **nine copies of the leftmost 128 pixels**, `BEATS_PER_LINE` being
9 and a beat 128 bits. That reads as a line-buffer fault and is a handshake one.
`deca_top` carries the adapter now and `fb_scanout` states its contract, which
nothing in it did.

**A DECA with a display has no console, and cannot be halted.** `sunmon.c:396`
sets `g_outsink = OUTSCREEN` whenever `s2fbthere()` succeeds and offers no way
to ask for both, and the keyboard SCC is instantiated with nothing connected --
so an `FB=1` machine is one you can photograph and not talk to. It also cannot
be shut down cleanly, which matters because reprogramming is a power cut: see
the note in `BRINGUP.md`. `tools/deca_reset.tcl` and `sun2_trace` are the only
instruments left.

**`test/deca_hdmi` exists for that reason** -- the output path with no Sun-2 at
all, 310 logic elements and a minute to build, so the first attempt at a picture
has nothing else that could be blamed. It also settled the one thing that cannot
be settled by reading: the ADV7513 samples on the rising edge of its CLK, so the
pixel clock goes out inverted. A working board there reads `0 0 0 1 0 B 1 1`.

**The board layer is the seam, and it is small.** `boards/DECA/` is a clock
generator (two ALTPLLs), a Wishbone-to-DDR3 adapter, a JTAG console bridge with
two UART halves, a DP83620 sequencer, and a board top implementing
`rtl/sun2-common/top_fpga.v`'s port list. `deca_wb_ocram.sv` -- main memory in
on-chip M9K -- is kept beside the DDR3 path deliberately: both satisfy the same
Wishbone contract, so they are interchangeable by construction and a
disagreement between them is a real finding.

`tools/portcheck.sh` diffs a module's port list against an instantiation
mechanically. It exists because `fb_video_en` -- see the trap below -- sat
unconnected for the entire life of the frame buffer, and it runs on every
Quartus build. Both boards report 47 ports, all connected.

**What the DECA does not have, and what follows.** (Video is no longer on this
list -- see above.) No hardware UART, so the
console goes over the on-board USB-Blaster II through an
`altera_avalon_jtag_uart`; the machine's bit-serial `tx`/`rx` are kept and
bridged rather than tapping bytes out of the SCC, because the SCC's own baud
generator running correctly off a MAX 10 PLL is precisely what has to be
proved. No hard memory controller, so DDR3 comes from `Inputs/BrianHG-DDR3`, a
third-party soft controller hardware-verified on this exact board. And the
MultiBus Ethernet card cannot fit at all: its 256 KiB of on-card RAM is
2,097,152 bits against the 10M50's entire 1,490,944-bit M9K budget, which is why
the DECA is a VME 2/50.

**Standalone test designs, and they earn their keep.** `test/deca_console` and
`test/deca_ddr3` are the DECA's equivalents of `test/hdmi`: the block, its
clocks, a pattern generator and nothing else, at about 1% of the device and a
minute to build. The console is the only instrument that board has, so when it
fails there is nothing left to debug it with; the DDR3 test walks a mebibyte
with an address-derived pattern and reports over JTAG. Both report through
In-System Sources and Probes rather than through the console, so that a memory
test and a console fault are never the same experiment.

**The panels are readable over JTAG.** `tools/deca_reset.tcl` prints `todebug`
and `diag_leds` -- the Sun-2 front panel and the debug ladder BRINGUP.md says to
read first -- plus DDR3 calibration, PHY link state and the console's four event
counters, and it can pulse the machine's reset. That reading is what ended a
netboot investigation that had no fault in it: `seen_stall=0` says no bus cycle
went unanswered, which exonerates the Wishbone bridge and DDR3 outright, and it
was true while a memory-latency hypothesis was still being drafted.

**The console holds 2048 bytes toward the host, and it had to.** The bridge
used to hold exactly one byte, with a timeout before giving up on it. That is
not enough elasticity for a console: the machine emits 960 bytes a second into
the JTAG UART's 64-byte write FIFO, so a host that pauses for 67 ms leaves the
bridge nowhere to put the next byte, and it overwrote the one it held -- a
silent loss mid-line. Long output truncated and the shell looked hung until
something made it print again.

The timeout made it worse rather than bounding it: it was reset on every
arrival, so during continuous output it could never expire. "Wait up to 84 ms
then give up on this byte" became "wait for as long as the machine keeps
talking", and the whole burst was lost rather than one byte of it.

`FIFO_LOG2` is a parameter -- 11 on the board, 2.1 seconds of output for two
M9K of 182; `tb_deca_console` instantiates 3 so eighty bytes overflow 64+8 and
the drop path is still tested, because the depth is a size and the dropping is
a mechanism. Dropping only when *that* fills keeps the property the single byte
existed to provide, a machine with nobody listening is never held up, while
making the case that actually happens cost nothing.

**It also retired the 65-byte artefact.** Every board capture used to lose the
banner after `Sun Workstation, Model Sun-2` because the 64-byte FIFO filled
before `juart-terminal` attached. The banner now arrives whole -- `Sun
Workstation, Model Sun-2/50 or Sun-2/160, Sun-2 keyboard`, `ROM Rev Q, 7MB
memory installed`, `Serial #3442, Ethernet address 8:0:20:1:6:E0` -- because
the queue holds it until someone listens. A workaround that had been documented
twice turned out to be a missing buffer.

Measured on the board at 16.667 MHz: `ls -la /usr/bin` returns all 12310 bytes
complete and in order, and `/dhryr` prints both its lines and gives the prompt
back without a keystroke.

**The console is fixed, and the answer was TCK.** Host-to-machine used to swap
adjacent bytes -- `abcdefghij` came back `cbedgfiij` -- while machine-to-host was
byte-perfect. The bridge now runs on `MAX10_CLK1_50`, and a 48-character string
echoes byte for byte; the machine takes typed commands.

The rule is the one already half-learned here: **the JTAG UART's user clock must
be comfortably faster than TCK**, which the timing report puts at 10 MHz. At
4.915 MHz -- below TCK -- the host read each byte twice and out of order, and
moving to cpu_clk at 12.5 MHz was recorded as the fix. It was half of one: 12.5
and 16.667 MHz are 1.25x and 1.67x TCK, enough for one direction and not the
other. 50 MHz is 5x and fixes both. It is also a real board oscillator rather
than a PLL output, so the console runs before and independently of everything
else -- which is what the board's only instrument should do -- and its framing
no longer depends on `CPU_CLK_HZ`.

What made it findable was eliminating everything else first, and each step is
worth keeping. The event counters read exactly ten in and ten out at all four
stages for ten bytes typed, so it was a data-value fault and not flow control.
`make -C test/deca_console LOOPBACK=1 CON_ON_CPU=1` wires the bridge's
transmitter back to its own receiver -- no SCC, no PROM, no CPU -- and
reproduced the swap, so the machine was not involved at all. `deca_uart_rx`
declares `valid` at 9.5 bit times and `deca_uart_tx` drops `busy` at 10, so the
echo is always latched before the FSM leaves `S_TXW2` and the FSM's ordering is
provably right. And the Avalon read matches `altera_avalon_jtag_uart.sv` line
for line -- `read_0` and `rvalid` registered on the A->B edge, `fifo_rd`
combinational in A, the read FIFO confirmed `lpm_showahead="OFF"` so its `q`
lands in the cycle the FSM samples. A FIFO cannot reorder; only the crossing
could.

## Architecture

**Reset is three nets, not one, and the differences are load-bearing.** A
2/50's are `P.RESET-` (also labelled `P2.INIT-`, one wire), driven by the
68010's own RESET pin through PAL A102 and reaching the Ethernet control
register, the video control register, the VME `SYSRESET` driver and the P2
connector; `INIT-`, a *different* PAL output driven by power-on reset, VME
reset and the watchdog, which clears the system enable register and the
diagnostic register; and nothing at all for the Am9513 ("not affected by
power-on resets, watchdog resets, or 68010 resets", Architecture Manual 6.8),
both Z8530s (no reset pin, and the board cannot make the RD+WR software reset
because those strobes come from separate decoders), the bus error register, the
contexts and the maps. Architecture Manual 4.6.1: "When the 68010 executes a
reset instruction, it resets all on-board and off-board I/O devices that offer
an external reset function. No other devices are affected."

Here that is `P_RESET_n = ~machine_reset & ~RESET_OUT` in `top_fpga.v` (the
peripheral net, carrying `sun2_ether_ctl`, `sun2_fb_ctl` and the bus cards),
`sys_reset` (the enable and diagnostic registers, the MMU decode, DVMA), and
`por_reset` in `sun2_fpga.v` — asserted once at configuration and never
re-armed by a button, a watchdog or a RESET instruction. `por_reset` exists
because an FPGA has to start somewhere: `z8530_scc.sv` has no `initial` blocks
and no declaration initialisers, so with no reset at all its FIFO pointers,
soft-reset counters and interrupt latches stay X *for ever*, putting X on RR0
bit 7 — `ZSRR0_BREAK`, the bit the NMI debounce compares against `g_debounce`.
The Wishbone bridge's `ENABLE` is on `por_reset` for a different reason: it
gates `wb_cyc`/`wb_stb` and is armed only at LED code `0x8F`, so clearing it on
a warm reset hangs the machine on the way back up — the monitor's non-power-up
path pushes every register to the stack long before `0x8F`.

**The watchdog works, and the monitor says so.** A double bus fault
(`tools/dogprobe`) halts the CPU, `top_fpga.v` senses `HALT_OUTn` and pulses
the machine reset, and the boot PROM prints `Watchdog reset!` — which it can
only do because the Am9513 survives, so its power-up test at `trap.s:117` reads
`0x0C22` rather than `CLKM_DEFAULT` and takes the other branch. Identical on
both cores; the two spell the open-drain HALT pin differently and agree on when
it is driven.

**One define picks the machine.** `rtl/sun2-common/sun2_config.vh` derives everything
machine-dependent from `SUN2_MULTIBUS` (default) or `SUN2_VME`: device-space
base page, size of memory space, the ID PROM's machine type, and which boot
PROM is compiled in. `sun2_fpga` prints the resolved configuration at time 0
and `$fatal`s on impossible combinations. Add machine-dependent things here,
not at the call site.

**Everything hangs off the 68010 bus, and the MMU sees all of it.** The CPU
drives `P_A`/`P_FC`/`P_AS_n`/`P_RW_n`/`P_UDS_n`/`P_LDS_n`; `sun2_mmu` translates
through segment map then page map; the page-map TYPE field selects memory (0),
on-board I/O (1) or the system bus (2/3). Device decode, the protection check,
the `C_S3..C_S24` bus timing chain, DTACK and the bus error register all key off
those same wires. **Consequence:** anything that becomes a bus master is
invisible to all of that if it drives the same pins. That is exactly how DVMA
works — `rtl/sun2-vme/sun2_dvma.v` arbitrates for the bus and drives supervisor-data
cycles, and `rtl/sun2-common/top_fpga.v` muxes CPU versus DVMA onto those wires. Nothing
downstream knows DVMA exists.

**Adding a device** means four things, and missing the last one gives a silent
12-clock timeout and a bus error: instantiate it, add a `MATCH_*` term, add an
arm to the `P_DOUT` read mux before the `16'hDEAD` fall-through, **and** add it
to the read and/or write DTACK terms.

**Two masters on DDR3.** `mig_arb` owns MIG's one user port; `wb_to_mig_ui` is
the CPU's client and `fb_scanout` the frame buffer's. One transaction in flight
on the whole interface, because MIG's `ORDERING = "NORM"` is not established
here and the read path has no tag. A client's request is still asserted during
the cycle its `done` comes back — mask it, or the arbiter runs the transaction
twice and you lose a CPU clock with nothing to show for it.

**One frame buffer, two places.** Both machines have the same 1152x900 screen
and both PROMs reach it at the same *virtual* addresses; only the page-map
entry differs. The 2/50 decodes it in TYPE 1 (pages 0..63, register at 0x40);
the 2/120's video board is a **P2-bus** card and decodes in TYPE 0 alongside
RAM — aperture at page 0xE00 (0x700000), register at 0xF03, and the
keyboard/mouse SCC at 0xF00, which is why `SUN2_FB` builds that SCC too. The
board decodes only A19/A12/A11 up there, so all three alias; `MATCH_FB` in
`sun2_fpga.v` matches that. Everything from `sun2_wishbone_bridge` to the HDMI
pins is shared and machine-independent.

**The MMU has two context registers, not one.** `sys/sun2/mmu.h` puts the
supervisor context at FC_MAP offset 6 and the user context at offset 7 — one
16-bit word, supervisor in the even byte, user in the odd — and every writer of
either is a `movsb` to its own byte. Supervisor accesses translate through the
supervisor context and user accesses through the user context, which is what
lets `sun2/locore.s` walk contexts 1..NCONTEXT-1 invalidating every segment
while it goes on executing. `ctx_reg.v` must therefore honour UDS/LDS; a write
that lands on both halves is invisible to the PROM, which always sets the two
to the same value (`mon/kernel/trap.s:398-400`), and fatal to SunOS, which is
the first thing to make them differ.

**The console has two entirely separate paths, and only one of them is the
SCC driver.** Kernel `printf` reaches the serial port through the *PROM*:
`cnputc` (`sys/sun/cons.c:332`) calls `romp->v_putchar`, which busy-waits on
RR0 and writes the data register (`mon/kernel/busyio.c:17-50`). No interrupts,
no WR9, no WR0 commands. Userspace goes somewhere else entirely --
`consconfig` (`sys/sun2/autoconf.c:614-624`) sets `consdev = zs` minor 0
whenever the PROM's `insource` and `outsink` are both UART A, which is what
happens with no frame buffer fitted, and `cnwrite` then forwards every write
to the interrupt-driven `zs` driver. The kernel comment says why: "check for
console on same ascii port to allow full speed output by using the UNIX driver
and avoiding the monitor."

**Consequence:** kernel messages appearing on the console prove that RR0 bit 2
and the transmit data register work, and *nothing else*. They say nothing
about interrupts, and a machine can print its whole autoconfig perfectly while
being unable to deliver one character of userspace output. Both SCCs
interrupt at **level 6** -- Architecture Manual 8.3 and 9.3, and
`sys/sun2/scb.s:50` names `zslevel6` at vector 0x1E "(UARTs)". The `priority
3` in `conf.sun2/GENERIC` is a software spl level, not a wire.

**Two Ethernets, sharing only the 82586.** The VME machine's is on board and
reaches main memory by DVMA through the MMU (`rtl/sun2-vme/sun2_dvma.v`). The MultiBus
machine's is a card with its own memory and its own page map
(`rtl/sun2-multibus/sun2_mb_ether.sv`), a slave that never masters anything. They share no
registers, no addressing and no byte-order convention — do not try to unify
them. The card hangs off page-map TYPE 2, which `sun2_fpga` decodes as a
*space*: it emits a bus address and a select, and the card supplies DTACK.
With nothing plugged in the timeout must still fire, because that is how the
PROM's probes discover empty addresses — a blanket TYPE 2 decode makes the
machine hallucinate a 3Com at `0xE0000`.

**The disk is the only bus master a MultiBus build has.** `rtl/sun2-multibus/sun2_xy450.sv`
is a Xylogics 450: six bytes of registers in MultiBus **I/O** space (page-map
TYPE 3, which is a *second* space port beside the TYPE 2 one and was not
decoded at all before), and everything else by DVMA — the controller fetches
its own 24-byte IOPB and moves its own sectors, at virtual `0xF00000 + X`
through the MMU, reusing `rtl/sun2-vme/sun2_dvma.v` unchanged. Media is an SD
card on a V3, a file in simulation, behind the block seam
`Inputs/Wish5380/doc/block.md` defines.

It **chains**, but SunOS on this machine almost never asks it to. `xychain`
(`xy.c:731-773`) walks `c->c_units[]` and takes **at most one ready IOPB per
drive**, then optionally appends the controller's own `c_cmd`. On a one-drive
machine -- every configuration in this project -- that is a chain of one during
ordinary read/write traffic, with `xy_chain = 0`, and two only when a
controller-level command happens to be pending at the same time. Nothing is ever
appended to a *running* chain. So `make -C sim xychain` exercises a path the
kernel does not take while moving file data, and the "one interrupt per chain"
requirement below is real but rarely reached. SunOS 4.1.4 went further and added
two ways to switch chaining off entirely (`XY_NOCHAINING` from the config file,
`DK_ISOLATE`/`XY_NOCHN` per ioctl), which suggests it gave somebody trouble on
real hardware.

CHEN in an IOPB's command byte says to follow that IOPB's Next
IOPB Address, relocated by the same registers as the head. Two things there
fail quietly. `xy_nxtoff` is **only valid when CHEN is set** — `xychain()`
clears `xy_chain` on the tail and leaves a stale offset beside it
(`xy.c:744-745`), so following it unconditionally is a DMA into the previous
transfer's buffer. And the driver wants **one interrupt at the end of a chain,
not one per IOPB**: `xyasynch()` sets `xy_ie` and clears `xy_intrall`, and a
second interrupt is read as the *next* chain completing. Note also that SunOS
3.4 never uses the Attention protocol at all — `XY_ATTN`/`XY_ACK` appear in no
C file in the tree — so AREQ/AACK exists here for 4.x and for not lying to a
driver that does use it.

Data moves **four bytes per DVMA transaction**, not one. The Wishbone port is
32 bits and `sun2_dvma` holds the bus request across both halves of one access,
so a longword is one arbitration and two 68010 cycles: 128 round trips per
sector instead of 512. A chunk runs to the end of the longword it starts in or
the end of the sector, so an unaligned `xy_bufoff` costs one short transaction
at each end and nothing else — `tb_xy450.sv` section 10b covers all four
alignments and checks the bytes either side of the buffer are untouched.

Two more facts, about how it reaches memory. **The PROM remaps the DVMA window
before every boot** — `FAKES1BOOT` is unconditional, so
`setupmap(fakemapinit2)` puts virtual `0xF00000`–`0xF3FFFF` on physical
`0xC0000` as ordinary memory, which is why a disk needs at least 1 MiB
installed and why the steady-state TYPE 2 mapping is a red herring. And **the
byte-address inversion applies to the IOPB but not to sector data**: MultiBus
numbers bytes little-endian, so IOPB byte *N* is at offset *N*^1, while data
moves in word mode and lands straight. Get the second one wrong and the label
still checksums — it reads `0xBEDA` instead of `0xDABE`.

**Mixed language, and the distinctions are load-bearing.** The MC68010
(`Inputs/Suska_Configware/68K10`) is VHDL and needs `-2008`. The Sun-2 gateware
in `rtl/sun2-common/*.v` must be compiled as **Verilog-2001, not SystemVerilog**. The SCC,
the 82586 and the testbenches are SystemVerilog. `sim/run_xsim.sh` and
`syn/build.tcl` keep these in separate lists; put new files in the right one.

## Conventions

**`Inputs/` is immutable.** It is third-party and reference material, mostly git
submodules (`git submodule update --init` after a fresh clone).
`Inputs/BrianHG-DDR3` is the DECA's DDR3 controller, vendored the same way; it
carries no formal licence ("Written by Brian Guralnick. For public use."), which
is worth knowing before anyone packages this. `Inputs/doc/` holds the datasheets
that RTL comments cite -- `dp83620.pdf` for every PHY register value, and
`DECA_board/` for the board's own schematic, pinout and reference projects. When
a value in `boards/DECA/` looks arbitrary, it is quoted from one of those. Never edit in
place. Where a change is genuinely needed it lives as a patch in
`patches/<name>/`, applied to a copy under `build/inputs/` by
`tools/patch_inputs.sh`, which the build flows invoke. Patches are meant to be
temporary — when one is accepted upstream, drop it and move the submodule
forward. The boot PROMs work the same way: `tools/sim_speedup*.txt` are applied
by `tools/rompatch` into `build/rom/`, never onto `Inputs/*.bin`, and rompatch
verifies the existing word before changing it.

**`Inputs/sunos-34-src` is the boot PROMs' own source, and `msun`/`rsun` are
revisions rather than machines.** This file said for a long time that
`sun/prom_monitor/msun/` builds the MultiBus monitor and `rsun/` the VME one.
It does not. They are **Rev Q** and **Rev R** of one tree -- their `sys/`
subtrees are identical bar an extra README and `h/`, and `mon/kernel` differs in
two files -- and the machine is chosen by **`-DVME` per build directory**, in
the `IDENT` line of each Makefile: `msun/mon/RevQ2` is Rev Q MultiBus,
`msun/mon/RevQs` is Rev Q **VME**, and `rsun/mon/RevR2` is Rev R MultiBus. So
the VME monitor is built out of `msun`, which is the opposite of what the old
sentence said, and a question about VME behaviour answered by reading `rsun`
was answered from the wrong directory. Reach for it before guessing at what a PROM is doing —
`sys/mon/s2map.h` names every I/O page numerically, `mon/kernel/sunmon.c` has
both machines' page-map setup side by side, and `mon/h/buserr.h` documents
register semantics no manual states. `m68k-linux-gnu-objdump -D -b binary -m
m68k:68010 --adjust-vma=0xEF0000` disassembles the images (use
`--start-address` to land on an instruction boundary).

**A SunOS failure is an address until you resolve it.** `tools/ufsread` reads a
4.2BSD filesystem out of a Sun disk image without root or a loop device, and
`tools/pcsym` maps a program counter onto the kernel's a.out symbol table:

```sh
tools/ufsread build/disk/small.img cat /vmunix -o build/disk/vmunix
tools/pcsym build/disk/vmunix 63c8e                     # -> _poke+0x32
grep -E "alive:|Called from|pc = " xsim.log | tools/pcsym build/disk/vmunix
```

That is the difference between "it died at 0x63c8e" and "it died inside
`poke()`, the kernel's own protected device probe, which means the probe's
fault recovery did not work". Check the a.out's text/data/bss against what the
standalone boot printed — if they disagree, the kernel on the disk is not the
one that booted. Neither tool writes anything, and the extracted kernel belongs
in `build/`, not in git.

**Reproduce a kernel fault from a boot block, not from the kernel.** Reaching
`poke()` through SunOS costs eight seconds of simulated time, most of a day of
wall clock, because the kernel has to come off the disk first.
`tools/beprobe/` does the same thing in about 1.6 s: it is a freestanding
68010 boot program that maps the page the kernel's probe faulted on
(`0x701000`, page map entry `0xF0800000`, TYPE 2), stores to it, catches the
bus error and prints the exception frame the CPU pushed. It exists because
that frame is the one thing the kernel cannot show us, and it was written to
settle whether the special status word describes the cycle. It does not:
Suska pushes `if=1 rw=1 fc=6` for a supervisor data *write* at FC 5.

```sh
make -C tools beprobe
tools/mkxydisk -o build/disk/beprobe.img --boot build/disk/beprobe.bin
make -C sim xsim XY450=1 MEM_MIB=1 ROM=fast STOP_ON=beprobe-finished \
     XSIMARGS="-testplusarg blk_image=$PWD/build/disk/beprobe.img"
```

Its handler recovers with a saved PC as well as a saved SP, deliberately.
`probe_write` is static and gets inlined, so there is no return address at
that stack pointer and an `rts` popped a string constant and jumped into
`.rodata` — which looked exactly like a machine fault and was not one.

**SunOS runs on a different timer from the monitor, and it works.**
`tools/clkprobe/` is the same kind of boot block for the Am9513. Every boot in
this project proves counter 1 — `TIMER_NMI`, level 7, the monitor's clock — and
only that one. SunOS uses counter 2, `TIMER_MISC`, **level 5**
(`msun/sys/mon/suntimer.h:16`), armed by `startrtclock()` in `main()` *after*
autoconfig, so nothing reached it until a SunOS boot got that far. The command
sequence differs from the monitor's too: the monitor points the data pointer
once with `CLK_ACC_MODE` and lets it auto-increment into the load register,
then starts with `CLK_LOAD_ARM`; the kernel points it again with `CLK_LLOAD`
and starts with a bare `CLK_ARM`, no load (`sun/sys/sun2/clock.c:57`).

```sh
make -C tools clkprobe
tools/mkxydisk -o build/disk/clkprobe.img --boot build/disk/clkprobe.bin
make -C sim xsim XY450=1 MEM_MIB=1 ROM=fast STOP_ON=clkprobe-finished \
     XSIMARGS="-testplusarg blk_image=$PWD/build/disk/clkprobe.img"
```

With the kernel's own sequence and its own `CLK_HZ(100)` = 3072, mode and load
read back as written and every terminal count arrives as a level-5 interrupt,
on both cores. So the counter, the mode decode, `CLK_LLOAD`, bare `CLK_ARM`
and the wiring of OUT2 to `INT5_n` are all sound — worth knowing mainly as an
elimination, since an idle SunOS looks exactly like a dead clock from outside.

It reports in three separable parts — registers read back, then the output pin
watched through the status register with interrupts masked, then the interrupt
itself — so a failure says which half is broken; it repeats the whole thing
with the monitor's `CLK_LOAD_ARM` sequence as a control; and it starts by
reading counter 1 back before writing anything, which is what the monitor's
own initialisation left there. That last one found a real bug — see the trap
below.

**`Old/` is the previous working implementation.** Not in git, never modified;
copy from it rather than referencing it.

## Verification discipline

**The old 23,629 fingerprint was almost entirely a bug.** Of those errors
23,607 were protection violations from seven PROM program-counter values, four
repeating exactly 4096 times — `NUMPMEGS * PGSPERSEG`, one per page-map write in
`diag.s`'s `PMconst`, `PMdata` and `PMaddr` passes — and the "physical page"
each reported was the pattern the PROM had just written (`000/333/ccc/fff`).
They were phantoms: `PROTERR` is combinational and the `C_S` chain is cleared
only on the posedge *after* `AS` releases, so it re-evaluated against an address
and function code that were not a bus cycle. The PROM cannot raise real ones —
`diag.s:41` lists protection as a FIXME rather than a test, the map tests all go
through untranslated `FC_MAP`, and during `PMconst` the bus error vector is
still uninitialised, so a real Sun-2 would double-fault on the first.

**The permission bits were also one bit high, which is what stopped SunOS.**
`struct pgmapent` in `sys/mon/s2map.h` is a valid bit then `PMP_SUP_READ`,
`SUP_WRITE`, `SUP_EXECUTE`, `USER_READ`, `USER_WRITE`, `USER_EXECUTE` — entry
bits 31 down to 25, i.e. `ps_pmap2devices[11:5]`. Supervisor program read is
`SUP_EXECUTE`, `ps[8]`; we tested `ps[9]`, which is `SUP_WRITE`. `startup()`
marks kernel text `PG_KR` = `SUP_READ|SUP_EXECUTE` (`sys/sun2/pte.h:52`), so the
kernel could not execute its own text: protection fault at `_start+0xf8`,
retried forever, each nested 68010 long frame walking the stack down until it
wrapped past zero into a double fault.

The MultiBus machine is the reference that must not regress. It boots to the
prompt with **22 bus errors** at `MEM_MIB=1 ROM=fast`, with no cards, and the
bus-error sequence should stay byte-identical. Check it after anything touching
shared logic, not just after machine-specific work.

Every one of those 22 is a device probe that timed out, which is the only kind
of bus error a correct boot takes. Fitting a card removes its probe, and the
changes add up:

| configuration | bus errors |
|---|---|
| no cards (the reference) | **22** |
| `FB=1` | **21** |
| `MB_ETHER=1` | **19** |
| `MB_3C400=1` | **20** |
| `FB=1 MB_ETHER=1` | **18** |
| `XY450=1` with an image, stopping at the boot block | **10** |
| `XY450=1 MB_ETHER=1 FB=1` with an image, `TIMEOUT_MS=8000` | **8** |

One error for the display's probe at `0xEC0000`, three for the Sun Ethernet
card, two for the 3Com's own address probed twice,
twelve for the disk — so 22 - 1 - 3 is exactly the pair and 22 - 14 the trio. A
count that does not decompose that way is worth running down before anything
else. These were measured together after the `PROTERR` fixes, and every one is
exactly **23,607** below the number it replaced: the phantom count was a
constant, identical in all six, and no genuine error moved.

The disk runs are:

```sh
make -C sim xsim MEM_MIB=1 ROM=fast XY450=1 STOP_ON="running." \
     XSIMARGS="-testplusarg blk_image=$PWD/build/disk/xy0.img"
make -C sim xsim MEM_MIB=1 ROM=fast XY450=1 MB_ETHER=1 FB=1 TIMEOUT_MS=8000 \
     XSIMARGS="-testplusarg blk_image=$PWD/build/disk/xy0.img"
```

and the stop string has to be one word, because `sim/Makefile` passes it to
xsim unquoted. The all-three run puts the console on the screen and leaves the
serial port silent; `make -C sim screenshot MACHINE=multibus MB_ETHER=1 FB=1
XY450=1` renders what it drew, which is the only artefact that shows the whole
machine working at once.

The VME 2/50 boots to the prompt with **10 bus errors** at `MEM_MIB=1`, all of
them the same kind of probe — the frame buffer at `0xEC0000`, MBMEM at
`0xF00000`, both Xylogics addresses, and two more, each probed twice. It runs a
different PROM image (`rsun`), so it is an independent check on shared logic and
worth running for that reason alone.

It reaches the prompt at **8.3 s** of simulated time, not the under-6 s it used
to take, and that is correct rather than a regression: with no disk it tries the
network, and `nd` gives up only after three retries, which the PROM times in NMI
ticks — so fixing the Am9513 write strobe, and with it the NMI's rate, stretched
the wait. `TIMEOUT_MS` therefore defaults to 12000 for `MACHINE=vme` and 6000
otherwise; `STOP_ON` ends the run at the prompt, so the larger number costs
nothing.

**`make -C sim check` does not boot anything.** It is `check_console.sh` against
whatever `console.log` is already in the run directory, so it will happily pass
against a log from days ago — that cost a wrong "VME is fine" here. Run
`make -C sim xsim MACHINE=vme MEM_MIB=1` first, then `check`.

It was **11** until `patches/Suska_Configware/0001` landed, the extra one being
the protection violation at `A=EF00D2 FC=6` at 6.8 us that this file carried
for a long time as an unchased power-on artefact. It was not an artefact. The
PROM executes `reset` at `0xEF00CC`, Suska's `WAITSTATES` tested `RESET_OUT_I`
ahead of `DTACK_In` and so ignored the acknowledgement for the prefetch already
in flight, `AS` stayed asserted into `C_S8`, and the protection check fired
against a page map entry software had not written. The X in that map was the
only thing making it survivable: with the maps powered up as zeros, as they are
on a board, the exception's own stack push faults too and the machine
double-faults before it writes its front panel. That is how it presented on
hardware. The patch removes the error; every other one is unchanged, in the
same order.

Unit tests are expected to earn their keep: mutate the RTL, confirm the test
fails, revert. `tb/tb_dvma.sv` was written this way and still missed a real
timing bug once, because its memory model answered a cycle sooner than the
machine does. `tb/tb_xy450.sv` missed two the same way and both are worth knowing
about. Every transfer in it was a round trip to the same address, so a wrong
cylinder/head/sector-to-block map was still its own inverse and passed; it now
reads the block number out of the media model directly, at a cylinder *and* a
head that are both non-zero. And its memory model answered errors without
remembering them, while the real `sun2_dvma` latches a bus error and stops the
channel until told to forget it — modelling that latch immediately exposed a
real bug, where a bad *data* address also killed the status writeback and the
IOPB came back with the driver's own zeroes in it, reading as success.

**The machine knows what time it is, and both operating systems needed it.**
`rtl/sun2-common/mm58167.v` is a software-compatible National MM58167, the
Sun-2/120's time-of-day chip at on-board I/O page 7.  It is MultiBus-only:
Architecture Manual 8.2 lists `[0x003800] 7 REAL-TIME CLOCK` for Machine Type 1
while 9.2 gives `[0x7F3800] Reserved` for Machine Type 2, and the PROM's own
header agrees -- `MIOPG_CLOCK 7`, no `VIOPG_CLOCK`.  Page 7 was already decoded
as `MATCH_RTC` and used only by the PHY status register under `` `ifdef
SUN2_VME ``, so the two share the page without colliding.

It is unconditional, like the Am9513 and the SCCs and unlike the cards, because
a 2/120 has the chip soldered down and a card cage can be empty.  That costs the
reference boot nothing: `CLOCK_BASE` appears in the PROM only as data in the two
`mapinit` tables, and `0x00EE1000` occurs exactly once in the shipped rev-R
image, at `struct pginit` spacing inside that table.  Measured, not assumed --
MultiBus stays at **22 bus errors and 274 characters, byte-identical on both
cores**, and VME at 10/312.

**What "software-compatible" had to mean was decided by the drivers, and they
disagree with each other.**  NetBSD's `mm58167_gettime` loops

    } while ((mm58167_read(sc, mm58167_status) & 1) == 0);

which exits only when the rollover bit reads **one** -- inverted with respect to
its own comment and to the datasheet.  A status bit that never sets hangs NetBSD
at spl7 for ever.  SunOS's `todget()` wants the opposite, retrying while the bit
is set and printing `TOD chip has gone berserk` after 100 tries.  Both are
satisfied by reading it as "has a 1 kHz tick happened since you last read 14H":
set every millisecond, cleared by the read, returning the pre-clear value.
SunOS's few-microsecond pass sees it clear; NetBSD's loop cannot wait more than
a millisecond.

SunOS's `todprobe()` is the stricter of the two probes and pins down three more
things: register 0's **low nibble must read zero**, the status register's bits
1..7 must read zero, and register 0 must **change within 2 ms** -- a frozen
replica fails.  NetBSD's `tod_obio_match` is only
`bus_space_peek_1(tag, bh, 0, NULL) == 0`, which returns an *error code*, so its
entire presence test is "does a byte read of offset 0 avoid a bus error".

`make -C sim mm58167` replays all four sequences over the Sun-2's own bus
protocol -- `cs_n` low, `rd_n`/`wr_n` selecting, strobes several clocks wide --
because a device tested through a one-clock handshake says nothing about a
device driven by a 68010.  48 checks; three mutations were tried and all three
caught, the important one being that a status bit stuck at zero fails
"gettime: the inverted loop terminates".

Two things about the model worth keeping.  **Both strobes are edge-detected**,
not just the write: `ttl_am9513.v` gets away with a bare `read` level only
because its reads have no side effects, and 10H and 14H here are read-to-clear.
And **DOUT is loaded once at the leading edge and held**, which is what makes a
read-to-clear register return its pre-clear value -- the CPU latches data at
`C_S8`, several clocks after the strobe rose, so a combinational read port would
hand it the value from after the clear.

On the board: SunOS goes from `WARNING: no TOD clock` and a single-user `#` to
`tod0 at obio 0x3800`, **no warnings at all, and a full multi-user boot with a
login prompt** -- `rc` no longer drops to single user once the date is sane.
`date` advances one second per second and traces back to the build-date constant
`syn/build.tcl` bakes in.  NetBSD gets `tod0 at obio0 addr 0x3800: mm58167` and
past `inittodr` -- the `trap type=0x0, code=0x1105, v=0x8` panic is gone.

**20 MHz was never a timing problem, and this file said it was for months.**
The story used to run: adding the RTC's ~384 LUTs took WNS from 0.667 to
0.594 ns, Vivado called it met, the board disagreed by hanging part-way through
the NFS kernel download, and therefore it was setup timing on the CPU core's
half-period path.  Every step of that is a correlation and the conclusion was
wrong.  The real cause is `P_RESET_n`, below; the RTC's LUTs did nothing but
re-place the design.  What should have been suspicious at the time is that
*slowing the clock* is only one of the things a rebuild changes, and the
symptom -- a hang with the CPU still running -- names no clock at all.

`CPU_DIV` exists because of it.  `make -C syn bitstream CPU_DIV=51` names the
MMCM divider directly and gives exactly VCO/51 = 19.607843 MHz, a clock no
integer `CPU_HZ` can express.  **Give it alone: `CPU_HZ` is then derived from
it, not supplied beside it.**  `CPU_DIV` wins over `CPU_HZ` in
`wukong_clkgen.sv`, so `syn/build.tcl` recomputes `cpu_hz` as VCO/`CPU_DIV`
before anything reads it.  It used not to, and the banner said `CPU clock
20000000 Hz` over a synthesis log saying `cpu 19607843 Hz (VCO/51, exact)` --
the same knob-does-not-reach-the-report trap this file records twice already.
Worse, `wukong_top.sv:453` computes `SD_CLK_PERIOD_PS` from `CPU_CLK_HZ` and
that *is* synthesised: every `CPU_DIV` used so far gives a lower frequency than
`CPU_HZ` claimed, so the SD clock only ever came out slow, but `CPU_DIV=25`
against `CPU_HZ=20000000` would have run it at twice the rate, and SD
identification mode has a hard 400 kHz ceiling.  The MHz tag in the output
directory carries one decimal where there is one, because VCO/51 and VCO/52
both truncated to `cpu19` -- the elaboration guard rejects a *frequency* that
does not divide the 1 GHz VCO in whole hertz, which conflates an exact divider
with an integer number of hertz.  Naming the divider keeps the no-silent-
rounding guarantee by construction.  **19.607843 MHz boots and 20 MHz does
not**, so a 2% cut was enough where 12.5 MHz was the next exactly-representable
step down; below about 19 MHz a different path becomes critical and further
slowing buys almost nothing (WNS 0.979 at VCO/51 against 1.276 at VCO/80).

**A knob has to reach the logic, not just the build, and this was the third time
that has cost a build here.**  `CPU_DIV` was declared on `wukong_clkgen` and
passed with `synth_design -generic`, which reaches the **top level and nothing
below it**: synthesis printed `cpu 20000000 Hz (VCO/50, exact)` and produced a
20 MHz design in a directory named `-div51`.  The fix is one parameter on
`wukong_top` forwarding to the instance.  Same shape as `fb_video_en` never
being connected and `HDMI30=1` being read by no file in the tree; check that a
new knob changes the *reported* configuration before trusting the artefact.

**Two more Z8530 defects, and the second one is the interesting story.**
NetBSD 2.0 reaches userland on the MultiBus machine and its first printed line
came out as `Wed Aug215: C26' -- a date with characters missing -- while the
kernel's own messages were perfect.  Same discriminator as the WR9 bug in
`patches/z8530_scc/0001': kernel output is polled, tty output is
interrupt-driven, so a clean kernel console and a lossy tty means the interrupt
path.

`patches/z8530_scc/0002` gates the IP bits by their enables.  `Z85C30.pdf`
states the rule outright -- "if the IE bit is not set by enabling interrupts,
then the IP for that source is never set" -- where the model latched all six
regardless and said so in its own comments.  It is a real defect.  **It is not
what garbled the console**, and the patch says so: it was diagnosed
confidently, it passed a testbench and a mutation, and on the board it changed
the output *not at all* -- byte for byte the same loss.

`patches/z8530_scc/0003` is the fix: **a transmit data write clears the
transmit IP.**  The model cleared it only on WR0 command 101.  The IP means
"the transmit buffer is empty", so refilling the buffer retires it; the command
exists for a driver with nothing more to send, which cannot clear it by
writing.  SunOS issues the command (`sundev/zs_common.c:384`,
`zs_async.c:615`) and so never noticed.  NetBSD never issues it -- the only
`ZSWR0_RESET_TXINT` in its whole tree is in the kgdb stub -- and
`zstty_txint` just writes the next byte.  So the IP never cleared, `/INT`
stayed asserted, `zstty_txint` was re-entered at once, and each re-entry wrote
another byte on top of the one still going out.

**The clue that mattered was that the loss was byte-identical between runs.**
That rules out a race and means a fixed loop, and it is what sent the search
from the dispatch side to the clearing side after the first fix did nothing.
With 0003 the same boot prints `Wed Aug 26 15:54:27 UTC 2026'.

Note what each patch can cite.  0002 quotes the datasheet.  0003 cannot: the
product specification carries only the WR0 register diagrams, and the prose on
what resets a Tx IP is in the SCC User's Manual, which is not in the tree.  Its
evidence is behavioural instead, and sound -- NetBSD/sun2 shipped and ran on
real Sun-2 hardware without ever issuing the command, and a transmitter whose
IP never clears cannot send a second character.

**Verified with everything in this file: VME is 10/312 and MultiBus 22/274,
both byte-identical, with the 118-bit `dbg_bus` packing checked on every clock
edge of both boots.**

**Verified: VME with 0002+0003 is 10/312**, byte-identical to the Suska VME
console, with `Ethernet initialised, transmitted, and found no server` passing
-- which matters twice over, because that check drives the 82586 through DVMA.
MultiBus is 22/274 on both cores with both patches.

`make -C sim scc` is 28 checks now, and each patch's removal fails only its own
two.  Both were driven over the Sun-2's bus protocol, and the RR3 checks exist
because RR3 is a path SunOS never takes: `zslevel6` dispatches on the
status-modified vector in RR2, `zsc_intr_hard` reads RR3's IP bits directly.
A register the reference boot never reads is a register with no coverage.

**A combinational reset net is a glitch two clock domains away.**
`top_fpga.v` drove `P_RESET_n` as `~machine_reset & ~RESET_OUT` -- one term over
two separately-routed registers -- and that net ends up on the *asynchronous*
preset of `rx_rst_q`/`tx_rst_q` inside `wish82586`, in the 2.5 MHz MII clocks.
`report_cdc` calls it out as **CDC-10, "Combinational logic detected before a
synchronizer", Critical**.  When the two inputs change in opposite directions on
one edge, the skew between their routes is a glitch on that preset, and whether
it is wide enough to take depends on placement.  It is one register now.

**It presented as SunOS freezing part-way through the NFS read of `vmunix`**,
with the machine otherwise alive, and it cost most of a session because every
cheap explanation fit.  What ruled them out, in order:

* the **LED ladder** -- `seen_stall` clear says *no bus cycle ever went
  unanswered*, which exonerates the Wishbone bridge and DDR3 outright, and
  `seen_err` lit with `fc_err` = 5 is only the PROM's own device probes, which
  a healthy boot takes too.  Read that panel before building anything;
* **`report_cdc` on the routed checkpoint**, which enumerates hazards instead of
  reasoning from the symptom.  It is the tool that found this, in one run, after
  three hypotheses argued from a single correlated variable had all failed.

**WNS is not the discriminator, and the numbers invert.**  0.468 and 1.126 ns
froze; 0.310 and 0.123 ns boot to multi-user.  A build with *more* setup margin
failing than one with less is the tell that the path in question is not being
timed at all.  Nor is frequency, quite: 17.54 MHz froze as a plain build and
booted with the ILA fitted, same clock, different placement.

**It was not a regression in the CPU core.**  `reset_busy` is byte-identical
across `Inputs/RD68011` c40052c..930d8e1; updating the submodule re-placed the
design and shook a latent defect loose.  A fault that moves when nothing about
the logic moved is a placement-sensitive one, and that is a category, not a
mystery.

Measured after the fix: **MultiBus at 20 MHz boots to a login prompt three times
out of three** with byte-identical 3490-byte consoles, and **VME at 20 MHz boots
to a login prompt**, which also proves the 82586's DVMA handover on real
hardware.  Simulation is unchanged -- MultiBus 22/274 byte-identical, VME 10/312
byte-identical -- so the fingerprint costs nothing for a peripheral reset that
releases one clock later.

**Left undone, deliberately recorded:** `report_cdc` still reports 674 CDC-1
"unknown CDC circuitry" and five more CDC-10s, two of them on the SCC's own
reset synchronisers and two on `rst_cpu/chain_reg[0]`.  Much of that is inside
MIG and benign; the Sun-2's own deserve a pass rather than waiting for the next
symptom to point at one.  And **`MEM_LATENCY` was a genuine coverage hole** --
every boot ever recorded here used the default one-cycle memory, so the bridge
had never been simulated at the 7-to-13 clocks the board actually has.  It is
clean at 13 (22/274, byte-identical), but that was luck rather than diligence.

**An asynchronous clock used raw, and the counter that would not count.**
`ttl_am9513.v` took `X2` -- the 4.9152 MHz oscillator, from mmcm_b -- sampled it
into one flop on `cpu_clk` from mmcm_a, and then wrote `f1_tick = X2 & ~x2_d`,
using the *raw* asynchronous net in a combinational term beside its own
sampling flop.  `syn/wukong_common.xdc` puts those two clocks in different
asynchronous groups, so the path is untimed and placement alone decides what
the flop sees.  `report_cdc` says it outright: **CDC-1 Critical, "1-bit unknown
CDC circuitry", `clkgen/mmcm_b/CLKOUT0` -> `timer/ctr_cntr_reg[1][*]/CE`** --
the raw oscillator was reaching the counters' *clock enables*.  A glitched
enable is a counter that does not count.

`mm58167.v` had copied the idiom and cited this file as precedent, so the TOD
was on the same cliff edge.  Both are two `ASYNC_REG` flops now, with the edge
detector on synchronised values only.

**The comment that justified it is the lesson.**  It argued the crossing was
safe because the bus clock is more than twice the oscillator, so no edge can be
missed.  That is a Nyquist argument about *edges*.  It says nothing about
metastability, and nothing about one asynchronous net fanning out to several
loads with different routing delays.  Grep for any other place a slow input is
edge-detected without a synchroniser and assume it is wrong until measured.

Measured on the board with `tools/clkprobe`, MultiBus, before and after:

```
                          before   after    VME (which always worked)
  CLK_HZ(100) OUT2 edges       5      22      37
  CLK_HZ(100) level 5 taken    0      21      34
  load 16     OUT2 edges       0     386     373
  load 16     level 5 taken    0    1558    1355
```

**What it fixed, measured the sound way.**  The two machines used to disagree
by a factor of nine on the same benchmark and now agree to within 1%:

```
                       real     user      sys    dhrystone says
  MultiBus, 20 MHz    128.7s    60.0s     0.8s      1407/s
  VME,      20 MHz    126.2s    59.5s     0.9s      1414/s
```

Same CPU, same clock, same binary out of `/` on the shared NFS root -- and
`real` matches an external stopwatch on both, which is what says the kernel's
timekeeping is sound.

**A benchmark's own report is not a measurement, and neither is a stopwatch
around the whole command.**  This file used to carry a story about the tick
running at 5.6 Hz on MultiBus and 83.7 on VME, derived by comparing what
dhrystone printed against a marker-to-marker wall clock.  Both halves were
wrong.  The wall clock included forking `echo`, the shell forking the binary,
the NFS load of 24 KB and process exit; and the arithmetic assumed dhrystone's
`HZ` matches the kernel's, which was never checked.  `/bin/time` settles it
without either assumption -- and note dhrystone's own 35 s against `time`'s
60 s of user, a factor of 1.71 that is suspiciously close to 100/60, so one of
the two still has the wrong `HZ`.  **Use `/bin/time` and compare `real` against
an external clock; quote `user` for CPU work.**

**What looked like the machine losing half its time was a runaway `cron`**, and
killing it took `real` from 128.7 s to 62.8 s while `user` stayed at 58.9.  VME's
wall time doubling across this fix was the same daemon, not the fix.  Check
`ps -aux` before believing any elapsed-time measurement on this machine; the
date these boards come up with is wrong by decades (the MM58167 has no year
register and SunOS loads it modulo SECDAY), which is a good way to make cron
spin.

**Simulation cannot see any of this** -- `clkprobe` passes every check in
simulation on both machines, because a simulator has neither metastability nor
routing delay.  The board is the only instrument for this class, and
netbooting the probe (serving it in place of the primary bootloader) turns a
measurement that needed a disk image into one that takes a minute on real
hardware.  `clkprobe` masks to **spl4** rather than spl0 for exactly that: a
netboot leaves the Ethernet armed, and its level 3 killed the probe with
`Exception 6C` until the window admitted only level 5 and above.

**The ILA can see the interrupt path now.**  `dbg_bus` is 118 bits: the top 16
are `{EN_INT, IPL2_n..IPL0_n, INT7_n..INT1_n, timer_int[5:1]}`, which is the
*request* side.  The acknowledge side alone cannot answer "which interrupts
fire" -- a request asserted and never granted and one never asserted are the
same absence -- and `timer_int` is what separates "the timer never asserted"
from "the encoder ate it".  `syn/ila_capture.tcl` gains `iack` and `iackseq`;
use `iackseq`, which qualifies capture on FC 7 so 4096 samples are 4096
acknowledges however far apart.  Plain `iack` triggers on one and then holds
4096 *clocks*, about 205 us, where a 100 Hz interrupt is 10 ms apart -- an
absent level 5 there means nothing at all.

Two traps met while reading captures, both of which produced confident
nonsense first: a capture window that is mostly the machine *idling in the
monitor after the probe finished*, where counter 2 is not armed and reads 0
because that is correct; and `ila_capture.tcl` printing `0 samples captured`
over a perfectly good 4096-sample CSV, because `STATUS.SAMPLE_COUNT` reads 0
once the data has been uploaded.  The second was recorded in `a16c586` as an
open defect and was not one.

**A dead process is `adb`'s question, not the ILA's.**  Four processes were
seen to die or hang -- `ld` with SIGILL, `lpd` and `inetd` with cores, `cron`
spinning -- and a bitstream with an ILA on `_core` was built to chase them.
`adb` on the board answered it in three commands and no build at all:

```
# echo '$r' | adb /usr/lib/lpd /core     registers, and which signal
# echo '$c' | adb /usr/lib/lpd /core     the frame that called the wild one
# echo 'ADDR?i' | adb /usr/lib/lpd       the file's instructions
# echo 'ADDR/i' | adb /usr/lib/lpd /core the *memory's* -- `?' file, `/' core
```

`?` against `/` is the sharp one: it compares what a page holds on disk with
what it held in memory, which is how "the machine corrupted it" was ruled out.

**And most of those deaths were not the machine.**  `lpd` dies identically on
*every* boot: two cores taken three hours and several reboots apart are
identical in 2,128,580 bytes of 2,132,118, differing only in the top-of-stack
argv and environment.  Same PC, same stack, same data segment.  Nothing
marginal in hardware reproduces to the byte.  It calls
`openlog("lpd", LOG_PID, LOG_LPR)` through PLT stub `0x200b0`, `ld.so` binds
that stub correctly -- the file holds the unbound `nop; bsr` and memory the
patched `jmp`, which is exactly right -- and it then faults *inside the shared
C library* with an odd address in `a0`.  `SIGBUS` on sun2 means `T_ADDRERR`
specifically, and only that.  `cron` spinning is the yearless MM58167 giving
the machine a 1986 date.  The one genuine anomaly was **`ld` taking SIGILL
about once in eight compiles, with the identical compile succeeding on retry**,
and it has not been seen since `7dae188`.

**The stability measurement that matters is a build, not a boot.**  A MultiBus
`div50` bitstream carrying both clock-crossing fixes compiled **53 gcc 2.6.3
sources over several hours with swap in use and no `ld` failure** -- 13 objects
of 100 KiB or more, the largest 216312 bytes, so better than two hundred
short-lived processes with real paging and sustained NFS writes behind them.
Against the one-in-eight rate `ld` used to fail at, `(7/8)^53` is 0.08%.  That
prior is soft -- it came from a single failure in about eight attempts -- but 53
clean compiles is far stronger than any boot fingerprint, which only ever
replays one fixed instruction sequence.

Two caveats worth keeping.  The board was running an **ILA** build, and
placement alone has flipped outcomes twice in this file, so a plain `div50`
bitstream has not had the same workout.  And the run ended on a failure that is
**not** the machine: `cc` gave `regclass.c", line 842: compiler error:
expression causes compiler loop: try simplifying`, which is SunOS's pcc-era
compiler reporting its own limit on an expression tree.  The discriminator is
free and worth applying to anything similar -- an identical failure on retry is
software, a failure that moves is the machine, which is exactly how `ld` was
told apart from `lpd` in the first place.

Two ways a capture lies about interrupts, both met here.  A 4096-sample window
at 20 MHz is **205 us**: a 100 Hz interrupt is 10 ms apart, so an absent level 5
in a plain capture means nothing -- use `iackseq`, which qualifies on FC 7 so
4096 samples are 4096 acknowledges.  And a window that runs on past the event
is mostly the machine *idling in the monitor afterwards*, where an unarmed
counter reads 0 because that is correct.

## Traps that have already cost time

**The read-side clock crossing is clean, measured with a counter rather than a
capture.** `syn/vio_read.tcl` reads the adapter's crossing counters over a VIO
-- the Xilinx equivalent of the DECA's In-System Sources and Probes, fitted with
`ILA=1`. After two full `patwr` passes (1 MiB):

```
  reads       306,520,938   read acknowledgements
  pattern       2,097,148   ... whose word matched the pattern before crossing
  corrupted             0   ... and did not match after
```

`pattern` is the control and it is large, so the check demonstrably sees the
pattern -- which is exactly what the ILA attempt could never show. Zero
corrupted, on a workload that reliably produces bad words, clears
`rd_lane -> wb_dat_o`.

**And the write crossing is clean too, so both hops in the adapter are out.**
`req_dat` is latched in the Wishbone domain and read combinationally in the
memory clock domain -- the mirror of the above, and the one that fitted every
observation, because a word corrupted there would be stored faithfully and read
back faithfully for ever after. With the counters widened to 32 bits and four
`patwr -u` passes (2 MiB):

```
  read crossing    pattern 2,097,148   corrupted 0
  write crossing   pattern 1,056,836   corrupted 0
```

At the measured fault rate a million checked write words expects about sixteen
corruptions. Zero, with a control that large, ends it: **neither clock crossing
in the adapter is the fault.**

Two mistakes the controls caught, and they are the reason the controls exist.
The first write check gated on `wb_sel_i == 4'hF` -- but **the 68010 is a 16-bit
bus**, so the bridge never issues a full 32-bit write and the check was dead,
reporting `pattern 0` beside `corrupted 0`. The second read the control as
`0x102f` and called it clean: 4143 words expects 0.13 hits and proves nothing,
which is what forced the counters from 16 bits to 32. **A zero is worth exactly
as much as the control beside it.**

**What is left is the bridge itself.** `sun2_wishbone_bridge` is single-domain
-- one clock, one `always` block, no synchronisers -- so it was never a CDC
suspect, and its data path has still never been checked: `P_DATA_IN` ->
`wb_dat_o` on a write, `wb_dat_i` -> `P_DATA_OUT` on a read. A word damaged
there is invisible to every adapter counter above, because it arrives already
wrong and so never sets `pre_ok`.

* **An ILA capture window is 205 us and a disk workload is minutes, so the
  trigger has to do all the work -- and a trigger nobody has validated is worth
  nothing.** The crossing check in `wb_to_mig_ui` (`xchk_bad`, ILA mode `xchk`)
  fires only on a word that matched `tools/patwr -u`'s pattern *before* the
  crossing and not after, which is elegantly self-gating and useless until you
  can show it ever sees the pattern at all. It never triggered over 14 minutes
  and four passes -- and the control (`xpat`, trigger on the pattern's shape
  alone) shows why that proves nothing: of 293 captured transactions, 292 were
  CPU instruction fetches (`4e75`, `206f`, `226f`) and the one pattern-shaped
  word was `80008000`, both halves index 0, which the encoding cannot produce.
  A coincidence, not the pattern.

  Two further ways the same experiment was void before that. **Vivado takes
  about 90 seconds to start and arm, and a `patwr` pass takes 60**, so the first
  two captures armed *after* the run they were meant to watch had finished; a
  long pass (`patwr ... 8`) is needed so the workload outlives the arming. And
  `xchk_exp` is computed for every transaction, so it looks pattern-shaped
  beside data that is plainly 68010 code -- it means nothing unless the
  transaction really was reading the pattern.

  The instrument this wants is a **counter read once at the end**, not a
  capture: the DECA's In-System Sources and Probes did exactly that, and the
  Wukong equivalent is a VIO, which this tree does not yet have. An ILA cannot
  count.

* **A probe narrower than its concatenation truncates in silence, and the
  arithmetic is easy to get wrong.** `probe_width` was set to 366 for a
  concatenation of 382 bits -- two 8-bit fields forgotten in the sum -- and
  every field shifted. The readout was not obviously broken; it was plausible
  nonsense, reporting `bridge loads 0` beside `late_load 39240` and `reads
  issued 0` beside `responses 41467`. Nothing warns, at any stage. Add up the
  widths in the comment beside the concatenation and check the total against
  `probe_width` each time one changes.

* **An instrument with no testbench, and a signature that looked plausible.**
  `sun2_blktrace` folds each sector as it passes so a block can be identified by
  its contents. `Inputs/Wish5380/doc/block.md:58` says `buf_rdata` answers
  `buf_addr` **one cycle late**; the first version folded it in the cycle the
  address changed, so every write-side signature was a fold over a byte sequence
  shifted by one. Nothing about that looks broken -- it yields ordinary-looking
  16-bit values that are simply not the block's -- and it reported 127 of 171
  sectors of a *correctly copied* file as corrupt, and named two sectors of
  other files as the intruders. `cmp` on the machine then put that file's first
  difference at byte 4385, past every sector the trace had condemned.

  Two things saved it from being believed. The LBA half of the same entry does
  not depend on that timing, and it was internally consistent -- thirteen blocks
  in the right order at the addresses 4.2BSD predicts -- so the two halves
  disagreed with each other. And a 16-bit fold over ~800 writes against ~2000
  candidate sectors is expected to collide about 24 times by chance, which is
  more than the "evidence" found. `tools/blktrace_match` prints that number
  above its output now, and `make -C sim blktrace` is the test the module
  shipped without: 23 checks, four mutations tried and all four caught -- the
  fourth only after the test was extended, because recording the key at
  `blk_done` instead of latching it at `blk_start` passed the first twenty.
  Writing the testbench also found a second defect the board had not yet shown,
  where a read's between-strobe idle cycles were folded as bytes of their own.

* **A test harness that runs a stale snapshot when the compile fails, and this
  one did, for every unit test.** `sim/run_unit.sh` guarded each step with
  `if xvlog ... | grep -E '^(ERROR|CRITICAL)'; then exit 1; fi` -- and xvlog
  writes its diagnostics to **stderr**, which the pipe does not carry. grep saw
  nothing, the guard passed, and xsim then ran whatever snapshot the last
  successful build had left. Two compile errors in one session were reported as
  "9 checks, 9 passed, PASS" from an older binary before this was chased down.
  All 23 sites redirect stderr into the guard now. The failure mode is a *green*
  test run, which is the worst one available.

* **MAX 10 puts initialised memory in logic unless told not to, and says
  nothing.** Without
  `set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE COMP IMAGE WITH ERAM"`
  Quartus implements every initialised ROM in gates. Measured on this design,
  three arms, everything else equal:

  | | logic elements | memory bits |
  |---|--:|--:|
  | ERAM off | 56,092 (**113%**, does not fit) | 151,296 |
  | ERAM on, `bootrom idx[14:0]` | 45,897 (92%) | 397,056 |
  | ERAM on, `bootrom idx[13:0]` | **22,938 (46%)** | **659,200** |

  Every figure decomposes exactly: 151,296 is the MMU maps plus the 82586, the
  two *uninitialised* RAMs. So the assignment gates precisely the initialised
  ones -- and both the boot PROM and RD68011's microcode store are initialised.

* **A case statement wider than its labels is not a ROM, to Quartus.**
  `bootrom.v` declared `idx[14:0]` -- 32768 entries -- while only 16384 are
  generated, because the PROM is 32 KiB, and `sun2_fpga.v` padded the top bit
  with a constant zero. A case that does not cover its selector is *incomplete*,
  and Quartus declines to infer a ROM from an incomplete case, silently. Vivado
  infers it either way, which is how a 15-bit index on a 14-bit ROM survived for
  years. Synthesis went from 3h 04m to 5m 11s when it was narrowed, because
  Quartus stopped grinding a 16384-way multiplexer into gates.

* **Quartus stops at 5000 iterations of a constant loop, and Vivado says
  nothing.** `sun2_clobber`'s table is 16384 entries zeroed by an `initial`
  loop, which is the only way Verilog-2001 has to initialise an array; Quartus
  refuses it outright -- `Error (10106): loop must terminate within 5000
  iterations` -- and then cannot elaborate the module that instantiates it. The
  module had been on the Wukong for three bitstreams before the DECA was rebuilt
  and met it. `syn/quartus.tcl` sets `VERILOG_CONSTANT_LOOP_LIMIT 65536`: it is
  the tool's limit on unrolling, not a statement about the design, so raising it
  is better than writing the initialisation a second way for one vendor. Assume
  any new array wider than 5000 entries needs it.

* **`$random` in an unguarded `initial` is an error on one vendor and ignored on
  the other.** `ctx_reg.v` and `gen8bit_reg.v` powered up random on purpose --
  neither register has a reset on a real Sun-2 -- and Quartus stops with Error
  10174 where Vivado shrugs. They are behind `SUN2_SIM` now.

* **A JTAG UART clocked slower than TCK duplicates bytes.** The DECA's console
  was on `clk_serial` at 4.915 MHz for good reasons -- the SCC's own domain, an
  exact 512-clock bit period, no dependence on `CPU_HZ` -- and every one of them
  was irrelevant: `alt_jtag_atlantic` crosses into the TCK domain, which
  `quartus_sta` reports at 10 MHz, and a slower user clock made the host read
  each byte twice and out of order. Five hypotheses about the RTL failed before
  in-system probes showed the design doing exactly one receive, write, read and
  transmit per byte while the host displayed ten characters for eight. Moving to
  `cpu_clk` at 12.5 MHz fixed it with the counters unchanged. A design writing
  sequentially into a FIFO cannot produce out-of-order output; only something
  downstream can.

* **"Hardware-verified" and "builds with today's tools" are different claims.**
  `Inputs/BrianHG-DDR3`'s own DECA project runs its DDR3 at 400 MHz and reports
  100% of timing met. On Quartus 25.1 that build is refused outright --
  `Error (176060): ... DDR3_CK_p at data rate 800 Mbps exceeds the maximum
  allowed data rate of 600 Mbps for Differential 1.5-V SSTL Class I` -- on the
  same device, the same speed grade, the same I/O standard, with no waiver on
  their side either. Theirs was Quartus 17.1. 250 MHz is used instead and costs
  nothing: a 12.5 MHz Sun-2 wants a few MB/s against about 1000 MB/s raw.

* **A write mask's polarity does not travel between controllers.** MIG's
  `app_wdf_mask` is active high meaning *do not* write this byte; BrianHG's
  `CMD_wmask` is active high meaning *do*. Carrying `wb_to_mig_ui`'s `mask_for()`
  across unchanged would have written every byte the CPU did not ask for and
  none of the ones it did, on sub-word accesses only -- which the boot PROM makes
  constantly. `make -C sim decaddr3` fails all ten checks under that mutation.

* **The DP83620's speed bit reads the opposite way round from instinct, and its
  straps are shared with the FPGA.** `PHYSTS` bit 1 is named "Speed10" and is
  *set* for 10 Mb/s; read backwards, a healthy 10 Mb/s Sun-2 reports 100 and
  nothing complains. Separately, `MII_MODE` is strapped on the RX_DV pin, which
  the DECA runs straight to the FPGA with no external pull -- so the part's
  internal pulldown decides and the board is MII, which the schematic settles in
  one look. But **before the FPGA is configured its pins are tri-stated with a
  weak pull-UP**, and in that window `NET_RESET_n` floats high too, so the PHY is
  not held in reset and latches RMII. What saves it is the reset the board
  asserts once configured, which re-latches the straps. That recovery is
  load-bearing; the sequencer clears the bit anyway.

* **The M9K holds 8192 usable bits, not 9216.** The extra 1024 are only
  reachable at widths 9, 18 and 36. Budgeting a MAX 10 at 9216 is 12% optimistic
  and turns a decision about what fits into a wrong one.

* **The boot PROM boots in far less memory than the tree claimed, and cannot
  netboot in any of it.** `sun2_config.vh` said "the PROM is happy with as little
  as 256 KiB"; measured, a VME machine reaches the monitor prompt at every size
  down to **32 KiB**, on both cores. But the boot loader's buffer is at
  `0x0a0462`, 640 KiB up, so a small machine takes a protection violation there
  and drops to the prompt -- which is the eleventh bus error in those runs and
  the reason on-chip memory can run the monitor and never SunOS.

* **Configuring the FPGA tears down the JTAG console, so a boot cannot be
  watched from its first byte unless the reset is pulsed first.**
  `tools/deca_reset.tcl reset` *then* `juart-terminal` works; the other order
  captures nothing, because ISSP and juart-terminal cannot both hold the chain.
  One untried ordering was generalised into "the two are unusable together", and
  a mechanism to hold the machine in reset until a console attached was built on
  that premise, did not work, and was thrown away. The PROM spends seconds
  testing 7 MiB before printing anything worth reading, which is the whole
  margin needed.


* **A chip-wide register written through the other channel.** The Z8530's WR2
  and WR9 belong to the chip, not to a channel, and may be written through
  either one. `Inputs/z8530_scc/z8530_scc.sv` had both commented out of its
  channel-B case -- falling into `default:`, pointer reset, data dropped, no
  error -- with the comment stating the correct behaviour still sitting above
  them. WR9 bit 3 is the Master Interrupt Enable, and `int_n` is that bit
  ANDed with every pending source, so the SCC could not raise a level 6
  interrupt at any point in the life of the machine. SunOS writes it through
  channel B: `zsattach` (`sundev/zs_common.c:196-216`) walks the two ports and
  leaves its pointer on port B before `ZWRITE(9, ZSWR9_MASTER_IE + ...)`.
  `patches/z8530_scc/0001` restores the two lines.

  **Nothing here could have caught it, and three things separately hid it.**
  The PROM polls and never touches WR9. Kernel `printf` goes out through the
  PROM's `putchar` vector, so a machine with a completely dead SCC interrupt
  prints its whole autoconfig -- see the console note above. And WR9's *reset*
  commands are decoded separately and do work from channel B, so
  `ZWRITE(9, ZSWR9_RESET_WORLD)` took effect and the chip looked healthy.

  The model's own testbench is the sharpest part. It has 22 tests, it covers
  interrupts thoroughly, and it passes -- because **every** WR9 write in it
  targets channel A (`z8530_scc_tb.sv` lines 316, 980, 1012, 1032, 1101, 1137),
  as does every WR2 write. A test that exercises a feature through one path
  says nothing about the other, and the path that matters is the one the real
  software takes. `make -C sim scc` exists for that reason: it drives the chip
  over the *Sun-2's* bus protocol (`cs_n` tied low, `rd_n`/`wr_n` selecting,
  where upstream strobes `cs_n`), writes every chip-wide register through
  channel B, and replays `zslevel6` (`sundev/zs_asm.s:24-51`) rather than a
  plausible dispatch. It carries a control that writes MIE through channel A,
  so a failure says which half is broken.

* **A faster CPU clock is a slower simulation.** `CPU_HZ=40000000` is a real
  configuration — same bus-error count, byte-identical console — and boot to
  the prompt costs **807 s of wall clock against 602 s** at 12.5 MHz, for 0.70 s
  of simulated time against 1.63 s. xsim's cost tracks **cpu_clk edges**, not
  simulated time, and clk40 (39.3216 MHz, fixed by the baud rate) clocks only
  the SCC. Simulated time fell by 2.3x where the clock rose by 3.2x, because
  ~270 ms of the boot is the PROM talking at 9600 baud and a faster CPU only
  spins harder waiting for it — so cpu_clk edges rose 37% and wall clock 34%.
  Anything bounded by real time rather than by instructions gets *worse*, and a
  SunOS boot has more of that than a monitor boot, not less.
* **A byte-addressed register pair needs byte strobes.** The two context
  registers share a word, and `ctx_reg.v` wrote both halves on any write. A
  68010 byte write drives the byte on *both* halves of the data bus, so
  `setusercontext(1)` moved the supervisor context too and SunOS died about
  0x48 bytes into `_start` — bus error on the instruction fetch, bus error on
  the stack frame, double fault, CPU halted. Nothing caught it for the whole
  life of the project because the PROM keeps the two contexts equal.
* **An unconnected input on a device model is an X in a status register.** The
  console SCC left `ctsa_n`, `dcda_n`, `synca_n` and all of channel B open, and
  RR0 bits 5, 4 and 3 are exactly those pins — so every read of it came back
  `00xxx100` while the keyboard SCC, which ties all of them, read `00000100`.
  Nothing on the board drives them (Architecture Manual 6.7, "Control lines are
  not used", and no drivers fitted), so the fix is to hold them deasserted, as
  the keyboard instance always had. The asymmetry inside one file is what gave
  it away; grep any new device instance for empty port connections on *inputs*.
  This is what caused the spurious `Abort' that ends a SunOS boot from nowhere
  — measured, not argued: the same run aborts at 3.259 s with the pins open and
  does not abort through 5 s with them tied, nothing else changed.
* **The monitor's abort is one byte, and it is at 0x5B6.** `g_debounce`. The
  NMI handler reads the console SCC's RR0 every tick, masks it with
  `ZSRR0_BREAK`, and `ef043c: cmpb 0x5b6,%d0 / beqs / moveb %d0,0x5b6 / beqs
  abort`. `d0.b` is `RR0 & 0x80` and bit 7 is clean, so the second branch is
  *always* taken once the first falls through: the machine aborts to the
  monitor exactly when that byte is not zero. An `Abort at <pc>` out of nowhere
  is therefore a byte-value question, not an interrupt question, and
  `+watch_addr=5b6 +abort_pc=ef0452` is the instrument for it: reads of that
  byte come `from ef0440` and writes `from ef0446`, which is how you tell the
  debounce apart from anything else touching it.

  Do not conclude from "the X bits are 5, 4 and 3 and `ZSRR0_BREAK` is 0x80"
  that the floating pins cannot reach this. That argument is wrong — the
  experiment above falsifies it — and the path by which the X reaches the
  branch condition has not been pinned down. Consecutive ticks store 0x80 and
  then 0x00 into `g_debounce` when `RR0 & 0x80` should be steady, which is what
  an indeterminate value in the compare looks like from outside. Treat an X
  anywhere near a status register as able to reach any conditional derived from
  it, whatever the mask says.
* **A kernel trap dump early in boot costs more simulated time than the boot.**
  `showregs+0x29a` is `32000000 >> _cpudelay` iterations of a busy loop, and
  `_cpudelay` is still 0 that early in `startup()` — about 17 s of simulated
  time at 40 MHz, hours of wall clock, spent between two printed lines. It
  looks exactly like a hang. Check the PC against `showregs` before killing a
  run that has stopped producing output.
* **A device model clocked on a strobe *level* acts once per clock, not once
  per bus cycle.** `ttl_am9513.v` had `assign write = ~WR_n & ~CS_n;` with
  `always @(posedge clk) if (write)`, and `sun2_fpga.v` drives `WR` for the
  whole data-strobe portion of a 68010 cycle with `CS_n` tied low — so one CPU
  write ran the body three times and the Am9513's data pointer auto-incremented
  under it. The monitor's own NMI setup (`sunmon.c:481`: one `CLK_ACC_MODE`,
  then mode and load written back to back) therefore left `0x0C22` in counter
  1's mode, load **and** hold registers, the load value 7680 never arrived, and
  the NMI ran at 98.9 Hz instead of 40 for the whole life of the project.
  SunOS's own clock escaped it because `startrtclock()` re-points with
  `CLK_LLOAD` before writing the load value; only the auto-increment idiom is
  hit, which is why nothing noticed. Measured two independent ways:
  `tools/clkprobe` reading counter 1 back from a boot block under both cores,
  and the level-7 count of a SunOS boot — 1199 acknowledgements in 12.0 s is
  99.9 Hz against the 98.9 the corrupted load value predicts. The fix is one
  edge detector, acting on the *leading* edge because the 68010 drives data in
  S3 and asserts the strobes in S4. Grep any device model for a level-sensitive
  strobe used inside a clocked block; this is the second bug of the shape in
  this file.

  Correcting it changes the NMI rate and therefore the interrupt counts in
  every recorded run — the MultiBus reference went from 13 level-7
  acknowledgements to 5 — while the bus error count, its sequence and the
  console text are all untouched. Measured, not assumed.

* **A bridge that serves two masters must know whose cycle it is answering.**
  `sun2_wishbone_bridge` sits on the muxed 68010 wires — `top_fpga` puts the
  CPU and DVMA on the same pins deliberately — and `mig_arb` allows one
  transaction in flight with nothing tagging it. It took any `wb_ack_i` as an
  answer to whatever cycle was on the bus, so an acknowledgement still
  resolving from the previous cycle, possibly the *other* master's, reached
  DTACK and the CPU latched that transaction's data. It also re-requested:
  `MATCH_ANY` stays asserted for the rest of a cycle and `~wb_ack_i_prev`
  suppressed the request for exactly one clock. A cycle owns its transaction
  now — `issued` qualifies the ack and the data latch, `done` stops the repeat.

  **A boot cannot show this and a data check can.** The VME boot splits 67
  longword reads with a master's cycle and completes every time; with the bug
  restored, `tb_sun2`'s memory check reports 10 corrupt reads out of 295,827 on
  that same boot. Pass/fail on a boot is a coarse instrument for corruption
  that is usually survivable — which is why this was found on the board first,
  and why the check exists now.
* **`dbg_data` lags by one transaction, and so does anything else watching
  `P_DATA_OUT`.** It is a register the bridge loads on acknowledgement, so
  during a bus cycle the wire carries the *previous* memory transaction's data
  and this cycle's own arrives during the next one — including a master's,
  which loads it too. The CPU is not getting stale data; the observation is
  stale. Every ILA capture needs reading with that shift, and four versions of
  a memory checker reported confident nonsense before it was accounted for:
  279,715 "corrupt" reads on a machine that boots, then a mapping that fitted
  neither half, then a 7% residual that was the expectation being read after
  the location had been rewritten. What caught each one was the machine under
  test demonstrably working. The PROM's page-sizing loop is the clearest
  demonstration: a read of page 006 reports 0005, 007 reports 0006, 008 reports
  0007.
* **A port left off an instantiation is a feature that reaches the board
  dead.** `wukong_top.sv` named every port of `top machine (...)` except
  `fb_video_en`, so Vivado invented a one-bit undriven wire, tied it low, and
  `fb_scanout`'s `visible = in_x && in_y && ven_s2` was constant 0 in every
  bitstream this project has ever produced. The frame buffer could not have
  displayed at any resolution.

  **Nothing in the flow could catch it, and that is the lesson.** `tb_sun2`
  drives `top_fpga` directly -- one level *below* the layer with the mistake in
  it, where the port is correctly wired -- so the simulator faithfully wrote
  0x8000 to the video control register and read it back. `tb_fb_scanout.sv`
  forces `video_en = 1'b1`, so the unit test and every `make -C sim
  screenshot` rendered a perfect picture. And `wukong_top.sv` is only ever
  built for synthesis, where an undeclared identifier is warning `Synth
  8-6901` rather than an error. Three independent checks all looked past the
  one wire.

  `syn/build.tcl` now promotes `Synth 8-6901` to an ERROR, so an implicit net
  fails the build. When a board symptom survives a simulation that says the
  RTL is right, suspect the layer the testbench does not instantiate -- and
  compare the module's port list against the instantiation mechanically rather
  than by eye. It is one `get_ports`-style diff and it found this in seconds
  after a day of not finding it.
* **1080p60 is not a mode this design can drive, and the tools said so all
  along.** `test/hdmi` -- the same `hdmi` block, the same OBUFDS, the same
  pins, colour bars and nothing else -- displays 1080p60 on a Wukong V1. The
  full machine, with the CPU, the MMU, DDR3 and the Ethernet in the same die,
  does not: the monitor sleeps, or syncs and tears. The discriminator is the
  TMDS serial clock, and it was measured rather than argued -- the full design
  drives 720p60's 371 MHz and 1280x1024's 540 MHz perfectly on the same board
  and the same monitor, and only 742 MHz fails.

  742 MHz breaks two ratings: a 7-series BUFG is good for 628 MHz and an
  OSERDESE2 for 680. Both appear in `report_pulse_width` as `Min Period`
  violations -- **not** in `report_timing_summary`, which is why a check on WNS
  and WHS alone passed them for the life of the project. Vivado reports only
  the worst resource per clock, so the OSERDES one stays invisible until the
  BUFG is dealt with. `syn/build.tcl` gates on both now; `ALLOW_PW=1` builds
  anyway and prints them.

  So `HDMI_MODE=1280x1024` is the answer, added to the library as
  `patches/hdmi/0001`: 1688x1066 at 108.125 / 540.625 MHz, VESA DMT rather than
  CEA, which fits the Sun's 1152x900 screen with a 64x62 border. 1080p30 would
  have been the obvious fix and is not one -- this bench's monitor rejects
  30 Hz outright -- and no CEA mode with room for 900 lines runs slower than
  148.5 MHz. Two smaller things fell out of the same hunt: **`HDMI30=1` was
  appended by `build.tcl` and read by no file in the tree**, so a "1080p30
  shows nothing" result was really a 1080p60 one; and **`VIDEO_ID_CODE 34` does
  not work**, not because the library lacks the case -- 34 shares code 16's arm
  -- but because `BIT_HEIGHT` is 11 bits *only* for code 16, so the same
  `assign frame_height = 1125` silently becomes 101 under 34.
* **A define that reaches nothing builds cleanly and hides a whole subsystem.**
  Losing `SUN2_FB` from `build.tcl` in a refactor gave a bitstream with no
  frame buffer, no HDMI, no keyboard SCC and **no driver at all on
  `extra_leds0`** -- because the FBDEBUG assignment lives inside `ifdef
  SUN2_FB` while the `ifndef SUN2_FB_DEBUG` guard still suppressed `todebug`.
  On the bench that read as three unrelated faults, and it arrived the same
  hour as a real power glitch, which made it look like hardware. Every gate in
  the flow passed, including the pulse width one -- with no HDMI clock in the
  design there is nothing to violate, so a vanished frame buffer reports
  *clean*. `build.tcl` echoes `== defines: ... ==` now and hard-fails when
  `FB=1` leaves no HDMI clock generator in the netlist.
* **The frame buffer is exempt from the bus timeout, and has to be.** Memory
  was already exempt because DDR3 is slower than the twelve clocks `C_S24`
  allows. The MultiBus frame buffer aperture is answered by the same Wishbone
  bridge out of the same DDR3, and was not -- so the monitor's display probe
  at `0xEC0000` timed out, `g_fbthere` went 0, and `sunmon.c:396` left the
  console on the serial port with a perfectly good display fitted.
  
  It is a one-clock race, and the ILA measured it on the board: `C_S24` fires
  on clock 12 and DTACK arrives on clock 13, the two landing on the same edge.
  AS to DTACK here is bimodal, 8 clocks or 13, so the fast case always worked
  and the slow case never could. Simulation could not show it at all until
  `MEM_LATENCY=13` -- at 7, which is what `make -C sim migddr3` measures for a
  Wishbone read, the probe still beats the timeout.
  
  Anything else that lands on the Wishbone bridge without an exemption meets
  the same wall. The exemption carries memory's bargain with it: an access up
  there that is never answered now hangs instead of raising a bus error.
* **The bus error register held the first error for ever, and SunOS reads it
  without writing.** `mon/h/buserr.h` documents the Sun-2 register as keeping
  only the first of several errors, cleared when software *writes* it, and the
  RTL implemented exactly that. Beside the one write the PROM ever does,
  `mon/kernel/trap.s:104` says "FIXME, remove this when latch is gone" -- and
  it went: `getbuserr` (`sys/sun2/locore.s:972`) is a bare `movsw
  BUSERRREG,d0` and no file in the SunOS tree writes the register. So the
  first bus error of a boot -- a PROM device probe, a timeout on a valid page,
  `0x84` -- was still sitting there when the kernel took a protection fault
  seconds later, and `trap.c` reads `BE_TIMEOUT` as "do not try to recover".
  That is the whole SunOS panic creating pid 1. A read re-arms the latch now,
  which keeps the documented behaviour for a handler that faults on its way to
  reading, and a new error outranks both so nothing is lost. All four boots
  are unchanged: MultiBus 22 and 274 on both cores with a byte-identical error
  sequence, VME 10 and 312 on Suska, 11 and 319 on RD68011.

  How it was found is the point: the ILA caught that cycle on the board with
  `PROTERR` set and `TIMEOUT` clear, which proved the MMU right and moved the
  search to the one thing between the MMU and the kernel. No simulation was
  run to find it.

  **Confirmed on hardware.** With the fix the kernel takes that fault
  silently -- no message, no panic -- and the ILA then finds the CPU
  executing kernel text in a tight loop at `_swtch+0x18`, the scheduler's
  idle loop. SunOS 4.0.3 creates process 1 and runs its scheduler on this
  machine.
* **An empty module is a black box, and only an ILA notices.** `tolog` -- the
  VCD hook wrapped round TxDA -- has no body, and Vivado calls that a black
  box; `opt_design` refuses to run on a design containing one. Every build for
  the life of the project got away with it because synthesis pruned the
  instance, which has no outputs, before DRC could see it. Marking debug nets
  keeps hierarchy that would otherwise have been optimised through, so the
  first `ILA=1` build died at `opt_design` naming a module with nothing to do
  with the ILA. It is behind `SUN2_SIM` now. The same shape is waiting in any
  other module that exists only to be looked at.
* **A debug hub cannot be told it runs at 20 MHz.** `C_CLK_INPUT_FREQ_HZ`
  takes 25 MHz to 650 MHz and rejects anything slower, and the hub Vivado
  inserts for an IP ILA takes the ILA's clock -- `cpu_clk`. It runs on
  `clk50_g` instead, which is legal because a hub and its cores may be in
  different domains, and `implement_debug_core` must run after the change or
  `place_design` stops with "needs to be (re)generated". Declaring a false
  25 MHz would also have built, and the thing it lies about is exactly what
  decides whether the hub answers JTAG.
* **`xvlog` is stricter than Verilator and Yosys about declaration order.** A
  wire declared after its first use compiles elsewhere and fails here.

  And the two tools disagree in the dangerous direction. `xvlog` makes it an
  **error**; Vivado makes it warning `Synth 8-6901` and invents an implicit
  undriven one-bit wire. So a change that is only ever built for synthesis can
  reach a board with the new term silently dead -- which is exactly what the
  frame buffer's timeout exemption did on its first build, `~MATCH_FB` against
  a wire nothing drove. Simulation refusing to compile is what caught it.
  Build the simulator too, even for a change that looks synthesis-only.
* **A clock that only *sometimes* gets a BUFG.** `clk50` drives the reset
  assembly and the PHY reset sequencer as well as the MMCMs. Vivado used to
  infer its global buffer, and inferred one for the MultiBus build but not the
  VME build of the same commit — 13 of 32 BUFGs either way, so not a budget
  limit. On fabric routing it carried 0.93 ns of skew and a same-clock hold
  path failed by 270 ps, in a machine that had nothing to do with the change
  that triggered it. It is instantiated explicitly now; do the same for any
  clock that reaches flip-flops rather than just an MMCM.
* **XDC ordering is silent.** `set_clock_groups` naming a clock that
  `create_clock` has not yet defined gets `get_clocks` returning nothing and the
  group is dropped with no warning — which surfaces later as a real hold
  violation on a crossing that should have been ignored.
* **`MEM_LATENCY` is not part of the simulation run directory's name.** Two
  latency variants of the same machine therefore share one directory and
  collide, which matters because comparing latencies is the only way to
  reproduce a DDR3-speed failure -- see the frame buffer timeout below. Run
  them one after another, and do not queue the second on a `pgrep` for the
  first: the check catches a gap between processes and starts anyway.
* **Two simulation runs of the same machine clobber each other.** Each machine
  gets its own directory under `build/sim/`, so different machines can run
  concurrently, but the same one twice cannot — the second recompiles the
  snapshot while the first is executing and xsim dies with a kernel fatal that
  looks like a design fault.
* **Simulation until recently used a zero-latency memory.** `make -C sim migddr3`
  measures the real path: a Wishbone read is 7 CPU clocks through MIG.
* Vivado litters whatever directory it runs in, so `syn/` runs it from
  `build/syn/vivado/work-<board>`.  Both flows land under `build/syn/`, one
  directory per vendor: `vivado/` for the Wukong, `quartus/` for the DECA.
