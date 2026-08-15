# Sun-2 FPGA

A replica of a Sun-2 workstation in an FPGA: MC68010, the Sun-2 MMU, the AMD
9513 timer and Zilog 8530 SCCs for the serial console and keyboard, booting the
real boot PROMs. Both machine types are supported — the MultiBus Sun 2/120
(Rev R PROM) and the VME Sun 2/50 (Rev Q) — selected by one define; see
[Which machine](#which-machine).

In simulation both pass the PROM's self test and reach the monitor prompt.
It also builds into a timing-clean bitstream for a QMTech Wukong V1
(XC7A100T-2FGG676) with DDR3 main memory — untested on real hardware so far.

## Layout

| Path | What |
|---|---|
| `rtl/sun2-common/` | the Sun-2 gateware shared by both machines: bus, MMU, PROM, timer, registers, Wishbone bridge |
| `rtl/sun2-multibus/` | what only a 2/120 has — the MultiBus Ethernet card and the Xylogics 450 disk controller |
| `rtl/sun2-vme/` | what only a 2/50 has — on-board Ethernet, its DVMA bridge, the PHY status register, the video control register |
| `boards/Wukong/` | the board layer, shared by the Wukong V1 and V3: clock generation, reset, Wishbone-to-DDR3, PHY bring-up, the DDR3 arbiter and the frame buffer's scan-out |
| `tb/` | testbenches and simulation models |
| `sim/` | simulation flows |
| `syn/` | FPGA build: constraints, MIG configuration, Vivado scripts |
| `tools/` | boot PROM preparation, and `mkxydisk` for disk images |
| `Inputs/` | third-party and reference material — **immutable** |
| `Old/` | the previous working implementation, kept for reference — not in git, never modified |

`Inputs/` holds git submodules, so a fresh clone needs:

```sh
git submodule update --init
```

Nothing under `Inputs/` is ever edited in place. If a change to that material
becomes necessary, it lives as a patch in this repository instead — the same
principle as the boot PROM, which is patched into `build/rom/` rather than
modified where it sits.

The sources under `Inputs/`:

* `Suska_Configware` — Wolfgang Förster's Suska cores; `68K10/` is the MC68010.
  This is the `MelkhiorVintageComputing` fork on branch `sun_emu_support`,
  which already carries the three fixes the Sun-2 needs (exception-handler
  `BUSY_EXH` timing, `MOVES` function-code selection, and FC = supervisor data
  during the reset vector fetch).
* `z8530_scc` — [vz50938/z8530_scc](https://github.com/vz50938/z8530_scc), the
  SCC used for the serial console. Its bus clock and serial clock are separate,
  so the CPU clock is free — the Suska SCC constrains it far too tightly. Feed
  its serial clock 4.9152 MHz and the PROM's own register table gives a correct
  9600 baud console.
* `Wish82586` — the Intel 82586 Ethernet controller, used as the VME machine's
  on-board Ethernet. Its `src/wb_csr_sun2.sv` is the same control register
  `rtl/sun2-vme/sun2_ether_ctl.v` implements natively; we use ours, because it sits in
  device space with the rest of the decode, and the two should be kept
  reconcilable.
* `sunos-34-src` — [calmsacibis995/sunos-34-src](https://github.com/calmsacibis995/sunos-34-src).
  Contains `sun/prom_monitor/`, which is **the source of the boot PROMs
  themselves**: `msun/` builds the MultiBus monitor, `rsun/` the VME one, from
  the same files behind `#ifdef VME`. It is the single most useful reference
  here — `sys/mon/s2map.h` names every I/O page numerically, `mon/kernel/sunmon.c`
  has both machines' page-map setup side by side, and `mon/h/buserr.h` documents
  register semantics no manual spells out. Reach for it before guessing at
  what a PROM is doing.
* `Wish5380` — an NCR 5380 SCSI controller, which this design does not use.
  What it is here for is `src/blk_sd.sv` and `src/sd_spi.sv`: a tested SD-card
  block back end with a documented seam (`doc/block.md`), which the Xylogics
  450 keeps its sectors on. The SCSI half is not compiled.
* `hdmi` — [hdl-util/hdmi](https://github.com/hdl-util/hdmi), the HDMI
  transmitter behind the frame buffer: TMDS encoding, the 10:1 serialisers and
  CEA-861 video timing, used at VIDEO_ID_CODE 16 (1920×1080p60) with
  `DVI_OUTPUT` so there is no audio island to feed.
* `sun2-multi-rev-R.bin` — Rev R boot PROM of a MultiBus Sun 2/120.
* `sun250_prom_combined.bin` — boot PROM of a VME Sun 2/50, used by
  `MACHINE=vme` (see [Which machine](#which-machine)).
* `doc/` — the Sun-2 Architecture Manual, the Sun 2/50 schematic and
  engineering manual, the 2/120 video board engineering manual, the Xylogics
  450 user's manual and schematic, the MC68000 user manual, and the QMTech
  Wukong board documents. The engineering manual is the one with an OCR text layer, and it
  carries the U214/U215 PAL listings — the DVMA arbiter's actual equations.

## Running the simulation

```sh
make sim          # or: make -C sim xsim
```

That builds the boot PROM images, compiles the design and runs it, printing the
front-panel LED codes as the PROM walks its self-test and decoding the serial
console to `build/sim/xsim/console.log`, which ends up looking like:

```
Self Test completed successfully.

Sun Workstation, Model Sun-2/120 or Sun-2/170, Sun-2 keyboard
ROM Rev R, 1MB memory installed
Serial #3442, Ethernet address 8:0:20:1:6:E0

Probing Multibus:
Using RS232 A input.
Auto-boot in progress...
No default boot devices
>
```

The serial number and Ethernet address come from `rtl/sun2-common/idprom.v`, and the memory
size is whatever `MEM_MIB` was set to — the PROM finds it by probing. There are
no boot devices yet, so auto-boot fails and drops to the monitor prompt; the
run stops there on its own, because `STOP_ON` defaults to `>`.

`make -C sim check` turns that into a pass/fail: it asserts the self test
completed, the machine identified itself, and the prompt appeared.

Useful knobs:

```sh
make -C sim xsim MEM_MIB=1              # a 1 MiB machine: much faster to boot
make -C sim xsim ROM=fast               # skip most of the RAM init pass too
make -C sim xsim TIMEOUT_MS=8000        # simulated milliseconds before giving up
make -C sim xsim MEM=sim_only           # 512 KiB in-core SRAM instead of Wishbone
make -C sim xsim ROM=pristine           # this machine's unmodified PROM (very slow)
make -C sim xsim MACHINE=vme            # be a Sun 2/50 (VME) instead of a 2/120
make -C sim xsim XY450=1                # fit the Xylogics 450 disk (MultiBus only)
make -C sim xychain                     # drive chained IOPBs from inside the machine
make -C sim xsim MEM_LATENCY=7          # memory as slow as the real DDR3 path
make -C sim xsim XSIMARGS="-testplusarg trace_dvma=16"   # Ethernet bus mastering
make -C sim xsim XSIMARGS="-testplusarg trace_irq=20"     # timer/interrupt activity
make -C sim xsim XSIMARGS="-testplusarg heartbeat_ms=100"
SUN2_VCD=1 make -C sim xsim XSIMARGS="-testplusarg vcd_full"
make -C sim check                       # assert the console reached the prompt
```

`MEM_LATENCY` is worth knowing about. It defaults to 0 — a memory that
answers the next cycle — which is what every simulation here used until the
real path was measured. `make -C sim migddr3` reports what it actually costs:
MIG returns read data 21 `ui_clk` after accepting the command, and a Wishbone
read is **7 CPU clocks** from STB to ACK. Run with `MEM_LATENCY=7` before
believing anything about bus bandwidth, particularly now that the Ethernet
competes for the same bus by DVMA.

Each machine gets its own directory under `build/sim/`, so a MultiBus and a VME
run can proceed at the same time. Two runs of the *same* machine cannot — they
share a snapshot directory, and the second recompiles it while the first is
executing.

`MEM_MIB` is the one to reach for first. The PROM writes every installed byte
during its setup pass, so a 7 MiB machine spends over three simulated seconds
there while a 1 MiB one spends under half of one. 7 MiB is the architectural
maximum, most real Sun-2s had 2 or 4, and the PROM copes with as little as
256 KiB — so unless memory size is what you are testing, use a small machine.

Expect it to take a while — roughly 0.5 s of wall clock per simulated
millisecond. Where the simulated time goes, on a 1 MiB machine:

| Simulated time | Phase |
|---|---|
| 0 – 0.16 ms | reset, LED walk, watchdog, context register |
| 0.16 – 0.31 s | segment map diagnostics (`L_SM_CONST/DATA/ADDR`) |
| 0.31 – 0.37 s | page map diagnostics (`L_PM_CONST/DATA/ADDR`) |
| 0.37 – 0.61 s | boot PROM checksum (`L_PROM`) |
| 0.61 s | `L_M_MAP` — main memory mapped, Wishbone bridge enabled |
| 0.66 – 1.12 s | `L_SETUP_MEM` — the PROM writes every installed byte |
| 1.12 – 1.5 s | map, framebuffer and keyboard setup |
| ~1.5 – 1.7 s | console banner, MultiBus probe, auto-boot, prompt |

That `L_SETUP_MEM` figure scales with `MEM_MIB`: 0.46 s at 1 MiB, 3.2 s at
7 MiB, and 7 ms with `ROM=fast`. Reaching the prompt takes about 1.7 simulated
seconds at `MEM_MIB=1 ROM=fast`, and about 4.5 at the 7 MiB default.

### Boot PROM variants

`tools/` turns the PROM images into the Verilog `case` body that `rtl/sun2-common/bootrom.v`
includes. For the MultiBus `sun2-multi-rev-R.bin`, in three flavours:

* **patched** (default) — three words changed, per `tools/sim_speedup.txt`: a
  diagnostic delay loop shortened from 50000 iterations to 2, and the
  destructive main-memory test jumped over. Without these, simulating to the
  monitor prompt is not practical.

  The old design's image carried a fourth change, at `ef70e8`: WR12 in the
  SCC's initialisation table, the baud rate time constant, bumped from 14 to
  30. That was a workaround for the Suska SCC the old design used; with
  `z8530_scc` fed a 4.9152 MHz clock it is not needed, and applying it would
  only halve the console from 9600 to 4800. It lives in
  `tools/legacy_baud.txt`, which is not part of any ROM the simulation runs —
  `make -C tools check` applies it solely to rebuild the old image and assert
  we reproduce it bit for bit.
* **fastboot** (`ROM=fast`) — the above plus `tools/sim_fastboot.txt`, which
  turns the `asrl #2,%d1` that scales the RAM-init count at `ef01ea` into
  `asrl #8`. The initialisation loop and its 32-bit wraparound still run, and
  low memory — where the monitor keeps its own data — is still initialised,
  but 64 times less of RAM is written. Not the known-good image, so don't use
  it for full-system or memory-related validation.
* **pristine** (`ROM=pristine`) — the PROM exactly as dumped.

The VME `sun250_prom_combined.bin` gets the same treatment minus fastboot:
patched by default per `tools/sim_speedup_sun250.txt`, or pristine with
`ROM=pristine`. The two shared patch sites are at different addresses, and the
delay loop needed care — `movel #50000,%d0` appears twice with byte-identical
context, and the first occurrence is on an error path that never runs. It also
carries a third patch of its own, shortening the 100000-iteration poll in
`iereset()` that auto-boot always runs into; see the file for why that is a
speedup rather than a fix.

### Simulators

**Vivado xsim** is the flow that works. The design is mixed-language — the
MC68010 is VHDL, everything else Verilog and SystemVerilog — so the simulator
has to handle both. Notes for anyone reproducing it:

* the Suska VHDL needs `-2008`; it connects `buffer` formals to `out` actuals,
  which VHDL-93 forbids;
* the Sun-2 gateware must be compiled in Verilog mode, not SystemVerilog mode;
* `xelab` links the snapshot with Vivado's bundled gcc, which cannot find
  `crt1.o` on a Debian multiarch system unless `LIBRARY_PATH` points at
  `/usr/lib/x86_64-linux-gnu`. `sim/run_xsim.sh` sets this when needed.

**GHDL + Icarus** (`make -C sim iverilog`) is written but does not work:
`ghdl --synth` rejects a 16-bit concatenation in `wf68k10_bus_interface.vhd`
that is in fact correctly sized, and that both xsim and Vivado accept. See the
comment at the top of `sim/run_iverilog.sh`.

## Configuration

`rtl/sun2-common/sun2_config.vh` holds the compile-time options; each is `ifndef`-guarded
so it can be forced from the command line.

### Which machine

The Architecture Manual describes two Sun-2s, and the design can be built as
either. One define picks it, and everything machine-dependent follows:

| | `SUN2_MULTIBUS` (default) | `SUN2_VME` |
|---|---|---|
| Model | 2/120, 2/170 | 2/50, 2/160 |
| "Machine Type" | 1 | 2 |
| System bus | MultiBus / IEEE-796 | VME |
| Boot PROM | `Inputs/sun2-multi-rev-R.bin` | `Inputs/sun250_prom_combined.bin` |
| `DEV_PAGE_BASE` | 0 (page 0x000) | 4064 (page 0xFE0) |
| `MEM_SPACE_PAGES` | 3584 (7 MiB) | 4096 (8 MiB) |
| `IDPROM_MACHINE_TYPE` | 1 | 2 |
| State | boots to the monitor prompt | boots to the monitor prompt |

`make -C sim xsim MACHINE=vme` is the whole of it. The three parameters are
individually overridable if an experiment wants a combination that is not
either real machine; `sun2_fpga` prints the resulting configuration at time 0
so the combination in force is never in doubt.

The VME machine reaches the prompt too:

```
Self Test completed successfully.

Sun Workstation, Model Sun-2/50 or Sun-2/160, Sun-2 keyboard
ROM Rev Q, 1MB memory installed
Serial #3442, Ethernet address 8:0:20:1:6:E0

Probing I/O bus: ie
Using RS232 A input.
Auto-boot in progress...
Boot: ie(0,0,0)vmunix
ie: cannot initialize
>
```

The `?`s are real: each is one ND boot request that went out on the wire and
got no answer. `ieprobe()` on a VME machine reports Ethernet present from the
ID PROM's machine-type byte alone, without issuing a bus cycle, so `ie` always
joins the boot device list and auto-boot always tries it — and here it works,
finds nothing, and gives up cleanly.

Two device pages differ from MultiBus and are instantiated only for VME
(`VIOPG_*` in the monitor's `sys/mon/s2map.h`):

| Page | VME | MultiBus |
|---|---|---|
| 0xFE1 | Intel 82586 Ethernet — control register (`rtl/sun2-vme/sun2_ether_ctl.v`) plus the controller itself (`rtl/sun2-vme/sun2_ethernet.sv`) | 80287 socket, not implemented |
| 0xFE3 | keyboard/mouse Z8530, a second instance of the serial SCC | parallel port, not implemented — the 2/120's keyboard SCC is on its video board instead, in type 0 space |
| 0xFE7 | Ethernet PHY status (`rtl/sun2-vme/sun2_phy_status.v`) — not a Sun-2 device at all, see below | National 58167 real-time clock, not implemented |

Nothing is attached to the keyboard SCC, so the monitor's keyboard hunt times
out and the console stays on serial A — which is what we want. The frame
buffer and video control (type 1 pages 0x000 and 0x040) are outside the
decoded device window unless `SUN2_FB` is defined; without it `s2fbthere()`
fails and the console has nowhere else to go. The same is true of the 2/120,
at quite different addresses — see [the frame buffer](#the-frame-buffer-and-hdmi).

Getting there also needed three things that had never worked in this design
and are shared with MultiBus, all of them latent because no unprotected bus
error and no interrupt had ever occurred on the way to the MultiBus prompt:

* **the bus error register was not writable.** It is read-to-inspect,
  write-to-clear; the default handler in `trap.s` acknowledges by writing it,
  and that write was not acked, so the handler bus-errored inside itself and
  nested until the stack ran off the bottom of memory. Any unprotected bus
  error anywhere was an unrecoverable double fault.
* **interrupts could not be acknowledged.** A 68010 has one VPA pin serving
  both 6800-style cycles and autovectoring; the Suska core splits it into
  `VPAn` and `AVECn`, and the Sun-2's VPA was wired to the former. The core
  took its vector off the data bus instead, picking up `0xAD` from the read
  mux's `16'hDEAD` fall-through.
* **the timer never counted.** `ttl_am9513` drove its OUT pins from a register
  nothing assigned, ignored the count-source field, and wrote counter
  registers a byte at a time even in the 16-bit mode the monitor selects — so
  the NMI timer's mode word `0x0C22` was stored as `0x2200`, selecting an
  unconnected input pin. Counter 1 is the NMI clock the monitor measures wall
  time with, and the 2/50 waits on it with no way around.

### Ethernet, and DVMA — the VME machine

The VME machine's on-board Ethernet is an Intel 82586 (`Inputs/Wish82586`),
and the interesting part is not the controller but how it reaches memory. Its
DMA addresses are **virtual**: on the real board they are latched straight onto
the CPU's address bus and translated by the same MMU. Sun calls it DVMA, and
Architecture Manual §7 is explicit that it exists to avoid *"the dual mapping
problems of DMA in a virtual memory environment"*.

So the controller is a bus master on the 68010 bus, not a client of the
physical-memory Wishbone that main memory uses. `rtl/sun2-vme/sun2_dvma.v` is that
bridge: Wishbone slave in, 68010 cycles out. What makes it small is that a DVMA
cycle is byte-for-byte a supervisor-data CPU cycle at the pins (schematic sheet
A03) — so the MMU, the protection check, the bus timing chain, DTACK and the
bus error register are all reused unchanged, and `rtl/sun2-common/top_fpga.v` only has to
mux who drives the address, function code, strobes and write data.

Three details are worth knowing before touching it:

* **Two-wire arbitration.** The 2/50 ties BGACK high and a master simply holds
  BR for as long as it wants the bus (MC68000UM §5.2). The Suska core supports
  this properly and already exported `BUS_EN` for the wrapper to mux on.
* **The byte lanes are crossed.** The driver byte-swaps every scalar in
  software, so memory holds Intel little-endian data at matching byte
  addresses; all the hardware must guarantee is that the 82586's byte address
  N reaches the byte the 68010 calls N. A 68010 puts the even byte on D[15:8]
  and an Intel part puts it on D[7:0], so crossing the lanes *cancels* the
  mismatch rather than adding a second swap. This is the real board's
  "permanently byte-reversed mode" (§6.13). Get it backwards and the chip reads
  its configuration pointer one byte off, decides the host bus is 8 bits wide,
  and looks exactly like a chip that is not there.
* **Read data is latched a clock after DTACK**, as a 68010 does at the end of
  S6 — the machine's memory path presents data behind its acknowledge.
  Sampling on the DTACK edge silently returns the *previous* cycle's data.

`make -C sim dvma` is the unit test, and it is written to fail loudly on all
three: it drives a byte-addressed memory model that stores what a 68010 would
store, so a lane crossing error shows up as bytes in the wrong order rather
than as a machine that does not boot.

`+trace_dvma=N` on a simulation run reports the first N cycles the controller
takes as bus master, with the physical page each translated to. The sequence to
look for is three reads around `0xFFFFF6` (the SCP address the part has
hard-wired), reads at `0x0A0400` (the ISCP), then a write of zero to
`0x0A0400` — that last one is what the boot PROM spins on, and the difference
between a working controller and a dead one.

On the board the MII goes to the RTL8211EG in bank 34, whose pins, clock
constraints and MII I/O delays are in `syn/wukong_v1.xdc`, with a reset
sequencer in `boards/Wukong/wukong_top.sv` holding PHYRSTB low for 20 ms and
waiting 50 ms more before MDIO is allowed — the datasheet asks for 10 and 30.
Seven of those balls are also PHY configuration straps, latched when its reset
releases; they are inputs and must stay inputs, with no pull property, or the
PHY comes up at the wrong address or in RGMII mode.

`boards/Wukong/phy_rtl8211_init.sv` brings it down to something a Sun-2 can talk
to, over `wb_mdio` at 125 kHz. Read the identifier as a smoke test, write
GBCR = 0 to withdraw the gigabit advertisement the straps make, advertise
10BASE-T only in ANAR, clear PHYCR bit 11 — "Assert CRS on Transmit", which
comes up **set** in GMII mode and would make the MAC defer on its own frames —
and only then restart negotiation. That order is forced: writes to registers 0,
4 and 9 latch on a reset or a restart and nothing else, and there is no
software reset in the sequence because it would undo them.

Advertising 10 rather than *forcing* it is deliberate. A forced link sends no
advertisement, so the partner parallel-detects and falls back to half duplex,
giving a duplex mismatch that looks exactly like a MAC bug.

### Asking the machine what the PHY did

The board cannot be probed interactively, and the three ways this fails
silently — MDIO never answered, the link came up at gigabit, or carrier sense
is stuck — are indistinguishable from a dead controller at the console. So all
of it is readable from the monitor prompt, in device page **0xFE7**, which a
real 2/50 leaves unused (`s2map.h` comments 0xFE6 and 0xFE7 as such and the
PROM never maps either). Read-only; a write takes the bus-error timeout, as
writing the ID PROM does.

| | |
|---|---|
| +0 | PHYID1 as read back over MDIO — `001C` is the Realtek OUI |
| +2 bit 15 | the bring-up sequence finished |
| +2 bit 14 | ... and the identifier matched (address 0 is a broadcast, so an answer alone proves nothing) |
| +2 bit 13 | link |
| +2 bit 12 | full duplex |
| +2 bits 11:10 | speed: 00 = 10, 01 = 100, 10 = 1000 Mb/s |
| +2 bit 9 | carrier sense stuck now |
| +2 bit 8 | ... or at any point since reset (sticky) |

The PROM does not map the page, so point one at it first. `0xEE0800` is
`ROP_BASE`, the RasterOp processor a VME machine does not have, which
`sunmon.c` maps valid-but-inaccessible precisely because nothing uses it:

```
>pee0800 fe400fe7             valid, all permissions, type 1, page 0xFE7
>eee0800
EE0800: 001C?                 a Realtek part answered MDIO
EE0802: F000?                 configured, matched, link up, full duplex, 10 Mb/s
q
```

`make -C sim board-phy` does exactly that in simulation and
`sim/check_console.sh` asserts both answers — `tb/uart_console.sv` types at the
prompt and `tb/mdio_phy_model.sv` is the PHY. It boots the whole machine first,
so it costs an hour of wall clock; the bring-up sequencer on its own is
`make -C sim phy`, which takes seconds.

In simulation the MII side goes to `tb/mii_peer.sv`, which supplies clocks and a
quiet line.
That is not optional: the PROM's driver waits on the controller with no timeout
anywhere, so a transmit that never completes for want of a PHY clock hangs the
machine solid with nothing printed.

### The frame buffer, and HDMI

Either machine could have a display, and with `SUN2_FB` this one does:
1152×900 monochrome on an HDMI monitor, letterboxed 1:1 inside 1920×1080. It
is off by default, because it is not needed to bring a board up and because it
changes what a working machine looks like.

```sh
make -C sim xsim MACHINE=vme FB=1 MEM_MIB=1
make -C sim xsim MACHINE=multibus FB=1 MEM_MIB=1 ROM=fast
make -C syn bitstream MACHINE=vme FB=1 BOARD=v3
```

**It is the same screen on both machines, and largely the same hardware in
quite different places.** Both boot PROMs reach it at the same *virtual*
addresses; all of the difference is one page-map entry each:

| | 2/50 | 2/120 |
|---|---|---|
| Aperture, virtual `0xEC0000` | type 1, pages 0–63 | **type 0**, pages 0xE00–0xE3F → `0x700000` |
| Control register, virtual `0xEE3800` | type 1 page 0x40 | **type 0** page 0xF03 → `0x781800` |
| Keyboard/mouse SCC, virtual `0xEEC000` | type 1 page 0xFE3, on board | **type 0** page 0xF00 → `0x780000`, *on the video board* |

On a 2/120 it is a card in the cage — but a **P2-bus** card, not a MultiBus
one, so it decodes in memory space alongside RAM rather than in the type 2
system-bus space where the Ethernet card lives. Chapter 4 of its manual
decodes nothing but `P2.*`; the P1 connector carries interrupts and power.
`MEM_SPACE_PAGES` is 3584 = 0xE00 on that machine, so the aperture begins
exactly one page past the end of memory space — which is why nothing answered
before, and why the PROM's own memory sizing stops in the same place
(`mon/diag/diag.s:607`, *"Meg 7 is reserved for framebuf"*).

Above `0x700000` the video board decodes A19, A12 and A11 and nothing else, so
the aperture repeats every 128 KiB to `0x77FFFE` and the register and SCC
repeat to `0x7FFFFE`. `MATCH_FB` matches that rather than decoding tightly —
Figure 2-1 of the board manual says so outright, "DO NOT USE, will map to
Video Memory".

1152 × 900 at one bit per pixel is a 144-byte stride and 129,600 of those
131,072 bytes; **a 1 bit is black**, the opposite of a Sun-1. The control
register's DISPEN (bit 15) is the only bit the monitor writes, but SunOS's
`bwtwoprobe` also wants `copybase` to read back what it wrote, wants the
register aliased at `+0` and `+2` across its whole page, and wants the four
jumper bits to read **zero** — a 1 there would ask for 1024×1024, or send the
driver looking for a colour board that is not here. Copy mode and the
retrace interrupt exist as bits and do nothing, which is all any software in
the tree ever needs.

`rtl/sun2-common/sun2_fb_ctl.v` serves both machines without a conditional in
it. Two notes, both worth having written down. The Architecture Manual §6.3
describes bits 11:8 for Machine Type 1 as three reserved bits plus an audio
enable for a sound generator at `0x780800` — but that is the device-layer
abstraction, not this board: Table 2-1 of the board's own manual gives 11:8 as
the J1600 configuration jumpers and marks `0x780800` *NOT USED*. There is no
sound generator on it, and `bw2reg.h` — the driver that has to work on both
machines — agrees with the board. And bits 7 and 0 of the copy base read back
zero, which the board manual states and `bw2reg.h` flags as *"aberrant bits.
Don't depend on 'em!"*; both of `bwtwoprobe`'s test values have them clear, so
no software in the tree can tell.

The pixels live in DDR3, in the top 8 MiB, reached the same way the CPU
reaches memory: `MATCH_FB` is a second aperture on `sun2_wishbone_bridge`,
remapped to `FB_WB_BASE`. So there is no second path to get wrong — the byte
lanes, the read-back and the DTACK are the ones that already carry every
memory cycle. What is new is a second *master*: `boards/Wukong/mig_arb.sv`
sits in front of MIG with the CPU adapter on one port and
`boards/Wukong/fb_scanout.sv` on the other.

Scanout reads a line at a time into a ping-pong buffer in `ui_clk` and shifts
it out in the pixel clock. A line is 9 beats of 16 bytes and an HDMI line is
14.8 µs, so the fetch has roughly six times the time it needs; the whole
screen at 60 Hz is 7.8 MB/s against a bus that does over a thousand. The cost
to the CPU is small and measured rather than argued — `make -C sim migddr3`
reports a mean read of 7.0 CPU clocks alone, 7.5 with realistic scanout
traffic and 9.1 with the scanout saturated deliberately.

`Inputs/hdmi` (hdl-util/hdmi) does the TMDS encoding and serialising, at
1920×1080p60 with `DVI_OUTPUT` so there is no audio to feed. Its 148.4375 MHz
pixel clock and the 742.1875 MHz clock the serialisers need come from a third
MMCM, `boards/Wukong/hdmi_clkgen.sv`, using QMTech's own recipe for this
board. **The fast clock is on a plain BUFG, which is beyond what an Artix-7 is
rated for** — that is what QMTech ship working on this hardware, and it is
flagged in `BRINGUP.md` as the one part of this no simulation can settle.
Both boards close timing with the frame buffer in, on either machine: the V1
at 1.281 ns of slack, the V3 at 1.262 as a 2/50 and 0.969 as a 2/120.

**The catch, and it is a real one:** when `s2fbthere()` succeeds the monitor
sets `g_outsink = OUTSCREEN` and **the serial port goes silent**. A machine
with a display is supposed to print on the display. So the end-to-end test
cannot read a banner off the console; it searches the RAM model for the Sun
logo instead, a known 128-word bitmap from `mon/dpy/sunlogo.c`, and finds it at
row 128 of the frame buffer. That one assertion covers the aperture decode, the
address remap, the byte lanes and the PROM's own drawing code.

It finds it at offset `0x04808` on **both** machines, which is the strongest
available statement that the drawing code really is the same code: `mon/dpy/`
has no `VME` conditionals anywhere in it.

On a 2/120 the display drags one more thing in with it. `sunmon.c:601` is *"On
Multibus, keyboard can't be there if there's no frame buffer"* — with no
display the monitor points `g_keybzscc` at a fake UART inside the PROM and
never touches `0xEEC000`, and with one it calls `reset_uart()` there with no
bus-error catcher in reach. So on that machine `SUN2_FB` also builds the
keyboard/mouse SCC, because the SCC is physically on the video board. Without
it the boot draws its banner and then loops at `L_SETUP_KEYB`, printing
`Timeout` on the screen it just found.

`make -C sim scanout` is the unit test for the display side: it checks every
pixel of a full frame against a positional hash, the window edges, the bit
order, the polarity, and that a line costs exactly nine beats.

And there is a way to actually **look** at what the machine drew:

```sh
make -C sim xsim MACHINE=vme FB=1 MEM_MIB=1   # boot; writes fb.mem at the end
make -C sim screenshot MACHINE=vme            # render it
```

The boot writes the 128 KiB aperture to `build/sim/xsim-<machine>-fb/fb.mem` as raw
32-bit Wishbone words — what is in DDR3, not an unscrambled bitmap. The second
step replays that through the **real `fb_scanout`** at 1920×1080 and writes
`build/sim/unit-scanout/screen.ppm`. That distinction is the point: the logo
search proves the CPU wrote the right bits, and nothing more, because at
`sim/xsim` level the scan-out does not exist. The picture is the first thing
that exercises the line addressing, the bit order inside a beat, the polarity
and the windowbox against real content rather than a hash — and it comes out
of the RTL's opinion of all four, not the testbench's.

Two steps rather than one because a boot is three quarters of an hour and a
render is seconds, so the image can be looked at, the RTL changed and the image
redrawn without booting again. `screenshot` also asserts what it should not
need eyes for: the logo's first two pixels, at screen (448, 218), must come out
white then black — which pins the offset, the beat reassembly, the bit order
and the polarity down in one line.

### Ethernet — the MultiBus machine, which shares none of that

A 2/120 has no on-board Ethernet. It has a card in the MultiBus cage, and the
card is a computer in its own right: the 82586 DMAs into **the board's own
dual-ported memory** through **the board's own page map**, and never becomes a
bus master on the CPU bus at all. There is no DVMA, no MMU involvement, no
arbitration — on the schematic the card passes `P1.BPRN` straight to
`P1.BPRO`. It is a MultiBus slave and nothing more.

`rtl/sun2-multibus/sun2_mb_ether.sv` is the card; `make -C sim xsim MB_ETHER=1` fits it. It
is optional because a 2/120 with an empty cage is equally a real machine, and
it is the one the 23,629-bus-error fingerprint describes.

Two windows in MultiBus memory space, both jumpered on the real card:

| | |
|---|---|
| `0x88000 +0x000..0x7FE` | page map, 1024 entries of 16 bits, 1 KiB pages |
| `0x88000 +0x800..0x83E` | the board's own ID PROM, low byte of each word |
| `0x88000 +0x840` | status (read) / control (write) |
| `0x88000 +0x844..0x847` | parity error address |
| `0x40000 +0..256K` | the local memory, translated and byte-swapped per page |

The register base is not ours to choose: `iestd[] = { 0x88000, 0x8C000, 0 }` is
in the shipped Rev R image at `0xEF7D58`, next to the strings `ie: cannot
initialize` and `ie: Ethernet cable problem`. The memory base *is* ours,
because the driver reads it back out of `mies_mbmhi` rather than assuming it —
but it has to dodge the SCSI at `0x80000`, the card's own second controller at
`0x8C000`, and the 3Com at `0xE0000`, whose probe is nothing but *did it
answer?*. Naturally aligned at 256 KiB, that leaves `0x40000`.

Which is also why **page-map TYPE 2 is decoded as a space, not a device**.
Nothing decoded it before — a system-bus cycle simply ran out the twelve-clock
timeout — and that was load-bearing, because it is how every one of the PROM's
probes discovers it has nothing to talk to. `sun2_fpga` now emits a bus address
and a select, and DTACK comes from the card; with an empty cage the timeout
still fires and the bus-error count does not move.

Two details worth knowing before touching it, both of which cost time:

* **`mp_swab = 1`, "68000 byte order", is the identity mapping** — not the
  exchanging one, whatever the interface spec's prose suggests. The driver
  byte-reverses every multi-byte field in software (`to_ieaddr`, `to_ieoff`)
  and uses the same conversions unchanged on the VME machine, which has no
  swapper at all. Get it backwards and the chip reads plausible rubbish.
* **The memory window must be naturally aligned.** The card compares `A19:A18`
  for a 256 KiB window, so a base that is merely 64 KiB-aligned spreads it over
  four times its size and swallows whatever else lives there. The module
  `$fatal`s rather than mis-decode quietly.

`make -C sim mbether` is the unit test. It replays the boot PROM's own
sequences rather than a paraphrase of them — `ieprobe()`'s three bus cycles,
`ieinit()`'s page-map programming, and then the chip's SCP handshake, which is
the only check that pins the byte order down.

### A disk: the Xylogics 450, on an SD card

`XY450=1` fits a Xylogics 450 SMD disk controller in the MultiBus cage, with a
micro-SD card where four fourteen-inch platters used to be. MultiBus only: a
2/50 takes a Xylogics 451 on the VME bus, which is a different card in a
different address space.

The machine boots from it:

```
Probing Multibus: xy
Auto-boot in progress...
Boot: xy(0,0,0)vmunix
Xylogics 450 boot block running.
```

```sh
tools/mkxydisk -o build/disk/xy0.img            # a labelled, bootable disk
make -C sim xsim XY450=1 MEM_MIB=1 ROM=fast STOP_ON="running." \
     XSIMARGS="-testplusarg blk_image=$PWD/build/disk/xy0.img"
```

`xy` is the *first* entry in the PROM's `boottab[]`, so a `b` with no argument
tries a Xylogics before anything else, and `showconfig()` probes for one every
time the machine starts. Without the card that probe times out and the machine
reports no boot devices, which is what it did until now.

**The registers are in MultiBus I/O space, page-map TYPE 3**, which nothing in
this design decoded before. Six bytes at `0xEE40` — the PROM knows `0xEE40` and
`0xEE48` and probes both, and only controller 0 is fitted, so the second probe
still has to time out. `sun2_fpga` gains an `mbio_*` port beside `mb_*` on
exactly the same terms: a *space*, not a device, where a card answers or the
cycle takes the usual timeout.

**It is the first bus master a MultiBus build has ever had.** The controller
fetches its 24-byte command block and moves every sector itself, and on a Sun-2
that means DVMA: MultiBus address X is virtual `0xF00000 + X`, supervisor data,
through the MMU. `rtl/sun2-vme/sun2_dvma.v` already did that for the 2/50's
Ethernet and needed no change — only `top_fpga.v` stops tying it off.

Three things about this were not obvious and cost real time to establish.

* **The PROM remaps before every boot.** Its steady-state map has virtual
  `0xF00000` as a megabyte of TYPE 2, which would send the controller's DVMA
  cycle straight back out to the bus. But `commands.c:5` is *"Always define it
  until we finger out what to do with DVMA"*, so `FAKES1BOOT` is unconditional,
  and both the `b` command and auto-boot run `setupmap(fakemapinit2)` before
  `boot()` — putting virtual `0xF00000`–`0xF3FFFF`, exactly the 256 KiB DVMA
  window, on physical page `0x180` as ordinary memory. That table is in the Rev
  R image at `0xEF6F04`. **A machine with less than 1 MiB installed therefore
  cannot boot from disk**, because the window lands on physical `0xC0000`;
  `sun2_fpga` `$fatal`s rather than let it read zeroes.
* **The byte numbering is inverted, but only for the IOPB.** MultiBus is
  little-endian and a 68000 is not, so with the data bus wired straight through
  the two byte numberings disagree by one: `xyaddr->xy_csr` is CPU offset 5 and
  hardware register `0x44`, and IOPB byte *N* is at offset *N*^1. SunOS's own
  `struct xydevice` and `struct xyiopb` carry the controller's numbers as
  comments and declare their fields in swapped pairs. Sector data is *not*
  inverted: the manual says the IOPB moves in byte mode while data moves in
  word mode, and no driver in the tree ever sets the byte-mode bit.
* **The image is a memory image.** Sector byte *K* lands at data address *K*,
  so `build/disk/xy0.img` is a byte-for-byte copy of what the Sun sees. That is
  the convention any image anyone can actually produce already has, because the
  only way to read a Sun-2 disk is through a controller — `dd if=/dev/rxy0a`
  yields the bytes the controller put in memory, not the bits on the platter.

Geometry is software-defined. The controller keeps four drive-size slots that
Set Drive Size fills in, and turns cylinder/head/sector into a block number
with `((cyl * heads) + head) * sectors + sector`. Power-up defaults are the
manual's Table 2-8, which matters because the PROM reads block 0 with each
drive type in turn before it has told the controller anything.

`tools/mkxydisk` writes a `dk_label` — magic `0xDABE`, the XOR-of-shorts
checksum `chklabel()` insists on, geometry and one partition — and a boot
program in blocks 1 to 15 that prints through the PROM's own `putchar` and
stops. That is the whole of what `xyboot()` reads before handing over control,
so it is enough to prove the path end to end without anyone having to find a
genuine SunOS image first.

On hardware the media is the V3's micro-SD slot (J9), through `blk_sd` and
`sd_spi` taken unchanged from `Inputs/Wish5380`. **A Wukong V1 has no card slot
at all**, so that build puts the four SPI lines on PMOD J11 in the order an
off-the-shelf micro-SD PMOD expects — a convention, not a measurement; see
`syn/wukong_sd_v1.xdc`. In simulation the same block seam has `tb/blk_file.sv`
and an ordinary file behind it, which is what makes the whole controller
testable without simulating a card at all.

**It chains.** The 450 executes a linked list of IOPBs from one Go: each
command byte's CHEN bit says whether to follow that IOPB's Next IOPB Address,
relocated by the same registers as the head, so a chain lives inside one 64 KiB
block. SunOS builds one per interrupt — at most one IOPB per drive plus the
controller's own, so five — and expects **one interrupt at the end**, not one
per IOPB: `xyasynch()` sets `xy_ie` and clears `xy_intrall` (`xy.c:709-716`),
and a second interrupt would be read as the *next* chain completing.

Two details of the chain walk are load-bearing and neither is obvious.

* **`xy_nxtoff` is only valid when CHEN is set.** `xychain()` clears
  `xy_chain` on the tail of every chain and never clears the offset beside it
  (`xy.c:744-745`), so the tail carries a live-looking pointer left over from
  whichever chain that IOPB was in the middle of last time. Following it is a
  DMA into the previous transfer's buffer.
* **A hard error stops the chain where it happened.** Everything behind the
  failure must come back untouched, `xy_complete` still clear, because
  `xyintr()` skips those and `xychain()` re-issues them verbatim — *"If the
  done bit isn't set, we just ignore the iopb; it will get chained up and
  executed again"* (`xy.c:1798-1801`).

That last sentence is also why the single-IOPB controller this replaced worked
at all: SunOS handles a card that runs only the head. Chaining buys fidelity,
throughput and fairness rather than correctness, and with one drive fitted a
chain is at most two IOPBs long.

**SunOS 3.4 never uses the Attention protocol.** `XY_ATTN` and `XY_ACK` are
declared in `sundev/xycreg.h` and referenced by no C file in the tree; the
driver only ever touches the controller between chains. It is implemented here
anyway, because AACK means "the chain is standing still and you may edit it"
and granting it mid-transfer — which is what this did before there was a chain
to protect — invites a driver that does use it, such as 4.x's, to rewrite a
link the controller is about to follow.

`make -C sim xy450` is the unit test: 102 checks, all replays of real code —
`xyprobe()` from both drivers, the controller reset, a NOP that has to report
controller type 1, a read of block 0 checked with `chklabel()`'s own checksum,
Set Drive Size, write-then-read, a two-sector transfer across the head
boundary, every completion code a driver in the tree tests for by name, and
the chain cases — one interrupt for a chain of five, a stale tail pointer that
must not be followed, an error that stops the chain dead, a chain that points
at itself, and the Attention handshake.

`make -C sim xychain` is the other half, and the only thing in this design that
has ever taken an interrupt from a MultiBus card. `tools/xychain` is a 68010
program built with an m68k cross-compiler, written on to the disk by
`mkxydisk --boot` and loaded by the boot PROM like any other boot block. It
builds chains in the DVMA window, drives them through the real MMU while the
CPU competes for the bus, installs a level-2 autovector handler at `0x68` and
counts the interrupts. Among other things it reads back the sector that
contains its own first page and compares it against the copy it is executing.

What is deliberately not there: formatting (Write Format, the track-header
commands and the defect map all need real per-sector headers, which an SD card
has no room for), ECC, overlapped seeking (EEF is accepted and ignored — with
one drive there is nothing to overlap and completing in chain order is
explicitly legal), a second controller at `0xEE48`, and 24-bit addressing.

### Everything else

| Define | Effect |
|---|---|
| *(default)* | main memory external, behind `sun2_wishbone_bridge` — DTACK from the Wishbone ack. This is what the FPGA build uses, with DDR3 behind it. |
| `MEM_SIM_ONLY` | 512 KiB synchronous SRAM inside `sun2_fpga`, DTACK from fixed bus timing. |
| `MEM_PAGES` | installed memory in 2 KiB pages; default 3584 (7 MiB). Only affects what the PROM finds installed — the bus still answers over the whole of `MEM_SPACE_PAGES` so the PROM's sizing probe works. |
| `ROM_FASTBOOT` | boot PROM with the RAM initialisation pass shortened 64-fold. MultiBus only. |
| `ROM_PRISTINE` | use this machine's unmodified boot PROM. |

`ttl_am9513` additionally takes a `TRACE` parameter (default 0) that turns on a
per-access register trace. It is off because it prints on every timer access
and dominates run time; instantiate the timer as `ttl_am9513 #(.TRACE(1))` in
`rtl/sun2-common/sun2_fpga.v` to get it back.

## Building for hardware

Target: QMTech Wukong, **V1** (XC7A100T-2FGG676) or **V3** (XC7A100T-1FGG676),
either with one MT41K128M16JT-125 DDR3L and a 50 MHz oscillator. The board
layer replaces what a LiteX SoC wrapper used to provide — clocks, DDR3
controller, Wishbone clock crossing, DRAM initialisation, reset sequencing and
pin constraints — with plain SystemVerilog plus Xilinx's MIG, and no LiteX at
all.

```sh
make -C syn ip                      # the MIG DDR3 controller, once per board
make -C syn bitstream               # 12.5 MHz CPU clock
make -C syn bitstream CPU_HZ=40000000
make -C syn bitstream MACHINE=vme   # a 2/50 instead of a 2/120
make -C syn both
```

Four axes, each defaulting to what every verified result was measured with:

| | | |
|---|---|---|
| `BOARD` | `v1` (default), `v3` | the V1 is discontinued, so the V3 is what a new build will land on; they differ in the speed grade and four pins — the oscillator, the reset button and the two LEDs |
| `MACHINE` | `multibus` (default), `vme` | which Sun-2 |
| `MB_ETHER` | `0` (default), `1` | the MultiBus Ethernet card |
| `FB` | `0` (default), `1` | the frame buffer on HDMI, VME only |

`BOARD` reaches the MIG too: both boards want identical DDR3 and differ only in
the target part, so `generate_ip.tcl` substitutes it into a per-board copy of
the one committed `.prj`, and `build/ip/<board>/` keeps them from overwriting
each other.

Nothing in this repository has run on a board yet. `BRINGUP.md` is the staged
procedure for the first time it does — what to check, in what order, and what
each failure looks like given that almost all of them are silent at the
console. It is also where the deferred debugging tooling lives, the ILA
included.

Each combination gets its own output directory, `build/syn/<machine>-cpu<MHz>/`.
Nothing generated is committed. `syn/mig/sun2_mig.prj` is the source of truth
for the memory controller (see `syn/mig/README.md` for its provenance and the
four fields we changed); everything MIG emits lands in `build/ip/`. The build
refuses to write a bitstream if timing is not met.

Every configuration builds clean on Vivado 2025.2:

| | Worst setup slack | Worst hold slack |
|---|---|---|
| V1, 12.5 MHz | +1.281 ns | +0.028 ns |
| V1, 40 MHz | +0.151 ns | +0.055 ns |
| V3 (−1), 12.5 MHz | +1.276 ns | +0.008 ns |
| V1, 12.5 MHz, frame buffer (2/50) | +1.281 ns | +0.049 ns |
| V3 (−1), 12.5 MHz, frame buffer (2/50) | +1.262 ns | +0.008 ns |
| V3 (−1), 12.5 MHz, frame buffer (2/120) | +0.969 ns | +0.054 ns |

40 MHz closes, but with little margin — treat it as the fast option, not the
default. **The hold figures are placement-sensitive and small**, and they move
by tens of picoseconds between builds of unrelated configurations; what they
have in common is that the limiting path is never ours — it is inside MIG or
inside the Suska 68010. The one that *was* ours is fixed: see the `clk50` note
below. The −1 part barely moves the setup number because the critical path is
inside MIG, which adapts; its hold figure of 8 ps is MIG's own read-data buffer
at the fast corner rather than anything of ours — met, but thin enough to write
down. Utilisation leaves plenty of room: 13878 LUTs (22%), 7137 registers (6%),
20 block RAMs (15%), 3 of 6 MMCMs (two ours, one MIG's) — and with the frame
buffer and HDMI, 17115 LUTs (27%), 22.5 block RAMs, 4 MMCMs and 89 I/O.

### Clocks

Two MMCMs in `boards/Wukong/wukong_clkgen.sv`, and a third in
`boards/Wukong/hdmi_clkgen.sv` when the frame buffer is built — all
instantiated directly rather than through the clocking wizard, so the files
read and simulate like any other source.

| Clock | Derivation | Result |
|---|---|---|
| MIG `sys_clk` 166.667 MHz | MMCM A, VCO 1000 MHz, ÷6 | exact |
| `cpu_clk` 12.5 or 40 MHz | MMCM A, ÷80 or ÷25 | exact |
| IDELAYCTRL 200 MHz | MMCM A, ÷5 | exact |
| SCC `serial_clk` 4.9152 MHz | MMCM B, ÷2 ×24.625 ÷125.25 | 4.915170 MHz, +0.0006% |
| HDMI `clk_pixel` 148.5 MHz | MMCM C, VCO 742.1875 MHz, ÷5 | 148.4375 MHz, −0.042% |
| HDMI `clk_pixel_x5` | MMCM C, ÷1 | 742.1875 MHz, exactly 5× |

4.9152 MHz is not a rational multiple of 50 MHz with small terms, so it gets an
MMCM to itself — where the fractional CLKOUT0 divider brings it within
0.0006%, and where changing `CPU_CLK_HZ` cannot perturb it. That matters
because the PROM derives the 9600 baud console straight from this clock. The
200 MHz output is needed because MIG only allows its "use the system clock"
IDELAYCTRL option when the input clock *is* 200 MHz.

148.5 MHz cannot be made exactly from 50 MHz through one MMCM at all —
148.5/50 is 2.97, and the feedback multiplier would have to be 2.97 times an
integer output divider — and neither existing MMCM can approach it: A's spare
outputs are integer dividers off a 1 GHz VCO, and B's one fractional output is
the serial clock, which must not be perturbed. So the third MMCM uses QMTech's
own recipe for this board, 0.042% low and well inside what CEA-861 allows.

`tb_clkgen` measures all six in simulation rather than trusting the
arithmetic — which is how the step-1 baud rate bug would have been caught. It
also checks the one relationship the TMDS serialisers depend on, that
`clk_pixel_x5` is *exactly* five times `clk_pixel`: OSERDESE2 in 10:1 DDR does
not work otherwise, and a behavioural model that generates the two clocks
independently is not five to one no matter how close each is on its own.

### Memory

`boards/Wukong/wb_to_mig_ui.sv` adapts the Sun-2's Wishbone master to MIG's native
user interface: 32-bit words in the CPU clock domain to 128-bit beats in MIG's
83.33 MHz `ui_clk`, with a two-phase handshake across the domains and one
transaction in flight. `app_wdf_mask` masks per byte, so sub-word writes need
no read-modify-write.

It does not touch MIG directly, though: `boards/Wukong/mig_arb.sv` owns the
`app_*` port and round-robins between the adapter and the frame buffer's
scan-out. One transaction in flight on the whole interface, because what MIG's
`ORDERING = "NORM"` guarantees about read-data return order is not established
here and the read path carries no tag. With no frame buffer the second client
is tied off and never asks. `tb_wb_to_mig_ui` checks it against `wb_ram_model` over
randomised traffic with randomised stalls on both of MIG's ready signals.

### Board-level simulation

```sh
make -C sim board                    # behavioural RAM, boots to the prompt
make -C sim board BOARD_MEM=ddr3     # real MIG + Micron's DDR3 model
```

The fast configuration leaves MIG out and hangs `wb_ram_model` on the Wishbone
port, and generates the clocks behaviourally: the MMCME2 model simulates a
1 GHz VCO and costs more events than the rest of the machine put together,
about 6× overall. Use `BOARD_CLKGEN=real` to simulate the actual MMCMs.

The `ddr3` configuration is for bring-up, not booting: MIG calibrates against
the Micron model at 125 µs and the reset chain releases the Sun-2 190 ns later,
but the boot PROM does not touch main memory until `L_M_MAP` around 600 ms,
which is far past what a full DDR3 model can simulate in reasonable time.

**The board testbench does not build with `FB=1`** — `sim/run_xsim_board.sh`
compiles `fb_scanout.sv` and `hdmi_clkgen.sv` but none of
`Inputs/hdmi/src/*.sv`, so `hdmi` is unresolved. Adding them is not quite free:
without `SYNTHESIS`, `MODEL_TECH` or `ALTERA_RESERVED_QIS`, `serializer.sv`
takes its generic IP-less branch, and both that branch and the `MODEL_TECH` one
drive `tmds[i]` from a posedge *and* a negedge `always_ff` — the DDR trick,
which xsim will not accept. The generic branch also assigns the 3-bit
`tmds_shift_negedge_temp` to the 1-bit `tmds_clock`, where it means
`tmds_clock_negedge_temp`. Both are one small `patches/hdmi/` away if the TMDS
stream is ever worth simulating. As it stands the frame buffer is simulated at
`sim/xsim` level, the display side by `make -C sim scanout` and `make -C sim
screenshot`, and the TMDS output itself only by the bitstream and, eventually,
a monitor.

That leaves one join the two board configurations do not cover — the adapter
talking to the *actual* controller rather than a model of it — so there is a
third test for exactly that:

```sh
make -C sim migddr3    # wb_to_mig_ui + real MIG + Micron model, ~3 minutes
make -C sim adapter    # wb_to_mig_ui vs the reference, randomised, seconds
make -C sim dvma       # sun2_dvma: Wishbone master -> 68010 bus cycles
make -C sim clkgen     # measure the generated clocks
make -C sim phy        # phy_rtl8211_init vs an independent clause-22 PHY model
make -C sim scanout    # fb_scanout: a whole frame, pixel by pixel
```

`migddr3` also stands in for the frame buffer's share of the bus:
`XSIMARGS="-testplusarg fb_traffic"` runs a scan-out-shaped second client
alongside the CPU, and `+fb_saturate` runs one that never stops asking. The
mean CPU read goes 7.0 → 7.5 → 9.1 clocks across the three.

Micron's DDR3 model comes from the *generated* example design, not the copy in
the Vivado install — that one is an unsubstituted template full of
`%MEM_DENSITY` placeholders. Either way it is referenced, never committed: it
carries Micron's AS-IS licence, not an open one.

### Things about this board worth knowing

* **The V1 50 MHz input (M22) is not on a clock-capable pin**, so the XDC needs
  `CLOCK_DEDICATED_ROUTE FALSE` on it. V2/V3 moved the oscillator to M21.
* **`clk50` has an explicit `BUFG`, and needs one.** It is not only the MMCMs'
  reference — the reset assembly and the PHY reset sequencer are clocked by it
  directly. Vivado infers the buffer, but not reliably: it inferred one for a
  MultiBus build and not the VME build of the same commit, with 13 of 32 BUFGs
  used either way. Left on general routing it measured 0.93 ns of skew and lost
  a same-clock hold path by 270 ps.
* **`if` is not supported in an XDC file.** Vivado's constraint parser accepts
  the file, emits `CRITICAL WARNING: [Designutils 20-1307]` among thousands of
  lines, and skips the block — which is how a `set_clock_groups` went missing
  and turned an asynchronous crossing into a 5 ns timing failure. Conditional
  constraints belong in `build.tcl`, choosing which XDC to read.
* **DDR3 `CS#` must not be driven.** Sheet 3 of the V1 schematic shows it tied
  low through R35 and not routed to the FPGA; E22 is a free I/O. MIG's
  configuration has the chip-select pin disabled, which is correct. The old
  LiteX XDC constrains `ddram_cs_n` to E22 and is wrong.
* **Bank 16 needs `INTERNAL_VREF 0.675`** — MIG emits this itself.
* Two Vivado non-project traps, both handled in `syn/build.tcl`: the part must
  be set *before* `read_ip`, or the IP silently locks against a default Kintex
  device; and `read_ip` alone is not enough — the IP needs `synth_ip`, or the
  top fails with a misleading "module not found".
