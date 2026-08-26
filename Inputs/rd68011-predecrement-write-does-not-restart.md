# A faulted `movel Dn,-(An)` does not resume; `(An)+` and `(abs)` do

Files implicated: not isolated. The evidence is behavioural and this report
deliberately stops where the evidence stops — but it comes with a minimal test
case that reproduces it in four lines of assembler, and with two controls that
pass on the same hardware, in the same boot, through the same handler.

Observed against RD68011 as of `8e8a1b4`, in a Sun-2/120 (MultiBus) replica on
a Xilinx Artix-7 (QMTech Wukong V1), at 20 MHz, with real DDR3 behind the
memory path.

**Fixed in `252f0d7`, and the report under-called its scope.** The cause was
not the predecrement addressing mode as such: it was `ea_latch`, the latch that
addressing modes which prefetch before they access use to carry their address
once `ir` has moved on. The frame has a word for that latch, and the frame
build destroyed it before writing it -- every frame write is an `aupd` on the
stack pointer, and an `aupd` is exactly what loads the latch -- so the word
recorded a stack address ten writes later, and `RTE` repeated the mistake in
reverse. The resumed access therefore went wherever the frame walk had reached.

So the affected set is every access that addresses through `ea_latch`: `MOVE`
to `-(An)` in all its forms, every read-modify-write on `(An)`, `(An)+` and
`-(An)`, the `-(Ay),-(Ax)` multiprecision group, and **the return-address
pushes of `JSR`, `BSR`, `PEA` and `LINK`** -- 257 microcode labels. The two
controls this report offered are still correct, and `MOVE.L -(A0),D1` --
predecrement as a *source* -- resumes, which is why "the predecrement itself"
was the wrong variable to name.

The existing upstream test passed throughout because its slave model has no
bus-error input, so a faulted write landed anyway and the memory halves were
right whether or not the write was ever reissued; the cycle-count check the
rest of the file uses for continuation was missing there.

Confirmed in the Sun-2 project by `tools/ctxprobe` case E (`E: -(An) restarted
correctly`, with controls C, F, G and H still passing) and, decisively, on
hardware: SunOS 4.0.3 on a Wukong V1 now forks and execs normally, where every
child the shell forked previously died with `Memory fault - core dumped`.


## Summary

A bus error taken on the operand write of

    movel  %d1,%a0@-            | 0x2101, predecrement

is not resumed. The handler runs, clears the condition that caused the fault,
and executes `rte` from the 29-word format-8 frame — and the CPU continues
somewhere unrelated, with registers that do not belong to the interrupted
instruction.

Two controls, differing from it in exactly one thing each, both resume
correctly on the same board in the same boot:

| case | instruction | addressing | privilege | result |
|---|---|---|---|---|
| C | `movel #imm,(abs)` | absolute | user | **resumes** |
| G | `movel #imm,(abs)` | absolute | supervisor | **resumes** |
| F | `movel %a0@+,%d1` | postincrement | supervisor | **resumes** |
| E | `movel %d1,%a0@-` | **predecrement** | supervisor | **does not** |

G holds the instruction fixed against C and changes only the privilege; F holds
the privilege fixed against E and changes only the direction of the address
register update. So neither privilege nor "uses an address register" is the
variable. What is left is the predecrement itself.


## What is seen

Four runs, all with the same failure and three of them byte-identical. The
probe prints the scratch page's map entry, enters the faulting instruction, and
never returns from it:

      E  movel Dn,-(An) whose write faults, then is restarted
         scratch page 100800 entry fe000181
      Address Error, addr: 0010045F at EF443A

`0xEF443A` is inside the boot PROM, in code the probe never calls:

      ef4430:  moveal %fp@(8),%a5
      ef4434:  moveal %a5@(1114),%a0     | longword read -> address error if a5 is odd
      ef4438:  bset   #5,%a0@(2112)      | PC 0xEF443A is inside this
      ef443e:  moveal %a5@(1114),%a0
      ef4442:  bclr   #5,%a0@(2112)

`0x0010045F` is odd, which is why it surfaces as an address error rather than
silently. So the CPU is executing a stale PROM address — the last thing that
ran before the probe was loaded — with a garbage `a5`. That is what resuming at
the wrong place looks like, not what a wrongly-restarted store looks like.

