# `loop_ir` is restored correctly and is wrong by the next iteration

Reply to `rd68011-upstream-what-the-core-does-and-what-to-capture-next.md`,
and a **retraction** of the memory-clobber reading in
`rd68011-sp56-is-correct-when-pushed-and-wrong-when-popped.md`.

One capture now holds the whole fault: the page fault, the frame going down,
the kernel's handling, the `RTE` reading it back, and the address error. Same
fault, same run, no cross-run pairing and no interval left unmeasured.

**Result: `SP+56` is pushed as `$10D9`, is never written again, is read back
as `$10D9` by the `RTE` -- and the loop nevertheless faults executing `$22C1`.
Nothing in memory changed. The wrong value appears between a correct restore
and the next iteration.**

RD68011 `3f6ca4f`, `LOOP_BUF_WORDS=16`, Sun-2/50 replica on an Arrow DECA at
16.667 MHz, SunOS 4.0.3 netbooted.


## Retraction first

The previous note reported `SP+56` pushed `$10D9` and popped `$22C1`, and
concluded that something wrote the word in between. **That was wrong, twice
over, and your section 5 predicted both errors.**

* The `$22C1` write I read as a clobber is the **outgoing address-error
  frame's own push**. In the new capture it is the first of a descending run
  of writes -- `3A7E=22C1, 3A7C=002F, 3A7A=0000, 3A78=BE00, 3A76=00D7,
  3A74=BE02` -- which match the address-error frame word for word. It is a new
  frame landing on the same stack address, exactly as you said.
* My "the `RTE` popped `$22C1`" came from the debug data register lagging one
  transaction. The read of `0x3A7E` is *immediately* followed by that write, so
  the lag correction picked up the write's data. The read's true value is
  `$10D9`.

Apologies for the noise. The instrument was right and the reader was not.


## What one capture now shows

Trigger: the failing user-data read at `0xDD8898`, qualified on `ERR` so a
healthy access to the same library page cannot fire it. Capture filter: store
only page 7, the supervisor stack. Sampling: one sample per bus *cycle* rather
than per clock, which is what finally made the window span the handling -- a
cycle here is a dozen clocks, so per-clock sampling spends the buffer eight
times over on each cycle.

Relative sample numbers below are stored stack cycles.

```
   +1          WRITE 0x3A7E = 10D9        the page fault's frame goes down
                                          (descending push, SP+56 first)

   ... 1086 stored stack cycles, no access to 0x3A7E at all ...

  +1061..+1086 READ  0x3A46 .. 0x3A7E     the RTE, ascending: the whole
                                          29-word frame read back

  +1087..       WRITE 0x3A7E = 22C1       the ADDRESS ERROR frame going down
                WRITE 0x3A7C = 002F
                WRITE 0x3A7A = 0000  ...
```

`SP+56` is written exactly twice in the entire capture: once by each frame
push. There is no third access, no DVMA cycle anywhere (`dvma` is 0 on every
sample), and nothing else touches the word.


## The two frames, from that single capture

| off | field | **incoming** (page fault) | **outgoing** (address error) |
|---|---|---|---|
| +0 | SR | `0000` | `0000` |
| +2/+4 | PC | `00D7 BE04` | `00D7 BE04` |
| +6 | format / vector | `8008` -- vector 2 | `800C` -- vector 3 |
| +8 | SSW | `1301` -- byte, read, FC 1 | `0001` -- word, write, FC 1 |
| +10/+12 | fault address | `00DD 8898` -- **even** | `00DD 8899` -- **odd** |
| +16 | data output buffer | `BDF0` | `000C` -- `D1` = 12 |
| +20 | data input buffer | `BDF0` | `2F2F` |
| +24 | instruction input buffer | `57C9` -- `DBEQ` | `57C9` -- `DBEQ` |
| +26 | version word | `2E00` | `2E00` |
| +28 | `upc_save` | `004D` -- 77, source-byte read | `034A` -- 842, `move_long_r2apost` |
| +30 | **`ir`** | **`10D9`** -- `MOVE.B (A1)+,(A0)+` | **`22C1`** -- `MOVE.L D1,(A1)+` |
| +36/+38 | internal | `00FF FCE4` | `0002 0FE6` -- the destination pointer |
| +40..+50 | internal | `00D7 BE00 / BE02 / BE00` | `00D7 BE00 / BE02 / BE00` |
| +56 | **`loop_ir`** | **`10D9`** | **`22C1`** |

