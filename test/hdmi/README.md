# An HDMI test with no Sun-2 in it

The Sun-2's frame buffer reached a monitor that would not display it, and
nothing in the build said why. This is the experiment that separated "the
display path is broken" from "the Sun-2 build drives it wrongly": the same
`Inputs/hdmi` block, the same four `OBUFDS`, the same Wukong TMDS pins, a
colour-bar pattern generated from `cx`/`cy` — and nothing else. No CPU, no MMU,
no DDR3, no `fb_scanout`, no ILA.

Adapted from [hdl-util/hdmi-demo](https://github.com/hdl-util/hdmi-demo)'s
Seeed Spartan Edge Accelerator top, which drives the same block on a Spartan-7.
What changed is the board: 50 MHz instead of 100, the Wukong's pins, and a test
pattern in place of the demo's audio.

```sh
make -C test/hdmi                 # 720p60
make -C test/hdmi MODE=1080       # 1080p60
make -C test/hdmi MODE=1030       # 1080p30 -- same raster as 1080p60, half the clock
make -C test/hdmi MODE=1280       # 1280x1024 at 60 Hz -- what the Sun-2 uses
make -C test/hdmi program [MODE=...]
```

Eight colour bars with a one-pixel white frame round the raster, so an edge
that is cut off or a mode that is wrong is visible rather than inferred.
`user_led[0]` is the MMCM's lock and `user_led[1]` a pixel-clock heartbeat, so
a dark screen can still be told apart from a dead clock.

## What it settled

**720p60 and 1080p60 work on a Wukong V1.** 720p60 first, then 1080p60 — the
monitor reporting it had synchronised on 1920x1080 at a 148.5 MHz pixel clock.

**1080p30 does not, and the monitor is why.** Same 2200x1125 raster, same
`VIDEO_ID_CODE 16`, only the two MMCM output dividers doubled — and this
display reports the signal out of range where it takes both the others. So
"halve the serial rate" is not free: it has to land on a mode the sink accepts,
and 30 Hz refresh is not one here. That is what `HDMI720=1` in the Sun-2 build
exists for — the same 371 MHz serial clock at a raster this monitor does take.

The measurement matters beyond this bench: it means a `HDMI30=1` bitstream that
shows nothing has told you about your monitor, not about your FPGA, and the
30 Hz knob cannot be used to test the serial rate on its own.

That matters because 1080p60 **fails a timing check** on this part and works
anyway:

```
Min Period  BUFG/I  required 1.592  actual 1.347  slack -0.245  b2/I
```

The 5x TMDS clock is 742 MHz where a 7-series global buffer is rated for 628.
Swapping the BUFG for the textbook `BUFIO` plus `BUFR` divided by five clears
that and exposes the next one down, `OSERDESE2/CLK` needing 1.471 ns against
the same 1.347 — and costs a regional clock, which in the Sun-2 build meant
WNS -2.992 ns inside `fb_scanout`. Vivado reports only the worst resource per
clock, which is why the OSERDES check is invisible until the BUFG is gone.

So both the buffer and the serialiser are over-clocked at 1080p60, by 245 ps
and 124 ps, and the part does it regardless — as QMTech's own 1080p design for
this board does. **Two conclusions worth keeping apart:** the violation is
real, and it is not what stops the Sun-2 frame buffer from displaying. Anything
that blames the pixel rate for a blank Sun-2 screen has to explain why these
bitstreams work.

`syn/build.tcl` gates the Sun-2 build on these checks, because a clock past its
buffer's rating is worth refusing by default even when it happens to work; this
test deliberately does not, since producing that bitstream is the point.

## Setup timing, for comparison

| build | WNS | note |
|---|---|---|
| this test, 720p60 | 9.337 ns | nothing else in the design |
| this test, 1080p30 | 9.098 ns | the 1080p60 raster at the 720p60 clock |
| this test, 1080p60 | 3.295 ns | still comfortable |
| this test, 1280x1024 | 5.444 ns | the mode the Sun-2 build settled on |
| Sun-2 + FB + ILA, 1080p60, BUFG | 1.281 ns | the whole machine |
| Sun-2 + FB + ILA, 1080p60, BUFIO/BUFR | **-2.992 ns** | the regional clock's cost |

The 1080p60 pixel rate is not what pressures setup timing here; the regional
clock is.
