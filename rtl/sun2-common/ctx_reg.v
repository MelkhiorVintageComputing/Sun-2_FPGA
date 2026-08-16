`timescale 1ns / 1ps

//
// The Sun-2 has *two* context registers, not one, and they must be writable
// independently.  sys/sun2/mmu.h:
//
//     #define SUPCONTEXTOFF   6       /* supervisor context register */
//     #define USERCONTEXTOFF  7       /* user context register */
//
// Supervisor accesses translate through the supervisor context and user
// accesses through the user context, which is what lets sun2/locore.s walk
// contexts 1..NCONTEXT-1 invalidating every segment while it goes on
// executing: setusercontext() moves only the user context, so the kernel's own
// instruction fetches stay in supervisor context 0 throughout.
//
// The two live in one 16-bit word at FC_MAP offset 6 -- supervisor in the even
// (upper) byte, user in the odd (lower) one -- and every writer of either is a
// `movsb` to its own byte.  So the byte strobes are not decoration: a write
// must land only on the half that was actually selected.
//
// Getting that wrong is invisible until something needs the two to differ,
// which is why it survived here so long.  The PROM writes them as separate
// bytes too, but always to the same value -- mon/kernel/trap.s:398-400 is
// `movsb d0,SUPCONTEXTOFF` immediately followed by `movsb d0,USERCONTEXTOFF`
// -- so a write that hit both halves changed nothing the monitor could see,
// and the MultiBus reference boot is byte-identical either way.  SunOS is the
// first thing to set them apart, and with the strobes ignored a 68010 byte
// write (which drives the byte on both halves of the data bus) made
// setusercontext(1) move the supervisor context to 1 as well.  The kernel's
// next instruction fetch then translated through a context whose segments it
// was in the middle of invalidating: bus error on the fetch, bus error on the
// stack frame, double fault, CPU halted about 0x48 bytes into _start.
//
module ctx_reg(input CLK,
	       input [15:0] 	 din,
	       input 		 USER_n,
	       input 		 WR,
	       input 		 UDS_n,
	       input 		 LDS_n,
	       output reg [15:0] dout,
	       output [2:0] 	 cx
	       );
   reg [7:0] 			 ctx;
   
   initial
     begin
        ctx = $random;
     end
   
   always @(posedge CLK)
     begin
	if (WR & ~UDS_n) ctx[7:4] <= din[11:8];   // offset 6, supervisor
	if (WR & ~LDS_n) ctx[3:0] <= din[3:0];    // offset 7, user
	dout <= {4'h0, ctx[7:4], 4'h0, ctx[3:0]};
     end
   assign cx = USER_n ? dout[10:8] : dout[2:0];
   
endmodule // ctx_reg