The incoming frame is coherent for the demand-paging fault on the loop's first
source byte: byte, read, even address, microword 77, and the *right*
instruction in both `ir` and `loop_ir`. The outgoing frame is coherent for
`MOVE.L D1,(A1)+` executing correctly -- as you established, four independent
fields name it and the alignment check is doing its job.


## The register file corroborates it

The frame carries no general registers, but the kernel's `SAVEALL`
(`locore.s:112`, `clrw sp@-; moveml #0xFFFF,sp@-`) puts them just below it --
with the frame's SR at `0x3A46`, `d0` is at `0x3A04`. That area is on the same
page and is in the capture:

```
    d0  0x00020FE6      dest, saved by strncpy's `movel %a0,%d0`
    d1  0x0000000D      = 13
    a0  0x00020FE6      dest
    a1  0x00DD8898      source, even
    a5  0x00DD605C      libc's data base
```

`d1` is **13** at the page fault and the outgoing frame's data output buffer is
`0000 000C`, **12** -- one `DBEQ` decrement later, i.e. exactly the one
iteration the bus shows completing in between (byte read at `0xDD8898`, byte
write at `0x020FE6`, `a1` advancing from even to odd).

So the data output buffer holds the value `MOVE.L D1,(A1)+` would write, and it
is the **user's** `d1`. The wrong instruction executed against the right
register file, in user context, through the user's `a1`. Had the core somehow
been running `copyin`'s instruction in the kernel's context, that field would
hold whatever the kernel was copying instead.


## The sequence, with nothing left unmeasured

1. The loop takes a demand-paging fault on `0xDD8898`, its first source byte.
   The core pushes a correct frame: `ir` and `loop_ir` both `$10D9`.
2. The kernel handles it. Over 1086 stored stack cycles **nothing writes
   `SP+56`**, and no bus master appears anywhere in the capture.
3. The `RTE` reads the frame back in full, ascending `0x3A46` to `0x3A7E`. It
   therefore restored `loop_ir = $10D9` -- the correct instruction.
4. The bus then shows the resumed iteration completing correctly: a byte read
   at `0xDD8898` with UDS alone, and a byte write at `0x020FE6`.
5. The next iteration faults, and the frame it pushes says the core was
   executing `MOVE.L D1,(A1)+`: `ir` `$22C1`, `loop_ir` `$22C1`,
   `upc_save` 842 in the long-move microcode, a word-sized write through `a1`
   at an odd address.

Between (3) and (5) no kernel code runs, no memory write occurs, and the value
in the frame in memory is `$10D9` throughout. **`loop_ir` acquires `$22C1`
inside the core, after a correct restore.**


## Where that points

Your section 3 says `loop_active` is set in exactly two places: `LP_ENTER`,
which writes `loop_ir` on the same edge, and `RESUME`, which restores it from
`SP+56` as separate microwords. This capture exonerates `RESUME` -- it was
handed `$10D9` and the instruction it resumed executed correctly for one
iteration.

That leaves the re-entry. After the resumed `MOVE.B` completes, the loop closes
through the `DBEQ` and loop mode is entered again; if that path latches
`loop_ir` from something other than the current `ir`, a value left over from
the kernel's own loop-mode loop is exactly what would be sitting there --
`copyin`'s `MOVE.L D1,(A1)+` is `$22C1`, and the kernel ran it while handling
this very fault.

That is a hypothesis about your microarchitecture offered by someone who cannot
see it; the measurement is the five steps above.


## Caveat

One capture. The push side was separately repeated three times with `SP+56` =
`$10D9` every time, and the failure itself reproduces on demand -- three
programs, byte-identical core dumps -- but the pop and the sequence above have
been seen once. The instrument additions this needed (exact-address trigger,
`ERR` qualifier, build-time depth and POST, a page capture filter, and
one-sample-per-cycle) are unit-tested at 34 checks in `make -C sim trace`.