Run four, with the two controls executed first (which leaves the machine in a
different state), fails differently — `No controller at mbio 6202F`, another
PROM message — which is consistent with "resumes somewhere arbitrary" and not
with a deterministic wrong address.

The controls in that same boot, immediately before it:

      G  movel #imm,(abs) in SUPERVISOR mode
         faults 01   memory 600dcafe  (want 600dcafe)
         G: supervisor-mode restart of (abs) is CORRECT

      F  movel (An)+,Dn whose read faults, then is restarted
         faults 01   An after 00100814  (want 00100814)
         value read 5eed1234  (want 5eed1234)
         F: (An)+ restarted correctly

Note what F establishes: after the fault and the `rte`, `An` holds the
correctly *incremented* value and the operand is the right one. The address
register is restored and re-applied properly in that direction.


## Reproduction

The probe is `tools/ctxprobe/` in the Sun-2_FPGA tree; cases E, F and G are the
relevant ones. The mechanism needs nothing from the Sun-2: any memory that can
be made to bus-error and then made not to will do.

The faulting instruction, written out so the addressing mode survives
optimisation:

    sup_predec:                          | u32 sup_predec(u32 addr, u32 val)
            movel  %sp,saved_sp
            movel  #1f,saved_pc
            movel  %sp@(4),%a0
            movel  %sp@(8),%d1
            movel  %d1,%a0@-             | <- faults, then should resume
            movel  %a0,%d0               | An afterwards, for the caller
            rts
    1:      moveq  #-1,%d0               | reached only if the handler gives up
            rts

and the control that passes, identical except for the direction:

    sup_postinc:                         | u32 sup_postinc(u32 addr, u32 *out)
            movel  %sp,saved_sp
            movel  #1f,saved_pc
            movel  %sp@(4),%a0
            movel  %a0@+,%d1             | <- faults, then resumes correctly
            movel  %sp@(8),%a1
            movel  %d1,%a1@
            movel  %a0,%d0
            rts
    1:      moveq  #-1,%d0
            rts

Around each: point the address register at a page whose mapping denies the
access, install a bus error handler that grants access and returns with `rte`,
and check afterwards that `An` is right and the operand moved. The handler is
capped at one fixup, so a retry that never converges gives up rather than
looping; E does not reach that path, it leaves before the handler can report.

Both are entered in supervisor mode on purpose, so the exception frame lands on
the ordinary supervisor stack and nothing about user mode, the user stack
pointer or a privilege change is involved.


## What has been ruled out

* **The harness.** G and F use the same handler, the same page, the same deny
  and grant sequence, the same privilege and the same boot. Only the opcode
  differs.
* **Interrupts.** Masking to level 7 for the duration changes nothing; the
  failure is byte-identical.
* **The fixup depth.** Capping the handler at 8 fixups and at 1 gives the same
  failure, so it is not frames accumulating on the stack.
* **The memory system.** Every other faulting access in the same probe — user
  instruction fetch, user data write, supervisor data write to an absolute
  address, supervisor postincrement read — faults where it should, reports
  correctly, and resumes.


## Where to look

Not isolated, and worth saying why: from outside, "the `rte` resumed in the
wrong place" and "the instruction resumed but wrote to the wrong address" are
distinguishable only if the instruction gets far enough to leave a trace, and
this one does not.

The 68010 handles a bus error by *continuation* rather than restart: the
format-8 frame carries internal state and the `rte` resumes the faulted bus
cycle from it, rather than re-executing the instruction from the beginning. For
`-(An)` the register has already been decremented when the write is attempted,
so the frame has to carry both the decremented register and enough state to
re-issue only the write. That asymmetry with `(An)+` — where the increment can
be deferred past the operand access — is the obvious place to start, but it is a
hypothesis and not something this report has evidence for.


## Why it matters here

Less than the longword-across-a-bus-grant bug did, and honestly: nothing in the
path this project was chasing when it found this uses a predecrement across a
fault. It was found by a probe written to exonerate `rts` — which it did, via
case F — and E was the case next door.

It is nevertheless a real recovery failure in a core that a demand-paged
operating system will drive into faults on ordinary instructions. `movel
Dn,-(An)` is how a compiler pushes an argument; a stack that has to be faulted
in underneath one is not an exotic situation.
