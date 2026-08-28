# A console test with no Sun-2 in it

The DECA brings no serial port and no display to the FPGA, so the JTAG console
is the **only** instrument that board has — and when it does not work there is
nothing left to debug it with. This is the design that breaks that circularity:
the same `deca_clkgen`, the same `deca_jtag_console`, the same two ALTPLLs and
the same pins as the real build, driven by a pattern generator instead of by an
MC68010. No CPU, no MMU, no boot PROM, no memory.

Same shape as `test/hdmi`, and for the same reason — that design separated "the
display path is broken" from "the Sun-2 build drives it wrongly", and settled in
one run what a day of full builds had not.

```sh
make -C test/deca_console                 # build, fit, assemble
make -C test/deca_console CPU_DIV=100     # with the 10 MHz CPU PLL instead
make -C test/deca_console program         # load it (needs the USB-Blaster udev rule)
make -C test/deca_console terminal        # juart-terminal on the console
```

**It is not a time optimisation, and it would be dishonest to sell it as one.**
Synthesising the whole machine takes about five minutes on this part. What this
buys is isolation: a full build that shows nothing leaves the JTAG UART, the PLL
ratio, the SCC and "did the CPU ever start" all alive as candidates at once, and
this removes the last two by construction.

## What it does

Two halves, one at a time, so a one-way fault reads as a one-way fault. `SW[0]`
picks: down transmits, up echoes.

**Transmit** puts a repeating 64-character line of printable ASCII at 9600 baud
onto the wire the SCC would drive, with a quarter-second pause between lines. If
`juart-terminal` shows it scrolling, then the PLL ratio, the serialiser, the
Avalon handshake, the JTAG UART and the host tooling are all sound — which is
most of what the real build depends on. The pause matters: a stuck byte shows up
as a stuck *column* rather than as a wall of text.

**Echo** sends back what you type with bit 5 flipped, so lower case returns
upper. Flipping a bit rather than echoing verbatim is deliberate — a host-side
local echo cannot then be mistaken for a working receive path.

`LED` is active low and carries, from bit 0: both PLLs locked, the serialiser
busy, a `clk_serial` heartbeat, which mode the switch selects, a byte dropped
because nothing was listening, and a framing error. A dark terminal must still
be distinguishable from a dead clock, which is why `test/hdmi` puts MMCM lock
and a pixel heartbeat on its LEDs too.

## What it has already settled, before any board

**The console PLL is what `deca_clkgen` claims it is.** The build reads the
figure back out of `quartus_sta` on every run rather than trusting the comment:

```
== clock clkgen|pll_b|auto_generated|pll1|clk[0]: 203.448 ns, 4.92 MHz ==
```

Quartus reduced the requested 87/885 to **29/295** — the same ratio — giving
50 MHz × 29/295 = **4,915,254.2 Hz**, period 203.4482 ns, which is **9600.1
baud** out of the SCC's /512. The solver neither rounded nor rejected the
parameters. That was the single largest unknown in moving a fractional-divider
clock onto a part with integer counters only.

It does **not** verify the CPU PLL: nothing here consumes `cpu_clk`, so that
output has no fan-out and produces no derived clock. The full build checks that
one.

**Uninitialised RAM infers without `INTERNAL_FLASH_UPDATE_MODE`.** This design
sets no such assignment and still reports 1,024 memory bits — the JTAG UART's
two 64-byte FIFOs. That is an independent confirmation of what the three-arm
measurement in `7ecd68e` concluded: that assignment gates *initialised* memory
and nothing else.

## Cost

656 logic elements (1%), 406 registers, 21 pins, 2 PLLs, 1,024 memory bits.
Map, fit, timing and assembly in about a minute.

## When the board arrives

Run this first, before trusting anything a full build says about the console.
The order that makes each failure mean one thing:

1. `make program` — LED 0 lit means both PLLs locked. If it is dark, nothing
   below is worth trying.
2. `make terminal` with `SW[0]` down — the scrolling line proves the whole
   transmit path.
3. `SW[0]` up, type — case-flipped echo proves receive.
4. Only then build and load the real machine.

If step 2 fails, SignalTap is the next instrument — `quartus_stp` is present in
this Lite installation. Qualify the capture on `av_chipselect` or `rx_valid`
rather than free-running: a 9600-baud bit is 512 clocks and a byte is 5,120, so
an unqualified window shows a fraction of one character. That is the same lesson
`syn/ila_capture.tcl` records as `iackseq`.
