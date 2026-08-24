# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A replica of a Sun-2 workstation in an FPGA: MC68010, the Sun-2 MMU, an Am9513
timer, Zilog 8530 SCCs and (on VME machines) an Intel 82586 Ethernet, booting
the real boot PROMs to the monitor prompt. Target board is a QMTech Wukong,
V1 or V3 (XC7A100T, FGG676) with DDR3 main memory.

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
submodules (`git submodule update --init` after a fresh clone). Never edit in
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

## Traps that have already cost time

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
