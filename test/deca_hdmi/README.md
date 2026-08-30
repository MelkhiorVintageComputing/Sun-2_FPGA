# A standalone HDMI test for the DECA

The pixel PLL, the raster, the ADV7513's configuration and a test pattern. No
Sun-2, no DDR3, no console.

```sh
make            # about a minute
make program
```

## Why this exists before the frame buffer

The DECA has exactly one instrument, the JTAG console — and **fitting a display
takes it away**. The boot PROM sets `g_outsink = OUTSCREEN` whenever
`s2fbthere()` succeeds (`sunmon.c:396`) and offers no way to ask for both, so an
`FB=1` machine is one you can photograph and not talk to. The first time a
picture is attempted there must therefore be nothing else in the design that
could be blamed for its absence.

It also settles the one decision that cannot be settled by reading: which edge
of the pixel clock to hand the transmitter. See `deca_hdmi_out.sv`.

Like `test/deca_console` and `test/deca_ddr3`, this reads the **same**
`boards/DECA` and `rtl/sun2-common` sources the real build reads, never copies
of them. A test that reads its own copy vouches for the copy.

## What a working board looks like

* a monitor that syncs at **1280x1024 60 Hz**,
* eight colour bars over the top three quarters, a grey ramp below,
* a one-pixel white border, which is the proof that the active window is
  exactly 1280x1024 and not merely nearly,
* `LED[0]` on — the register table has been sent,
* `LED[1]` on — the pixel PLL is locked,
* `LED[2]` flickering — that is VSYNC at 60 Hz, so the raster is running,
* `LED[3]` **off** — no byte went unacknowledged,
* `LED[7:4]` — configuration passes, and it should read 1 and stay there.

The LEDs separate the failures that otherwise look identical. A black screen
with `LED[3]` lit is a part that is not answering at all — the wrong I2C pins,
the wrong address, or no 1.8 V. A black screen with `LED[0]` and `LED[1]` on and
`LED[3]` off is a part that took its configuration and is still not producing a
picture, which points at the pixel bus rather than the control path.
`LED[7:4]` climbing on its own is the transmitter re-interrupting, which means
hot plug detect is bouncing — the cable or the sink, not the FPGA.

## Deliberately checkable things

`build.tcl` fails the build if the sequencer or the raster is missing from the
netlist, in the style of the `alt_jtag_atlantic` check in `syn/quartus.tcl` — a
design that is nothing but these two is worse than useless without them, and
Quartus has no equivalent of Vivado's promote-implicit-nets-to-errors.

It also prints what the PLL was **actually** programmed with, read out of the
STA report rather than recomputed:

```
== pixel clock vidclk|pll_v|...|clk[0]: 9.259 ns, 108.0 MHz ==
```

`deca_vidclk` asks for 54/25 from 50 MHz; the megafunction is free to round it,
reduce it or reject it, and a comment is not a measurement. This is the cheapest
place in the project to check, because the design is 1% of the device.

## Measured

310 logic elements (<1%), 136 registers, 44 pins, one PLL. Timing met with
4.921 ns of setup slack and 0.315 ns of hold; **Fmax 230.5 MHz on the pixel
clock against the 108 MHz asked for**, which is the answer to whether a MAX 10
speed grade 6 can carry this raster — comfortably.

## Knobs

`make CLK_INVERT=0` sends the pixel clock uninverted. The default inverts it,
and `deca_hdmi_out.sv` explains why: the part samples on the rising edge of its
CLK with 1.0 ns of setup, this design launches on the rising edge of the pixel
clock, and inverting puts the sampling edge half a period after the launch
instead of on top of it. Terasic's DECA reference does the same; BrianHG's does
not and compensates elsewhere. If the picture shimmers or never appears, this is
the first thing to try, and it is a rebuild rather than an edit.
