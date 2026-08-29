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

**What the DECA does not have, and what follows.** No hardware UART, so the
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

**Open:** the console's host-to-machine direction swaps adjacent bytes --
`ABCDEFGH` arrives as `@CBEDGFI`. Output is byte-perfect. It reproduces without
loopback, `tb_deca_console` passes on the same RTL, and the event counters are
the place to start.

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

It **chains**: CHEN in an IOPB's command byte says to follow that IOPB's Next
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

**`Inputs/sunos-34-src` is the boot PROMs' own source.** `sun/prom_monitor/msun/`
builds the MultiBus monitor and `rsun/` the VME one, from the same files behind
`#ifdef VME`. Reach for it before guessing at what a PROM is doing —
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
| `FB=1 MB_ETHER=1` | **18** |
| `XY450=1` with an image, stopping at the boot block | **10** |
| `XY450=1 MB_ETHER=1 FB=1` with an image, `TIMEOUT_MS=8000` | **8** |

One error for the display's probe at `0xEC0000`, three for the Ethernet card,
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
  `build/syn/work`.
