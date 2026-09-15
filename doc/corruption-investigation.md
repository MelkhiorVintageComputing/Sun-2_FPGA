# The corruption investigation, and the instruments it used

Moved out of `CLAUDE.md` on 2026-09-15, when every instrument in the RTL was
removed on branch `strip_debug`. The sections below are verbatim as they stood in
`CLAUDE.md` at `6b55c1a`, the tree before that work, and they describe modules,
scripts, build knobs and probes that **no longer exist in the tree**:
`sun2_clobber`, `sun2_dvma_probe`, `sun2_blktrace`, `sun2_trace`, `dbg_bus` with
the Vivado ILA, bus-history ILA and VIO, the DVMA throttle, `WRITE_VERIFY` and
`DOUBLE_READ` in the DDR3 adapters, the pattern checkers in the bridge and the
Xylogics 450, and the readout scripts under `syn/` and `tools/` that drove them.
`git show 6b55c1a:<path>` recovers any of them.

`CLAUDE.md` keeps the outcome -- the mechanism, the fix, the measurements and
the lessons that still apply. This is how it was reached, kept because the
eliminations in it are real, even where the theories around them were retracted.

## The single-word disk corruption

**Resolved 2026-09-13 -- read this first.** The single-word disk corruption
that everything below chases was a *bus-errored memory access issuing a phantom
DDR3 request*: in the clock after a refused cycle's AS negates, `MATCH_MEM` was
true for one clock, the adapter ran that orphan read, and the next memory cycle
-- typically a master's first halfword -- took its acknowledge and its data.
Found with a bus-history ILA, reproduced by `tb/tb_orphan_ack.sv`, fixed in
`sun2_fpga.v` by holding the MMU's refusal for the rest of the cycle, and
measured on the board at **0 of 8,388,608** where the same setup gave 140, 149
and 177, and again at 0 on a machine booted from the filesystem under test. See "Found and fixed" near the end of this investigation. The history
below is kept because the eliminations in it are real, but several of its
theories (retention, write visibility, DM pins) are superseded by that result.

**Writing to the card corrupts files, the blocks go to the right places, and
what it needs is concurrency rather than volume.** A copy is byte-perfect on
its own and three copies back to back all come back wrong -- measured on a
freshly written filesystem in single user, so it is neither the medium's
history nor a busy multi-user machine:

```
  /usr/bin/adb -> /wa   copied alone            50905 -> 50905   intact
  /vmunix      -> /wb   three copies back to    22308 -> 12922   corrupt
  /usr/bin/csh -> /wc   back, same session      34435 -> 29822   corrupt
  /usr/bin/adb -> /wd                           50905 -> 46503   corrupt
```

`fsck` is clean afterwards, so the damage is inside files and not in the
structure, and `cmp` puts `/wd`'s first difference at byte 4385 -- past several
blocks that are byte-identical, so it is not a transfer that goes wrong from
the start.

**Misdirection is dead, and that was the open question.** `sun2_blktrace`
(`BLKTRACE=1`, read out by `tools/deca_blktrace.tcl`) recorded the copies:
every block landed at exactly the LBA its position in the file predicts --
partition sector 2400 + 32k for block k, which is 4.2BSD's rotational layout --
in order and self-consistent, for all thirteen blocks of a file that came back
corrupt. So "the hardware writes at the wrong address" is finished, and the
fault is in the data path between memory and the card.

Four layers were already cleared by test and none of them was it: the media, the
SD path on real hardware (`test/deca_sdtest`), `blk_sd` in simulation (`make -C
sim blksd`), and the SCSI engine and `sun2_dvma` (`make -C sim mbscsi`, `dvma`)
including at DDR3-like latency with several commands back to back. The XY450
corrupts identically, which exonerates every line of the SCSI work; what the
three controllers share below them is `sun2_dvma`, `sun2_wishbone_bridge` and
BrianHG's controller. `tools/wrprobe` puts a CPU in a spin loop while the
master streams, which is the one condition no testbench here reproduces, and it
passes -- so whatever it is, a boot block driving the same path does not
provoke it.

**What it is: exactly one 16-bit word per damaged sector, at an even offset.**
Not a burst, not a whole sector, not another file's block:

```
  adb sector  89, byte 136:   660c -> ffff
  csh sector  73, byte 500:   0000 -> 4ef8
```

