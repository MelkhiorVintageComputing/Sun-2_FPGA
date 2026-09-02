# The $8 frame describes a byte move as a word write, and the address-error
# check then fires on it

Companion to `rd68011-byte-move-resumed-by-rte-takes-an-address-error.md`,
which reports the failure and its trigger. This one is about the **exception
frame the core builds**, captured word by word off the bus, because it names
the malformed access directly.

Observed against RD68011 `3f6ca4f` (`LOOP_BUF_WORDS=16`) in a Sun-2/50 (VME)
replica on an Arrow DECA (MAX 10) at 16.667 MHz, running SunOS 4.0.3.


## Summary

`moveb %a1@+,%a0@+` faults with an address error. The format $8 frame the core
pushes says the faulted access was a **word**, and a **write**, at the address
of the instruction's **source** operand:

    special status word   0x0001     BY = 0 (not a byte), RW = 0 (write), FC = 1
    fault address         0xDD8899   a1 -- the source, which this instruction reads

For `moveb (a1)+,(a0)+` the access at `a1` is a **byte read**. A byte access
has no alignment requirement, so it cannot raise an address error. A *word*
access at `0xDD8899` can, and does -- which is consistent with the core having
formed a word-sized access internally and its own alignment check then firing
on it, correctly, against an access that should never have existed.

The instruction had just been resumed by `RTE`; see the companion report for
the trigger and for why a straight-line run of the same loop is correct.


## How the frame was captured

A 1024-sample recorder on the CPU bus (`rtl/sun2-common/sun2_trace.v` in this
project), triggered on the *kernel's* address-error handler -- `addrerr`,
`0x410E`, read out of the kernel's own `protoscb+0xC` -- with 960 samples of
pre-trigger history. The 68010 pushes the frame high address first, so the
whole of it is in the window ahead of the trigger:

    writes descend  0x3A7E -> 0x3A46   = 29 words = 58 bytes = a format $8 frame
    then            0x00000C, 0x00000E read   = the vector 3 fetch
    then            0x00410E fetched           = addrerr entered

26 of the 29 words carried data on the bus and are reproduced below; the three
missing are the frame's reserved words at +14, +18 and +22.


## The frame, as the core wrote it

Low address first. `SP` after the push is `0x3A46`.

| offset | field | value |
|---|---|---|
| +0  | SR | `0000` |
| +2  | PC (high) | `00D7` |
| +4  | PC (low) | `BE04` |
| +6  | format / vector offset | `800C` |
| +8  | **special status word** | **`0001`** |
| +10 | **fault address (high)** | **`00DD`** |
| +12 | **fault address (low)** | **`8899`** |
| +16 | data output buffer | `000C` |
| +20 | data input buffer | `2F2F` |
| +24 | instruction input buffer | `57C9` |
| +26 | internal | `2E00` |
| +28 | internal | `034A` |
| +30 | internal | `22C1` |
| +32 | internal | `0000` |
| +34 | internal | `0000` |
| +36 | internal | `0002` |
| +38 | internal | `0FE6` |
| +40 | internal | `00D7` |
| +42 | internal | `BE00` |
| +44 | internal | `00D7` |
| +46 | internal | `BE02` |
| +48 | internal | `00D7` |
| +50 | internal | `BE00` |
| +52 | internal | `0000` |
| +54 | internal | `002F` |
| +56 | internal | `22C1` |

What the fields say, and why each is worth reading:

* **`800C`** -- format 8, vector offset `0x0C`: vector 3, address error. Not a
  bus error; `BERR` is never asserted anywhere in the 1024-sample capture.
* **`0001` (SSW)** -- with the 68010's layout (`RR IF DF RM HB BY RW`, then the
  function code in bits 2..0): `BY = 0` so **not a byte transfer**, `RW = 0` so
  **a write**, `FC = 1` so user data. Every one of those three is wrong for the
  access this instruction makes at `a1`, which is a byte *read*.
* **`00DD8899` (fault address)** -- `a1` after its post-increment, i.e. the
  source pointer for the iteration that faulted. Odd, which is why a
  word-sized access there raises vector 3.
