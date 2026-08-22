# Bringing this up on real hardware

Everything here has only ever run in simulation. This is the list of what to do
with a QMTech Wukong in front of you, and of the tooling that was deliberately
deferred until something actually misbehaves.

Both board revisions are supported and share all their RTL. **The V1 is no
longer sold; a new board will be a V3.** They differ in the FPGA speed grade
and four pins, so pick the right `BOARD=` and the right pin column below.

The rule that shapes the order: **each step has an unambiguous pass/fail, and
nothing is switched on until the thing under it has passed.** The failure modes
in this design are almost all silent — a PHY at the wrong speed, a stuck
carrier and a dead controller are the same thing at the console — so a step
that "seems to work" is not a pass.

```sh
make -C syn ip       BOARD=v3                    # once per board
make -C syn bitstream BOARD=v3 MACHINE=vme       # -> build/syn/v3-vme-cpu12/sun2_wukong_v3.bit
```

Console is 9600 8N1 on `serial_tx` **E3** / `serial_rx` **F3** on either board.
Both on-board LEDs are active low.

| | V1 | V3 |
|---|---|---|
| FPGA | XC7A100T-2FGG676I | XC7A100T-1FGG676C |
| 50 MHz oscillator | M22 | M21 |
| reset button | J8 | H7 |
| `user_led[0]` — lit = out of reset | J6 | G21 |
| `user_led[1]` — lit = DRAM calibrated, then link up | H6 | G20 |
| second button (unused) | H7 | M6 |
| console, Ethernet, DDR3, PMOD | — identical — | |

`diag_leds0[7:0]` is the Sun-2 front panel on PMOD J10, the PROM's own progress
code, and is on the same eight balls either way.

## Staged bring-up

### 1. The machine, without touching Ethernet

Boot to `>`. This is the whole design minus the PHY, and it is the step most
likely to fail for a reason that has nothing to do with Ethernet.

* **Pass:** the self-test banner, `Sun Workstation, Model Sun-2/50 or
  Sun-2/160`, and the prompt.
* **Nothing at all on the console:** check `user_led[0]`. If it never lights,
  the reset chain is stuck — MMCM lock or `init_calib_complete`. DDR3 is the
  usual suspect and the diag LEDs will still be at their reset value.
