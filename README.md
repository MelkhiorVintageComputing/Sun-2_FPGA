# Sun-2 FPGA

A replica of a Sun-2 workstation in an FPGA. The current target is the MultiBus
Sun 2/120: MC68010, the Sun-2 MMU, the AMD 9513 timer and a Zilog 8530 SCC for
the serial console, booting the real Rev R boot PROM. A MultiBus Sun-2 has no
on-board Ethernet, so there is none here either.

Right now the design is exercised in simulation only, where it passes the
PROM's self test and reaches the monitor prompt.

## Layout

| Path | What |
|---|---|
| `rtl/` | the Sun-2 gateware: bus, MMU, PROM, timer, registers, Wishbone bridge |
| `tb/` | testbench, Wishbone memory model, serial console decoder |
| `sim/` | simulation flows |
| `tools/` | boot PROM preparation |
| `Inputs/` | third-party and reference material — **immutable** |
| `Old/` | the previous working implementation, kept for reference — not in git, never modified |

`Inputs/` holds git submodules, so a fresh clone needs:

```sh
git submodule update --init
```

Nothing under `Inputs/` is ever edited in place. If a change to that material
becomes necessary, it lives as a patch in this repository instead.

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
* `Wish82586` — Intel 82586 Ethernet, for the VME machines later.
* `sun2-multi-rev-R.bin` — Rev R boot PROM of a MultiBus Sun 2/120.
* `sun250_prom_combined.bin` — boot PROM of a VME Sun 2/50 (not used yet).
* `doc/` — the Sun-2 Architecture Manual and the QMTech Wukong board documents.

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
make -C sim xsim ROM=pristine           # the unmodified PROM (very slow)
make -C sim xsim XSIMARGS="-testplusarg heartbeat_ms=100"
SUN2_VCD=1 make -C sim xsim XSIMARGS="-testplusarg vcd_full"
make -C sim check                       # assert the console reached the prompt
```

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

`tools/` turns `Inputs/sun2-multi-rev-R.bin` into the Verilog `case` body that
`rtl/bootrom.v` includes, in three flavours:

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

| Define | Effect |
|---|---|
| *(default)* | main memory external, behind `sun2_wishbone_bridge` — 7 MiB, DTACK from the Wishbone ack. This is what the FPGA build uses, with LiteDRAM behind it. |
| `MEM_SIM_ONLY` | 512 KiB synchronous SRAM inside `sun2_fpga`, DTACK from fixed bus timing. |
| `MEM_PAGES` | installed memory in 2 KiB pages; default 3584 (7 MiB, the architectural maximum). Only affects what the PROM finds installed — the bus still answers over the full 7 MiB so the PROM's sizing probe works. |
| `ROM_FASTBOOT` | boot PROM with the RAM initialisation pass shortened 64-fold. |
| `ROM_PRISTINE` | use the unmodified boot PROM. |

`ttl_am9513` additionally takes a `TRACE` parameter (default 0) that turns on a
per-access register trace. It is off because it prints on every timer access
and dominates run time; instantiate the timer as `ttl_am9513 #(.TRACE(1))` in
`rtl/sun2_fpga.v` to get it back.
