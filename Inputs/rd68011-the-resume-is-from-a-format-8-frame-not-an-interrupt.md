# The resume is from a format-$8 frame, and two corrections

Third note on the `openlog`/`strncpy` address error. It answers the two
questions put to this project, and **corrects two statements** made in the
earlier notes -- one of which changes the reproducer recipe, so it is the
important part of this document.

Companions:
`rd68011-byte-move-resumed-by-rte-takes-an-address-error.md` (the failure),
`rd68011-format-8-frame-describes-a-byte-move-as-a-word-write.md` (the frame).

Observed against RD68011 `3f6ca4f`, Sun-2/50 replica on an Arrow DECA, 16.667
MHz, SunOS 4.0.3.


## Correction 1 (important): the RTE pops a full 29-word format-$8 frame

The first note said the exception being returned from was a short format-$0
frame -- an interrupt. **That was wrong.** It came from reading only the last
few supervisor cycles before the fault; the read-back starts much earlier in
the capture.

The full sequence of supervisor accesses ahead of the address error, in the
order they appear:

```
  -957 .. -755   0x3A1E .. 0x3A40    moveml sp@,#0x7FFF   -- registers
  -703 .. -667   0x3A46 .. 0x3A4C    SR, PC, format word
  -614 .. -502   0x3A46 .. 0x3A5E    SR, PC, format, SSW, fault address,
                                     data output buffer, data input buffer,
                                     instruction input buffer
  -460 .. -308   0x3A64 .. 0x3A7E    the 16 internal-information words
```

`0x3A46` to `0x3A7E` is 29 words. The kernel reads the **whole long frame**
back and `RTE`s it. That is SunOS's instruction-resume path exactly as its
source describes it (see Correction 2), and it means the faulting instruction
was **continued from a bus-error frame**, not restarted after an interrupt.

### Why that matters more than it sounds

A boot block in this project (`tools/rteprobe/`) forces every instruction of
the same loop to be re-entered by `RTE`, using the trace bit, and **passes on
RD68011 and on WF68K10 (Suska) alike** -- 1352 trace exceptions taken, 52
copies, no faults. That looked like a negative result for the whole theory.

It is not: a trace exception produces a **format-$0** frame, so those `RTE`s
restore no internal state at all. The failing case needs the 68010's
*continuation* path -- `RTE` of a format-$8 frame, where the processor reloads
its internal state from the frame's 16 information words and resumes the
instruction part-way through.

**So the reproducer recipe in the first note is incomplete.** It is not "resume
the loop by `RTE`". It is:

1. run the byte-move loop (`moveb %a1@+,%a0@+` / `dbeq`, entered at the `dbeq`);
2. make an access inside it take a **bus error**;
3. have the handler make the access succeed (fix the mapping, or use the
   software-rerun bits) and `RTE` the **format-$8** frame unchanged;
4. watch the next iteration.

On the machine, step 2 is an ordinary demand-paging fault: a companion capture
triggered on the kernel's `buserr` handler shows a normal one, `format 8008`
(vector 2), `SSW 0x2102`, `FC 2`, fault address equal to the PC -- an
instruction-fetch page fault in the shared library.


## Correction 2: the kernel does not corrupt the frame

The first note left open whether SunOS mangles the frame between push and pop.
It does not, on this path. From the SunOS 3.4 sun2 sources:

* `sun/sys/sun2/locore.s:497` -- when `trap()` returns `besize == 0` the kernel
  takes the `2$` branch: `moveml sp@,#0x7FFF` (restores everything **except**
  `a7`, so it cannot clobber the frame) then `RTE`. The 58-byte frame is handed
  back untouched. `trap()` returns 0 exactly on the resume paths:
  `pagefault()` success (`trap.c:173,262`), `grow()` success (`trap.c:263-266`),
  and `simzero` (`trap.c:267-282`).
* `sun/sys/sun2/locore.s:487-495` -- the kernel *does* destroy format-$8 frames,
  sliding the register base up by `besize`, copying only SR and PC and
  `clrw`-ing the format word to make a format-$0 frame. But that happens only
  when `besize = sizeof(struct bei_long8)` = 50, i.e. only on paths where the
  instruction is **not** resumed: `u_lofault` fixups, and user faults becoming
  SIGSEGV/SIGBUS.
