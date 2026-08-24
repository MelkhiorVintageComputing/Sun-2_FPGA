WF68K10: the special status word does not describe the faulted bus cycle
=======================================================================

Files touched: wf68k10_bus_interface.vhd, wf68k10_control.vhd
Tested with: ghdl (--std=08 -fsynopsys -fexplicit -frelaxed), WF68K10_TOP as of
VERSION x"20210815", NO_PIPELINE=false, NO_LOOP=false, NO_INDEXSCALING=true.


Symptom
-------

Fault a word write to supervisor data space -- MOVE.W #imm,(An) with FC=5,
terminated by BERRn with DTACKn never asserted -- and read the special status
word at 8(SP) in the format $8 frame the bus error handler is entered with.

  WF68K10 pushes  0x2306 : IF=1, BY=1, RW=1, FC=6
  MC68010 pushes  0x0005 : IF=0, DF=0, RM=0, HB=0, BY=0, RW=0, FC=5

That is, the frame describes a byte-sized instruction fetch, a read, in
supervisor *program* space, where the cycle that faulted was a word write in
supervisor *data* space. Every field except the reserved ones is wrong. The
fault address (10(SP)) and the format/vector word (6(SP)) are correct, so a
test that checks only those passes.

Separately, a bus error on an instruction prefetch is never reported at all:
JMP to an address that returns BERR leaves the core prefetching forward
(0x800000, 0x800002, 0x800004, ...) indefinitely and no exception is taken.


Cause
-----

Three independent defects, all in the handling of a faulted cycle.

1. wf68k10_bus_interface.vhd, process P_DF -- the word is composed from the
   wrong signals, and then overwritten before it is used.

       SSW <= To_StdLogicVector (RMC & '0' & OPCODE_REQ & RD_REQ & RMC)
              & SIZEVAR & RW_In & "00000" & FC_IN;

   a) RW. RW_In is defined as

          RW_In <= '0' when WRITE_ACCESS = '1' and BUS_CTRL_STATE = DATA_C1C4
                   else '1';

      but the assignment above is guarded by BUS_CTRL_STATE = START_CYCLE, so
      RW_In is unconditionally '1' at the moment it is sampled. The SSW always
      says "read".

   b) HB and BY. SIZEVAR is "10" for a long, "01" for a word and "00" for a
      byte, and it is dropped straight into SSW(10 downto 9) = HB & BY. Per
      figure 6-9, BY is the byte-transfer flag: set for a byte and clear for a
      word. The mapping above sets BY for a *word* and clears it for a byte,
      and puts the size's high bit where HB (which half of the transfer
      register a byte came from or goes to) belongs.

   c) RR. SSW(15) is the rerun flag and is driven from RMC. The MC68010 always
      writes the processor-rerun value, 0. (RMC is separately, and correctly,
      driven onto RM at bit 11.)

   d) IF and DF are taken from OPCODE_REQ and RD_REQ, which are the *pending*
      requests, not the request this cycle serves. Process ACCESSTYPE arbitrates
      them as RD_REQ > WR_REQ > OPCODE_REQ; with the prefetch pipeline running,
      OPCODE_REQ is commonly still asserted during a data cycle, so a faulted
      write reports IF=1.

      DF is also the wrong sense for a write in the first place: per the manual
      IF and DF tell a handler which input buffer a faulted *read* is to be
      completed into ("If the bus cycle is a read, the data at the fault address
      should be written to the images of the data input buffer, instruction
      input buffer, or both according to the DF and IF bits"). A write sets
      neither.

   e) The word is rewritten at the start of every bus cycle, and the exception
      handler does not raise BUSY_EXH -- the guard that freezes the register --
      until several clocks after the fault. The next pipelined opcode prefetch
      starts inside that window and overwrites the faulted cycle's attributes
      with its own. This is what turns the answer into a plausible-looking
      supervisor-program-space instruction fetch. FAULT_ADR in wf68k10_top.vhd
      is written only when BERRn is asserted and so does not have this problem,
      which is why the fault address survives while the SSW does not.

   Cases (a)-(d) are each visible on their own; (e) is what makes the result
   look like an entirely different cycle.

2. wf68k10_control.vhd -- BERR is suppressed exactly when an opcode fault is
   reported.

       BERR <= '0' when FETCH_STATE = START_OP and EXEC_WB_STATE = IDLE else
               ...
               '1' when OPD_ACK = '1' and OW_VALID = '0' else

   A faulted opcode reaches the execution unit through OPD_ACK with OW_VALID
   low, and that handshake happens while the controller sits in START_OP with
   EXEC_WB_STATE = IDLE -- it is the act of starting the next instruction. The
   leading "disable when the controller is not active" term therefore masks
   every instruction-fetch bus error. Measured on the JMP case above: OW_VALID
   is '0' and OPD_ACK strobes, and BERR stays '0'.

3. wf68k10_bus_interface.vhd, process VALIDATION -- an opcode fault invalidates
   the data buffer.

       elsif BUS_CTRL_STATE = DATA_C1C4 and BUS_FLT = '1' then
           DATA_VALID <= '0';

   The OPCODE_VALID branch just above is properly qualified with
   OPCODE_ACCESS = '1'; this one is not, so a faulted *opcode* cycle clears
   DATA_VALID too. DATA_VALID is only restored by the next DATA_RDY_I, so the
   first stack write of the resulting bus error exception is seen with
   DATA_RDY = '1' and DATA_VALID = '0'. That is the exception handler's
   DOUBLE_BUSFLT condition, and the core halts. (This is latent until defect 2
   is fixed, because until then no instruction-fetch bus error is taken at all.)


Fix
---

wf68k10_bus_interface.vhd, P_DF: build the word from the arbitrated request
(the same RD_REQ > WR_REQ > OPCODE_REQ priority ACCESSTYPE uses), give BY and
HB their meanings from figure 6-9, tie RR low, capture on an aborted
address-error cycle as well as on a cycle that reaches DATA_C1C4, and hold the
register from the fault (BUS_FLT or AERR_I) until BUSY_EXH rises. Three
integer-typed helper variables and one hold flag; no signals added, no
restructuring.

wf68k10_bus_interface.vhd, VALIDATION: qualify the DATA_VALID clear with
READ_ACCESS or WRITE_ACCESS, symmetrically with the OPCODE_VALID clear above it.

wf68k10_control.vhd: move the opcode-fault term above the "controller not
active" disable in the BERR priority chain. Order only; no term is added or
removed.


Reproducing
-----------

A self-checking MC68010 program that faults a cycle in each shape and compares
the pushed special status word against figure 6-9 is at

    https://github.com/  <RD68011>  sim/programs/p06_ssw.S

with a ghdl testbench for this core at sim/suska/wf68k10_ssw_tb.vhd. It faults,
in order: a supervisor data write (word), a supervisor data read (word), a
supervisor data write (byte, even), the same (byte, odd), an instruction fetch,
a user data write, a user program fetch, and the read half of a TAS. The
handler abandons the frame rather than returning through it, so each case runs
once.

Before: the run stops at the first case with SSW = 0x2306.
After:  all nine checks pass. The pushed words, with HB masked off in the word
        cases (the manual leaves HB undefined when BY is clear), are

          0005  1105  0205  0205  2106  0001  2102  1b05

        and unmasked, 0605 and 1f05 for the two even-address byte cases.

Any small program does the same thing: MOVE.W #imm,(An) into an address that
answers BERR and no DTACK, then read 8(SP) in the vector 2 handler.
