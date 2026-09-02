# A byte move resumed by RTE takes a spurious address error

Files implicated: **not isolated**, but the mechanism is. See **What the bus
shows**, which is a cycle-level capture of the fault rather than an inference
from a core file.

Observed against RD68011 `3f6ca4f` (branch `loop-buffer`, `LOOP_BUF_WORDS=16`)
and against the same core with the loop buffer disabled, in a Sun-2/50 (VME)
replica on an Arrow DECA (MAX 10) at 16.667 MHz, running SunOS 4.0.3.


> **Corrected by
> `rd68011-the-resume-is-from-a-format-8-frame-not-an-interrupt.md`.** This
> note says the exception returned from was an interrupt (a short format-$0
> frame). It was not: the kernel reads back a full 29-word **format-$8** frame
> and `RTE`s it, so the instruction is *continued* from a bus-error frame
> rather than restarted after an interrupt. The reproducer recipe below is
> incomplete for the same reason -- a plain `RTE` does not reproduce it, and a
> boot block that forces one passes on both cores.

## Summary

`moveb %a1@+,%a0@+` — a **byte** move, which has no alignment requirement on a
68010 — raises an **address error** (vector 3) when it is re-entered by `RTE`
after an exception, with both operands at odd addresses.

The processor does not attempt the access. No bus cycle is issued for it at
all; the core decides internally to fault. Byte accesses have no alignment
rule, so this is wrong however the instruction was reached.

It kills every program that calls `openlog()`: `inetd`, `in.telnetd` and `lpd`
all die with `SIGBUS` at the same instruction, because on SunOS/sun2 `SIGBUS`
comes only from `T_ADDRERR` (`sys/sun2/trap.c`, `case T_ADDRERR + USER` ->
`SIGBUS`; `T_BUSERR + USER` gives `SIGSEGV`).


## The instruction

`libc.so.0.12`'s `strncpy`, at library offset `0x5df0`, mapped at `0xd76000`:

```
    5df0:  206f 0004      moveal %sp@(4),%a0     ; dest
    5df4:  226f 0008      moveal %sp@(8),%a1     ; src
    5df8:  222f 000c      movel  %sp@(12),%d1    ; n
    5dfc:  2008           movel  %a0,%d0
    5dfe:  6002           bras   0x5e02          ; enter at the dbeq
    5e00:  10d9           moveb  %a1@+,%a0@+     ; <-- faults
    5e02:  57c9 fffc      dbeq   %d1,0x5e00
```

Reached from `openlog("inetd", LOG_PID|LOG_NOWAIT, LOG_DAEMON)`, called as the
first thing `inetd`'s `main()` does.


## What the bus shows

Captured on the machine with a 1024-sample recorder on the CPU bus, triggered
on entry to the kernel's address-error handler (`addrerr`, `0x410e`, found from
the kernel's own `protoscb+0xC`) with 960 samples of *pre-trigger* history.
Columns are the sample's offset from the trigger, the address, the function
code, read/write, the data strobes, and the data.

```
   -340..-297   A=003A78..3A7E  FC=5  READ   00D7 BE00 ...   \  rei+0x96, then
                A=0044F0..44F4  FC=6  fetch                  /  RTE: PC:=D7BE00

   -294         A=DD8898        FC=1  READ   UDS only  -> 2F    byte 1, source
   -281         A=020FE6        FC=1  WRITE  UDS only  -> 2F    byte 1, dest

                *** no cycle at DD8899.  No cycle at 020FE7. ***

   -264..-46    A=003A7E..3A46  FC=5  WRITE                     frame push
   -62          A=003A4C        FC=5  WRITE  800C               format 8,
                                                                vector offset
                                                                0x0C = vector 3
                                                                ADDRESS ERROR
   -45..-27     A=003A48/3A4A   FC=5  WRITE  00D7 / BE04        PC = 0x00D7BE04
   -26          A=00000C        FC=5  READ                      vector 3 fetch
   -14          A=00000E        FC=5  READ   -> 410E
    -1          A=00410E        FC=6  fetch                     addrerr entered
```

Read that in order:

1. The kernel is in `rei`, its return-from-exception path, and executes an
   `RTE` that restores `PC = 0xD7BE00` -- the `moveb` at the top of the loop.
2. User code resumes and performs **one** iteration correctly: an even-byte
   read at `0xDD8898` (UDS asserted alone) and an even-byte write at
   `0x020FE6`.
3. The next iteration would read `0xDD8899` and write `0x020FE7`, both odd.
   **Neither appears on the bus.** The processor issues no cycle.
