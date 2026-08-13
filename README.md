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
| `rtl/` | the Sun-2 gateware: bus, MMU, PROM, timer, registers, Wishbone bridge |
| `rtl/board/` | the board layer: clock generation, reset, Wishbone-to-DDR3 |
| `tb/` | testbenches and simulation models |
| `sim/` | simulation flows |
| `syn/` | FPGA build: constraints, MIG configuration, Vivado scripts |
| `tools/` | boot PROM preparation |
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
  `rtl/sun2_ether_ctl.v` implements natively; we use ours, because it sits in
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
* `sun2-multi-rev-R.bin` — Rev R boot PROM of a MultiBus Sun 2/120.
* `sun250_prom_combined.bin` — boot PROM of a VME Sun 2/50, used by
  `MACHINE=vme` (see [Which machine](#which-machine)).
* `doc/` — the Sun-2 Architecture Manual, the Sun 2/50 schematic and
  engineering manual, the MC68000 user manual, and the QMTech Wukong board
  documents. The engineering manual is the one with an OCR text layer, and it
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

The serial number and Ethernet address come from `rtl/idprom.v`, and the memory
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

`tools/` turns the PROM images into the Verilog `case` body that `rtl/bootrom.v`
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

`rtl/sun2_config.vh` holds the compile-time options; each is `ifndef`-guarded
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
| 0xFE1 | Intel 82586 Ethernet — control register (`rtl/sun2_ether_ctl.v`) plus the controller itself (`rtl/sun2_ethernet.sv`) | 80287 socket, not implemented |
| 0xFE3 | keyboard/mouse Z8530, a second instance of the serial SCC | parallel port, not implemented |
| 0xFE7 | Ethernet PHY status (`rtl/sun2_phy_status.v`) — not a Sun-2 device at all, see below | National 58167 real-time clock, not implemented |

Nothing is attached to the keyboard SCC, so the monitor's keyboard hunt times
out and the console stays on serial A — which is what we want. The frame
buffer and video control (type 1 pages 0x000 and 0x040) are deliberately
outside the decoded device window, so `s2fbthere()` fails for the same reason.

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

### Ethernet, and DVMA

The VME machine's on-board Ethernet is an Intel 82586 (`Inputs/Wish82586`),
and the interesting part is not the controller but how it reaches memory. Its
DMA addresses are **virtual**: on the real board they are latched straight onto
the CPU's address bus and translated by the same MMU. Sun calls it DVMA, and
Architecture Manual §7 is explicit that it exists to avoid *"the dual mapping
problems of DMA in a virtual memory environment"*.

So the controller is a bus master on the 68010 bus, not a client of the
physical-memory Wishbone that main memory uses. `rtl/sun2_dvma.v` is that
bridge: Wishbone slave in, 68010 cycles out. What makes it small is that a DVMA
cycle is byte-for-byte a supervisor-data CPU cycle at the pins (schematic sheet
A03) — so the MMU, the protection check, the bus timing chain, DTACK and the
bus error register are all reused unchanged, and `rtl/top_fpga.v` only has to
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
sequencer in `rtl/board/wukong_v1_top.sv` holding PHYRSTB low for 20 ms and
waiting 50 ms more before MDIO is allowed — the datasheet asks for 10 and 30.
Seven of those balls are also PHY configuration straps, latched when its reset
releases; they are inputs and must stay inputs, with no pull property, or the
PHY comes up at the wrong address or in RGMII mode.

`rtl/board/phy_rtl8211_init.sv` brings it down to something a Sun-2 can talk
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
`rtl/sun2_fpga.v` to get it back.

## Building for hardware

Target: QMTech Wukong **V1** (XC7A100T-2FGG676, one MT41K128M16JT-125 DDR3L,
50 MHz oscillator). The board layer replaces what a LiteX SoC wrapper used to
provide — clocks, DDR3 controller, Wishbone clock crossing, DRAM
initialisation, reset sequencing and pin constraints — with plain
SystemVerilog plus Xilinx's MIG, and no LiteX at all.

```sh
make -C syn ip           # generate the MIG DDR3 controller from its .prj
make -C syn bitstream    # 12.5 MHz CPU clock
make -C syn bitstream CPU_HZ=40000000
make -C syn bitstream MACHINE=vme   # a 2/50 instead of a 2/120
make -C syn both
```

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

Both configurations build clean on Vivado 2025.2:

| CPU clock | Worst setup slack | Worst hold slack |
|---|---|---|
| 12.5 MHz | +1.281 ns | +0.044 ns |
| 40 MHz | +0.151 ns | +0.055 ns |

40 MHz closes, but with little margin — treat it as the fast option, not the
default. Utilisation is the same either way and leaves plenty of room: 13878
LUTs (22%), 7137 registers (6%), 20 block RAMs (15%), 3 of 6 MMCMs (two ours,
one MIG's).

### Clocks

Two MMCMs in `rtl/board/wukong_clkgen.sv`, instantiated directly rather than
through the clocking wizard, so the file reads and simulates like any other
source.

| Clock | Derivation | Result |
|---|---|---|
| MIG `sys_clk` 166.667 MHz | MMCM A, VCO 1000 MHz, ÷6 | exact |
| `cpu_clk` 12.5 or 40 MHz | MMCM A, ÷80 or ÷25 | exact |
| IDELAYCTRL 200 MHz | MMCM A, ÷5 | exact |
| SCC `serial_clk` 4.9152 MHz | MMCM B, ÷2 ×24.625 ÷125.25 | 4.915170 MHz, +0.0006% |

4.9152 MHz is not a rational multiple of 50 MHz with small terms, so it gets an
MMCM to itself — where the fractional CLKOUT0 divider brings it within
0.0006%, and where changing `CPU_CLK_HZ` cannot perturb it. That matters
because the PROM derives the 9600 baud console straight from this clock. The
200 MHz output is needed because MIG only allows its "use the system clock"
IDELAYCTRL option when the input clock *is* 200 MHz.

`tb_clkgen` measures all four in simulation rather than trusting the
arithmetic — which is how the step-1 baud rate bug would have been caught.

### Memory

`rtl/board/wb_to_mig_ui.sv` adapts the Sun-2's Wishbone master to MIG's native
user interface: 32-bit words in the CPU clock domain to 128-bit beats in MIG's
83.33 MHz `ui_clk`, with a two-phase handshake across the domains and one
transaction in flight. `app_wdf_mask` masks per byte, so sub-word writes need
no read-modify-write. `tb_wb_to_mig_ui` checks it against `wb_ram_model` over
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

That leaves one join the two board configurations do not cover — the adapter
talking to the *actual* controller rather than a model of it — so there is a
third test for exactly that:

```sh
make -C sim migddr3    # wb_to_mig_ui + real MIG + Micron model, ~3 minutes
make -C sim adapter    # wb_to_mig_ui vs the reference, randomised, seconds
make -C sim dvma       # sun2_dvma: Wishbone master -> 68010 bus cycles
make -C sim clkgen     # measure the generated clocks
make -C sim phy        # phy_rtl8211_init vs an independent clause-22 PHY model
```

Micron's DDR3 model comes from the *generated* example design, not the copy in
the Vivado install — that one is an unsubstituted template full of
`%MEM_DENSITY` placeholders. Either way it is referenced, never committed: it
carries Micron's AS-IS licence, not an open one.

### Things about this board worth knowing

* **The V1 50 MHz input (M22) is not on a clock-capable pin**, so the XDC needs
  `CLOCK_DEDICATED_ROUTE FALSE` on it. V2/V3 moved the oscillator to M21.
* **DDR3 `CS#` must not be driven.** Sheet 3 of the V1 schematic shows it tied
  low through R35 and not routed to the FPGA; E22 is a free I/O. MIG's
  configuration has the chip-select pin disabled, which is correct. The old
  LiteX XDC constrains `ddram_cs_n` to E22 and is wrong.
* **Bank 16 needs `INTERNAL_VREF 0.675`** — MIG emits this itself.
* Two Vivado non-project traps, both handled in `syn/build.tcl`: the part must
  be set *before* `read_ip`, or the IP silently locks against a default Kintex
  device; and `read_ip` alone is not enough — the IP needs `synth_ip`, or the
  top fails with a misleading "module not found".