* **Garbage on the console:** the SCC's 4.9152 MHz clock is wrong. `make -C sim
  clkgen` measures what the MMCMs actually generate.

### 2. MDIO alone: is there a PHY, and is it the one we think?

No MAC traffic. Read the identifier through the status register:

```
>pee0800 fe400fe7
>eee0800
EE0800: 001C?
```

* **Pass:** `001C`, the Realtek OUI.
* **`FFFF`:** the management interface never answered. Wiring (MDC H2, MDIO
  H1), the 1.5k pull-up, or the reset timing. `phy_reset_n` R1 has no external
  circuit at all, so if the bitstream is not driving it the part may never have
  come out of reset.
* **`0000`:** something is holding MDIO low.
* **Anything else:** you are talking to a different part, or to PHY address 0,
  which is a broadcast — that is exactly why this checks the identifier rather
  than merely that something replied.

A bus error here instead of a value means the page map entry did not take;
re-read it with `pee0800` on its own.

### 3. Did it negotiate 10 Mb/s?

The decisive one. Continue the same command with a bare return:

```
EE0802: F000?
```

Bits, most significant first: configured, identifier matched, link, full
duplex, speed `00`, carrier stuck now, carrier stuck ever.

* **Pass:** `F000`. Anything with bits 11:10 not `00` means the PHY and the MAC
  disagree about how wide the interface is and no frame will ever cross it —
  the failure that looks exactly like a dead controller.
* **Bit 15 clear:** the bring-up sequence never finished. It is a straight-line
  state machine, so this means MDIO stalled part way.
* **Bit 13 clear:** no link. Cable, or the partner will not do 10BASE-T.
* **Bit 9 or 8 set:** carrier sense is or has been stuck. Every transmit will
  defer; the MAC's deferral timeout turns that into `ie: Ethernet cable
  problem` rather than a hang, which is why bit 8 is sticky — the condition
  clears faster than you can read the register.

**Also confirm TXCLK (M2) and RXCLK (P4) are 2.5 MHz**, with a scope or the ILA
below. This is the one assumption the datasheet answers and the board has never
demonstrated: that a part strapped for GMII presents a 4-bit MII at 10 Mb/s.

### 4. Let it boot and try to net-boot

Expect, as in simulation:

```
Probing I/O bus: ie
Auto-boot in progress...
Boot: ie(0,0,0)vmunix
???nd: no file server, giving up.
>
```

Each `?` is one ND read request that went out on the wire and got no answer.
Three of them and the prompt means the 82586 initialised, configured itself and
transmitted — all of it by DVMA through the MMU. Put a packet capture on the
other end of the cable and the frames should be there.

* **`ie: cannot initialize`:** the controller never cleared the ISCP busy flag.
  The DVMA path, not the PHY.
* **`ie: Ethernet cable problem`:** transmit deferred until it gave up. Check
  bit 8 of the status register.
* **No `?` at all:** it never got as far as transmitting.

## The ILA

There is one, on the MMU. `ILA=1` on a bitstream build fits an integrated logic
analyser sampling `dbg_bus` — the wide debug bus `rtl/sun2-common/sun2_fpga.v`
exports, whose field map is the comment beside its assignment there.

```sh
make -C syn ip-ila BOARD=v1                                  # once per board
make -C syn bitstream ILA=1 BOARD=v1 MACHINE=multibus MB_ETHER=1 \
     CPU=rd68011 CPU_HZ=20000000
make -C syn hw       ILA=1 BOARD=v1 MACHINE=multibus MB_ETHER=1 \
     CPU=rd68011 CPU_HZ=20000000