4. Instead it pushes a 68010 long (format 8) exception frame whose format word
   is `0x800C` -- vector offset `0x0C`, vector 3, address error -- with
   `PC = 0x00D7BE04`, fetches the vector from `0x0C`, and enters `addrerr`.

`BERR` is never asserted anywhere in the 1024-sample capture. This is not a bus
error being misreported: it is the core raising an address error by itself.


## Input conditions

```
    strncpy(dest = 0x020FE6, src = 0xDD8898, n = 12)

    both operands even on entry; both odd for the second iteration
    d1 = 12 in the exception frame -- the dbeq has not decremented
    the instruction is entered by RTE, not by falling into the loop
```

`a5 = 0xdd605c` (libc's data base) and `a1 = 0xdd8899` are identical in every
core file taken: two from `inetd` (NFS root and local SCSI root, with the loop
buffer) and one from `in.telnetd` (SCSI root, **without** the loop buffer).
`lpd` has been dying the same way for months; two of its cores taken hours
apart are identical in 2,128,580 bytes of 2,132,118.


## Why "odd byte operands" alone is not the trigger

A freestanding boot block sweeps the identical loop over all four entry
alignments of (dest, src) and every length 1..16 -- 64 cases, including the
exact `n = 12` -- and **passes on RD68011 and on WF68K10 (Suska) alike**, with
controls proving the handler works (a *word* read at an odd address does raise
vector 3; a byte read at an odd address does not). `tools/strprobe/` in this
project, 1962 bytes, no kernel and no libc.

That result is not a contradiction, it is the discriminator: **the probe masks
interrupts to level 7** (`movew #0x2700,%sr`), so its loop is never interrupted
and never resumed. The failing case needs the loop to be *re-entered by `RTE`*.

It is also why ordinary software does not fall over. `strncpy` from an even
source to an even destination is the commonest string copy there is, and this
machine boots SunOS multi-user, runs `sh`, `awk` and `fsck`, and compiles C.
The fault needs an exception to land inside the two-instruction loop and the
resumed iteration to have odd operands.


## Not the loop buffer, and not the machine

* **Both loop-buffer settings.** `inetd` dies with `LOOP_BUF_WORDS=16`;
  `in.telnetd` dies with the loop buffer disabled, at the same PC with the same
  registers.
* **Both root filesystems**, NFS and a local SCSI disk.
* **Both regions of the storage medium** -- one region of the micro-SD card was
  genuinely failing and was replaced by moving the disk 512 MiB along the card;
  the crash is unchanged on the healthy region with a freshly written,
  `fsck`-clean filesystem.
* **The binaries are intact**, checksummed against the pristine image.
* **`ld.so` binding is correct**: the PLT stub for `openlog` in the core's data
  segment holds `jmp 0xd8496c`, which is `_openlog`.


## Building a core-only reproducer

No Sun-2 and no MMU needed. The shape is:

```
        moveal  #dest,%a0        ; even, writable
        moveal  #src,%a1         ; even, readable
        movel   #12,%d1
        bras    2f               ; enter at the dbeq, as libc does
    1:  moveb   %a1@+,%a0@+
    2:  dbeq    %d1,1b
```

with **an exception taken during the loop and returned from by `RTE`**. An
interrupt is the easiest: assert an autovectored IRQ so it is recognised
between the first and second iterations, let the handler `RTE`, and check
whether the second iteration issues a byte cycle at the odd addresses or raises
vector 3 instead.

Vector 2 and vector 3 should point at distinguishable handlers. The failing
signature is: one byte transferred, then a format-8 frame with vector offset
`0x0C`, and **no bus cycle for the second byte**.

Worth varying, since which of these matters is not established here:

* where in the loop the exception lands (before the `moveb`, between it and the
  `dbeq`, or during the `dbeq`);
* the operand alignment on resume -- the failing case has both odd;
* `LOOP_BUF_WORDS` 0 and 16, which changes the victim but not the fault.


## Status

Open. The mechanism is captured at the bus and the observation reproduces to
the register across three programs, two root filesystems, two storage regions
and both loop-buffer settings. What has not been done here is isolating it in
the RTL, and one caveat is owed: the bus capture above is a **single** trace,
so a repeat would be worth having before anyone edits the core on the strength
of it.

This is the fourth instruction-restart defect this project has reported against
RD68011 (`ea_latch` destroying a frame word, the predecrement write that does
not restart, and the longword read across a bus grant), and it belongs to the
same family: an access that is correct when executed once and wrong when
resumed.
