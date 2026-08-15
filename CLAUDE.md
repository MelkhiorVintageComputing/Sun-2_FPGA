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
make -C sim board [BOARD_MEM=ddr3]        # the machine as it will be on the Wukong
make -C syn ip [BOARD=v3]                 # generate the MIG DDR3 controller (once per board)
make -C syn bitstream [MACHINE=vme] [CPU_HZ=40000000] [BOARD=v3] [XY450=1]
tools/mkxydisk -o build/disk/xy0.img       # a labelled, bootable disk image
```

Simulation knobs that matter, all on `make -C sim xsim`:

| knob | effect |
|---|---|
| `MEM_MIB=1` | the first one to reach for — the PROM writes every installed byte, so 7 MiB costs seconds of simulated time and 1 MiB costs under half of one |
| `ROM=fast` | shortens the PROM's RAM-init pass 64-fold (MultiBus only) |
| `MEM_LATENCY=7` | memory as slow as the real DDR3 path; 0 (the default) is a one-cycle memory |
| `MB_ETHER=1` | MultiBus only: fit the Sun-2 Ethernet card in the cage. Off by default, because the 23,629 fingerprint is the machine *without* it |
| `FB=1` | fit the frame buffer, either machine. Changes what the machine looks like — with a display the console goes to the screen and the serial port falls silent. On MultiBus it also builds the keyboard/mouse SCC, which is on the video board |
| `XY450=1` | MultiBus only: fit the Xylogics 450 disk controller. Needs `MEM_MIB=1` or more and `-testplusarg blk_image=<abs path>`; `tools/mkxydisk` writes one |
| `TIMEOUT_MS=` | simulated milliseconds before giving up |
| `XSIMARGS="-testplusarg trace_dvma=16"` | also `trace_irq`, `heartbeat_ms`, `crs_stuck`, `vcd_full` |

Unit tests (seconds to minutes, unlike a boot):

```sh
make -C sim dvma       # sun2_dvma: Wishbone master -> 68010 bus cycles
make -C sim adapter    # wb_to_mig_ui against a reference model
make -C sim migddr3    # the adapter against the real MIG + Micron DDR3, reports bus latency
make -C sim clkgen     # measures what the MMCMs actually generate
make -C sim phy        # phy_rtl8211_init against an independent clause-22 PHY model
make -C sim mbether    # the MultiBus Ethernet card, driven as the boot PROM drives it
make -C sim xy450      # the Xylogics 450 disk controller, against a real disk image
make -C sim scanout    # fb_scanout: every pixel of a frame, against a known pattern
```

A boot with `FB=1` writes `build/sim/xsim-vme-fb/fb.mem` — the aperture as raw
32-bit Wishbone words. `make -C sim screenshot` replays it through the real
`fb_scanout` and writes `build/sim/unit-scanout/screen.ppm`, which is the only
thing that renders what the machine actually drew rather than reading it out of
the memory model.

The board testbench can also type at the monitor prompt (`tb/uart_console.sv`),
which is how the PHY status register in device page 0xFE7 is checked
end-to-end — a full boot first, so it is an hour of wall clock, not minutes:

```sh
make -C sim board-phy   # boot, then map 0xFE7 and read it from the prompt
```

Expect a full boot to take roughly 0.5 s of wall clock per simulated
millisecond. `make -C sim board BOARD_MEM=ddr3` is ~1500x slower again and
cannot reach the prompt — it is only good for showing MIG calibrate.

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

Two facts about it that are easy to get wrong and fail quietly. **The PROM
remaps the DVMA window before every boot** — `FAKES1BOOT` is unconditional, so
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

**`Old/` is the previous working implementation.** Not in git, never modified;
copy from it rather than referencing it.

## Verification discipline

The MultiBus machine is the reference that must not regress. It boots to the
prompt with **23,629 bus errors** at `MEM_MIB=1 ROM=fast`, with no cards, and
the bus-error sequence should stay byte-identical — most of those errors are
the PROM's own page-map diagnostics, so the count is a sensitive fingerprint of
MMU and bus behaviour. Check it after anything touching shared logic, not just
after machine-specific work.

Fitting a card changes the fingerprint, which is why the reference has none,
and the changes add up: `FB=1` gives **23,628**, `MB_ETHER=1` gives **23,626**,
and both together give **23,625**. Each missing error is a probe that used to
time out -- one at `0xEC0000` for the display, three for the Ethernet card --
so 23,629 - 1 - 3 is exactly the pair. A count that does not decompose that way
is worth running down before anything else.

A disk changes it more, because a successful boot ends the run sooner than a
failed one: `XY450=1` with an image, stopping at the boot block rather than at
the prompt, gives **23,617** —

```sh
make -C sim xsim MEM_MIB=1 ROM=fast XY450=1 STOP_ON="running." \
     XSIMARGS="-testplusarg blk_image=$PWD/build/disk/xy0.img"
```

and the stop string has to be one word, because `sim/Makefile` passes it to
xsim unquoted.  A 2/120 with all three cards -- `XY450=1 MB_ETHER=1 FB=1` at
`TIMEOUT_MS=8000` -- gives **23,615**, with the console on the screen and the
serial port silent; `make -C sim screenshot MACHINE=multibus MB_ETHER=1 FB=1
XY450=1` renders what it drew, which is the only artefact that shows the whole
machine working at once.

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