```

`make hw` programs the board and leaves the Hardware Manager open on it; `make
program` does the same and exits. Both take the same knobs as `bitstream`,
because that is how they find the artefact — there is nowhere else to say which
build is meant. `HW_URL=host:3121` for a board on another machine; the default
is a local `hw_server`.

An ILA build gets its own output directory (`...-ila`) and writes a `.ltx`
beside the bitstream. Without that probe file the Hardware Manager finds the
debug hub and then has no names for anything on it, so it is half the
instrument, not an extra.

**What it was built for.** SunOS 4.0.3 netboots and panics creating process 1:
the kernel touches the last byte of pid 1's user stack expecting the fault that
grows it, and the machine reports that fault as a bus *timeout* rather than a
*protection violation*. `tools/mmuprobe` asks the same question seven ways from
a boot block and gets the right answer every time on both cores, so what SunOS
brings is history a boot block cannot synthesise — and reproducing that in
simulation is ten hours per attempt against ten minutes per bitstream. That
ratio is the whole argument for the ILA.

The diagnostic is one comparison: `ps_pmap2devices` sampled in the `C_S8 &
~P_AS_n` window against what an FC=3 read of the page map returns for the same
address afterwards. Equal means the lookup is sound and the fault is elsewhere;
different is the bug, and `ia_smap2pmap` in the same window says which of the
two map stages produced it.

**Triggering.** The probes are split along field boundaries so the basic
trigger unit is enough — one comparator per probe, ANDed:

* wide first: `probe7[1] == 1` (`ERR`), to see which bus errors happen and in
  what order;
* then `probe7[1] == 1 && probe1 == 1` — every PROM device probe is FC 5, so
  user data is a clean discriminator for the kernel's access;
* trigger position mid-buffer, because a stale map index would show in the
  cycles *before* the failing one.

Capture control is enabled: qualify on `~P_AS_n` (`probe2[5] == 0`) and 4096
samples cover bus cycles rather than the idle clocks between them.

**It has already earned its keep.** The first capture off the board answered
the question it was built for. Triggering on a bus error at FC 1 caught the
kernel's `subyte` to `USRSTACK-1`: `smap=ff` (SEGINV), `ps=800` (valid, no
permissions), `PROTERR_raw` set on the cycle's first clock, `PROTERR` the
moment `C_S8` arrived, `TIMEOUT` never -- and it cannot, since `ma=000` TYPE 0
makes `MATCH_MEM` and memory is exempt from the timeout. The two instruction
fetches before it were `0x470a` and `0x470c`, `_suibyte`, the PC from the
panic. So the MMU reported the fault correctly and the bus error *register*
did not: it was still holding a device probe from seconds earlier, because it
kept the first error until written and SunOS only ever reads it. See the trap
in CLAUDE.md. Ten minutes of bitstream, one capture, no simulation.

**What it costs, measured on the V1 build it was made for** (MultiBus,
MB_ETHER, RD68011, 20 MHz): **+1883 LUTs** (21217 to 23100, 33% to 36%),
**+3224 flip-flops**, and **+8.5 BRAM tiles** (85.5 to 94 of 135, 63% to 70%).
Timing still passes -- WNS 1.281 ns unchanged, WHS **0.057 ns** against 0.071
without it. Hold was the risk and it survived, but 14 ps is what an ILA costs
here, so re-read the timing report rather than assuming the next one will.

**Two things bite when building one, and neither is about the ILA.**

`tolog` is an empty module -- the VCD hook round TxDA -- and an empty module is
a **black box**, which `opt_design` refuses to run on. Every build got away
with it because synthesis pruned the instance first; marking debug nets keeps
hierarchy that would otherwise have been optimised through, and the first ILA
build died in a module with nothing to do with the ILA. It is behind
`SUN2_SIM` now, which both simulation flows define.

And the **debug hub will not accept a 20 MHz clock**:
`C_CLK_INPUT_FREQ_HZ` takes 25 MHz to 650 MHz and rejects anything slower
outright, so a hub on `cpu_clk` cannot be told what it is clocked at. It is on
`clk50_g` instead -- a hub and its cores are allowed to be in different
domains, so the ILA goes on sampling `cpu_clk` -- and `implement_debug_core`
has to run after that change or `place_design` stops with "debug core
instances ... needs to be (re)generated".

**JTAG.** `syn/program.tcl` asks the cable what rates it has and takes the
fastest within the hub's limit; the Wukong's offers 750 kHz to 12 MHz and it
picks 12. Setting a rate a cable does not have is a hard error, not a
rounding, which is why it is asked rather than assumed.

**It is off unless asked for.** The whole bus, the port included, is behind
`SUN2_ILA`, so an ordinary bitstream is byte-identical to one built before any
of this existed. That is measured, not assumed, and it is why the define
reaches as far as `sun2_fpga.v`: with only the ILA instantiation conditional
and the port always present, the design gained 8 LUTs and lost 17 ps of hold
margin -- on a build whose worst hold slack is 71 ps. Simulation defines
`SUN2_ILA` unconditionally, where the bus is free.

**Two things to expect.** The core has two input pipeline stages, so everything
it shows is two clocks late — uniformly, so relative timing is unaffected. And
fitting it moves placement: re-read the timing report rather than assuming the
last clean run still holds, and if the failure stops reproducing with the ILA
in, that is evidence about the mechanism and belongs in the record rather than
being worked around.

## Deferred until something misbehaves

### An ILA on the Ethernet side

The MII pins, MDC/MDIO, CRS/COL and the DVMA handshake (`P_BR_n`, `P_BG_n`,
`dvma_active`, `P_DTACK_n`, `P_BERR_n`) — a second group, not an extension of
the MMU one.

It is *not* the first thing to reach for. The status register in
device page 0xFE7 answers most of what it was for and answers it from the
monitor prompt, without a JTAG cable, a Vivado session or a rebuild. What an
ILA adds that the register cannot is the *timing*: whether MDC is actually
toggling at 125 kHz, whether TXCLK is 2.5 MHz, and what the DVMA arbitration
handshake looks like cycle by cycle.

The scaffolding now exists — `syn/generate_ip.tcl` generates the core,
`syn/build.tcl` reads and synthesises it, `syn/program.tcl` gets it onto the
board — so this is a second `create_ip` and a second instantiation. Sample it
on `mii_rx_clk` rather than trying to put the receive group and the `cpu_clk`
group in one core.

### The frame buffer, if it is built

`make -C syn bitstream FB=1 BOARD=v3` adds the 1152x900 display on HDMI,
letterboxed 1:1 in 1920x1080 -- the 2/50's on-board frame buffer with
`MACHINE=vme`, or the 2/120's video board with `MACHINE=multibus`. Plug a
monitor into the HDMI socket; the console moves there and **the serial port
goes silent**, which is what a Sun-2 with a display does and is the first thing
to check rather than a symptom of failure.

* **Nothing on either console:** the machine is not booting; go back to step 1
  with `FB=0`.
* **Serial silent, screen blank:** the display was found but nothing is
  scanning out. DISPEN is bit 15 of the video control register at `0xEE3800`.
* **A picture, but wrong:** if it is inverted the polarity is wrong (a 1 bit is
  black); if it is sheared the line stride is wrong; if the border is not black
  the window is wrong. `make -C sim scanout` checks all three against a known
  pattern, and `make -C sim screenshot MACHINE=<machine>` renders what the last
  boot actually drew, so the same fault can be compared against a picture
  rather than described.
* **A 2/120 that draws its banner and then stops**, printing `Timeout` on the
  screen it just found: that is the keyboard/mouse SCC, which is on the video
  board. It is built with `FB=1` on that machine for exactly this reason, so
  seeing it means the SCC is not decoding -- type 0 page 0xF00.

Both boards close timing with it: V1 at WNS 1.281, V3 at 1.262 as a 2/50 and
0.969 as a 2/120; with a disk as well, V3 gives 1.248. **The one thing simulation cannot answer** is whether the
part really drives 1.485 Gb/s per TMDS lane. The 5x clock is on a plain BUFG, above what an Artix-7 is rated for,
which is what QMTech's own 1080p design for this board does; there is no
failing timing path because the clock only feeds OSERDES hard blocks, so the
tools have nothing to report either way. If the screen is unstable or the sink
will not lock, that is where to look, and the fix is 1080p30 -- VIDEO_ID_CODE
34 in `wukong_top.sv`, half the serial rate for the same picture.

### The disk, if it is built

`make -C syn bitstream XY450=1 BOARD=v3` fits the Xylogics 450 and drives the
V3's micro-SD slot, J9 -- CLK on L4, CMD on J8, DAT0 on M5, DAT3 as /CS on J6,
card detect on N6.

**A V1 has no card slot at all**, so `BOARD=v1` puts the four SPI lines on PMOD
**J11** instead, in the Digilent Type 2 (SPI) order an off-the-shelf micro-SD
PMOD expects: /CS on H4, MOSI on F4, MISO on A4, SCK on A5. That is a
convention rather than a measurement -- nothing has ever been plugged in there
-- so check it against whatever breakout is actually used before trusting it.
See `syn/wukong_sd_v1.xdc`.

Put an image on the card first. `tools/mkxydisk` writes a labelled, bootable
one; it goes on the card raw, at LBA 0, with no partition table and no
filesystem:

```sh
tools/mkxydisk -o xy0.img
sudo dd if=xy0.img of=/dev/sdX bs=1M conv=fsync    # the whole card is the disk
```

Then the machine should say `Probing Multibus: xy` and auto-boot into it.

* **`Probing Multibus:` with nothing after it:** the card is not answering its
  registers at all. That is six bytes in MultiBus I/O space and nothing to do
  with the SD card -- it fails the same way with no card inserted, so an empty
  slot rules the SD side out.
* **`Waiting for disk to spin up...`:** the registers work and the media does
  not. `blk_sd` never came ready, which means the card never finished its SPI
  init: CMD0, CMD8, ACMD41, CMD58, CMD9. This is the first thing on this board
  that depends on real signal integrity at 25 MHz on four unbuffered lines.
* **`xy: error 5 cmd 2`:** Header Not Found, which here means the block was
  past the end of the media. Either the card is smaller than the label claims
  or `blk_count` came back wrong from CMD9.
* **`xy: error e cmd 2`:** Slave Acknowledge Error -- a DVMA cycle that nothing
  answered. That is the machine, not the disk: check that the memory reaches
  physical `0xC0000`, because the boot map puts the DVMA window there.
* **`No label found - attempting boot anyway.`:** the sectors are moving and
  the bytes are wrong. Byte order is the first suspect; a label read with the
  sector bytes swapped still passes the checksum and fails only on the magic.

**The interrupt has been exercised, once.** `make -C sim xychain` boots a
68010 program off the disk that installs a level-2 autovector handler and
drives chained IOPBs, which is the only thing in this design that has ever
taken an interrupt from a MultiBus card. If the disk works but the machine
seems to stall under load, that path -- IPND as a level, the 74LS148 encoder,
`EN_INT` in the system enable register -- is where to look, and that target is
how to look at it.

**No SD card model is simulated.** The block seam is what makes everything
above it testable without one -- `make -C sim xy450` runs the whole controller
against a file -- and per the rule at the top of this list, a card model
belongs here rather than being built speculatively. If the card is the thing
that misbehaves, that is the moment to write one.

### Known limits, not bugs

* **Gigabit** is out of reach on this board: the PHY's CLK125 is not routed to
  the FPGA, and the MAC would want a 125 MHz Wishbone clock.
* **100 Mb/s** does not work at a 12.5 MHz CPU clock — the receive unit cannot
  sustain it even with an infinitely fast bus. The bring-up advertises 10BASE-T
  only, deliberately.
* **Link-change interrupts** are unavailable: INTB is not routed. The status
  register polls, and the boot PROM polls anyway.
* **Actually net-booting** needs an ND server, not more hardware.
* **The disk cannot be formatted from the machine.** Write Format, the
  track-header commands and the defect map all need real per-sector headers,
  which an SD card has no room for; `/stand/diag` will get an error. Images are
  made with `tools/mkxydisk` on the host.
* **No overlapped seeking.** EEF is accepted and ignored. With one drive there
  is nothing to overlap and IOPBs completing in chain order is explicitly
  legal; it becomes worth revisiting if drives 1-3 are ever fitted.
* **Only one drive, unit 0**, and only one controller. The PROM probes
  `0xEE48` for a second and has to find nothing there.

### Bandwidth, still only half measured

`make -C sim migddr3` measured the real path: a Wishbone read is 7 CPU clocks
through MIG, and the VME machine boots identically at `MEM_LATENCY=7`. But the
boot PROM only ever transmits one frame at a time, so nothing has exercised the
receive-side cliff — a stream of minimum-size frames at 10 Mb/s needs one
memory access every 2.43 µs, and a 32-bit DVMA word is two 68010 cycles. When
that is exceeded the symptom is not clean: bytes vanish from the *middle* of a
frame, and the receiver then ignores the whole of the next one. Real traffic on
the wire is the first thing that will test this.

The frame buffer, when built, takes a share of the same bus, and that share is
measured rather than argued: `make -C sim migddr3` with
`XSIMARGS="-testplusarg fb_traffic"` puts a scan-out-shaped client alongside
the CPU and the mean read goes 7.0 -> 7.5 clocks, worst case 9. With
`+fb_saturate` -- a client that never stops asking, which the real scan-out
never does -- it is 9.1 mean and 11 worst. So `MEM_LATENCY=7` stays the right
figure to simulate at, and the receive-side budget above still holds with the
display running. It is worth re-checking if the scan-out is ever made to fetch
more than a line at a time.