* `sun/sys/sun2/trap.c:275-282` -- the one in-place mutation of a frame that is
  then resumed sets `bei_rerun = 1` and `bei_dib = 0`. That is Motorola's
  documented software-rerun mechanism on explicitly writable fields, and does
  not touch +26..+56.
* `sun/sys/sun2/machdep.c:789-901` -- signal delivery copies only a
  `sigcontext` (SP, PC, PS). No exception frame ever reaches the user stack.

Two requirements for any 68010 implementation fall out of that reading, and
both are worth checking independently of this bug: the RR/DIB software-rerun
path must work, and the kernel will `RTE` short format-$0 frames whose PC came
out of a format-$8 frame.


## Answer: `0x22C1` is kernel text, and it names the malformed access

`0x22C1` is the opcode `movel %d1,%a1@+`. It occurs 18 times in this kernel;
one is at `_copyin+0x36`, inside `copyin`'s longword loop:

```
    4836:  0e98 1000    movesl %a0@+,%d1     ; read from user space
    483a:  22c1         movel  %d1,%a1@+     ; <-- 0x22C1
    483c:  51c8 fff8    dbf    %d0,0x4836
```

`copyin` is the kernel's user-to-kernel copy, run constantly -- including while
handling a fault.

That opcode describes the *malformed* access in the address-error frame better
than the instruction that was executing:

| frame field | `moveb %a1@+,%a0@+` (executing) | `movel %d1,%a1@+` (`0x22C1`) |
|---|---|---|
| SSW `BY = 0`, not a byte | no -- a byte | **yes -- longword** |
| SSW `RW = 0`, a write | no -- reads through `a1` | **yes -- writes through `a1`** |
| fault address `0xDD8899` = `a1` | source of a byte read | **destination of the write** |

Three fields agree with `0x22C1` and none with the running instruction, while
the frame's instruction input buffer holds `0x57C9` -- the user's `dbeq`. The
frame carries state from two instruction streams at once.

This is offered as a hypothesis, not a conclusion. What the core intends those
internal words to mean is not documented here, and a stale value in a frame
field is not by itself proof that the access was formed from it.


## The push-versus-pop comparison, in full

It can be made after all, from the single `addrerr`-triggered capture: the
`RTE`'s read-back of the *incoming* frame and the core's push of the *outgoing*
one are both inside the same window.

One measurement note, because it changes the numbers: on this bus the debug
data register lags by one transaction for **reads** (it loads on
acknowledgement), so a read's data appears during the *following* bus cycle.
Writes carry the CPU's own data during their own cycle. The read column below
is lag-corrected; the write column is not, and needs no correction. Two
independent checks say the alignment is right in both: the format/vector word
lands at +6 and reads `0x8008` / `0x800C`, the only values those exceptions can
produce, and the PC at +2/+4 reads `0x00D7BE04`, which four independent core
dumps give.

| off | field | **POP** -- handed back by the kernel's `RTE` | **PUSH** -- built by the core after the fault |
|---|---|---|---|
| +0  | SR | `0000` | `0000` |
| +2  | PC hi | `00D7` | `00D7` |
| +4  | PC lo | `BE04` | `BE04` |
| +6  | format / vector | `8008` -- **vector 2, bus error** | `800C` -- **vector 3, address error** |
| +8  | SSW | `1301` | `0001` |
| +10 | fault addr hi | `00DD` | `00DD` |
| +12 | fault addr lo | `8898` -- **even** | `8899` -- **odd** |
| +16 | data output buffer | `BDF0` | `000C` |
| +20 | data input buffer | `BDF0` | `2F2F` |
| +24 | instruction input buffer | `57C9` -- `dbeq` | `57C9` -- `dbeq` |
| +26 | internal | `2E00` | `2E00` |
| +28 | internal | `004D` | `034A` |
| +30 | internal | **`10D9` -- `moveb %a1@+,%a0@+`** | **`22C1` -- `movel %d1,%a1@+`** |
| +32 | internal | `0000` | `0000` |
| +34 | internal | `00D7` | `0000` |
| +36 | internal | `00FF` | `0002` |
| +38 | internal | `FCE4` | `0FE6` |
| +40 | internal | `00D7` | `00D7` |
| +42 | internal | `BE00` | `BE00` |
| +44 | internal | `00D7` | `00D7` |
| +46 | internal | `BE02` | `BE02` |
| +48 | internal | `00D7` | `00D7` |
| +50 | internal | `BE00` | `BE00` |
| +52 | internal | `0000` | `0000` |
| +54 | internal | `000E` | `002F` |
| +56 | internal | `22C1` | `22C1` |