`4ef8` is ordinary 68010 code (`JMP`), so the `ffff` is not a bus-idle pattern
either -- both look like data from somewhere else. One word in roughly a hundred
thousand. A DVMA longword is two 68010 cycles, so **one wrong 16-bit word is one
half of one longword read**, which is the shape of two bugs this tree has already
fixed (RD68011's bus-grant handover, and the bridge serving two masters).

**The trace predicts the medium, twice over.** On a pristine filesystem it named
`csh` sector 8 and `adb` sector 13 as the damaged ones; `cmp` on the rebooted
machine put the first differences at bytes 4121 and 7145 -- sectors 8 and 13.
That is the instrument checked against ground truth rather than trusted.

**Two candidates eliminated by measurement, both cheap and both plausible:**

* *BrianHG's `PORT_CACHE_SMART`.* With it zero, a read whose address matches a
  write still sitting in the write cache (`WC_ready` set, `WC_DDR3_ack` not yet
  seen) goes to DRAM and returns the previous contents -- the exact shape of the
  fault. `deca_top` had it zero. Set to 1 (`DDR3_SMART`, +460 LE, timing met)
  the corruption is unchanged. It also sits in the path the **CPU** uses, and
  the machine's own survival argues against that path: the CPU issues orders of
  magnitude more traffic through the bridge than any master, and a fault there
  at this rate would be fatal long before it showed up in a file.
* *A stale bus grant in `sun2_dvma`.* `P_BG_n` was tested as a level, and the
  module negates `P_BR_n` for only two clocks (`S_ACK`, `S_IDLE`), so during a
  streaming transfer it can re-request inside the CPU's spec-#36 window and read
  the *previous* transaction's grant as an answer. Real, and **fixed** -- it now
  waits in `S_IDLE` until the grant is withdrawn, which also buys spec #39 by
  construction. But it cannot be the cause: `D_FETCH` returns only after
  `D_OUT`/`D_OUTACK` have handed all four bytes to the target one at a time, so
  the gap between Wishbone fetches is far longer than the 1.5-3.5 clock window.
  Measured: with the fix in and a pristine filesystem, 5 sectors of ~600 still
  corrupt.
* *AS timing.* `sun2_dvma` drove AS from a posedge state machine, so both edges
  landed on rising ones and the asserted width was a whole number of clocks --
  minimum 2.0, where a 68010 never gives less than 2.5 and releases on a falling
  edge (spec #14). That matters in principle because `sun2_fpga`'s chain is
  edge-faithful. **Fixed** (`09ecfe2`), and the corruption is unchanged: 5
  sectors of ~600 again, at the same rate. The 2.0-clock floor was unreachable
  anyway -- memory DTACK cannot arrive before `C_S6`, two clocks after AS, so a
  DVMA memory cycle's AS is nine to fifteen clocks wide in practice.

  Note what the fix is *not*. A "BG was seen negated" flag deadlocks: it still
  re-asserts BR after two clocks, and a core deciding from the current BR level
  may then never negate BG, leaving the flag clear for ever. Holding BR negated
  is what makes the CPU withdraw the grant.

**Both directions corrupt, and the read side had been wrongly cleared.** A file
pristine on the medium came back wrong *in memory*, and a file correct in memory
landed wrong on the medium, in the same session:

```
                       on disk (cold)   in memory (warm)
  /usr/bin/adb            50905            55306
  /usr/bin/csh            34435            34435
  /za  (copy of csh)      49861            34435
  /zb  (copy of adb)      01370            55306
```

`/usr/bin/adb` is byte-perfect on the card and was read into the buffer cache
wrong; `/za` was correct in the buffer cache and reached the card wrong. So this
is not a memory-to-device transfer bug, and the paragraph below -- which
concluded reads were clean from `dd if=/dev/rsd0a | sum` agreeing twice -- was
measuring the *raw* path, which bypasses the buffer cache, and does not
generalise.

**That reframes the whole search, and suggests one mechanism for all of it.**
Data is correct when written and wrong when read back later, in both directions,
while every handshake, response and lane check in between reads zero and a
double read of the same address agrees with itself. What fits all of that is
data decaying *while resident in DDR3* -- a refresh or retention problem in
`Inputs/BrianHG-DDR3` -- rather than anything about the transfer. It would also
explain why `test/deca_ddr3` passes (it writes and reads straight back, with no
dwell) and why the CPU survives (its text pages are re-read from disk, and a
decayed instruction shows up as the `lpd` cores and `ld` SIGILLs this file
already records).

**Retention was measured and it is not that.** `tools/memdwell` fills memory
with a self-describing pattern, leaves it alone, and reads it back; on 2 MiB in
single user, three dwells of 600 s each plus a zero-dwell control gave **0 wrong
of 3,145,728 halfwords**. Idle memory does not rot, so the decay story is dead
as stated.

**What fits instead is a write that a later read does not see, and it explains
both directions with one mechanism.** A disk write is: the CPU writes the buffer
into DDR3, then DVMA reads that buffer out. If the CPU's write has not become
visible when the master reads, the card gets the *previous* contents while a
later CPU read sees the landed write -- which is exactly `/za`, correct in
memory at 34435 and wrong on the card at 49861. A disk read is the mirror: DVMA
writes the buffer, the CPU reads it, and a write not yet visible gives the CPU
stale data while the card holds the truth -- exactly `/usr/bin/adb`, 50905 on
the card and 55306 in memory. `patwr`'s bad word decoding to *old-generation
content from another position* is the same thing seen a third way.

**And the double read cannot see it, by construction.** It issues the same
address twice back to back and compares; if a write has not landed, both reads
return the same stale value and agree. Every counter stays zero. So the zero it
reported is consistent with this and never excluded it.

**Measured, and writes are visible.** `WRITE_VERIFY` in `deca_wb_to_ddr3` reads
every write straight back and compares it against what was written, byte-masked
by `wb_sel`, with `PORT_CACHE_SMART` held at 0 so the read-back cannot be
answered out of the write cache and confirm itself. `tb_deca_wb_ddr3` runs the
arm and injects a dropped write to prove the check can see one. On the board,
across a boot: **0 wrong**. The counter is demonstrably live -- responses exceed
`reads issued` by about 19,895, which are the read-backs themselves, since that
counter only counts `CMD_ena && !req_we`.

**So every layer this project owns is now measured clean, and the fault is still
there.** Handshake, response accounting, lane, half, capture, read consistency
and write visibility all read zero on runs that corrupt.

**Qualified 2026-09-13: the write-visibility zero above was one boot, not a run
that corrupted.** About 20,000 verified writes, against a fault of roughly one
word in 60,000 to 130,000 pattern writes, cannot tell a lost write from none.
It has since been repeated on a real corrupting pass (the "sun2_clobber" results
further down): `patwr` 90 wrong, 88 wrong at the master's capture, **write
verify still 0** over the whole 16 MiB. But the check compares **only the bytes
the write itself enabled**, so it proves each halfword was right *immediately
after its own write* and says nothing about the other half of the same 32-bit
word afterwards.

**It is not the DECA, and it is not BrianHG's controller.** A Wukong V3 --
Xilinx, Vivado, MIG, a MultiBus machine with the **Xylogics 450** rather than
SCSI, at 20 MHz -- boots SunOS from the same micro-SD card and corrupts at the
same rate. `tools/patwr`, 512 KiB, written and verified cold after a reboot:

```
  BAD  sector  69 word 132  want c584  got 6d08
  BAD  sector 215 word 114  want d772  got 281c
  BAD  sector 326 word 158  want c69e  got 6d08
  BAD  sector 853 word  44  want d52c  got 281c
  patwr: 4 of 262144 words wrong
```

Four in 262,144, against three to six on the DECA. So the fault survives a
change of FPGA vendor, toolchain, DDR3 controller, board and disk controller,
which eliminates every DECA-specific suspect at once -- BrianHG's controller
above all, after several sessions spent narrowing onto it.

**What both machines share is this project's own RTL**: `sun2_wishbone_bridge`,
`sun2_dvma`, the MMU and bus in `sun2_fpga`, `blk_sd`, and the RD68011 core.
The DECA measurements already put the damage *before* the master's capture --
the word is wrong as it comes out of the bridge -- and the bridge is shared
while the two memory controllers under it are not. That is the place to look.

**Two distinct wrong values, each appearing twice**, is the other lead: `6d08`
at two file offsets 9834 words apart and `281c` at two more. A fault that
returns the *same* wrong word at unrelated addresses is not random decay; it
looks like a stale register or a buffer read twice.

**Caught in flight: the data is already wrong when it reaches the card.**
`tools/patwr -u` writes a pattern that is the same in every sector -- halfword i
is `0x8000 | i`, so byte 2i is `0x80` and byte 2i+1 is `i` -- which the FPGA can
predict from the buffer address alone. `sun2_blktrace` checks every byte against
that as it goes out, gated on the sector's first two bytes so ordinary traffic
is ignored. On a freshly written filesystem, 256 KiB:

```
  sectors seen      512
  bytes wrong         6
  first: LBA 00100644 byte 432, wanted 80 got 53
```

Six bytes in 262,144 -- the familiar rate -- and **the fault is now localised in
hardware, at the moment it happens**, rather than inferred from a checksum after
a reboot. It is upstream of `blk_sd`, the SPI bus, the card and the medium,
because it is already present at the last point inside the FPGA before them.
`wanted 80 got 53` is also informative: `0x80` is the *even* byte of every
halfword, so the damaged byte is the high half of a 16-bit word, and `0x53` is
neither a neighbouring pattern byte nor zero.

**The same check at the master's capture closes the span.** `sun2_dvma_probe`
predicts the pattern from `dvma_a[8:1]` -- a buffer-cache block is 512-byte
aligned, so the halfword index within a sector is in the address -- and counts
only an *isolated* miss, one with matching words on both sides. On the same run:

```
  at the master's capture   wrong words 4, first took 53d2 (wanted 80xx)
  at the card interface     byte 432, wanted 80 got 53
```

**The "4" above is not the master-capture count** -- found and fixed
2026-09-13. `tools/deca_dvmaprobe.tcl` assigned `pat_bad` twice, the
master-capture count (offset 32) and then the block-seam count (offset 389), in
the same commit that recorded this table (`d075d7f`), so "wrong words" has
always printed the block-seam figure. `first took 53d2` is a separate field
(offset 48), set only by a real master-capture miss, so the conclusion drawn
from it stands; the count does not. The fixed tool read **88** at the master's
capture against `patwr`'s 90 on the first run after the fix.

**`0x53` replacing `0x80` at both ends.** So the word is already wrong when the
master captures it from the bridge, and `sun2_dvma`, the SCSI engine, the sector
buffer, `blk_sd` and the card are all downstream of the damage. The fault is at
or below DDR3.

**And that is not retention, because the same memory is provably good when
written.** `WRITE_VERIFY` reads every write straight back and finds 0 wrong;
`DOUBLE_READ` finds the controller self-consistent; `memdwell` finds no decay in
600 s of idle. What is left is a value that changes between the write and a
later read **while other traffic is in flight** -- disturbance under load rather
than decay at rest, which is why every quiet test passes. `0x80` to `0x53` is
five bits, so it is not a bit flip; it is a different byte, from somewhere else.

Two things about reading these counters. `matches` is 16 bits and a 512-sector
pass is 131,072 words, so it wraps: the first run of this check read `matches 0`
and looked dead when it was exactly two wraps. And the check must count only
isolated misses -- the first version armed on a run and then flagged everything,
reporting 1018, because a master reads plenty that is not the pattern.

**Everything from DDR3 up to and including the bridge is now measured clean on
a run that demonstrably corrupted.** That last clause is the whole point: the
counters had read zero twice before on runs that turned out not to have
corrupted at all, which proves nothing. A `patwr -u` pass followed by a reboot
and a cold verify gave **5 of 262,144 words wrong**, the familiar signature, and
the VIO on the same run read:

```
  read crossing    pattern 3,653,604     corrupted  0
  write crossing   pattern 2,095,307     corrupted  0
  bridge address   loads   741,868,089   wrong addr 0
  bridge half      pattern 1,826,787     wrong half 0
```

So on a corrupting run, with controls in the millions: both adapter clock
crossings are clean, every response is matched to the address its request went
out with, and the half the bridge selects and latches is the right one. The
fault is **not** in DDR3, not in either crossing, and not in the bridge.

**The wrong values are ASCII, and that is the lead.** `2e2e` is `..`, `2f2d` is
`/-` -- two characters of the bootloader's own `|/-\` spinner -- and `584f` is
`XO`. Not decayed bits and not another position in the pattern: content from
somewhere else entirely, which is what a stale bus value or a mux selecting the
wrong source looks like.

**Which leaves one span, and it is narrow.** `P_DATA_OUT` is proven correct as
it is latched; the DECA measured `dvma_din` already wrong at the master's
capture. Between them lie only `sun2_fpga`'s read mux onto `P_DOUT` and
`top_fpga`'s muxing of CPU against DVMA -- both shared by the two boards, and
neither instrumented.

**Two traps from the tooling, both of which produced confident nonsense.**
`tools/patwr`'s flags used to be mutually exclusive, so a `-u` file could not be
verified after a reboot at all -- the cold check that anchors every hardware
counter was impossible to run. Making them combine introduced the second: the
new parsing loop assigned `vonly` and `fill` only inside its branches, and they
are auto locals, so a plain write ran as **"verify only"** against a zero-filled
file and reported 5531 bad words. A run of consecutive `got 0000` is that, or an
interrupted write; the single-word fault is always isolated. Read the banner --
it says which mode actually ran.

**The mux is clean, the master's capture is correct, and that moves the fault
*downstream* of everything instrumented so far.** On a run that corrupted 2 of
262,144 words:

```
  mem reads   585,496   the master's memory captures
  mux wrong         0   P_DOUT was always the bridge's registered word
  pattern     524,283   ... of which were the pattern
  pattern bad       0   ... and every one of them was right
```

So `sun2_fpga`'s 20-way `P_DOUT` mux and the CPU/DVMA routing are exonerated,
and -- the stronger half -- **the word `sun2_dvma` captures is correct**. The
damage happens after the capture.

**That contradicts the DECA's earlier reading, and the Wukong's is the one to
believe.** `sun2_dvma_probe`'s original check predicted the pattern from
`dvma_a[8:1]` and counted *isolated misses* after arming on a run -- a heuristic
that had already produced 1018 false positives once and needed rewriting. The
check here compares `dvma_din` against `brg_dout`, the bridge's own registered
word, on the capture edge: a direct comparison with no arming and no
prediction, with a 585,496 control on a corrupting run. Where a heuristic and a
direct comparison disagree, the direct one wins.

**Which leaves `sun2_dvma`'s assembly, and it fits the evidence exactly.**
`sun2_dvma.v:379` builds the Wishbone word from two halves latched in
*different* 68010 bus cycles:

```verilog
   wb_dat_o <= {rd_hi[7:0], rd_hi[15:8], rd_lo[7:0], rd_lo[15:8]};
```

If one cycle's latch is missed, that half keeps the **previous transaction's**
value and the assembly writes it out -- one wrong 16-bit word at an even offset,
carrying content from somewhere else entirely. That is the whole signature, and
`2e2e` (`..`) and `2f2d` (`/-`) are what a stale half from an earlier sector
looks like. It is also below the point where the XY450 and the SCSI card
diverge, which is why both corrupt identically.

The check is a flag per half, cleared when a transaction starts and set at each
`S_LATCH`: count any assembly where both were not set.

**The sector buffer is written correctly, nothing is dropped, and the fault is
now inside one RAM.** Three runs, each anchored by a cold verify that the run
really did corrupt (1, 3 and 5 wrong words):

```
  sbuf bytes offered   1,048,776   the control
  wrong, isolated              0   every byte offered was the right one
  DROPPED                      0   no DMA write lost to the buffer port
```

`sun2_xy450.sv`'s buffer is one port shared by two masters --
`buf_we = blk_busy ? blk_buf_we : dma_buf_we` -- so a DMA write offered while
`blk_sd` holds the port is discarded silently, and `E_IN_PUT`'s own comment
argues from timing that the last one "lands". **It does: the counter is zero.**
A good hypothesis, cheap to test, and wrong.

So the byte is right when offered and right when stored, while `sun2_blktrace`
on the DECA sees it wrong as it is *read out* at the `blk_*` seam. What is left
between those two points is the `sbuf` RAM itself and its read port:

```verilog
   if (buf_we) sbuf[buf_addr] <= buf_wdata;
   buf_q <= sbuf[buf_addr];
```

a single-port read-first RAM whose address is muxed by `blk_busy`, answering one
cycle late (`Inputs/Wish5380/doc/block.md:58`). That is a very small piece of
RTL, and it is shared with the SCSI card only through `blk_sd`'s side of the
seam -- which is the part both cards do have in common.

**The raw-versus-isolated split is what made the number readable.** The first
board run of this check read **214 wrong bytes** against a disk that took 5
wrong words -- forty times too many. Every one of them was a *run*: a sector
that is not the pattern, still being checked because the arming flag was set by
the sector before. Counting only isolated misses takes it to zero and leaves the
raw figure beside it for comparison. This is the third instrument in this file
to need that rule; assume any new one does too.

**The byte is correct entering the sector buffer and correct leaving it.** With
the check counting once per byte -- on the clock `blk_buf_addr` moves, which is
when `blk_sd` loads `spi_tx` and `crc16` from the same expression -- the control
lands within two of the write side, which is what says the instrument is right:

```
  offered into the buffer   1,048,776   wrong 0   dropped 0
  read back out of it       1,048,778   wrong 0
```

on a run whose cold verify found 3 of 262,144 words wrong. So the buffer stores
and returns exactly what it was given, and the sample taken is provably the byte
`blk_sd` consumed: `byte_done` is high the clock after the address moves, and
`ok_q` is the comparison registered from the clock before, which is the value
that was on `buf_rdata` when it was captured.

**What is left is very small, and one part of it argues against itself.**
Between `spi_tx` and the card there is only the SPI shifter and the wire -- but
`crc16` is computed from the *same* `blk_i.buf_rdata` in the *same* clock, so a
byte damaged after that point would go out with a CRC that does not match it,
and the card would reject the block rather than store it wrong. A whole sector
would keep its old contents, not one word.

**The card was read on a host and it settles it: the medium is wrong, and the
three damaged sectors are exactly the three the machine reported.** 400 MiB
dumped from the card and scanned for `patwr -u`'s pattern, which is
unmistakable (`80 00 80 01 80 02 ...`) and needs no filesystem walk:

```
  pattern sectors 1040   clean 1037   damaged 3
  LBA  2405 byte  4   want 80 02   got 2e 2e     (file sector 101 word  2)
  LBA 30678 byte 28   want 80 0e   got 2e 2e     (file sector 358 word 14)
  LBA 31285 byte 76   want 80 26   got 58 4f     (file sector 661 word 38)
```

The machine's own cold verify named those three word indices with those three
values. So the read path is faithful -- it reported exactly what is on the card
-- and the damage happened on the way out.

**And that produces a contradiction which is itself the finding.** On the run
that wrote them, the byte was measured correct entering the sector buffer
(1,048,776, none wrong, none dropped) and correct leaving it (1,048,778, none
wrong). `blk_sd` loads `spi_tx` **and** `crc16` from that same `buf_rdata` in
the same clock, so a byte damaged after the CRC was computed would go out with a
CRC that does not match and the card would **reject the block** -- losing a
whole sector, not two bytes. No logic fault after the buffer fits.

**What fits is a glitch on `buf_rdata` at the capture edge.** Both `spi_tx` and
`crc16` sample that net, so both take the same wrong value: the CRC agrees with
the corrupted data, the card accepts it, and one byte is wrong on the medium.
The checker in `sun2_xy450` reads the same *logical* net through different
*physical* routing, so a marginal path to one load and not the other is
invisible to it by construction.

That makes this a timing problem rather than an RTL one, and it accounts for
every property this investigation has recorded: **simulation can never reproduce
it**, because zero-delay logic cannot glitch; every RTL-level check reads zero;
both boards show it while sitting near their limits; and it is rare,
single-byte, and placement-sensitive. This build meets timing at **WNS 0.039
ns**.

**The clock was changed and the account above is wrong.** Same RTL at
`CPU_DIV=80` -- 12.5 MHz, WNS **1.228 ns** against 0.039, thirty-one times the
margin -- corrupts at exactly the same rate: 3 of 262,144, where 20 MHz gave 1,
2, 3, 3 and 5 across runs. **It is not a setup-time glitch**, and the neat
story about `spi_tx` and `crc16` sampling a glitching net is retracted.

**The wrong values are 68010 instructions, and that is the lead.** They were
read here as ASCII -- `2e2e` as `..`, `584f` as `XO`, `2f2d` as `/-` -- and that
was wrong. Searched in context on the card:

```
  584f   101,968 occurrences   addqw #4,%sp     -- stack cleanup after a call
  2f2d    14,529               movel %a5@(d16),%sp@-
  2e2e    10,250
```

`584f` is one of the most common words in any compiled 68010 program. So the
corrupting source is **program text**, the same few opcodes every time because
those are the commonest ones, appearing at random positions.

**And that explains why every check in the disk path reads zero, by
construction.** `n_pat32` counts a word only when `brg_dout` already matched the
pattern; `xchk_n_wpat` counts a write only when it was the pattern in the
Wishbone domain; the `sbuf` checks arm on a sector whose byte 0 is `0x80`. A
word that is *already wrong in memory* matches none of those conditions, so it
is never counted -- the whole instrumented path faithfully carries a word that
was corrupt before it started.

So the suspicion moves off the disk path entirely and onto the buffer-cache page
in DDR3: something is putting program text into it between the CPU's write and
the master's read. `patwr`'s own read-back is clean, but it reads from the
buffer cache and runs *before* the kernel flushes, so it cannot see a page
contaminated after that.

**The inverse check was built and it is the first non-zero in the whole
investigation.** `sun2_dvma_probe`'s original run-armed counters -- armed by a
run of words matching what their *address* predicts, not by the word already
being the pattern -- widened to 32 bits and put on the VIO:

```
  in a run     524,286   the control, essentially every pattern word
  ARRIVED BAD        2   wrong before it entered the disk path
```

Two passes, two bad arrivals; the cold verify of the final state found **1**,
which is the last pass's share. Consistent, and anchored.

**So the word is already wrong when the master captures it from the bridge** --
which is exactly what the DECA's `sun2_dvma_probe` said, and which this file
retracted in favour of the content-gated check. **That retraction was wrong**:
the content-gated comparison cannot see this fault by construction, and the
heuristic it was said to beat was measuring the right thing all along. A direct
comparison is not automatically better than a heuristic if it is gated on the
very condition the fault violates.

**Which means memory held program text where the pattern belonged.** The write
crossing says the CPU's write landed, the bridge says the response matches the
address it was requested for, and the master says it read that address and got
`584f`. Something wrote into that DDR3 location between the two.

**The controller holds its request perfectly still, so that is not it either.**
`sun2_dvma` now latches `wb_adr_i` and `wb_dat_i` when a transaction is taken
and compares them for as long as it runs -- `dvma_a` is `{wb_adr_i, half}`,
combinational with no latch of its own, so a moving `wb_adr_i` would put the
access on a different page:

```
  transactions  728,901
  ADDR MOVED          0
  DATA MOVED          0
  ARRIVED BAD         7   (same run, so the fault was present)
```

**The ILA caught the failing cycle, and the address the bridge is given is
built from a page-map output that lags.** With `arrived_bad` as the trigger --
the first trigger in this investigation that was *known* to fire, because the
counter behind it reads 2 and 7 on runs whose cold verify finds the corruption
-- one capture shows the whole thing:

```
  -38  A=7815d3 FC=5 ps=f02  data=80d2  dvma=1
  -27  A=7815d3 FC=5 ps=f02  data=80d3  dvma=1
  -26  A=01235e FC=1 ps=d03  data=dead  dvma=0   <- a CPU cycle interleaves
  -22  A=7815d4 FC=5 ps=d03  data=dead  dvma=1   <- ps is still the CPU's page
  -20  A=7815d4 FC=5 ps=f02  data=80d3  dvma=1
  -14  A=7815d4 FC=5 ps=f02  data=584f  dvma=1   <- the wrong word
    0  A=7815d5 FC=5 ps=f02  data=80d5  dvma=1   <== trigger
```

Three consecutive addresses return `80d3`, **`584f`**, `80d5`: the wrong word
sits exactly where `80d4` belongs, in an otherwise perfect run, and the cycle
that fetched it **began carrying the previous CPU cycle's page-map entry**.

**And the address handed to the bridge is made of that entry:**

```verilog
   .P_ADR_IN({1'h0, ma_pmap2devices[11:0], P_A[10:1]})   // full physical
```

`ma_pmap2devices` is the page map's registered read, so it is valid a cycle
after the lookup; `MATCH_MEM` is `... & (ma_pmap2devices[11:0] < MEM_PAGES) &
C_S6`, using it combinationally. A request issued while it still holds the
previous cycle's page reads **the wrong physical page**, and DDR3 returns that
page's contents perfectly -- which is why every check downstream is clean and
why the wrong values are always common 68010 opcodes.

It accounts for every property recorded here. The word is wrong before the
master captures it; the bridge's own address check compares `P_ADR_IN` at issue
against `P_ADR_IN` at load and they *agree*, because both are stale; the rate is
unchanged by clock frequency, because it is a logic race and not a setup
violation; it needs a CPU cycle interleaved with a DVMA cycle, which is why a
disk transfer under load provokes it and a quiet memory test never does; and it
is in `sun2_fpga.v`, shared by both boards.

**An extra settling cycle before AS was tried and does not fix it.** The
hypothesis was that the MMU chain is a cycle late when `FC[2]` changes, because
the context register selects a different half and everything downstream shifts.
`sun2_dvma` grew an `S_SETTLE` state between `S_ADDR` and `S_STROBE`, giving the
address and function code **two** clocks before AS instead of one. Measured:

```
  in a run     524,282
  ARRIVED BAD        6      unchanged
```

with the MultiBus fingerprint still 22/274, so the change was harmless and
useless. It has been reverted.

Three things came out of it that narrow the search rather than widen it:

* **The chain really is two clocks.** `smap_sram` is synchronous, so
  `ia_smap2pmap` is valid a clock after `P_A` and `cx` move; `pmap_sram` indexes
  on *that*, so `ma_pmap2devices` is valid a clock later again. `S_SETTLE`
  supplied exactly the missing clock, and the fault did not move.
* **So the transient is not what reaches the bridge.** `MATCH_MEM` is gated on
  `C_S6`, which the captures show arriving several clocks after the map has
  settled -- the `048 -> 045 -> aca` transient is real but has gone by then.
* **The context register is not involved at all.** In all three captures both
  halves held the same value and `cx` never moved, so no context selection
  changed. The user-mode-precedes-fault correlation (3 of 3) is a property of
  the workload -- `patwr` is a user program, so interleaved CPU cycles are
  user-mode as a matter of course -- and not the mechanism.

**And the physical page is correct at the moment the request is issued.**
Reading `ma_pmap2devices` at the clock `C_S6` rises, in all three captures:

```
  ev1  C_S6 at -20: A=781674 FC=5 dvma=1  ma=b26
  ev2  C_S6 at -20: A=78152a FC=5 dvma=1  ma=aca
  ev3  C_S6 at -20: A=78152e FC=5 dvma=1  ma=b6e
```

Every one is the right page for that cycle. `MATCH_MEM` is gated on `C_S6`, so
that is the value the bridge uses -- the transient has settled several clocks
earlier. **The stale-page-map account is dead**, and the `S_SETTLE` null result
was telling us so before this confirmed it.

**DOUBLE_READ and ARRIVED BAD on the same run resolve it.** `DOUBLE_READ` is
ported to `wb_to_mig_ui` now and issues every read twice, comparing the answers:

```
  in a run       524,279
  ARRIVED BAD          9      the fault was present on this run
  compared   195,547,866      every read doubled
  DISAGREED            0
```

195 million comparisons, none disagreeing, while nine words arrived wrong. So
the read is **not** a transient: memory really did hold program text at the
instant the master read it, and the pattern appeared there later -- which is why
`patwr`'s own read-back, minutes afterwards, is clean every time.

**That makes it a write-visibility fault, and the mechanism is already named in
this file.** "One transaction in flight on the whole interface, because MIG's
`ORDERING = "NORM"` is not established here and the read path has no tag."
The adapter serialises its *own* requests, but a write is finished from its
point of view when the controller accepts it, not when it reaches DRAM. A read
issued afterwards -- by the other master, for the buffer the CPU has just
filled -- can be answered from memory before that write drains, and it gets the
page's previous contents: program text.

It fits every measurement. The word is wrong before the master captures it; the
physical page is right at `C_S6`; both crossings, the lane, the half and the
response matching are clean, because every one of them faithfully carries a
value the controller really returned; the rate does not move with clock
frequency; and it needs a CPU write and a master read of the same page close
together, which is exactly a disk flush of a buffer the CPU has just written and
nothing a quiet memory test ever does. `WRITE_VERIFY` passes because it reads
back through the same port, which *is* ordered against its own write.

**MIG's strict ordering does not fix it, and that matters.** `syn/mig/sun2_mig.prj`
carried `<Ordering>Normal</Ordering>` -- the mode that explicitly lets the
controller reorder for efficiency -- which looked like the whole answer.
Rebuilt with `Strict`, confirmed as `ORDERING = "STRICT"` in the generated
`sun2_mig_mig.v`:

```
  in a run     524,282
  ARRIVED BAD        6      unchanged
  compared 205,049,131
  DISAGREED          0
```

So the controller is not reordering a read ahead of a write. Reverted to
`Normal`.

**The contradiction was an artefact of file size, and the account built on it is
withdrawn.** `patwr`'s in-pass read-back is ordinary buffered I/O -- `write()`
then `read()` on the same descriptor -- so with a 512 KiB file on a 7 MiB
machine it is served entirely from the pages the CPU just wrote. It compared
memory against memory and could not fail. The tool's own header says exactly
this and prescribes the fix ("make the file far larger than the cache"), and
512 KiB does not meet it.

Rerun at **8 MiB**, larger than RAM, the read-back misses the cache and reports
the corruption **in the same pass, with no reboot**:

```
  BAD  sector 217 word 172  want 80ac  got 584f
  BAD  sector 361 word 126  want 807e  got 2e2e
  BAD  sector 783 word  20  want 8014  got 2f2d
```

So there was never any evidence that memory held the right word at the master's
address. Everything is consistent with the simplest reading: **memory holds
program text there, and always did.** The master reads it faithfully
(`ARRIVED BAD`), the controller agrees with itself (`DISAGREED 0` over 205
million pairs), strict ordering changes nothing because there is nothing to
reorder, and the disk gets what memory held.

**A write-coverage check on the CPU's side, and its first reading needs
refining.** `tools/patwr -u` makes every write self-identifying, so
`sun2_wishbone_bridge` keeps 256 bits -- one per halfword offset -- for the
512-byte block being written, and when the address moves to another block asks
whether every bit was set. Counting could never answer this: the pattern-write
counter already *exceeds* the file it wrote, so a shortfall of six in half a
million is invisible. Completeness can.

On an 8 MiB pass, with the read-back now missing the cache and reporting the
corruption in-pass:

```
  in a run     4,194,221   = the 4,194,304 halfwords in the file
  ARRIVED BAD         83
  blocks          15,448   near-full pattern blocks closed
  INCOMPLETE       1,191   ... missing at least one write
```

The two controls are as good as they get -- both land on the workload's own
size. **`INCOMPLETE` does not**: 1,191 is 7.7% of blocks against a corruption
rate near 0.5%, fourteen times too many, and `first miss offset 0` is the
signature of a block closed before it was filled rather than a lost write. The
kernel interleaves metadata and writeback with the copy, so a block is left and
returned to, and every such departure closes it early.

**Counting the shape of the miss rather than the fact of it answers the
question: the CPU's writes are not missing.** A lost write leaves a block
missing *exactly one* halfword; an interleaved block misses many. Gated on 255
of 256:

```
  in a run     4,194,211   control = the file's halfwords
  ARRIVED BAD         93
  blocks          14,289   control
  INCOMPLETE           1   one block, missing one write
```

**One, against ninety-three corrupted words.** So a missing CPU write accounts
for at most one of them and is not the mechanism -- and the single hit may
itself be a boundary artefact of the same kind the unrefined check produced in
quantity.

**And `ARRIVED BAD` is now calibrated one-for-one against the fault.** `patwr`
reported **93 of 4,194,304 words wrong** on that same run, in-pass, against the
detector's 93. The two are measured at opposite ends of the machine -- one in
the bridge's clock domain, the other by software reading the file back from
disk -- and they agree exactly. That is the strongest validation any instrument
in this investigation has had, and it means a hypothesis can now be tested
against a count that *is* the corruption rather than a proxy for it.

**And the DVMA side is clean too, so the last writer of memory is exonerated.**
The mirror check watches every data access the disk controller makes and asks
whether it lands inside the sector it is moving. On an 8 MiB pass:

```
  ARRIVED BAD          92      patwr: 92 of 4,194,304 -- exact, a second time
  blocks           14,266
  INCOMPLETE            0      every CPU write present
  DVMA accesses 6,867,712
  OUTSIDE               0      none outside its sector
```

`INCOMPLETE 0` also retires the single hit the previous run showed: it was the
boundary artefact it looked like, not a lost write.

**So both writers of memory are now measured clean on a run that corrupted 92
words.** The CPU writes every word of every buffer; the disk controller never
addresses outside the sector it is moving; memory is self-consistent across 205
million read-pairs; nothing is reordered; the physical page is right at `C_S6`;
and the read path from DDR3 to the card is clean end to end. The corruption
persists at exactly the same rate through all of it.

**The CPU alone does not corrupt memory, and the same machine corrupts a disk
write minutes later.** `tools/memchk.c` with `tools/memloop.s` fills 3 MiB with
a constant and reads every longword back, both loops in the 68010's **loop
mode** -- one one-word instruction plus `DBcc`, cached inside the chip, so the
bus carries operand traffic and no instruction fetches. Six constants, three
passes, about 108 MiB of read and write traffic from the heaviest memory client
the machine has:

```
  memchk, 3 MiB x 6 constants x 3 passes      0 wrong
  patwr -u, 16 MiB, same boot, same machine   corrupting
```

So it is not simply "memory under load". A disk transfer differs from this in
one respect that matters: it interleaves a DVMA master with the CPU, where
`memchk` is the CPU alone at full rate. That is consistent with everything else
here -- the fault has always needed a master.

**A rewritten card was needed to run it at all, and the reason is worth
keeping.** `ld` failed to link even `main(){printf("hi\n");}` on the 512 MiB
copy and again on the 1536 MiB one, with the failure moving between SIGSEGV and
SIGILL. Two filesystems and a moving failure reads as the machine, and it was
not: with every copy rewritten, `cc` links and runs first time. **The toolchain
had been corrupted on disk by the very fault under investigation.** A machine
that cannot build its own instruments is the end state of leaving a filesystem
in service after it has been written by a corrupting path.

**What a constant cannot see**, recorded beside the zero: a word fetched from
elsewhere *in the same buffer* holds the same constant and is invisible. Program
text intruding -- what the disk tests actually find -- is caught, and varying the
constant catches a value surviving from the previous pass. A position-derived
pattern is strictly stronger and is the next step.

**The Ethernet's DVMA is clean, over 33.5 MB, in both directions.** A VME 2/50
with no storage -- so the 82586 is the only master -- netbooted, with
`tools/netchk.c` on the machine and `tools/netchk_host.py` on a host on the same
subnet, streaming `patwr -u`'s pattern over TCP so that no filesystem, buffer
cache, disk driver or controller is in the path at all:

```
  host -> board   16,777,216 + 67,108,864 bytes, 0 wrong   DMA writing memory
  board -> host   16,777,216 + 67,108,864 bytes, 0 wrong   DMA reading memory
```

**160 MiB in total, not one wrong byte.** The disk path corrupts about one word
per 45 KB, so the same fault would have shown on the order of 3,700 bad words
across those passes. The CPU was busy throughout, so CPU and DVMA cycles were
interleaved exactly as they are during a disk transfer.

**The first version of this test was its own bottleneck, which is worth
recording.** It built and checked the pattern a byte at a time, which on a
20 MHz 68010 runs at a few hundred KB/s -- the program, not the machine, was the
limit, and the Ethernet and the DMA were barely troubled. Because the pattern
repeats every 512 bytes, a buffer whose length is a multiple of 512 is valid at
*every* aligned offset in the stream: build it once and the send side does no
per-byte work at all, while the check side is one longword compare per four
bytes. Same coverage, four times the volume, and the load lands where it is
supposed to.

**And on one bitstream with both masters, the Ethernet *and* the disk are
clean -- which moves the fault onto the machine rather than the controller.**
A VME 2/50 built with `VME_SCSI=1`, so the 82586 and the SCSI card are both
fitted and both master the bus, reading the same micro-SD card the MultiBus
builds corrupt:

```
  network, 32 MiB   0 wrong          82586 DMA
  SCSI disk, 16 MiB 0 of 8,388,608   SCSI DMA, read-back missing an 8 MB cache
```

**That "it follows the machine" reading was wrong, and holding the machine
fixed is what showed it.** The comparison behind it changed *two* variables at
once -- MultiBus+XY450 against VME+SCSI -- so it could not tell a machine apart
from a controller. A MultiBus 2/120 with the **SCSI** card, on the very
filesystem the VME+SCSI run had just verified, is clean twice over:

```
  MultiBus + XY450, offset 0    196 of 8,388,608   16 MiB, same protocol
  MultiBus + XY450, offset 0     92 of 4,194,304   8 MiB, earlier build
  MultiBus + XY450, offset 1024  81 of 4,194,304
  MultiBus + SCSI,  offset 512    0 of 8,388,608   two passes, 32 MiB
  VME      + SCSI,  offset 512    0 of 8,388,608
  VME      + SCSI,  offset 0      0 of 8,388,608
```

The first line is the positive control repeated **at the same 16 MiB and from
the same tree as the SCSI runs**, so the comparison no longer spans two
protocols: 196 wrong against 0, on one board, one machine, one card, with only
the controller changed. The rate is consistent with the 8 MiB figures --
196 in 8.4 million is 92 in 4.2 million doubled -- so nothing about the newer
build or the larger file moved it.

Same machine, same board, same card, same `blk_sd`, same bridge and DDR3 --
**only the disk controller differs, and only `sun2_xy450` corrupts.** The
control holds: 7 MiB of RAM against a 16 MiB file, so the in-pass read-back
genuinely misses the buffer cache, and the XY450 rate predicts about 170 bad
words per pass where zero were seen.

**The DECA settles it, and "only the XY450" is wrong too.** The same MultiBus
SCSI build on the DECA, at the same 512 MiB offset, on the same filesystem the
Wukong had just verified clean, corrupts: **83 of 8,388,608**.

**Confirmed on a card rewritten from scratch, which removes the last confound.**
That first DECA figure was taken on a filesystem this investigation had been
writing to for weeks -- the one whose `ld` could no longer link a hello-world --
so "the medium is worn out" was still available as an explanation. With every
copy on the card rewritten, the same bitstream on the same offset gives
**102 of 8,388,608**: the same rate, on a filesystem hours old. The DECA
MultiBus+SCSI result is real.

The full matrix, every cell a 16 MiB pass with the read-back missing the cache:

| board | machine | controller | memory | result |
|---|---|---|---|---|
| Wukong | MultiBus | XY450 | MIG | **196** of 8,388,608 |
| Wukong | MultiBus | SCSI | MIG | 0, twice |
| Wukong | VME | SCSI | MIG | 0, twice |
| DECA | MultiBus | SCSI | BrianHG | **83**, then **102** of 8,388,608 |
| DECA | VME | SCSI | BrianHG | **120** of 8,388,608 |

**The DECA's VME machine corrupts too, and that fills the last corner.** Same
board, same controller, same memory, same 16.667 MHz, same `patwr.c` by
checksum, on a pristine `eagle-sd.img` at 1536 MiB -- only the machine changed,
MultiBus 2/120 to VME 2/50: **120 against 102**. Those are the same rate.

So **the machine is not the variable on either board.** The Wukong is clean on
MultiBus+SCSI *and* VME+SCSI; the DECA corrupts on MultiBus+SCSI *and*
VME+SCSI. What is left standing is the board, and -- on the Wukong alone -- the
controller.

**Which is what the stimulus-rate hypothesis predicted, and it is now the
reading the whole table supports.** Sort the five cells by how hard the master
drives memory relative to how fast that memory answers:

```
  Wukong  MIG      + SCSI  (sparse master, fast memory)     0, 0, 0, 0
  Wukong  MIG      + XY450 (dense  master, fast memory)   196
  DECA    BrianHG  + SCSI  (sparse master, slow memory)    83, 102, 120
```

One threshold orders every measurement. The XY450 moves four bytes per DVMA
transaction back to back; the SCSI card stages a longword and walks it out a
byte at a time through `scsi_fabric`, so it asks for memory far less often.
MIG answers faster than BrianHG's controller. A fault that needs master traffic
above some rate *relative to the memory path* is clean in exactly one of those
three cells and present in the other two -- which no "it is the machine" or "it
is the controller" reading can produce, because both of those have now been
held fixed and varied in both directions.

**What this does not settle** is what the threshold is a threshold *on*. Rate
is one candidate; so is anything else that tracks it, such as how often a
master's cycle lands close to a CPU cycle, or how long a request is outstanding.
The next experiment is to vary the rate with board and controller held fixed --
slow the XY450's DVMA on the Wukong until it corrupts less, or clock the DECA
down -- because that is the one axis the five cells above never varied on its
own.

Two caveats on the VME cell, stated because they are real. A 2/50 fits the
82586, so this machine has a second potential master the MultiBus build does
not -- the machines differ by more than the bus, and the Ethernet was idle but
present. And it is a fresh place-and-route, which has flipped outcomes twice in
this file; the DECA has now corrupted across three independent builds, so the
*direction* is safe, but the exact rate is one pass.

**And the wrong values follow the filesystem, not the board -- which is a
correction.** The 83-word run was recorded here as showing `53d2`, `281c` and
`6d08`, "the three this file recorded for the DECA long ago, and not the
Wukong's, because each board's memory holds its own program text". That
reasoning was wrong. On the rewritten card the DECA's 102 wrong words are
`2f2d` (36), `2e2e` (31) and `584f` (26) -- **the Wukong's three**, in the same
order of frequency, with a tail of `0000`, `4ef8`, `7572`, `2f64`, `2f2e`,
`005f` and `0006` at one each.

The intruding content is whatever program text the *filesystem* has resident,
so two boards reading identical images produce identical values and the same
board reading a different image produces different ones. The board was never
the variable; the card's contents were. That also means the value histogram is
a property of the workload and cannot be used to tell two boards' faults apart,
which is what the retracted sentence tried to do.

**So it is neither the machine nor the controller alone.** MultiBus is not the
variable -- Wukong MultiBus+SCSI is clean, and neither is VME, which is clean on
the Wukong and corrupts on the DECA. The XY450 is not the variable -- DECA SCSI
corrupts without one. The disk controller is not even the variable in itself:
the *same* card is clean on one board and corrupts on the other.

**What survives is that the controller sets the stimulus rate.** The XY450 moves
four bytes per DVMA transaction back to back, while the SCSI card stages a
longword and walks it out a byte at a time across `scsi_fabric` -- far fewer
memory accesses per unit time. So SCSI on MIG may simply be too slow to provoke
what XY450 on MIG does, while SCSI on the slower BrianHG path is fast enough
relative to *its* memory. That restores the shared path as the suspect, with the
controller acting as a knob on how hard it is driven rather than as the fault.

It is a hypothesis, and it is testable: the rate is the thing to vary next,
holding board and controller fixed.

**The XY450 drivers were audited for timing assumptions, and none of them can
produce this fault.** Every layer was read -- the 3.4 and 4.1.4 kernel drivers,
`sunstand/xy.c`, `prom_monitor/{msun,rsun}/mon/prom2/xy.c` (the PROM this board
actually runs), and `stand/src/diag/xy.c`. Every timing requirement found is a
**control-path** one: command start, command completion, reset, interrupt
delivery. Violating any of them produces a loud failure -- a panic, a lost
interrupt, a timed-out probe, a whole sector read early -- **not a silent
single-word substitution in the middle of a correctly-addressed sector**. No
driver anywhere imposes a rate, a spacing, or a bus-hold limit on the DMA
itself; `xy_throttle` (32 words/transfer) is advisory to the controller and is
the only thing said about it at all.

**Both were checked against the RTL and both are honoured.** `sun2_xy450` sets
`csr_gbsy` on the same clock edge that decodes the GO write -- the decode is
`wr_lo & sel_ctl & mbio_din[7]`, where `wr_lo` is qualified by
`first = mbio_hit & (phase == 2'd0)`, a genuine one-shot rather than a level, so
BUSY is asserted **one clock into the GO write cycle** against the 30 us the
driver allows. And it is cleared in exactly one place in normal operation,
`E_FINISH`, which is reachable only through `E_WB_W`; every DVMA access in the
engine -- `E_IN_W`, `E_OUT_W`, `E_WB_W` -- advances only on `wb_ack_i`. So BUSY
does not drop at IOPB-fetch completion, and the interrupt (`csr_ipnd`, set in
`E_IOPB_END` and `E_FINISH`) is raised strictly after the last DVMA write has
been acknowledged. Reset behaves too: `csr_gbsy` is held for `RESET_CLOCKS = 64`
(3.8 us at 16.7 MHz) against a 100 us boot-path wait.

**What "acknowledged" resolves to is the one thing worth writing down.** The
chain is `sun2_xy450` -> `sun2_dvma` -> a 68010 cycle -> `sun2_wishbone_bridge`
(`W_ACK = (wb_ack_i & issued) | done`) -> `wb_to_mig_ui`, whose `wb_ack_o` fires
on `ack_pulse` from the memory domain, which `mig_arb` raises when **MIG accepts
the write**:

```verilog
   wire cmd_ok = cmd_done | (app_en       & app_rdy);
   wire dat_ok = dat_done | (app_wdf_wren & app_wdf_rdy);
```

MIG's UI has no write-completion response -- writes are posted -- so the whole
ack chain means *accepted by the controller*, never *committed to DRAM*. The
driver's only synchronisation for "everything the controller wrote is visible"
is that interrupt, and the interrupt is gated on acceptance. **That window is
real and it is already closed by measurement rather than by argument**: it would
only bite if the controller could answer a read from DRAM ahead of a pending
write in its own queue, which is exactly what `Strict` against `Normal`
ordering governs, and rebuilding with `ORDERING = "STRICT"` changed nothing.
`WRITE_VERIFY` reads every write straight back at 0 wrong (checking only the
bytes each write enables -- see the qualification above), and it is the
device->memory direction, which the cold reads show clean.

The two hits, kept because the reasoning above is what retires them:

* **When does BUSY assert relative to the GO write?** The boot path is
  `xy_csr = XY_GO;` then `do { DELAY(30); } while (xy_csr & XY_BUSY);`
  (`sunstand/xy.c:268-272`, identical in `prom2/xy.c:207-210`). The `DELAY`
  runs *first*, so this reads "wait 30 us, and if BUSY is clear the command is
  finished" -- and the boot path has no other completion test, it never looks at
  `xy_complete`. If the replica raises BUSY a few clocks late, or drops it at
  IOPB-fetch completion rather than at data completion, the PROM proceeds while
  DVMA is still in flight. Note `XY_GO` (write, 0x80) and `XY_BUSY` (read, 0x80)
  are the same bit (`xycreg.h:43-44`).
* **Is the interrupt raised before or after the last DVMA write retires?** With
  `xy_autoup = 1` and `xy_intrall = 0` the driver takes one interrupt and then
  reads `xy_complete` *out of DVMA memory* for every IOPB, with no register
  re-read and no flush. Everything the controller wrote must be visible when the
  interrupt lands. This would corrupt device->memory, and the measurements put
  this fault in memory->device, so it is not the cause -- but it is free to
  check.

**The strongest historical evidence, and it cuts against the replica being at
fault.** Every 4.1.4 change in this area is a *wait added* -- `xycsrvalid`,
`xywait`, `xyintwait` -- and one carries the rationale in the source:

```
 * make sure the busy bit goes ON before we wait until it clears..
 * This is a problem with faster machines where the controller does
 * not have enough time to react to the command.
 * Changed by EK 9/10/89
```

So Sun found that a faster CPU could outrun this controller in the interrupt
path and patched around it with polls. **The kernel booting here is 4.0.3, which
predates that annotation**, so the running driver behaves like 3.4 and does
*not* wait -- which makes the replica's BUSY and interrupt timing more load-
bearing, not less.

**The kernel and the PROM contradict each other about register spacing, which
bounds what the replica must support.** The kernel says a 15 us delay and a
readback are needed after every register write, "due to a bug in the 450"
(`xy.c:159-163`, `1349-1352`), and `panic`s on a double miscompare. The
standalone and PROM drivers write all five registers **back to back with no
delay and no readback** (`sunstand/xy.c:263-268`). Both cannot be true of the
same chip. For the replica: the minimum inter-register spacing that must work is
one 68010 bus cycle, and the kernel's 15 us is slack it should not need.

Two smaller things the audit settled. `XY_ATTN`/`XY_ACK` are used by **no**
driver in either tree -- only the header defines them, confirming what this file
already recorded. And the SCSI driver carries materially fewer timing
assumptions than xy: three `DELAY` sites against eighteen, every one a back-off
inside a loop testing a real handshake bit, with no write-then-read-back, no
fixed-delay-then-assume, no device-rewritten structure in host memory, and no
chain. That asymmetry is *consistent with* SCSI being clean where the XY450 is
not, but it is about control-path robustness and explains no single wrong word.

**`report_cdc` does not separate a corrupting build from a clean one.**
Vivado's CDC report was run on the routed checkpoints of all three Wukong
builds -- MultiBus+XY450, which corrupts 196 words, and MultiBus+SCSI and
VME+SCSI, which are both clean. The populations are *structurally identical*:

```
  build      CDC-1   CDC-10   CDC-15   CDC-10 outside the ILA/VIO
  xy450        637       28      367       5      <- corrupts
  mbscsi       637       26      367       5      <- clean
  vmescsi      848       40      587      10      <- clean
```

The 28-against-26 looked like a real difference and is not: filtering the
debug-core rows leaves five in each, and diffing them shows the same five nets
with a different bit of the same counter named as the launch flop
(`hold_ctr_reg[4]` against `[0]`, `serial/rst_a_cnt_reg[3]` against `[1]`). The
rest of the diff is the instance name of the one `sun2_dvma` -- `xy_dvma`
against `sc_dvma`. **Nothing structural distinguishes them.** And VME+SCSI
carries nearly *twice* the CDC population, from the 82586's `phy_rx_clk` and
`phy_tx_clk` domains, while corrupting nothing at all -- so the count does not
even correlate in the right direction.

**One real data-path crossing it does name, present in every build.** The
`z8530_scc`'s receive FIFO, in `mmcm_b_serial`, reaches `sun2_dvma`'s `rd_lo`
and `rd_hi` latches in `mmcm_a_cpu` -- eight endpoints, **CDC-15 "Clock enable
controlled CDC structure", Warning**, across an `Asynch Clock Groups` exception,
which means it is deliberately untimed:

```
  machine/sun2/serial/u_rx_fifo_a/mem_reg[2][2]/C -> machine/xy_dvma/rd_hi_reg[10]/D
```

Those are exactly the two latches whose assembly
`wb_dat_o <= {rd_hi[7:0], rd_hi[15:8], rd_lo[7:0], rd_lo[15:8]}` produces the
16-bit granule the fault has. The path exists because **`P_DOUT` is a 20-way
read mux and the SCC is one of its arms**, so structurally a DVMA latch can
capture a word launched in the serial domain. Functionally it should never
happen -- a DVMA memory read selects the memory arm, never the SCC's -- and it
is in the two clean builds identically, so it cannot be what separates them.
Worth knowing anyway, because this file already records one bug of exactly this
shape (the raw `X2` oscillator reaching the Am9513's clock enables) and because
an untimed path is one placement away from behaving differently.

The five non-debug CDC-10s are the ones this file already listed as left
undone: MIG's `init_calib_complete` and `hold_ctr` into `rst_cpu/chain_reg[0]`'s
preset, the SCC's own two soft-reset synchronisers, and `rst_cpu/chain_reg[2]`
into `serial/sreset_b_sync_reg[0]`'s clear. All reset assembly, none in a data
path, all present in corrupting and clean alike.

**So CDC is not the discriminator on this board**, which is a real elimination
rather than an absence of evidence: the instrument that found the `P_RESET_n`
bug in one run was pointed at a corrupting build and a clean one and reports
the same thing about both.

**A clean cell can be made to corrupt, and what does it is *irregular* master
timing rather than a slower one.** The Wukong VME+SCSI machine at 20 MHz has
read zero five times running -- twice before the throttle existed, and three
times in one session on a freshly written card, with an interleaved control.
With the throttle in **random** mode it corrupts:

```
  bitstream        setting              mean gap   result        elapsed
  normal (no THR)  --                      --      0 of 8,388,608   42m
  throttle         mask 0                   0      0                42m
  throttle         FIXED gap 63            63      0                42m
  throttle         mask 0 (control)         0      0                42m
  throttle         RANDOM mean 63.5      63.5      **43**           42m
```

**Fixed and random have the same mean rate by construction** -- `THR_MASK>>1`
against a uniform draw over `[0, THR_MASK]` -- and differ only in the
regularity of the master's request spacing. Fixed is clean; random is not. So
on this cell the variable is **jitter, not rate**, and the throttle's two modes
were built for exactly this comparison.

**The signature is the fault, not a new one.** The 43 wrong values are
`2e2e` (20), `2f2d` (15), `584f` (4) and `0000` (2) -- the same three common
68010 opcodes that every corrupting run in this file reports, which is program
text intruding into the buffer. Word offsets split 23 even to 20 odd, so it is
not confined to one half of a longword.

**This is the first knob that turns the fault ON in a configuration that is
otherwise clean**, which is worth more than one that halves it in a
configuration that is already dirty: it is a positive control. Every previous
experiment could only ask "did the rate go down"; this one can ask "did the
fault appear", against a cell with a perfect record and no Poisson spread to
hide in.

**It also supersedes the DECA reading, which was confounded.** That sweep had
fixed-63 at 81 and random-63.5 at 85 and was read as "rate is the variable,
alignment is not". Its baseline drifted 163 -> 140 -> 109 across the session,
the sigma figures were computed against a baseline assumed constant, and the
whole thing is retracted below. This experiment has a flat baseline -- four
consecutive 42-minute passes at zero, control included -- so where the two
disagree, this one is the measurement.

**Confirmed, three for three.** The repeats put it beyond a single sample:

```
  off / normal bitstream   0, 0, 0, 0      mean  0
  FIXED  gap 63            0, 1            mean  0.5
  RANDOM mean 63.5         43, 38, 44      mean 41.7
```

Every pass 42 minutes, so the knob changes neither throughput nor total work --
only the regularity of the master's request spacing -- and the separation is
about eighty to one. **Random provokes the fault every time; fixed does not.**

One correction to the first write-up: **fixed is not a perfect zero.** Its
repeat returned 1 wrong word where the first returned 0. That is either this
cell's own very low background rate or a slight perturbation from the fixed
gap; against 38 to 44 it does not trouble the result, but "fixed is clean" is
better stated as "fixed is at baseline, within one word of it".

**And the obvious alternative was tested and is dead: it is not the long-gap
tail.** Random over `[0, 127]` contains delays up to 127 that a fixed gap of 63
never produces, so the whole effect might have been that small fraction of long
delays rather than the irregularity. Running the fixed maximum settles it:

```
  off / normal bitstream            0, 0, 0, 0      mean   0
  FIXED  gap  63                    0, 1            mean   0.5
  FIXED  gap 127  (the maximum)     0               mean   0
  RANDOM mean  63.5  range 0-127    43, 38, 44      mean  41.7
  RANDOM mean 127.5  range 0-255    34
```

**A fixed 127-clock gap reaches the same maximum delay as random `[0,127]`,
carries twice its mean, and corrupts nothing.** So long delays are not the
mechanism. And doubling the jitter range changes nothing measurable -- 34
against 38 to 44, all inside Poisson noise -- so the effect does not scale with
how large the jitter is either.

**And it is not the parity of the gap either.** Both fixed points tested so far
were *odd* -- 63 and 127 -- while random draws both parities, so "even gaps are
the dangerous ones" explained every result without invoking jitter at all. A
68010 bus cycle is an even number of clocks and `sun2_dvma` drives AS on one
edge and releases it on the other, so a gap shifting the next request by an odd
number of clocks lands it on the opposite phase from an even one; with a
half-period path and an untimed CDC-15 into `rd_lo`/`rd_hi` already on record,
that was physically plausible. Measured, it is wrong:

```
  FIXED gap 62  (even)             0
```

The full set:

```
  off / normal bitstream            0, 0, 0, 0      mean   0
  FIXED  gap  62  (even)            0               mean   0
  FIXED  gap  63  (odd)             0, 1            mean   0.5
  FIXED  gap 127  (odd, maximum)    0               mean   0
  RANDOM mean  63.5  range 0-127    43, 38, 44      mean  41.7
  RANDOM mean 127.5  range 0-255    34
```

**Every fixed gap is at baseline whatever its size or parity; every random gap
corrupts whatever its mean.** Four readings are excluded by measurement rather
than argument:

* **not rate** -- fixed 62, 63 and 127 are three different rates, all clean;
* **not the long-gap tail** -- fixed 127 matches random's maximum, clean;
* **not jitter magnitude** -- mean 63.5 and mean 127.5 agree;
* **not gap parity** -- fixed 62 is even and clean.

What is left is the *irregularity itself*: the master's requests arriving at
unpredictable intervals, whatever their mean, extreme or parity. That is a
narrow and unusual property for a fault to key on -- most hardware faults key
on a threshold, not on unpredictability -- and it is what any explanation now
has to account for.

**A capture machine whose disk carries nothing but the test.** A MultiBus
2/120 with the XY450 *and* the Sun MultiBus Ethernet, netbooted, so root, swap
and every binary come over NFS through the Ethernet card's own 256 KiB and the
XY450 is the only bus master -- its DVMA buffers hold `patwr` traffic and
nothing else. `xy0a` is mounted on `/mnt` for the test alone. It still corrupts:
**164 of 8,388,608** in 79 minutes (`2e2e` 57, `584f` 55, `2f2d` 52), the same
three values as ever, so the intruding text is not the disk's own program text
being paged in through the buffers under test. The build is
`v3-multibus-mbether-xy450-cpu20-rd68011-ila-div50-off1024m`, 23,960 LUTs and
106.5 of 135 BRAM tiles before the instrument below.

Netbooting it takes one thing that is not obvious. The PROM's `boottab` lists
`xy` before `ie`, so it always autoboots the disk and BREAK loses the race: let
it boot, `sync`, `/etc/halt`, then `b ie()vmunix -a`. **Answer the `-a` prompts
twice** -- the bootloader's (root fstype `nfs`, an empty root name, which
bootparams fills in as `x11spl:/home/dolbeau2/Sun3_BootDir/nfsroot/sun2_f_m`)
and then the kernel's own root and swap prompts, `nfs` and empty names again.
Answering only the first set boots an NFS-loaded kernel that still mounts
`xy0a` as root, which is exactly the traffic this machine exists to exclude.
Root's shell is csh, so `$?` is `Variable syntax.` and the whole line is
rejected unexecuted.

**`sun2_clobber`: the history of a buffer, which no transfer check can give.**
Every instrument so far asks a question of one transfer, and every one reads
zero while `ARRIVED BAD` counts the corruption one for one. So memory really
holds text where the pattern went, and the open question is *how it got
there* -- a question of history. `rtl/sun2-common/sun2_clobber.v`, inside the
bridge, keeps one bit per 512-byte block (14,336 blocks, one RAMB18): "the last
write here was the pattern". Against it, a non-pattern write into a pattern
block is resolved by the next write into that block as *reuse* (not the pattern
either), *iso* (the pattern again -- one foreign word inside a copy, *behind*
if below the copy head), or *lone* (nothing more before a timeout); a
non-pattern *read* from a pattern block is a *ghost*. Iso-behind plus lone near
`ARRIVED BAD` would say a write put the text there, and the record names
whether the CPU or the master wrote it; ghosts near it with those at zero would
say no write of text was ever seen. `make -C sim clobber` is 166 checks, and
eleven mutations are each caught by the scenario aimed at them. It reaches the
VIO as `cl_*` (`syn/vio_read.tcl`, "WRITE HISTORY") and the ILA as probe 17,
with capture modes `clob`, `clobiso`, `clobcand`, `ghost`, `ghostdvma` and
`arrivedx`, all qualified one sample per memory transaction.

**It also closes a gap every earlier write check had: the lanes.**
`wb_to_mig_ui` latches `wb_sel` on the same clock as address and data, and the
write-coverage check tested address and data only; DECA's `WRITE_VERIFY` masked
its comparison *by* `wb_sel`. A pattern write issued with one strobe missing
would leave the old text in place under both. `PARTIAL` counts exactly that.

**Its first bitstream was flooded by coincidence, and the numbers are the
lesson.** It marked a block on any single pattern-shaped word. On the board,
before `patwr` had written a byte, SunOS's own boot had counted **33,776
ghosts, 63 lones and 381 partials**: `{0x80, index}` is not a rare word, and one
chance match marked a block of kernel data whose every later access then
counted against it -- the `clob` trigger would have fired on noise. A block is
now marked only by a *run*, a pattern write whose previous write was the
pattern at the word before (or word 255 of the block below, for word 0), and
`PARTIAL` is gated the same way. Every instrument in this file has needed such
a rule; this one shipped without it for one build. With the rule, a full disk
boot, halt and netboot leaves **every** counter at 0.

**The results: the damage is a ghost, and the "foreign write" is its copy.**
Three 16 MiB `patwr -u` passes on the netbooted capture machine, the last on the
run-gated bitstream with a zero baseline:

```
                          run 1 (v1)   run 2 (v1)   run 3 (v2)
  patwr, words wrong          140          149          132
  ARRIVED BAD                +140         +149         +132
  ghost, read by the master  +140         +149         +132
  iso-behind, by the master  +140         +149         +132
  lone                          .            .            0
  PARTIAL (run-gated)           .            .            0   of 16,849,362 pattern writes
  DISAGREED / OUTSIDE           0            0          0 / 0
```

Four counters in two modules are identical to `patwr` on every run. Reading them
took one wrong turn, recorded because it looked right: the iso count was read at
first as "a master writes text into the buffer". The first capture (`clobiso`)
showed what it is -- the XY450 writing `2f2d` at word 78 of a sector *during
patwr's verify*, which patwr then reported as `sector 14 word 78 got 2f2d`: the
faithful **read-back of a sector already wrong on the medium**. The damage is
the ghost: at the disk write, the master reads text out of a block whose last
bridge-visible write was the pattern, while write coverage says every word of it
was written. **No write of text into those blocks is ever seen at the bridge**,
and none is issued with a lane missing.

**The window cannot reach the write that matters.** `arrivedx` (trigger on
`dv_arrived_bad`, armed *before* patwr -- patwr writes the whole file before it
verifies, so every damaging read is in the first ~40 minutes, and `ghostdvma`
armed half-way through run 2 waited an hour for events that had all happened)
caught the master reading `584f` at word 180 of block 0x392e00 in an otherwise
perfect stream, and **no write into that block anywhere in the ~3,500 prior
transactions**. The CPU's copy into it is older than a 4,096-deep ILA can hold.

**Every damaged word is the first halfword of its 32-bit word: 511 of 511**
(140 + 149 + 132 on the Wukong, 90 on the DECA). That is also the **first bus
cycle** of each longword: the kernel fills the buffer in `_copyin` (0x4804,
reached from `_uiomove`) with `movesl %a0@+,%d1 ; movel %d1,%a1@+`, and a long
write to `(An)+` goes high word first; long reads go high word first; and
`sun2_dvma` does half 0 before half 1 in both directions (384 back-to-back
even-then-odd master reads in one capture). Only `-(An)` writes the low word
first, and `copyin` does not use it. Buffer blocks are 512-byte aligned, so each
longword is exactly one 32-bit DDR3 word.

**Both memory controllers mask sub-word writes with the DDR3 chip's own DM
balls, and simulation hides that.** MIG with `DATA_MASK=1` sends `app_wdf_mask`
nowhere but the DM pins -- output-only bitlanes in the data byte groups, FPGA
A22/C22, which the Wukong V3 schematic routes as DDR_DQM0/1 to the part's
UDM/LDM -- while `wb_to_mig_ui` drives the same word into all four lanes. Micron's
DDR3L x16 has functional UDM/LDM. BrianHG does the same ("DDR3_DM[0] drives
write DQ[7:0]"). The Micron simulation model implements `dm_tdqs` as a byte mask
(`ddr3_model.sv` `bit_mask`), which is why `make -C sim migddr3`'s partial write
passes; and MIG's calibration holds the mask at 0 throughout
(`mux_wrdata_mask = ... ? mc_wrdata_mask : 'b0`), so DM is never exercised
until the machine runs. On Artix-7 there is no ODELAY, so DM gets the same
per-byte-group write alignment as DQ -- a plain timing gap is less likely than
something specific to those two traces or to the isolated one-word DM pulse a
halfword write produces.

**The DECA's write-verify, on a corrupting pass, says the halfword *was*
written.** `deca-multibus-...-mbscsi-blktrace-off512m-lb16` (09-10, `434d207`,
`WRITE_VERIFY=1`): `patwr` 90 of 8,388,608, all even, the same three values;
88 wrong at the master's capture (first at 0xF03568, word 180, `2e2e`); **write
verify 0**, with every write of the run routed through the read-back and the
`responses - reads issued` control advancing. The read-back really reached
DDR3: `PORT_R_CACHE_TOUT` is 0 with `PORT_R_CACHE_TOUT_ENA` left at its default,
which reloads the timeout with bit 8 set so the read cache never hits, and
`PORT_CACHE_SMART` is 0. So "the first write never lands" -- a missed DM pulse on
its own write -- is **falsified on the DECA**.

**What that check cannot see is the next cycle.** It compares only the bytes the
write enabled: after the even write it checks the even half, after the odd write
only the odd half. The second write of the pair, or anything later, could undo
the even half invisibly. But a plain mask failure on that second write does not
produce *old text* on either controller -- MIG would put the odd word's value
in the even half (`80xx+1`), BrianHG the even value it had just written -- so the
old contents must come from something that carries the page's *previous* state,
and that path is not identified. On the Wukong the same counters cannot tell
"never landed" from "landed and reverted"; there is no write-verify there.

(The follow-up proposed here -- make the DECA's write-verify re-check the first
halfword after the second write -- was overtaken: memory was never wrong.)

**Found and fixed: a refused memory access issued a phantom DDR3 request, and
the next memory cycle took its answer.**

*The instrument.* A second ILA core, `u_busila` (`syn/generate_ip.tcl`,
`boards/Wukong/wukong_top.sv`), 13 probes and 8,192 samples: the 68010 bus
(address, FC, strobes, the C_S chain, data, `dvma_active`, physical page) *and*
the memory side of the bridge -- the whole 32-bit word DDR3 returned, the
Wishbone control lines and address -- triggered on `dv_arrived_bad` and
storage-qualified by a "bus changed" strobe. `sun2_ila` went to 1,024 samples to
free the BRAM (`ila_capture.tcl` now picks it by cell name and scales its trigger
positions). `syn/busila_capture.tcl` arms it; `tools/busila_dec.py` decodes. The
capture must be armed before `patwr` starts. Vivado suffixes probes that share a
net with the other core (`dbg_addr_1`), which the decoder accepts.

*What it showed* (netbooted XY450 machine, first capture):

```
  -22..-20  cpu FC1 read phys 0246bc: AS, C_S4, C_S6
  -19       BERR, no DTACK                         the MMU refused it
  -18       AS negated, C_S6 still 1, wb_cyc=1 for word 0091af, no ack
  -13       master read halfword 94 of word 148d2f: wb_cyc
  -10       ack arrives with 23ed584f              -- 0091af's contents
   -9       master latches 584f
   -4..-1   halfword 95, same DDR3 word, re-issued: 805f805e, correct
```

The only request dropped without an acknowledge in 8,192 samples, immediately
before the bad read.

*The mechanism.* `MMU_REFUSE` is gated by `~P_AS_n`; the C_S chain clears on the
posedge *after* AS negates. So in that one clock `MMU_OK` read 1 while `C_S6` was
still 1, and `MATCH_MEM` -- and every other `MATCH_*` -- came true for a cycle
the MMU had refused. The bridge had issued nothing in that cycle, so it issued a
fresh request; both DDR3 adapters latch a request on its first clock and run it
to completion, and ignore a new request while busy; and the bridge accepts
`wb_ack_i & issued` from whatever cycle is on the bus. A memory cycle starting
within the orphan's latency therefore got the refused page's word and never
issued its own read. That is every property this file recorded: one halfword,
the first of a pair (the master takes the bus straight after the CPU's fault),
program text (the faulting process's memory), memory itself never wrong (why
DOUBLE_READ, WRITE_VERIFY and every DDR3 check were clean and the ghost counter
fired), timing-dependent (the random-throttle result), and both boards (shared
`sun2_fpga`, same adapter shape). A refused *write* issued a write with
`wb_sel` = 0 -- harmless to data, but equally able to steal an acknowledge.

*The reproduction.* `make -C sim orphan` (`tb/tb_orphan_ack.sv`) drives the real
`sun2_fpga` with a 68010 bus-functional driver into the real `wb_to_mig_ui`,
`mig_arb` and `mig_ui_model`. `tb_sun2` can never show this: `wb_ram_model`
forgets a request whose CYC drops, and the real adapters do not. On the unfixed
RTL, 3 of 8 checks fail: one refused read issues a request; a valid read 0 or
1 clocks later is wrong 32 of 32 times at each gap, **all 64 returning the
refused page's word**; refused writes issue write requests. A valid-then-valid
control is clean at every gap.

*The fix* (`sun2_fpga.v`, `MMU_REFUSED`): the refusal is latched on any posedge
where `MMU_REFUSE` is true and cleared on the posedge with AS negated -- the edge
that clears the C_S chain -- and `MMU_OK = ~MMU_REFUSE & ~MMU_REFUSED`. Chosen
over re-gating the decode with AS as the change least likely to disturb anything:
nothing differs while AS is asserted.

*Measured.* Simulation: `orphan` 8/8; `bridge` PASS; MultiBus 22/274 and VME
10/312 with bus-error sequences identical to the unfixed RTL *including
timestamps*; `xychain` PASS. Board, same netbooted MultiBus+XY450+Ethernet
Wukong and the same 1024 MiB copy:

```
                           unfixed (3 runs)     fixed
  patwr, words wrong       140, 149, 177         0 of 8,388,608
  ARRIVED BAD              = patwr               0 of 8,388,608 master pattern reads
  ghost (by the master)    = patwr               0
  iso / lone / PARTIAL     -                     0 / 0 / 0
```

*Confirmed on a machine booted from the filesystem under test.* The run above
was netbooted, which was deliberate -- it excluded the disk from everything but
the test file -- and it therefore also excluded the workload most likely to
provoke the fault, since the orphan request follows a CPU page fault and a
netbooted machine pages its text over NFS. Repeated on the **same board booted
from `xy0a`**, a pristine 2048 MiB copy, `fsck` clean, multi-user, with the
disk carrying root, the binaries and the paging as well as the 16 MiB test
file:

```
  patwr                 0 of 8,388,608 words wrong
  in a run              8,388,608      = the file's halfwords, the control
  pattern writes       16,847,081
  ARRIVED BAD / GHOST   0 / 0
  iso / iso_behind / lone / PARTIAL / collide      0 / 0 / 0 / 0 / 0
  DISAGREED / OUTSIDE   0 / 0
  candidates          552, all by the master       INCOMPLETE 1
```

Two non-zeros, and neither is the fault. **552 candidates, every one the
master's**, is what a disk-booted machine is supposed to show and the netbooted
one could not: a candidate is a non-pattern write into a block whose last write
was the pattern, and here the master really does write filesystem metadata and
paged-in text into blocks the test file used to hold. They all resolved as
*reuse* -- iso, iso-behind and lone are zero -- which is the resolution that
means the block was handed on rather than damaged. And `INCOMPLETE 1` in 16,849
blocks, first miss at offset 0xff, is the boundary artefact this file already
records: a block closed early because the kernel interleaved, not a lost write.

*And it crosses vendors: the DECA is clean too.* The VME+SCSI build at 1536
MiB, on the filesystem that gave **120 of 8,388,608** unfixed, on a MAX 10 with
BrianHG's controller instead of Artix-7 and MIG:

```
  patwr                      0 of 8,388,608 words wrong
  block seam, sectors seen   2 -> 32,770     (+32,768, exactly the file)
  block seam, bytes wrong    1010 -> 1010    (+0)
  write verify 0             adapter: unexpected 0, wrong lane 0
```

The seam figure is the strong one, because it is measured **in flight inside
the FPGA** at the last point before `blk_sd` rather than inferred from a
checksum after a reboot: every one of the 32,768 pattern sectors reached the
card interface intact. The 1010 is the boot's own traffic false-arming the
check before the test started -- the arming is gated on a sector's first two
bytes -- and it did not move, which is why these counters are read as deltas.
`fsck` also passed without repair on a copy written by corrupting bitstreams,
where the Wukong's 1024 MiB copy had needed `fsck -y`.

**The master-capture check reads 0 on a VME build because it is tied off, not
because it saw nothing.** `top_fpga.v:276` leaves `dvma_latch` at 0 under
`SUN2_VME` deliberately -- a VME machine has two masters behind an arbiter, and
tying the probe to one of them would report a fraction of the traffic as though
it were all of it. The probe script says so itself ("the bridge is loading, so
the master's capture strobe is dead"). It is live on a MultiBus build, where
`xy_dvma` or `sc_dvma` drives it.

**MultiBus+SCSI at 512 MiB is clean too, with the master-capture check live.**
That cell gave 83 and then 102 unfixed; fixed it gives **0 of 8,388,608**, and
because this is a MultiBus build `sc_dvma` drives the probe the VME build ties
off -- 41,984 captures, **wrong words 0**, against the 88 it read on the
unfixed 90-word run. The block seam went from 1 sector to 32,769 with its
byte count unmoved at 506, and write verify, `unexpected`, `wrong lane` and
the double read are all 0.

**Its filesystem needed `fsck -y` first, and the damage was metadata.** The
512 MiB copy had been written by corrupting bitstreams for weeks; its first
fixed boot stopped at `PARTIALLY ALLOCATED INODE I=55418` /
`UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY` and dropped to single user with
root read-only. `fsck -y` cleared the inode, and the machine then booted
multi-user with `/patwr` intact at its reference checksum. That is the same
shape as the Wukong's 1024 MiB copy, now seen on the other board: **an unfixed
bitstream damages the filesystem's structure, not only file contents**, so a
copy is not a usable instrument until it has been checked or rewritten. Reboot
with `-n` after repairing a mounted root, or the stale in-core superblock is
written back over the repair.

**And MultiBus+XY450 at 1024 MiB closes the set: 0 of 8,388,608.** That is the
densest master this project has -- four bytes per DVMA transaction, back to
back, the configuration that produced the highest rates anywhere in this
investigation. Block seam 2 -> 32,770 sectors with its byte count unmoved at
1010, master capture `wrong words` 0, write verify, `unexpected`, `wrong lane`
and double read all 0.

**The machine also compiled its own instrument, which is the older failure
re-run.** `/patwr` was missing from that root and the build has no network, so
`tools/patwr.c` went over the console and `cc -O` built it on the machine:
no diagnostics, and the result is **byte-identical to the reference binary**
(`sum` 52827, 24576 bytes). That is `cpp`, `ccom`, `as` and `ld` plus dozens of
short-lived processes paging off the disk under test -- the workload that used
to give `ld: dhrystone.o: premature EOF` and an intermittent SIGILL.

So the fix is measured clean on **five cells across both boards**:

| board | machine + controller | offset | unfixed | fixed |
|---|---|---|---|---|
| Wukong | MultiBus + XY450, netbooted | 1024 MiB | 140, 149, 177 | **0** |
| Wukong | MultiBus + XY450, disk-booted | 2048 MiB | -- | **0** |
| DECA | VME + SCSI | 1536 MiB | 120 | **0** |
| DECA | MultiBus + SCSI | 512 MiB | 83, 102 | **0** |
| DECA | MultiBus + XY450 | 1024 MiB | -- | **0** |

Two FPGA vendors, two toolchains, two DDR3 controllers, two machines and two
disk controllers, on one RTL change.
`sun2_clobber` did not elaborate under Quartus at all until
`VERILOG_CONSTANT_LOOP_LIMIT` was raised; see the trap. Filesystems written by unfixed bitstreams can carry silent damage in
metadata as well as data -- the 1024 MiB copy failed its boot fsck with an
unknown inode type on the first fixed boot and needed `fsck -y`; any copy used
for a pristine source should be checked or rewritten. The fixed Wukong build met
hold by only 0.008 ns (WHS). Hardening the bridge/adapter handshake so a cycle
can only accept its own request's acknowledge -- defence in depth against any
future phantom request -- is not done. Bitstreams are archived in
`build/archive/` (`…-busila-v1`, `…-fixB`, `…-off2048m-fixB`) with the run notes.

Two tools met on the way: `pkill -f <pattern>` kills the shell running it when
the pattern is in its own command line (exit 144, twice in this investigation --
select by PID with a bracketed pattern such as `[d]eca_console`); and the DECA
console and ISSP cannot share the chain, so a probe read means stopping
`juart-terminal` and re-attaching after.

**The corruption rate is not stable over a session, and that invalidates every
single-pass comparison in a long sweep -- including the one below.**
`sun2_dvma` gained a throttle (`THR_MASK`/`THR_RAND`, gating only the *entry*
to `S_IDLE`, driven from a dedicated `THRT` ISSP source so one bitstream covers
a whole sweep and placement cannot vary between points). Nine 16 MiB `patwr -u`
passes on the DECA, VME 2/50 + VME SCSI at 1536 MiB, in time order:

```
  pos  setting        wrong   trend   delta
   1   off (mask 0)    163     163      0
   2   fixed  3        137     156    -19
   3   fixed 15        123     150    -27
   4   fixed 63         81     143    -62
   5   off (mask 0)    140     136     +4
   6   random 63.5      85     129    -44
   7   random 15.5      58     123    -65
   8   fixed 127        89     116    -27
   9   off (mask 0)    109     109      0
```

**The three unthrottled controls read 163, 140, 109** -- monotonically down,
3.3 sigma end to end, with nothing changed between them. The baseline fell about
a third over four and a half hours.

**A claim was made here and is retracted.** This file briefly recorded the
fixed-mode points as "monotonic, a 46% fall, about 4.6 sigma, drift excluded".
The exclusion rested on the position-5 control coming back *up* to 140 after the
81 at position 4. That was not a return to baseline; it was the baseline's own
downward slope passing through, and one point was read as evidence of stability
when it was a point on a line. The sigma figures were computed against a
baseline assumed constant and are meaningless.

**What survives.** Detrended against the three controls, every throttled point
sits below the local baseline by 19 to 65 words while the controls sit on it to
within 4. So a throttle effect is probably real. But the drift is the same order
as the effect and there is one pass per setting, so it cannot be quantified from
this data, and the interesting features -- the apparent saturation between gap
63 and gap 127, and fixed-15 (123) disagreeing with random-15.5 (58) at 4.8
sigma where fixed-63 and random-63.5 agreed to 0.3 -- are all inside the
confound.

**The design error is the lesson.** A sweep whose points are 32 minutes apart
needs its control *interleaved with every point*, or the order randomised, not
one control in the middle and one at each end. Three controls were enough to
detect the drift and not enough to correct for it. Paired A/B -- control, point,
control, point -- costs twice the runs and is the only version of this
experiment worth running.

**The drift's cause is unknown and is its own finding.** It is not the knob:
the controls have the throttle off. Candidates, none established -- the SD
card's flash translation layer remapping after repeated rewrites of the same
LBAs, thermal drift over hours, or filesystem free-list state evolving across
nine rewrites of the same 16 MiB file. Anything that reads this machine's
corruption rate as a stable quantity should measure it three times first.

**What the sweep does establish, independent of the drift**, is that the knob
works and is honest: `make -C sim dvma` times identical traffic in three modes
and requires the gap to slow it (29 clocks per access unthrottled, 40.5 at fixed
gap 15); `tools/deca_throttle.tcl` reads the source back and refuses a point if
it did not take; total pass time is constant at 32m00s to 32m21s across all
nine, so every point moved the same data in the same time. And the regressions
hold -- MultiBus 22/274 and VME 10/312, byte-exact, with `check_console` clean.

**Elapsed time is the wrong control for this knob, and the arithmetic says
why.** A pass moves 32 MiB in 1920 s, which is 29 ms per sector; a 15-clock gap
across a sector's 128 longword transactions adds 115 us, 0.4% of that. The pass
is SPI- and filesystem-bound, so total duration cannot see the throttle however
well it works. What it changes is spacing *inside* a gather burst. A first
reading of the flat elapsed time as "the knob is not biting" was also wrong.

**And it is not the card region, which the Wukong could not previously rule
out.** `DISK_OFF_MIB` was Quartus-only -- it appears in `syn/Makefile` and not
once in `syn/build.tcl` -- so every measurement the Wukong has ever produced was
taken at sector 0. It reaches the Vivado flow now, applied at the media in
`wukong_top` exactly as `deca_top` does it, with the `outdir` tag added to
*both* expressions. Same machine, same controller, same bitstream logic, only
the region of the card different:

```
  offset 0     92 of 4,194,304 words wrong
  offset 1024  81 of 4,194,304
```

So the medium is not the variable. That matters because this project has been
caught by it before -- `351e320` found a create/delete stress damaging inode
2140 every time at sector 0 and cleanly at 512 MiB -- but that was a different
card, replaced since, and the rate here does not move.

**The offsets are not interchangeable, and picking the wrong one wastes a
boot.** Even multiples of 512 MiB (0, 1024, 2048) hold `eagle.img`, whose
`/etc/fstab` names `xy0`; odd ones (512, 1536, 2560, 3584) hold `eagle-sd.img`,
naming `sd0`. A machine pointed at the other kind boots and then cannot mount
its root read-write: the VME SCSI test above ran at offset 0 and came up on an
`xy0` fstab, which read exactly like a broken NFS root and cost a diagnosis.

**Confirmed on a second pass, with the filesystem the build is meant for.** The
first VME+SCSI run predated `DISK_OFF_MIB` on this flow and therefore sat at
offset 0, on an `eagle.img` whose fstab names `xy0` -- it booted, but its root
came up read-only and had to be hand-remounted. Rebuilt at **512 MiB**, it finds
`eagle-sd.img`, mounts `root on sd0a fstype 4.2` against a matching fstab, and
comes up clean:

```
  VME + SCSI, offset 0     0 of 8,388,608 words wrong
  VME + SCSI, offset 512   0 of 8,388,608
  MultiBus + XY450, off 0     92 of 4,194,304
  MultiBus + XY450, off 1024  81 of 4,194,304
```

32 MiB through the SCSI path across two builds and two regions of the card,
where the MultiBus rate predicts about 370 bad words. So the comparison no
longer rests on a single pass, and neither side depends on which copy of the
image it used.

**That exonerates the whole shared path under a different master.** The VME
Ethernet reaches memory through the same `sun2_dvma`, the same
`sun2_wishbone_bridge`, the same MMU and `C_S` chain, the same `wb_to_mig_ui`
and the same MIG and DDR3 -- all of it carrying 33.5 MB without a single wrong
byte. Whatever the fault is, it is **not** in the machinery every DVMA master
shares.

What differs between the two cases is the disk controllers and what sits under
them: `sun2_xy450` and `sun2_scsi_core`, and the `blk_sd` seam and SD card both
of them use. `blk_sd` is the one piece the XY450 and the SCSI card have in
common, which is what makes both boards corrupt identically while the Ethernet
does not.

**Two cautions about the comparison, stated because they are real.** It is a
different machine (VME, not MultiBus) and therefore a different bitstream and
device decode, and it is a different `sun2_dvma` instance. So this is not
literally the same logic exercised two ways; it is the same *shared modules*
exercised by a different master, which is weaker but still decisive at a rate
ratio above 700 to 1.

**Measured 2026-09-14: 500 B/s straight loses 8% of the file, a line at a time
at 200 B/s loses none.** Sending `patwr.c` (14,799 bytes) into `cat > file` at
500 B/s delivered 13,545 bytes with the tty ringing its bell throughout -- the
input queue overflowing, because `cat` blocks on the SD card while bytes keep
arriving and the link has no flow control. Sending one line at a time, pausing
`len/200 + 0.08` seconds after each, delivered all 14,799 with `sum` matching
the host. Pause per line rather than per byte: the point is to let the queue
drain after the write blocks, not to average a slower rate.

**A third caution, about the instrument itself.** Transferring the source over
the 9600-baud console dropped a run of text on the first attempt and the compile
failed; `sum` caught it. The console has no flow control and every write on a
diskless machine blocks on NFS, so a transfer must be paced and its checksum
checked before anything built from it is believed.

**What has not been compared, and is the only pairing left:** the *physical*
address of a failing read against the physical addresses the CPU actually wrote.
Every check here predicts from the address it is handed -- the coverage check
proves *a* block was fully written, and `ARRIVED BAD` proves *a* read came back
wrong, and nothing establishes that the two are the same block. A 2 KiB mapping
error cannot produce an isolated word, so that is excluded; what is not excluded
is a block written at one physical address and read from another for reasons
that are not the page map.

**Which moves the fault to the CPU's write.** A word the CPU wrote into the
buffer never reached that location. The write-side crossing check counts writes
that *arrived at the adapter* carrying the right data and finds none wrong -- it
cannot see a write that never reached the bridge, or one issued to a different
address. That is the mirror of every instrument built so far, and it is where
this now points.

**The old note, kept because the reasoning was sound given what was believed:** The adapter is
single-transaction-in-flight and is the only client on this build, so every
request reaches MIG in the order the machine issued it; with `Strict` they are
also *executed* in that order. A read that still returns the location's previous
contents therefore had its write issued **after** it, in real time -- not
reordered underneath. The question is no longer "did the controller reorder?"
but "why was that word not yet written when the master read it?", and that is a
question about the machine above the adapter, not about DDR3.

**What it predicts, and how to test it without a rebuild:** anything that
separates the CPU's write from the master's read in time should suppress it.
The cheapest is `sync` between filling and flushing; the real fix is to make the
adapter hold a read until prior writes are known committed, or to establish
strict ordering in the controller.

**What is not yet pinned down** is the exact window -- whether `C_S6` can be
true for a cycle before the map output settles, or whether the bridge latches
early -- and that is what the fix has to be built on.

**The old note on the address the bridge asks DDR3 for.** Every address
check so far compares a signal with itself at two moments: the bridge's
`P_ADR_IN` at issue against `P_ADR_IN` at load, and now `wb_adr_i` at issue
against `wb_adr_i` during. **Nothing checks `P_ADR_IN -> wb_adr_o`** -- the
translation from the 68010 address to the Wishbone word address the adapter
actually fetches. A read that goes to the wrong DDR3 word returns another
page's contents faithfully, satisfies every self-consistency check in the path,
and hands the master program text. That is the one link in the chain where the
address is *transformed* rather than merely held, and it is the only untested
one left.

**On this build there is only one other writer: the disk itself.** A
MultiBus XY450 machine has the CPU and one DVMA master. During a *disk write*
the master only reads -- but the kernel interleaves disk *reads*, and a DVMA
write is disk content going into memory. Disk content on this card is binaries,
which is precisely what `584f` (`addqw #4,%sp`) and `2f2d` are. **A DVMA write
landing one word outside its buffer would drop program text into the page being
written.** That is a different code path from everything instrumented so far,
all of which was the memory-to-device direction.

**The old question about the read direction is closed by the host read.**
The two identical cold reads above were read as proof that the medium is wrong.
That inference assumed a read-path fault would be *random*; a deterministic one
-- the same address mangled the same way every time -- fits the evidence
equally. The disk-to-memory direction is uninstrumented on this board, and it
shares the same `sbuf`, with `blk_sd` writing and the DMA reading. **The
decisive test needs no bitstream: read the card on a host and compare the
sectors against the pattern.** If the card is right, everything above is
correct and the fault is in the read path.

**The refinement that got there, and why `2046` was not a finding.** On a run that corrupted 3 words, the byte read back out of the
sector buffer was flagged 2046 times against a control of 42,480,549 -- and
1024 sectors x 2 passes is **2048**. One flag per sector write is a boundary
artefact, not a fault, almost certainly the arming clock or the `blk_busy` edge
being counted. The control is inflated the same way: it increments every clock
while `blk_busy & blk_we`, and `blk_buf_addr` only moves once per SPI byte, so
each byte is counted about forty times.

Neither is fatal to the design of the check -- `rq_addr` and `buf_q` are both
one clock behind `blk_buf_addr`, so they are aligned and the steady state does
compare correctly -- but a number that lands within two of the sector count is
an artefact until proven otherwise. **Count once per byte, on the clock
`blk_buf_addr` changes, and exclude the first and last of a transfer.**

Recorded because the alternative was to report 2046 as a finding, and it is the
same shape as the 214 that turned out to be metadata runs and the 1018 that
turned out to be non-pattern traffic.

**The medium really is wrong, so the read path is not the corrupter.** That had
never been established on the Wukong: `patwr -v` proves only that a file written
and read back differs, and the in-flight evidence at the card interface came
from the DECA's `sun2_blktrace` -- on the SCSI card, not this one. Two cold
reads of the same file, each after its own reboot so nothing is served from the
buffer cache, name **the same three sectors with the same three wrong values**:

```
  sector 277 word  38   want 8026  got 584f
  sector 329 word 154   want 809a  got 2f2d
  sector 805 word  24   want 8018  got 2e2e
```

A read path that corrupted would give a different list each time. So the damage
happened once, on the way out, and is now on the card. It costs one reboot and
it removes half the search space.

**Which makes the remaining list short.** Every byte *offered* into the sector
buffer is proven correct -- 1,048,776 of them, 0 isolated wrong, 0 dropped --
and that covers `sun2_dvma`'s assembly, the Wishbone handoff and the XY450's
staging transitively, because `dma_buf_wdata` is extracted from `rd_stage` which
comes straight from `wb_dat_i`. What is left between a correct byte entering the
buffer and a wrong byte on the card is only:

* the `sbuf` RAM itself,
* `buf_q`, its registered read port -- the check is written but counts per
  clock rather than per byte, see the artefact above,
* `blk_sd`'s SPI shift and CRC, uninstrumented on this board.

**The gap that remains is the write *data* path above the adapter.** Everything
built so far checks reads, or checks a write against `req_dat` -- what the
adapter was handed. Nothing checks that `req_dat` is what the CPU or the master
actually put on the bus. `sun2_wishbone_bridge`'s write path
(`P_DATA_IN` -> `wb_dat_o`) and `sun2_dvma`'s write staging have never been
instrumented, and a word corrupted there would satisfy every check listed above:
the adapter would faithfully store, and faithfully read back, the wrong value.

**A caution about the machine as an instrument.** After many corrupting runs the
2560 MiB filesystem degraded to the point where `/usr/bin/adb` and
`/usr/bin/csh` both read wrong on a *cold* boot (54248 and 61295 against 50905
and 34435), and `ld` began failing deterministically until a reboot. Rewrite the
card before any run whose conclusion depends on a source being pristine.

**The asymmetry claim below is therefore withdrawn.**

**The asymmetry was measured and interpreted too narrowly.** The
suspicion here used to be that it was observational -- writes are verifiable
because the source is in hand, reads are not, and a corrupted word arriving in a
page read from disk is invisible until it is executed, which this machine does
plenty of (`lpd` cores, `ld` SIGILL, `halt` with `Illegal instruction`, `fsck`
with `Emulator trap`). Measured, it is not: **`dd if=/dev/rsd0a bs=8k count=256
| sum` twice gives `22901` both times.** The raw device bypasses the buffer
cache, so that is two million words fetched from the medium into memory by DVMA
with no caching in between; at the write side's rate of roughly one bad sector
in a hundred and twenty the two sums could not agree. And `sum /usr/bin/adb`
returns the reference image's `50905` on every boot, which is ground truth
rather than self-consistency.

So the fault is specifically **memory to device** -- the master's *read* of
memory -- and not device to memory. The direction that works is the one where
DVMA writes memory and the CPU reads it back.

**A used filesystem stops being an instrument.** After several corrupting runs
the machine's own `/usr/bin/csh` and `/usr/bin/adb` no longer matched their
pristine checksums, while `/usr/bin/sum` and `/usr/bin/od` still did -- so
copies made from them looked corrupt against the reference image while being
faithful copies of a damaged source. Verify the *sources* on the machine before
each run; the card carries pristine copies at several offsets for this reason.

**The bridge-to-master handoff is clean, including which half of the word it
took.** `sun2_dvma_probe` (`BLKTRACE=1`, read by `tools/deca_dvmaprobe.tcl`)
watches the one pairing that exists only in the failing direction:
`sun2_wishbone_bridge` loads `P_DATA_OUT` on `wb_ack_i & issued`, and
`sun2_dvma` captures `dvma_din` at the end of `S_LATCH`. Over a run of three
copies it counted **33,280 memory-read captures with exactly one bridge load
inside every one**, none with none, none with two, and **none that took the
wrong half** -- while the same run corrupted `csh` at sector 45 and `adb` at
sector 157, both confirmed by `cmp` after a reboot with the sources verified
pristine beforehand.

The half check matters because of the granule. A DVMA longword is two 68010
cycles, each of which fetches a 32-bit word from DDR3 and takes 16 bits of it by
`P_ADR_IN[1]`; the corruption is 16 bits wide, so a wrong half-select was the
natural fit and is now excluded by measurement. **What is left is the value**:
the master got exactly one load, from the half it asked for, and the data in
that half was wrong. That points below the bridge -- `deca_wb_to_ddr3` and
BrianHG's controller -- and not at the handshake above it.

**The two controllers agreeing is what makes that argument tight.** After
`sun2_dvma` the paths share nothing: the XY450 unpacks `wb_dat_i` straight into
its own `sbuf` through one muxed write port (`sun2_xy450.sv:851,320`), while the
SCSI card stages the longword, walks it out a byte at a time across the SCSI bus
through `scsi_fabric`, and lands it in `scsi_targ`'s dual-ported `mem`
(`sun2_scsi_core.sv:618,193`, `scsi_targ.sv:154`). Both corrupt identically, so
the fault is in what they share, and everything shared above the data itself has
now been measured clean.

**And the whole chain below it accounts perfectly, which puts the fault in the
data BrianHG's controller returns.** `deca_wb_to_ddr3` counts the reads it
issues, the responses it receives, responses arriving outside `D_READ`, and
reads whose 32-bit lane changed between issue and response -- the last being the
one *value* selection in the path, since BrianHG returns a 128-bit line and the
adapter takes a quarter of it by `req_adr[1:0]`. Measured on a run that
corrupted `csh` at sector 13 and `adb` at sector 171:

```
  captures      33280   no_load 0   late_load 0   wrong half 0
  reads issued  38592   responses 38592   unexpected 0   wrong lane 0
```

So every request has exactly one response, no response arrives unbidden, the
right quarter of the line is taken, the right half of that word is taken, and
the master captures it exactly once -- and sixteen bits still arrive wrong. The
memory holds the right data at that moment (a copy read back from the buffer
cache before any reboot checksums correctly), so what is left is that the read
returned the wrong contents. That is inside `Inputs/BrianHG-DDR3`, not in
anything this project wrote above it.

Worth knowing before chasing it there: the CPU uses the same controller and the
machine runs for hours, so whatever it is has to be far rarer for the CPU's
access pattern than for a master's, or invisible to it. `test/deca_ddr3` walks a
mebibyte and passes, which is the pattern *least* like a disk transfer.

**The corrupted word is stale data, not a failed write, and `tools/patwr`
is what said so.** It writes a pattern that describes its own position -- bit 15
a generation tag, bits 14:8 the sector modulo 128, bits 7:0 the word offset --
in two generations differing only in the tag, so a bad word decodes to a
position *and* says which generation it belongs to. Filling with zeros first
could not do that: zero carries no position, and the first run's bad words came
back `0000`, `0001`, `00ef` with nothing in them to read.

With a fill generation underneath, on a freshly written card:

```
  sector 293 word 210   want a5d2  got 0096
  OLD gen, sector 0 word 150, -9532 words (-19064 bytes)
```

One word in 262,144, the rate files show. The tag is clear, so it is
**fill-generation content** -- what the medium and the buffer cache held before
this write -- and it is at a *different* offset, so it is not the "this word was
never written" case either. It is old data fetched from somewhere else.

That matters because the address checks are all clean: `sun2_dvma_probe` and the
adapter's counters say one load per cycle, the right 32-bit lane, the right
16-bit half. What none of them checks is that the data a response carries
*belongs to the address that was requested* -- BrianHG's controller could answer
with a previous read's contents and every counter above would still read zero.
That is the gap the next instrument should close, and the read vector the
controller carries (`READ_ID`, `DDR3_VECTOR_SIZE`) is the handle for it.

Two cautions for anyone repeating this. The sector index is modulo 128, so a
file longer than 128 sectors makes the displacement ambiguous by multiples of
64 KiB -- the -19064 bytes above is the smallest candidate, not a certainty, and
a run of 128 sectors or fewer would be exact. And a verify is meaningless unless
the *write* pass printed its summary: an interrupted write leaves a half-written
file that reads as catastrophic corruption.

**Getting that instrument to read anything took five separate fixes to the same
signal, and the lesson is about `ifdef` rather than about DVMA.** The port on
`sun2_fpga`, its connection in `top_fpga`, the port on `top_fpga`, and the
declaration *and* connection in `deca_top` were each inside `` `ifdef SUN2_ILA ``,
which is only defined under `TRACE=1`. In an ordinary build every one of them
vanished, and the readout showed a healthy machine with all counters zero. The
declaration was the worst of them: with it compiled out, `dvma_probe` became an
**implicit one-bit net**, so bit 0 had a path and bits 79..1 did not -- which is
why the probe returned a fixed `...0001` whatever was wired to it, including a
hardcoded constant.

Quartus reports that, and in exactly one place: the map report's port
connectivity check, `Output port (80 bits) is wider than the port expression
(1 bits) it drives`. Nothing appears in the console log, and binding a
connection to a port that does not exist produces no message at all. `grep -A6
'Port Connectivity Checks' build/syn/quartus/*/sun2.map.rpt` is the check to run
after adding any signal that crosses a module boundary.

Two probe design rules came out of it, both cheap and both load-bearing:

* **A free-running heartbeat counter.** It proves clock, counter, module
  crossing and readout in one number, so a zero anywhere else is a fact about
  the machine rather than a question about the probe.
* **A counter for something that must be busy.** Bridge loads happen on every
  CPU memory read, so zero there can only be the instrument. Without it, "all
  counters zero" has two explanations and no way to choose -- which is precisely
  where this sat for four builds.

And two wrong models the board corrected, neither of which reading the RTL had
caught. The first invariant was "a load in the clock before the capture", which
flagged 11282 of 11282 captures: `W_ACK` is `(wb_ack_i & issued) | done` and the
DTACK the master waits on is gated further by the `C_S` chain, so the load lands
somewhere inside the cycle. The second was counting *every* `S_LATCH`, which
flagged everything again -- `S_LATCH` runs on writes too, and a write produces no
load at all, so a boot streaming a disk into memory looks like total failure.
100% of anything is a broken model, not a broken machine.

**Do not read a signature out of a trace without checking the instrument
first.** The signature half of `sun2_blktrace` was wrong on its first outing --
see the trap below -- and it named two sectors of other files as the intruders
in a corrupted block. Both were chance collisions in a 16-bit fold.
`tools/blktrace_match` prints the expected number of those, `W*S/65536`, above
its own output for that reason.

## The DECA's trace buffer and the spurious SCSI probe

**There is a logic analyser on the DECA now, and its first capture exonerated
the bus.** `rtl/sun2-common/sun2_trace.v` is a 256-sample circular buffer on the
same 118-bit `dbg_bus` the Wukong's ILA taps, read out over In-System Sources
and Probes by `tools/deca_trace.tcl`, fitted with `make -C syn quartus TRACE=1`.
It is ordinary RTL rather than SignalTap because **SignalTap cannot be
scripted** -- `quartus_stp`'s `::quartus::stp` runs an acquisition and offers
nothing at all for creating one -- and being ordinary RTL means it is
unit-tested (`make -C sim trace`, 22 checks, both mutations caught) before a
bitstream is spent on it.

Triggering on page 0xEE2800 at **FC 5** on a 13.889 MHz cold boot, the run that
prints `Probing I/O bus: sd ie`, catches the probe itself:

```
 rel  A       FC AS RW DTACK BERR C_S4 C_S6 C_S8 C_S24 ps_pmap TIMEOUT ERR MATCH_MEM
  +0  EE280C   5  0  1   1     1    0    0    0    0     FE6      0     0      0
  +1  EE280C   5  0  1   1     1    1    0    0    0     EC8      0     0      0
  +3  EE280C   5  0  1   1     1    1    1    1    0     EC8      0     0      0
 +11  EE280C   5  0  1   1     1    1    1    1    1     ECA      0     0      0
 +12  EE280C   5  0  1   1     0    1    1    1    1     ECA      1     1      0
 +13  EE280C   5  1  1   1     1    1    1    1    1     ECA      1     1      0
```

**That is a perfect timeout, and it is the only thing the hardware could do.**
There was no SCSI anywhere in *that* design -- so no `MATCH_*` term covered the
page, nothing sourced DTACK, and the cycle had to time out. (That is no longer
true of the tree in general: `MB_SCSI=1` and `VME_SCSI=1` both decode a host
adapter now, and a MultiBus build answers at `0x80000`. The reasoning below is
about the build the capture came from, where the cage really was empty.) That is the documented contract for TYPE 2 space
and it is how the PROM discovers empty addresses at all.

Decoding `ps_pmap` (`ps_pmap2devices`, entry bits 31..20) says where the cycle
actually went: **0xEC8 is VALID, TYPE 2 -- the system bus**, not on-board I/O.
So although `SCSI_BASE` sits in `s2addrs.h`'s "on-board and off-board I/O"
block between the parallel port at 0xEE2000 and the *on-board* Ethernet at
0xEE3000, the PROM maps that page out to the bus, where on this machine nothing
is plugged in. The genuinely off-board controller is the other entry,
`sdstd[1] = MBMEM_BASE+0x84000 = 0xF84000`.

The page is VALID, `PROTERR` is clear,
`MATCH_MEM` is 0 so the memory exemption correctly does not apply, DTACK never
asserts, `C_S24` fires 11 clocks after `AS`, and `BERR` is asserted on the next
one with `TIMEOUT` and `ERR` both set. As a free corroboration that the field
map is being read correctly, `ps_pmap` goes 0xEC8 -> 0xECA *during* the cycle:
bit 1 is ACC, and that is the MMU's accessed-bit writer doing its job, caught
in the act. The MMU, the device decode, the `C_S`
chain and the bus timeout are all doing exactly the right thing at the
frequency that fails.

**And the trace then found it: an array bound that fails to stop the loop.**
`sdprobe` walks `sdstd[] = { 0xEE2800, 0xF84000, 0 }` for `i < 2`. Both real
entries probe correctly -- 0xEE280C and 0xF8400C each time out, each raises a
textbook 68010 bus error, and the handler returns -1 both times, all visible in
the capture. Then, with `i` just written to memory as **2**:

```
 +455  000F28 FC5 WR 0002        i = 2
 +482  EF5682 FC6 RD 6C44        bges 0xEF56C8   (the loop exit)
 +508  EF5684 ...                ... and execution continues HERE
 +585  EF7944 FC5 RD             sdstd[2] -- the terminator, 0x00000000
 +681  000F24 FC5 WR 000C        peek(0x0000000C)
```

**`cmpi.l #2` against an `i` of 2 did not take its `bge`.** The loop runs a
third time, indexes one past the end of the table, reads the terminating zero,
adds `dma_count`'s offset of 12, and probes **address 0x0C** -- which is low
RAM, so it reads, it takes `0x6789`, it reads `0x6789` back, and `sdprobe`
returns **2**.

That is the whole failure, and it explains the thing that made no sense:
`Boot: sd(2,0,0)`. `sdprobe` can only ever return 0, 1 or -1, so a controller
number of 2 was impossible -- unless the loop ran with `i` = 2, which is exactly
what it did. `Probing I/O bus: sd ie` is the same wrong verdict one call
earlier, and the `scsi: timeout` / `cannot select` that follow are the driver
talking to address 0x0C.

**Two candidates remain for the wrong branch and they are cleanly separable.**
`cmpi.l #2,%fp@(-8)` is a *longword* read, two bus cycles, and this project has
history there: RD68011's fixed bug was a longword read losing its first half
across a bus grant. Either the core's condition codes are wrong for that
compare, or the compare read a stale `i` -- note the index computation a few
instructions later read the same location and got 2, which is what makes the
stale-read case interesting rather than obvious. Reading the value the CPU
actually latched needs care: `dbg_data` lags by one *memory* transaction and
PROM fetches do not go through the bridge, so the shift cannot be applied
naively across a mixed sequence.

**So the fault is above the bus, not on it.** `sdprobe`
(`rsun/sys/sunstand/sd.c`) reports a controller present only if
`peek(&har->dma_count)` does *not* return -1; the hardware raises the bus error
that should make it return -1, and the machine still prints `sd`. That moves the
search to bus-error *delivery and recovery* -- the exception frame, the restart,
and the bus error register -- and away from everything this file spent four
builds suspecting. Note also `Boot: sd(2,0,0)`: `sdprobe` can only ever return 0
or 1, so the controller number the PROM ends up with did not come from it.

So the next move is not another frequency. It is SignalTap on the `C_S` chain
and the DTACK terms at the SCSI probe address -- the DECA's equivalent of the
ILA that found the Wukong's frame-buffer timeout race, which was this same
shape: `C_S24` firing on clock 12 against a DTACK on clock 13.

## The ILA on the MMU bus

**There is an ILA, and it is aimed at the MMU.** `ILA=1` fits one on `dbg_bus`
-- 102 bits of address, function code, both map lookup stages, the protection
and timeout terms, the bus handshake, the data, both context registers, and
`dvma_active`, which is the one thing `sun2_fpga` cannot work out for itself:
`top_fpga` muxes the master onto the same wires on purpose, so no combination
of address and function code separates a master's cycle from the CPU's. It is
packed in `sun2_fpga.v` with its field
map beside it and sampled every clock rather than once per cycle. It exists
because SunOS panics creating pid 1 with a protection violation reported as a
bus timeout, `tools/mmuprobe` cannot reproduce that from a boot block, and a
bitstream costs ten minutes where the simulation that would show it costs ten
hours. Simulation always builds the bus and `tb_sun2.sv` checks every field
against the signal it claims to carry, on every clock edge of every boot, so a
field cannot silently drift from its map; a bitstream builds it only under
`ILA=1`, because the bare port cost 8 LUTs and 17 ps of hold margin in a build
with no ILA in it. `BRINGUP.md` has the triggers and the diagnostic.

**The ILA can see the interrupt path now.**  `dbg_bus` is 118 bits: the top 16
are `{EN_INT, IPL2_n..IPL0_n, INT7_n..INT1_n, timer_int[5:1]}`, which is the
*request* side.  The acknowledge side alone cannot answer "which interrupts
fire" -- a request asserted and never granted and one never asserted are the
same absence -- and `timer_int` is what separates "the timer never asserted"
from "the encoder ate it".  `syn/ila_capture.tcl` gains `iack` and `iackseq`;
use `iackseq`, which qualifies capture on FC 7 so 4096 samples are 4096
acknowledges however far apart.  Plain `iack` triggers on one and then holds
4096 *clocks*, about 205 us, where a 100 Hz interrupt is 10 ms apart -- an
absent level 5 there means nothing at all.

Two traps met while reading captures, both of which produced confident
nonsense first: a capture window that is mostly the machine *idling in the
monitor after the probe finished*, where counter 2 is not armed and reads 0
because that is correct; and `ila_capture.tcl` printing `0 samples captured`
over a perfectly good 4096-sample CSV, because `STATUS.SAMPLE_COUNT` reads 0
once the data has been uploaded.  The second was recorded in `a16c586` as an
open defect and was not one.

Two ways a capture lies about interrupts, both met here.  A 4096-sample window
at 20 MHz is **205 us**: a 100 Hz interrupt is 10 ms apart, so an absent level 5
in a plain capture means nothing -- use `iackseq`, which qualifies on FC 7 so
4096 samples are 4096 acknowledges.  And a window that runs on past the event
is mostly the machine *idling in the monitor afterwards*, where an unarmed
counter reads 0 because that is correct.

## Traps from the instrument era

**The read-side clock crossing is clean, measured with a counter rather than a
capture.** `syn/vio_read.tcl` reads the adapter's crossing counters over a VIO
-- the Xilinx equivalent of the DECA's In-System Sources and Probes, fitted with
`ILA=1`. After two full `patwr` passes (1 MiB):

```
  reads       306,520,938   read acknowledgements
  pattern       2,097,148   ... whose word matched the pattern before crossing
  corrupted             0   ... and did not match after
```

`pattern` is the control and it is large, so the check demonstrably sees the
pattern -- which is exactly what the ILA attempt could never show. Zero
corrupted, on a workload that reliably produces bad words, clears
`rd_lane -> wb_dat_o`.

**And the write crossing is clean too, so both hops in the adapter are out.**
`req_dat` is latched in the Wishbone domain and read combinationally in the
memory clock domain -- the mirror of the above, and the one that fitted every
observation, because a word corrupted there would be stored faithfully and read
back faithfully for ever after. With the counters widened to 32 bits and four
`patwr -u` passes (2 MiB):

```
  read crossing    pattern 2,097,148   corrupted 0
  write crossing   pattern 1,056,836   corrupted 0
```

At the measured fault rate a million checked write words expects about sixteen
corruptions. Zero, with a control that large, ends it: **neither clock crossing
in the adapter is the fault.**

Two mistakes the controls caught, and they are the reason the controls exist.
The first write check gated on `wb_sel_i == 4'hF` -- but **the 68010 is a 16-bit
bus**, so the bridge never issues a full 32-bit write and the check was dead,
reporting `pattern 0` beside `corrupted 0`. The second read the control as
`0x102f` and called it clean: 4143 words expects 0.13 hits and proves nothing,
which is what forced the counters from 16 bits to 32. **A zero is worth exactly
as much as the control beside it.**

**What is left is the bridge itself.** `sun2_wishbone_bridge` is single-domain
-- one clock, one `always` block, no synchronisers -- so it was never a CDC
suspect, and its data path has still never been checked: `P_DATA_IN` ->
`wb_dat_o` on a write, `wb_dat_i` -> `P_DATA_OUT` on a read. A word damaged
there is invisible to every adapter counter above, because it arrives already
wrong and so never sets `pre_ok`.

* **An ILA capture window is 205 us and a disk workload is minutes, so the
  trigger has to do all the work -- and a trigger nobody has validated is worth
  nothing.** The crossing check in `wb_to_mig_ui` (`xchk_bad`, ILA mode `xchk`)
  fires only on a word that matched `tools/patwr -u`'s pattern *before* the
  crossing and not after, which is elegantly self-gating and useless until you
  can show it ever sees the pattern at all. It never triggered over 14 minutes
  and four passes -- and the control (`xpat`, trigger on the pattern's shape
  alone) shows why that proves nothing: of 293 captured transactions, 292 were
  CPU instruction fetches (`4e75`, `206f`, `226f`) and the one pattern-shaped
  word was `80008000`, both halves index 0, which the encoding cannot produce.
  A coincidence, not the pattern.

  Two further ways the same experiment was void before that. **Vivado takes
  about 90 seconds to start and arm, and a `patwr` pass takes 60**, so the first
  two captures armed *after* the run they were meant to watch had finished; a
  long pass (`patwr ... 8`) is needed so the workload outlives the arming. And
  `xchk_exp` is computed for every transaction, so it looks pattern-shaped
  beside data that is plainly 68010 code -- it means nothing unless the
  transaction really was reading the pattern.

  The instrument this wants is a **counter read once at the end**, not a
  capture: the DECA's In-System Sources and Probes did exactly that, and the
  Wukong equivalent is a VIO, which this tree does not yet have. An ILA cannot
  count.

* **An instrument with no testbench, and a signature that looked plausible.**
  `sun2_blktrace` folds each sector as it passes so a block can be identified by
  its contents. `Inputs/Wish5380/doc/block.md:58` says `buf_rdata` answers
  `buf_addr` **one cycle late**; the first version folded it in the cycle the
  address changed, so every write-side signature was a fold over a byte sequence
  shifted by one. Nothing about that looks broken -- it yields ordinary-looking
  16-bit values that are simply not the block's -- and it reported 127 of 171
  sectors of a *correctly copied* file as corrupt, and named two sectors of
  other files as the intruders. `cmp` on the machine then put that file's first
  difference at byte 4385, past every sector the trace had condemned.

  Two things saved it from being believed. The LBA half of the same entry does
  not depend on that timing, and it was internally consistent -- thirteen blocks
  in the right order at the addresses 4.2BSD predicts -- so the two halves
  disagreed with each other. And a 16-bit fold over ~800 writes against ~2000
  candidate sectors is expected to collide about 24 times by chance, which is
  more than the "evidence" found. `tools/blktrace_match` prints that number
  above its output now, and `make -C sim blktrace` is the test the module
  shipped without: 23 checks, four mutations tried and all four caught -- the
  fourth only after the test was extended, because recording the key at
  `blk_done` instead of latching it at `blk_start` passed the first twenty.
  Writing the testbench also found a second defect the board had not yet shown,
  where a read's between-strobe idle cycles were folded as bytes of their own.

* **A debug hub cannot be told it runs at 20 MHz.** `C_CLK_INPUT_FREQ_HZ`
  takes 25 MHz to 650 MHz and rejects anything slower, and the hub Vivado
  inserts for an IP ILA takes the ILA's clock -- `cpu_clk`. It runs on
  `clk50_g` instead, which is legal because a hub and its cores may be in
  different domains, and `implement_debug_core` must run after the change or
  `place_design` stops with "needs to be (re)generated". Declaring a false
  25 MHz would also have built, and the thing it lies about is exactly what
  decides whether the hub answers JTAG.

* **A probe narrower than its concatenation truncates in silence, and the
  arithmetic is easy to get wrong.** `probe_width` was set to 366 for a
  concatenation of 382 bits -- two 8-bit fields forgotten in the sum -- and
  every field shifted. The readout was not obviously broken; it was plausible
  nonsense, reporting `bridge loads 0` beside `late_load 39240` and `reads
  issued 0` beside `responses 41467`. Nothing warns, at any stage. Add up the
  widths in the comment beside the concatenation and check the total against
  `probe_width` each time one changes.
