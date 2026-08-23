# The first word of an exception frame goes on the user stack

*Found in RD68011 at `a44b71a`, running as the CPU of a Sun-2 replica
(MC68010, Sun-2 MMU) on a Xilinx Artix-7.  Diagnosed on hardware with an ILA
and reproduced in simulation with a freestanding boot program; both are
described below so the report can be checked without either.*

## Summary

When an exception is taken **from user mode**, the first word of the stack
frame is written at **USP-2** instead of **SSP-2**.  The remaining words of the
frame are written correctly on the supervisor stack.  The user stack pointer is
not modified, so nothing in the register file shows it afterwards -- only the
memory under the user stack does.

The misdirected write carries the **supervisor** function code (FC 5) while
using the **user** stack pointer's address, which is the fingerprint of the
cause: the function code for a bus cycle is derived from the *next* status
register while the A7 bank is chosen by the *current* one.

## Why it matters

On any system where the page under the user stack pointer is not writable, the
stray write faults *inside exception processing*.  That is a double bus fault:
the CPU halts.

This is not a corner case on a real operating system.  A process that has just
been `exec`ed has its user stack pointer just below the top of the stack
region, and on a demand-paged system that page is frequently not yet present.
The first exception such a process takes is then fatal.

Concretely: SunOS 4.0.3 dies here creating process 1, every time, at the first
instruction of `/sbin/init`.  The kernel deliberately runs a process that has
no MMU context yet in the kernel's context so that its first access faults and
the handler can allocate one (`sys/sun2/vax.s`); that intended fault is the
exception whose frame goes astray.  The machine halts, the watchdog resets it,
and the console shows nothing but `Watchdog reset!`.

## Mechanism, in the source

`rtl/rd68011_seq.sv`:

* line 474 -- A7 is whichever stack pointer the *registered* S bit selects:

  ```systemverilog
  `define RDREG(i) (((i) == 4'd15) ? (sr[rd68011_pkg::SR_S] ? ssp : usp) ...
  ```

* lines 1882 and 1893 -- writes back to A7, from the ALU port and from the
  address-update port, select the same way, on `sr`.

* lines 1486 and 1494 -- the function code of the bus cycle the microword
  issues is derived from `sr_nxt`, deliberately:

  ```systemverilog
  U_FC_DATA: req_fc = sr_nxt[rd68011_pkg::SR_S] ? FC_SUPER_D : FC_USER_D;
  ```

  with the comment that the bus unit latches the function code on the edge that
  ends the previous cycle, "MOVE to SR is where it shows".

* lines 1198-1201 -- exception entry sets the S bit into `sr_nxt`:

  ```systemverilog
  if (f_dst == rd68011_ucode_pkg::U_DST_SR_EXC) begin
    sr_nxt[rd68011_pkg::SR_S] = 1'b1;
    sr_nxt[rd68011_pkg::SR_T] = 1'b0;
  end
  ```

So on the microword that enters exception processing, `sr_nxt[S]` is already 1
and `sr[S]` is still 0.  Any bus cycle that microword issues is emitted with
the supervisor function code but addressed through the *user* A7.  The first
frame push is exactly such a cycle.  From the following microword `sr[S]` is 1
and everything agrees, which is why only one word is affected.

## What was observed

A user-mode bus error, traced cycle by cycle on the bus (`FC`, `R/W` and
address of every access):

```
A=100000 FC=1 RW=0      the faulting user data write
A=02fffe FC=5 RW=0      first frame word -- USP-2, supervisor FC, user address
A=000fe0 FC=5 RW=0      the rest of the frame, correctly on the SSP
A=000fde FC=5 RW=0
A=000fdc FC=5 RW=0
   ... down to 000faa
```

The stack pointers around it:

```
USP  = 0x00030000   before and after -- never modified
SSP  = 0x00000fe4   before
SSP  = 0x00000faa   after   (fell 0x3a = 58 bytes = 29 words, a format 8 frame)
```

29 words is a complete 68010 long bus-error frame.  28 of them are on the
supervisor stack (`0xfe0` down to `0xfaa`); the 29th, which belongs at `0xfe2`,
went to `0x2fffe`.

A word painted at USP-2 beforehand comes back overwritten:

```
the word under the user stack was a5a5a5a5, now a5a5b018
```

## Reproducing it

A freestanding 68010 program, in supervisor mode with a flat map:

1. Put the two stack pointers far apart -- `USP = 0x00030000`, the supervisor
   stack wherever the monitor left it.
2. Paint the word at `USP-2`.
3. Install a bus error handler.
4. `RTE` to user mode with a frame of `{SR=0x0000, PC=user_code, format 0}`.
5. In user mode, access an address that faults.
6. In the handler, record `%sp` and `%usp`, and read the paint back.

The paint has changed; neither stack pointer shows anything wrong.  **Comparing
the stack pointers alone is not sufficient to detect this** -- the first version
of this test did exactly that and declared the core correct.

The same program taking a `TRAP #0` from user mode instead of a bus error is
worth running as a control.

## Suggested fix

The A7 bank selection needs to follow the S bit on the same microword that sets
it, as the function code already does -- i.e. select on `sr_nxt[SR_S]` rather
than `sr[SR_S]` for the read path at line 474 and for the two writeback paths
at 1882 and 1893.

Two things to weigh, which is why this reports the defect rather than offering
a patch:

* `RDREG` is the general register read, so moving it to `sr_nxt` affects every
  microword that both changes S and reads A7.  `RTE` and `MOVE to SR` also
  write S (the comment at line 1180 says as much), and for those the intended
  A7 for the *same* microword may well be the old one.  A change confined to
  the exception-entry destination (`U_DST_SR_EXC`, `U_DST_SR_IRQ`) would be
  narrower.
* Alternatively the microcode could set S one microword before the first push,
  leaving the RTL alone.

The choice belongs to whoever knows the microcode's intent.

## Scope

* Affects every exception taken from user mode: bus error, address error,
  trap, interrupt.  Only the first frame word is misplaced, so it is invisible
  wherever the user stack happens to be writable -- which is why a machine can
  run a long time before meeting it.
* Was not visible in this project until an operating system ran user code:
  a monitor and boot programs stay in supervisor mode, where both A7 selections
  are the same register.
* Independent of the frame format: a four-word trap frame and a 29-word
  format 8 frame are affected alike.

## For comparison

The same test on the other 68010 core this project can build (Suska, from
`Inputs/Suska_Configware`) stacks the user-mode `TRAP` frame correctly, and
does not complete the user-mode bus error case at all -- the run reaches the
faulting access and never returns.  That is a separate defect in a different
core and is noted here only so the numbers above are not read as a comparison
between the two.
