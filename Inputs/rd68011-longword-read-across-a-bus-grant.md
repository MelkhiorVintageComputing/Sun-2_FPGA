# A longword read across a bus grant loses its first word

Files implicated: `rtl/rd68011_biu.sv`, `rtl/rd68011_seq.sv` — but see
**Where to look**: the mechanism has *not* been isolated in the source, and
this report deliberately stops where the evidence stops.

Observed against RD68011 as of `cad1ea4`, in a Sun-2/50 (VME) replica on a
Xilinx Artix-7, at 20 MHz, with an Intel 82586 doing DVMA through the MMU.


## Summary

A 68010 longword read is two word cycles. A bus master may legally be granted
the bus between them. When that happens, RD68011 assembles the longword with
its **first (high) word corrupted and its second (low) word intact**.

    memory holds        0x00EE3000
    the CPU obtains     0x00003000      high word lost
                        0x0E660000 |    high word replaced by unrelated data
                        0x00A00000 |

The low half is right every time. Only the half read *before* the grant is
wrong.

The machine's side has been eliminated by measurement: every one of **295,827
CPU memory reads** on a full boot returns exactly what memory holds, including
all ten that had a master's cycle inside them. The data reaching the core is
correct; what the core makes of it is not.


## Why it matters

The corrupted longword is almost always a pointer, because that is what
`moveal (An),%a0` and its relatives read. The consequences are therefore not
localised:

* a pointer dereferenced at a wild address — `Timeout Bus Error, addr:
  FFFFFFFF`, `0E664370`, `00EF15CC`;
* a jump through one — `Exception 10` (illegal instruction), `Exception 2C`
  (line 1111 emulator), each reported at a PC holding perfectly ordinary code;
* a double bus fault, and the watchdog.

All three have been seen from the same bitstream on the same board within
minutes of each other, which is what a race looks like from outside. Nothing
about the failure names its cause; it took an ILA to find it.

It only bites when a bus master is active, so a machine with no DMA will never
see it. Ours netboots: the 82586 streams a kernel into memory by DVMA while the
CPU runs the boot PROM, and a longword read every few thousand catches a grant.


## What was observed

On the board, with an ILA on the CPU bus (102 bits: address, function code,
both map stages, the handshake, the data, and a bit that says whether the cycle
belongs to the CPU or to a master):

    ef431a  moveal %a5@(1118),%a0     ; a0 := the Ethernet control register
    ef431e  bset #5,%a0@              ; raise Channel Attention
    ef4322  moveal %a5@(1118),%a0     ; reload it
    ef4326  bclr #5,%a0@              ; drop it

The first `moveal` runs with the bus quiet and produces `0x00EE3000`; the
`bset` duly writes the Ethernet control register at `0xEE3000`. The chip acts
on the attention and begins fetching its configuration pointer. The second
`moveal` therefore runs with the chip's cycles interleaved, and produces
`0x00003000` — so the `bclr` clears a bit at `0x003000`, in main memory, and
Channel Attention is never dropped.

The same instruction pair, four instructions apart, reading the same address,
with nothing writing to it in between.

Both halves of the failing read are visible in the capture, and both were
answered correctly by the machine. The corruption is entirely in what the core
retained.


## Why the machine is not at fault

Three independent lines, because "it must be your end" deserves better than an
assertion:

1. **Every CPU memory read is checked against memory, on a whole boot.** The
   testbench rebuilds the physical address exactly as the machine hands it to
   the memory bridge and compares what the bus carried against what memory
   holds: **295,827 reads, 0 wrong**, including all ten DVMA-interleaved
   longwords.

   That check is not vacuous, and it was made to fail before being believed.
   Re-introducing the memory-bridge bug mentioned below and running the same
   boot gives **10 wrong out of the same 295,827**, every one of them flagged
   as having a master's cycle inside it. Zero, from a check that reports ten
   when there is something to report.

2. **The other core does not fail.** A WF68K10 (Suska) in the identical
   gateware, same bitstream lineage, same DDR3 timing, same 82586 doing the
   same DVMA, loads a bootloader and a SunOS kernel over the network. RD68011
   fails within a second of the same point.

3. **The bus arbiter is separately verified.** Its unit test sweeps a master's
   request across every offset through a CPU longword read, including a grant
   delivered mid-cycle, and checks the CPU's data as well as the cycles; three
   mutations of its arbitration term are caught. (One genuine machine-side bug
   *was* found this way and fixed first — a memory bridge that accepted any
   acknowledgement as an answer to whatever cycle was on the bus. The symptom
   above survives that fix.)


## Reproducing it

Without an FPGA, and without a Sun-2:

The shape is a longword read whose two word cycles straddle a bus grant. Drive
`br_n_i` so that `bg_n_o` is asserted after the first word cycle completes and
before the second begins, with the two reads returning distinguishable data,
and check the assembled 32-bit result. `sim/tb/bus_arb_tb.sv` already models
the two-wire handover this machine uses (BGACK tied negated, BR and BG alone).

With the Sun-2 replica, in simulation, roughly fifty minutes unattended:

    make -C sim xsim MACHINE=vme MEM_MIB=1 CPU=rd68011

ends in `Timeout Bus Error, addr: 0E664370 at 664370` — note `4370` in both
that and the `00A04370` seen on other runs: the low word is the same and
correct, the high word is not.


## Where to look

Stated as leads, not as a diagnosis — the mechanism has not been isolated:

* `rd68011_biu.sv:508-512` latches read data into `req_rdata` on the falling
  edge of S6, per UM 5.1.1. A longword's first word must survive from there
  until the second arrives.
* The BIU has an `ST_ARB` state entered when the bus is granted away
  (`rd68011_biu.sv:275-284`, `arb_bus_released`). A longword whose halves
  straddle a grant passes through it between the two S6 edges.
* `rd68011_seq.sv:337-338` muxes `rdata` from `req_rdata`, and the microcode
  assembles the two words. Whatever holds the first word across the grant is
  the thing to check.

The asymmetry is the clue worth keeping: the word read *before* the grant is
lost, the word read after it is kept.


## Scope

Any read-modify-write or multi-word transfer whose cycles can be separated by a
grant is exposed, not just `moveal`. `movem`, a long `move`, and the two halves
of a stacked exception frame have the same shape. Only longword *reads* have
been observed failing, because that is what the failing code does.

Single-word accesses are unaffected: they cannot straddle a grant.


## For comparison

The previous report from this machine —
`rd68011-exception-frame-on-user-stack.md`, fixed in `3508fd1` — was a
deterministic defect that a boot block could demonstrate. This one is a race:
it needs a second bus master, and it needs the grant to fall between two
particular cycles. It is correspondingly harder to see and correspondingly
easy to mistake for something else. It was carried in the Sun-2 project's notes
for months as "a protection violation on an instruction fetch at `A=a04370` — a
wild PC — unchased", and that entry is this bug.
