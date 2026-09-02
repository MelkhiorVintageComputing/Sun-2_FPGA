# `SP+56` is right when the core pushes it and wrong when `RTE` reads it back

> **RETRACTED -- superseded by
> `rd68011-loop-ir-goes-wrong-after-a-correct-resume.md`.** The `$22C1` this
> note reads as a write between push and pop is the *outgoing* address-error
> frame's own push landing on the same stack address, and the "popped `$22C1`"
> is the debug data register's one-transaction lag picking up that adjacent
> write. A single capture spanning the whole fault shows `SP+56` written
> exactly twice -- once per frame -- read back by `RTE` as `$10D9`, and the
> loop faulting on `$22C1` regardless. Nothing in memory changes.

Reply to `rd68011-upstream-what-the-core-does-and-what-to-capture-next.md`.
This is your test **(b)**, run on the machine, plus the repeatability control
that makes it a measurement rather than an inference.

**Result: the core pushes `$10D9`. The `RTE` reads back `$22C1`. Exactly one
word of the 29 differs, and no bus master touched it.**

**But the two measurements are of different `inetd` invocations, and that gap
is not closed.** See *Are these the same fault?* below before relying on this.
The push is reproducible three times over; the pop is one capture; and no
capture contains both. Your alternative -- that the core pushed `$22C1` that
time, in a scenario your sweep has not found -- is not excluded by anything
here.

Observed on RD68011 `3f6ca4f`, `LOOP_BUF_WORDS=16`, Sun-2/50 replica on an
Arrow DECA at 16.667 MHz, SunOS 4.0.3 netbooted.


## What was measured

Two captures on the same 118-bit CPU bus recorder, 1024 samples.

**The push.** Trigger: a user-data read at `0xDD8898` **that the machine is
failing** -- the `ERR` term added to the recorder for this, because triggering
on the address alone catches a healthy access from some other process using the
same library, which is what spoiled the first attempt. `POST` 960, so the
buffer keeps what follows the fault. The trigger sample is the fault itself:

```
    A=DD8898  FC=1  RW=1  DTACK=1  BERR=0  ERR=1  PROTERR=1
```

a protection violation on the source byte -- the demand-paging fault.

