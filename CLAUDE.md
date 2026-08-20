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
tools/mkxydisk -o build/disk/xy0.img       # a labelled, bootable disk image
tools/ufsread IMG cat /vmunix -o OUT      # pull a file out of a 4.2BSD image
tools/pcsym OUT 63c8e 40b6                # 68010 PCs -> kernel symbols
tools/fbshot                              # render the screen mid-run (FB=1)
make -C tools beprobe                     # a boot block that measures a bus error frame
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

RD68011 is early, and nothing about the Sun-2 should ever be changed on the
strength of what one core does and the other does not.

It is nevertheless the only thing that has taken SunOS past `startup()`. With
`XY450=1` and no video board it boots 4.0.3 to the VM page-pool
initialisation, and its 138 bus errors decompose as ten device probes plus 128
repeats of `A=701000` — `poke()` walking every page of the DVMA bus window and
recovering from each fault, which is exactly what the kernel asks for and what
Suska does not do. That is an observation about the cores, not a licence to
change anything here: the machine below the instantiation is the same file in
both builds, and the MultiBus fingerprint is measured against Suska.

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

Nothing here has run on a board. `BRINGUP.md` holds the staged hardware
procedure and the debugging tooling deferred until something misbehaves — the
ILA among it. Add to that list rather than building diagnostics speculatively.

## Architecture

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

The VME 2/50 boots to the prompt with **11 bus errors** at `MEM_MIB=1`, all but
one of them the same kind of probe — the frame buffer at `0xEC0000`, MBMEM at
`0xF00000`, both Xylogics addresses, and two more, each probed twice. It runs a
different PROM image (`rsun`), so it is an independent check on shared logic and
worth running for that reason alone.

**`make -C sim check` does not boot anything.** It is `check_console.sh` against
whatever `console.log` is already in the run directory, so it will happily pass
against a log from days ago — that cost a wrong "VME is fine" here. Run
`make -C sim xsim MACHINE=vme MEM_MIB=1` first, then `check`.

The one protection violation left on either machine is `A=EF00D2 FC=6` at about
6.8 us, before reset has finished, with the page map still reading `type x page
xxx`. It is a power-on artefact, identical on both machines, and not yet chased.

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
* **`xvlog` is stricter than Verilator and Yosys about declaration order.** A
  wire declared after its first use compiles elsewhere and fails here.
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
* **Two simulation runs of the same machine clobber each other.** Each machine
  gets its own directory under `build/sim/`, so different machines can run
  concurrently, but the same one twice cannot — the second recompiles the
  snapshot while the first is executing and xsim dies with a kernel fatal that
  looks like a design fault.
* **Simulation until recently used a zero-latency memory.** `make -C sim migddr3`
  measures the real path: a Wishbone read is 7 CPU clocks through MIG.
* Vivado litters whatever directory it runs in, so `syn/` runs it from
  `build/syn/work`.