* **`2F2F` (data input buffer)** -- `0x2F` on both halves: the byte
  successfully read on the *previous* iteration, duplicated as a byte read
  is on this bus. The bus capture shows that read completing normally at
  `0xDD8898` with UDS asserted alone.
* **`57C9` (instruction input buffer)** -- the opcode of `dbeq %d1,...`, the
  second instruction of the loop, consistent with `PC = 0xD7BE04` pointing at
  its extension word.
* **`0002` / `0FE6` at +36/+38** -- the destination pointer `0x00020FE6`, and
  `00D7 BE00`, `00D7 BE02`, `00D7 BE00` at +40..+50 are the loop's own
  addresses. So both operands and both instruction addresses are in the frame.


## `0x22C1` is kernel text, and it names the malformed access

Upstream asked whether `0x22C1` -- the value at +30 and +56 -- is recognisable.
It is. It is the opcode `movel %d1,%a1@+`, and it occurs 18 times in this
kernel; one of them is at `_copyin+0x36`:

```
    4836:  0e98 1000    movesl %a0@+,%d1     ; read from user space
    483a:  22c1         movel  %d1,%a1@+     ; <-- 0x22C1
    483c:  51c8 fff8    dbf    %d0,0x4836
```

`copyin` is the kernel's user-to-kernel copy, run constantly, including on the
path that handles a fault.

That opcode describes the *malformed* access in this frame far better than the
instruction that was actually executing does:

| frame field | `moveb %a1@+,%a0@+` (executing) | `movel %d1,%a1@+` (`0x22C1`) |
|---|---|---|
| `BY = 0`, not a byte | no -- a byte | **yes -- longword** |
| `RW = 0`, a write | no -- reads through `a1` | **yes -- writes through `a1`** |
| fault address = `a1` = `0xDD8899` | source of a byte read | **destination of the write** |

Three fields agree with the stale opcode and disagree with the running one.
Note also that the frame's *instruction input buffer* holds `0x57C9`, the
user's `dbeq` -- so the frame carries state from two different instruction
streams at once.

That is consistent with the resumed instruction being described by internal
state left over from an earlier kernel loop rather than by itself, which is the
kind of state an `RTE` resume path would have to reset and evidently does not.
It is a hypothesis, not a conclusion: what the core intends those internal
words to mean is not documented here, and a stale *value* in a frame field is
not by itself proof that the access was formed from it.

## Why the decode can be trusted

`dbg_data` on this bus lags by one memory transaction, so attributing data to
addresses needs care. Two independent checks say the attribution above is not
shifted: the format/vector word lands exactly at +6 and reads `0x800C`, which
is the only value it can legally take for this exception; and the PC at +2/+4
reads `0x00D7BE04`, which four independent core dumps give for the same fault.
A one-word shift would put `BE04` in the format word and `800C` in the PC.


## Why this is the useful half of the report

The failure could be described from core files alone -- three programs, one PC,
identical registers. What the frame adds is the core's own account of *what
access it thought it was making*, and that account is malformed in three
independent ways at once (size, direction, and an address the instruction only
ever reads). That is a stronger statement than "an address error happened
where it should not", and it points at where the access is formed rather than
at the alignment check, which appears to be behaving correctly on the operand
it was handed.

It also explains the shape of the failure downstream. SunOS reads this frame:
`sys/sun2/trap.c` reaches `SIGBUS` only from `T_ADDRERR`, so the process dies
with `SIGBUS` and the faulted address never reaches the core file -- `u.u_code`
is not set on that path. Only `PC` and the user stack pointer survive into the
dump, which is why four core files could not say what this one capture does.


## Caveats

* **One capture.** The frame above is a single trace. The register values in it
  agree exactly with four independent core dumps (`PC`, and the operand
  registers), but the SSW and fault address have been read once.
* **SSW bit assignment.** The decode above uses the MC68010 user manual's
  layout. If the core intends a different encoding the conclusion about `BY`
  and `RW` would need revisiting -- though the fault address alone, naming the
  source operand of a byte read, is enough to show the access is malformed.
* **Not isolated in the RTL**, and no change is proposed here.