**The pop.** Trigger: entry to the kernel's `addrerr` handler at `0x410E`
(found from the kernel's own `protoscb+0xC`), `POST` 64, so the buffer keeps
the ~950 cycles *before* the address error -- which contain the `RTE`'s
read-back of the incoming frame.

Read data on this bus lags by one transaction (the debug register loads on
acknowledgement), so the pop column is lag-corrected; write data is carried
during its own cycle and is not.


## The two frames, word for word

Both at `SP = 0x3A46`.

| off | field | **PUSH** by the core | **POP** by `RTE` |
|---|---|---|---|
| +0 | SR | `0000` | `0000` |
| +2 | PC hi | `00D7` | `00D7` |
| +4 | PC lo | `BE04` | `BE04` |
| +6 | format / vector | `8008` | `8008` |
| +8 | SSW | `1301` | `1301` |
| +10 | fault addr hi | `00DD` | `00DD` |
| +12 | fault addr lo | `8898` | `8898` |
| +16 | data output buffer | `BDF0` | `BDF0` |
| +20 | data input buffer | -- | `BDF0` |
| +24 | instruction input buffer | `57C9` | `57C9` |
| +26 | version word | `2E00` | `2E00` |
| +28 | `upc_save` | `004D` | `004D` |
| +30 | `ir` | `10D9` | `10D9` |
| +32 | internal | `0000` | `0000` |
| +34 | internal | `00D7` | `00D7` |
| +36 | internal | `00FF` | `00FF` |
| +38 | internal | `FCE4` | `FCE4` |
| +40 | internal | `00D7` | `00D7` |
| +42 | internal | `BE00` | `BE00` |
| +44 | internal | `00D7` | `00D7` |
| +46 | internal | `BE02` | `BE02` |
| +48 | internal | `00D7` | `00D7` |
| +50 | internal | `BE00` | `BE00` |
| +52 | internal | `0000` | `0000` |
| +54 | internal | `000E` | `000E` |
| +56 | **`loop_ir`** | **`10D9`** | **`22C1`** |

Every word the recorder saw is identical except `SP+56`. `ir` at +30 still
holds `$10D9`, the user's `MOVE.B (A1)+,(A0)+`; only the looped-instruction
slot is different.

Decoding the rest with your field map, the pushed frame is entirely coherent:
`SSW $1301` is byte, read, user data; the fault address is **even**;
`upc_save $4D` is microword 77, the source-byte read of
`move_byte_apost2apost`; the version word's loop bits say loop mode running.
That is the legitimate demand-paging fault on the loop's first source byte,
described correctly, with the correct instruction in both `ir` and `loop_ir`.


## The repeatability control

Because the push and the pop cannot both fit in one 1024-sample window -- the
kernel's page-fault handling far exceeds the ~61 microseconds the buffer covers
-- they come from different `inetd` invocations. That pairing is only legitimate
if each capture is reproducible, so the push was repeated three times:

| off | field | run 1 | run 2 | run 3 |
|---|---|---|---|---|
| +6 | format | `8008` | `8008` | `8008` |
| +8 | SSW | `1301` | `1301` | `1301` |
| +10/+12 | fault address | `00DD8898` | `00DD8898` | `00DD8898` |
| +24 | IRC | `57C9` | `57C9` | `57C9` |
| +26 | version | `2E00` | `2E00` | `2E00` |
| +28 | `upc_save` | `004D` | `004D` | `004D` |
| +30 | `ir` | `10D9` | `10D9` | `10D9` |
| +56 | **`loop_ir`** | **`10D9`** | **`10D9`** | **`10D9`** |

23 of the 25 captured words are identical in all three. The two that vary are
+16 (data output buffer) and +34, `BDF0`/`BDF0`/`0000` -- and the data output
buffer is a don't-care for a *read* fault, so those are residue slots rather
than signal. **`SP+56` is `$10D9` every time.**

The pop side was attempted twice; one capture triggered and gave the table
above, the other did not trigger at all (its `inetd` produced no address error
in the window). So: push confirmed three times, pop once.


## Are these the same fault?  Not proven

The push and the pop cannot share a window: the recorder is 1024 samples,
about 61 microseconds at 16.667 MHz, and the kernel's page-fault handling
between them is far longer. So they are different invocations, and the claim
"one word changed" rests on the two being interchangeable.

What supports that:

* the push is **identical in three consecutive runs**, `SP+56` = `$10D9` every
  time, with only the two don't-care slots varying;
* the popped frame is a frame *for the same fault*: `format 8008`, fault
  address `00DD8898`, `SSW 1301`, `upc_save 004D`, `ir 10D9` -- every field
  matches the pushed frame, and each process faults on that address once;
* within the pop capture's window, which reaches 957 samples (~57 microseconds)
  before the trigger, the **earliest supervisor write into the frame area is
  after the address error** -- the outgoing frame's own push, at sample -264.
  Nothing wrote the frame in the ~19 microseconds before the `RTE` read it.

What is **not** established:

* that run's own push was never observed. If the core pushed `$22C1` in that
  invocation, everything above is equally consistent -- and that is a core bug
  rather than a memory clobber. Nothing in these captures separates the two.
* the pop was captured **once**. A second attempt did not trigger (its `inetd`
  produced no address error in the window), so there is no repeatability
  control on the pop to match the one on the push.

Two things would close it, and both are cheap compared with what has already
been spent:

* **your (a)** -- log `56(%sp)` as the first act of the bus-error handler. If it
  reads `$10D9` there and the `RTE` later pops `$22C1`, push and pop are
  bracketed within one fault, in one run, with no recorder involved at all;
* **a deeper buffer.** This recorder is `DEPTH_LOG2` = 10 by choice, not by
  necessity; the part has memory to spare, and 4096 or 8192 samples would let a
  single capture hold a fast page fault's push and its own pop.

Until one of those is done, the right reading of this report is: *the core
demonstrably pushes the correct value on this fault, and a frame for the same
fault is demonstrably read back wrong -- in different runs of a failure that
otherwise reproduces to the byte.*


## What this rules out

* **A core save bug *on the runs measured*.** The core writes the correct
  value in all three. Subject to the caveat above, this is not what your 2030
  cases were failing to reproduce, and the address-error frame
  that follows is faithful in every field -- as you said, the alignment check is
  behaving correctly on a genuine word write formed from a wrong `loop_ir`.
* **A bus master.** Neither capture contains a single DVMA cycle. The 82586 and
  the disk controller are out.
* **Everything except that one word.** 24 other frame words survive the
  interval unchanged, so this is not a frame being relocated, rebuilt from a
  template, truncated, or normalised -- all of which would disturb more.


## Where that leaves the search

`SP+56` is the **highest** address in the frame, immediately below whatever was
on the supervisor stack before the exception. A write that lands one word past
the end of something, or at a "top of frame" computed one word high, hits that
word and no other -- which is your hypothesis (e), and it is now the only one
of your five that fits the shape of the evidence.

Against that, a read of the SunOS 3.4 sources says the kernel never writes it:
`SP+56` is `bei_undef[1]` in `struct bei_long8` (`sun/sys/sun2/buserr.h:47`),
and `bei_undef`, `bei_maskpc` and `bei_irc` are **never referenced anywhere in
the tree** -- not read, not written, not address-taken. The only writes into a
frame in the whole kernel are `beip->bei_rerun` (`SP+8`) and `beip->bei_dib`
(`SP+20`) at `trap.c:277-278`, inside a `simzero` block that is disabled by
default and unreachable once `pagefault()` succeeds at `trap.c:261-262`. On the
resume path `rei` takes the `2$` branch (`locore.s:496-499`),
`moveml sp@,#0x7FFF` -- deliberately excluding `a7` so it cannot touch the
frame -- then `RTE`. In `locore.s` the largest offset ever stored into the
frame is `R_VOR`, frame +6.

So the write is not a named store to that field. It is something indirect: an
off-by-one, a stack pointer briefly one word high, or a buffer whose end lands
there. Your (a) -- log `56(%sp)` at the top of the bus-error handler -- would
bracket it immediately, and is the next thing to do.

`$22C1` remains `MOVE.L D1,(A1)+` at `_copyin+0x36` (`locore.s:838-839`
expanded in `ENTRY(copyin)`), which is a loop the kernel runs constantly and
which would legitimately be *its* looped instruction while it runs.


## Instrument notes

Three additions were needed to get this, all in
`rtl/sun2-common/sun2_trace.v` and unit-tested (`make -C sim trace`, 30 checks):

* an exact-address trigger (`A[10:1]` as well as the page), because every 68010
  exception vector shares one 2 KiB page;
* `TRACE_POST` as a build knob, so a capture can keep the cycles *before* the
  trigger rather than after;
* an `ERR` qualifier, so a trigger can demand a *failing* cycle -- without it
  the address trigger fires on a healthy access from another process and the
  fault is long past by the time the buffer fills.