26 of the 29 words are recovered in each; the three missing are the frame's
reserved words at +14, +18 and +22.

### What the comparison says

* **`SP+56` is `22C1` in both -- unchanged.** So the answer to the question as
  put is *no*: nothing between the push and the pop altered that word. That
  agrees with the source reading in Correction 2.
* **`SP+30` differs between the two frames, but that is not by itself a
  mutation, and an earlier draft of this note over-claimed it.** The incoming
  frame carries `10D9` there -- the opcode of `moveb %a1@+,%a0@+`, the
  instruction executing -- and the outgoing one carries `22C1`,
  `movel %d1,%a1@+` from `copyin`. These are **two different exception frames
  describing two different faults**, written to the same stack address one after
  the other; the second push simply overwrote the first. Nothing here shows a
  word being altered in place, and the internal-information words are opaque
  state whose content this project cannot predict.

  What remains odd, and is the reason the word is worth reporting at all, is
  that the **outgoing** frame carries `copyin`'s instruction word while its own
  PC is `0x00D7BE04`, in libc's `strncpy`. A frame holding `22C1` would be the
  expected content for a fault taken *in* `copyin`; this fault was not. So the
  outgoing frame appears to carry state from an instruction stream other than
  the one it names. That is an observation, not a mechanism.
* **The fault addresses fit the story exactly.** The incoming bus error is at
  `0xDD8898`, **even** -- the legitimate demand-paging fault on the first byte
  the loop reads. The outgoing address error is at `0xDD8899`, **odd** -- one
  byte further on, the second iteration. Between them the bus shows that first
  byte being read and written correctly.
* **The other differing words** (+8, +16, +20, +28, +34, +36, +38, +54) are the
  two exceptions' own state and are not comparable; they are listed for
  completeness rather than as evidence.

So the kernel is exonerated twice over. By measurement: `SP+56` is identical
across the two frames. And by source, specifically for the word that differs --
`SP+30` is `bei_undef[1]`, and `bei_undef`, `bei_maskpc` and `bei_irc` are
**never referenced anywhere in the SunOS 3.4 tree**: not read, not written, not
address-taken. The only writes into a frame in the whole kernel are
`beip->bei_rerun` (SP+8) and `beip->bei_dib` (SP+20) at `trap.c:277-278`, both
inside the `simzero` block, which is disabled by default (`trap.c:78`) and in
any case unreachable once `pagefault()` succeeds at `trap.c:261-262`. In
`locore.s` the largest offset ever stored into the frame is `R_VOR`, frame +6.
On the demand-paging resume path the kernel writes nothing into the frame at
all.

Whatever produces the malformed access is therefore on the core's side of the
`RTE`. That is a statement about where to look, not about what is wrong: the
bus evidence -- one byte transferred correctly, then a fault with no cycle for
the second -- is what stands on its own.


## Why a same-fault comparison looked impossible at first

Capturing a page fault's push and *its own* pop needs both to fall inside one
1024-sample window -- about 61 microseconds at 16.667 MHz -- and the kernel's
page-fault handling takes far longer. A separate `buserr`-triggered capture
does show an ordinary page fault's push (`format 8008`, `SSW 0x2102`, `FC 2`,
fault address equal to the PC: an instruction-fetch fault in the shared
library), but it is a different fault instance.

That turned out not to matter, because the pop of the incoming frame and the
push of the outgoing one are both in the `addrerr` window, which is the
comparison that answers the question.


## Status

The failure is characterised; the mechanism is not isolated in the RTL and no
change is proposed. The most useful thing in this note is the corrected
reproducer condition: **`RTE` of a format-$8 frame**, not an `RTE` in general.
