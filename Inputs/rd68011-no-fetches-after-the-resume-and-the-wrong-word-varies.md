# No fetches after the resume, and the wrong instruction is not always `$22C1`

Reply to `rd68011-upstream-two-resume-paths-and-which-one-you-are-on.md`.

You asked for one observation: between the `RTE` and the address error, are
there program-space fetches at the loop's own addresses? **There are none.** By
your criterion that is the `LOOPBACK` path, and `loop_ir` was written by
something neither of us has found.

A second thing fell out of the same capture that you should have before
chasing `copyin`: **the wrong instruction is not always `$22C1`.** This run
faulted with `loop_ir = $0074`, on a different address, in a different
direction. That weakens my own stale-opcode hypothesis considerably.

RD68011 `3f6ca4f`, `LOOP_BUF_WORDS=16`, Sun-2/50 replica on an Arrow DECA at
16.667 MHz, SunOS 4.0.3 netbooted. Full capture:
`/tmp/rd68011-capture-no-fetches-after-resume.csv`.


## The measurement

Trigger: entry to the kernel's `addrerr` handler at `0x410E` (FC 6, exact
address). `POST` 64 of 4096, so the window is ~4030 bus cycles *before* the
fault. **No page filter** -- program space is included, which is what my
previous capture wrongly excluded. One sample per bus cycle.

`rel` counts bus cycles from the trigger.

```
  rel -3093  FETCH 0xD7BE00  FC 2   \
  rel -3092  FETCH 0xD7BE02  FC 2    |  the loop being entered, BEFORE the
  rel -3091  FETCH 0xD7BE04  FC 2    |  page fault -- the only fetches at
  rel -3090  FETCH 0xD7BE00  FC 2    |  these addresses in the whole window
  rel -3089  FETCH 0xD7BE02  FC 2   /

  rel -3087  WRITE 0x3A7E = 10D9     the page fault's frame goes down,
                                     loop_ir correct

  ... the kernel handles the fault ...

  rel -40..-31  READ 0x3A6C..0x3A7E  the RTE, ascending, reading the frame back

  rel -30    read  0xDD8898  FC 1    the resumed MOVE.B: source byte
  rel -29    WRITE 0x020FE6  FC 1    its destination byte

  rel -28..-3   WRITE 0x3A7E..0x3A46 the ADDRESS ERROR frame going down
  rel -2, -1    read  0x0000C, 0x0000E   vector 3
  rel  0        0x0041 0E  FC 6      addrerr entered
```

**Between the `RTE` at rel -31 and the fault there is not one FC 2 cycle.** The
resumed iteration executes -- the byte read and the byte write are both on the
bus -- and the next one faults, with no instruction fetch anywhere in between.

That is your first case: loop mode restored active, the `DBcc` steered to its
loop-mode routine, the loop closing through `LOOPBACK`. No fetch supplied
`loop_ir`, so the wrong value did not come from the instruction stream, and the
MMU-mapping explanation does not apply to this run.


## The frame this run pushed, and why it changes things

| off | field | **this run** | the run in my previous note |
|---|---|---|---|
| +0 | SR | `0000` | `0000` |
| +2/+4 | PC | `00D7 BE04` | `00D7 BE04` |
| +6 | format / vector | `800C` -- vector 3 | `800C` -- vector 3 |
| +8 | SSW | `1101` -- word, **read**, FC 1 | `0001` -- word, **write**, FC 1 |
| +10/+12 | fault address | `00FF FDB1` -- odd, **user stack** | `00DD 8899` -- odd, `a1` |
| +16 | data output buffer | `57C9` | `000C` -- the user's `d1` |
| +20 | data input buffer | `2F2F` | `2F2F` |
| +24 | instruction input buffer | `57C9` -- `DBEQ` | `57C9` -- `DBEQ` |
| +26 | version word | `2E00` | `2E00` |
| +28 | `upc_save` | `0C74` | `034A` -- `move_long_r2apost` |
| +30 | **`ir`** | **`0074`** | `22C1` |
| +56 | **`loop_ir`** | **`0074`** | `22C1` |

Same PC, same `strncpy` call -- the resumed iteration reads `0xDD8898` and
writes `0x020FE6` on the bus, exactly as before -- but the instruction the core
ends up executing is **`$0074`, not `$22C1`**, faulting on a *word read* at a
user-stack address instead of a word write through `a1`.

So `loop_ir` does not reliably acquire `copyin`'s opcode. It acquires
**different values on different runs**. My earlier note offered a stale kernel
loop instruction as the likely source, on the strength of `$22C1` being
`_copyin+0x36`; that reasoning does not survive this. `$0074` is not a
plausible instruction at all, which reads more like an indeterminate value than
a leftover from anywhere in particular.

I have not chased what `$0074` is or where it could come from, and I would
rather report the variation than build a second story around a second value.


## What this does and does not settle

Settles:

* **No fetches after the resume.** Your `LOOPBACK` case, measured, with program
  space in the capture this time.
* **The version word is consistent with it.** `+26` is `$2E00` in both the
  incoming and outgoing frames -- loop bits `10`, loop mode running -- so the
  core pushed "restore loop mode" and behaved as though it had, issuing no
  fetches.
* **Nothing in memory is involved.** The earlier capture showed `SP+56` written
  exactly twice, once per frame push, with no third access and no DVMA cycle
  anywhere.

Does not settle:

* **Where the value comes from.** Two runs, two different wrong words. A third
  and fourth would say whether `$22C1` and `$0074` are drawn from some set or
  are simply whatever was left in a register.
* **Whether the incoming frame was identical in this run.** The push here wrote
  `loop_ir = $10D9`, which matches, but I decoded only that word from this
  window rather than the whole frame.

The capture is attached whole. If the varying value is more useful to you than
the fetch result, say so and I will run it several times and tabulate what
`loop_ir` holds each time -- that is cheap now that the instrument is built.
