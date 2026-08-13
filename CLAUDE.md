# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A replica of a Sun-2 workstation in an FPGA: MC68010, the Sun-2 MMU, an Am9513
timer, Zilog 8530 SCCs and (on VME machines) an Intel 82586 Ethernet, booting
the real boot PROMs to the monitor prompt. Target board is a QMTech Wukong V1
(XC7A100T-2FGG676) with DDR3 main memory.

## Commands

```sh
make sim                                  # boot the MultiBus 2/120 (= make -C sim xsim)
make -C sim xsim MACHINE=vme              # boot the VME 2/50 instead
make -C sim check MACHINE=vme             # pass/fail on the console log
make -C sim board [BOARD_MEM=ddr3]        # the machine as it will be on the Wukong
make -C syn ip                            # generate the MIG DDR3 controller (once)
make -C syn bitstream [MACHINE=vme] [CPU_HZ=40000000]
```

Simulation knobs that matter, all on `make -C sim xsim`:

| knob | effect |
|---|---|
| `MEM_MIB=1` | the first one to reach for — the PROM writes every installed byte, so 7 MiB costs seconds of simulated time and 1 MiB costs under half of one |
| `ROM=fast` | shortens the PROM's RAM-init pass 64-fold (MultiBus only) |
| `MEM_LATENCY=7` | memory as slow as the real DDR3 path; 0 (the default) is a one-cycle memory |
| `TIMEOUT_MS=` | simulated milliseconds before giving up |
| `XSIMARGS="-testplusarg trace_dvma=16"` | also `trace_irq`, `heartbeat_ms`, `crs_stuck`, `vcd_full` |

Unit tests (seconds to minutes, unlike a boot):

```sh
make -C sim dvma       # sun2_dvma: Wishbone master -> 68010 bus cycles
make -C sim adapter    # wb_to_mig_ui against a reference model
make -C sim migddr3    # the adapter against the real MIG + Micron DDR3, reports bus latency
make -C sim clkgen     # measures what the MMCMs actually generate
make -C sim phy        # phy_rtl8211_init against an independent clause-22 PHY model
```

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

**One define picks the machine.** `rtl/sun2_config.vh` derives everything
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
works — `rtl/sun2_dvma.v` arbitrates for the bus and drives supervisor-data
cycles, and `rtl/top_fpga.v` muxes CPU versus DVMA onto those wires. Nothing
downstream knows DVMA exists.

**Adding a device** means four things, and missing the last one gives a silent
12-clock timeout and a bus error: instantiate it, add a `MATCH_*` term, add an
arm to the `P_DOUT` read mux before the `16'hDEAD` fall-through, **and** add it
to the read and/or write DTACK terms.

**Mixed language, and the distinctions are load-bearing.** The MC68010
(`Inputs/Suska_Configware/68K10`) is VHDL and needs `-2008`. The Sun-2 gateware
in `rtl/*.v` must be compiled as **Verilog-2001, not SystemVerilog**. The SCC,
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
prompt with **23,629 bus errors** at `MEM_MIB=1 ROM=fast`, and the bus-error
sequence should stay byte-identical — most of those errors are the PROM's own
page-map diagnostics, so the count is a sensitive fingerprint of MMU and bus
behaviour. Check it after anything touching shared logic, not just after
machine-specific work.

Unit tests are expected to earn their keep: mutate the RTL, confirm the test
fails, revert. `tb/tb_dvma.sv` was written this way and still missed a real
timing bug once, because its memory model answered a cycle sooner than the
machine does.

## Traps that have already cost time

* **`xvlog` is stricter than Verilator and Yosys about declaration order.** A
  wire declared after its first use compiles elsewhere and fails here.
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
