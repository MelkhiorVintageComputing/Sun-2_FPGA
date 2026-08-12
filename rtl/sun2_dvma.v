`timescale 1ns / 1ps

//
// DVMA: a Wishbone master's accesses turned into MC68010 bus cycles.
//
// Sun calls it Direct Virtual Memory Access because that is the whole point --
// the addresses an I/O channel puts out are *virtual*, and they go through the
// same MMU as the CPU's.  Architecture Manual section 7:
//
//   "DVMA allows P1-Bus masters to directly access onboard memory with a
//    virtual address.  Direct virtual memory access avoids the dual mapping
//    problems of DMA in a virtual memory environment.  DVMA translates and
//    protects all accesses within the system in an identical fashion."
//
// On the 2/50 the 82586's multiplexed address is latched into P.A01..P.A23 by
// three ALS374s (schematic sheet A07, U702/U703/U704) and the U215 PAL drives
// P.FC = 5, supervisor data.  Downstream of those pins a DVMA cycle is
// indistinguishable from a CPU cycle, which is why nothing else in this design
// needs to know DVMA exists: the segment and page maps, the protection check,
// the bus timing chain, DTACK and the bus error register are all reused.
//
// Two things this module is responsible for that the schematic spreads across
// several parts:
//
//   * arbitration (the U214 PAL on sheet A02).  The 2/50 does *two-wire*
//     arbitration -- BGACK is tied high -- so a master holds BR asserted for as
//     long as it wants the bus and releases by negating it.  See MC68000UM
//     section 5.2: "Bus arbitration on all microprocessors ... BGACK must be
//     pulled high for 2-wire bus arbitration."  The real PAL arbitrates three
//     requesters (DRAM refresh, Ethernet, VME) in that priority order; there is
//     only one here, so what is left is the handshake.
//
//   * the byte lane crossing.  The data bus between the 82586 and the rest of
//     the machine is wired byte-reversed (ALS244 U707/U708, sheet A07;
//     Architecture Manual section 6.13, "connected to the system in a permanent
//     byte-reversed mode").  See the note on byte order below -- it is the
//     single easiest thing to get wrong here, and it fails silently.
//
module sun2_dvma(input             CLK,
		 input 		   RESET,

		 //
		 // Wishbone B4 classic slave: the 82586's master port.
		 // wb_adr_i is a *word* address, so the byte address is
		 // {wb_adr_i, 2'b00} -- 24 bits, exactly the space the chip can
		 // reach and exactly what P_A[23:1] wants.
		 //
		 input 		   wb_cyc_i,
		 input 		   wb_stb_i,
		 input 		   wb_we_i,
		 input [3:0] 	   wb_sel_i,
		 input [21:0] 	   wb_adr_i,
		 input [31:0] 	   wb_dat_i,
		 output reg [31:0] wb_dat_o,
		 output reg 	   wb_ack_o,
		 output reg 	   wb_err_o,

		 //
		 // Arbitration.  EN_DVMA is the system enable register's bit 5;
		 // Architecture Manual section 4.5 has it cleared on power-up and
		 // watchdog reset, so nothing can DVMA until software says so.
		 //
		 input 		   EN_DVMA,
		 output 	   P_BR_n,
		 input 		   P_BG_n,
		 input 		   BUS_EN, // the CPU is still driving the bus
		 input 		   cpu_as_n, // ... and has a cycle in progress

		 //
		 // What we drive once we own the bus.  top_fpga muxes these onto
		 // the CPU's own outputs when dvma_active is set.
		 //
		 output 	   dvma_active,
		 output [23:1] 	   dvma_a,
		 output [2:0] 	   dvma_fc,
		 output 	   dvma_as_n,
		 output 	   dvma_rw_n,
		 output 	   dvma_uds_n,
		 output 	   dvma_lds_n,
		 output [15:0] 	   dvma_dout,

		 // Termination, from the machine.
		 input [15:0] 	   dvma_din,
		 input 		   P_DTACK_n,
		 input 		   P_BERR_n,

		 //
		 // The E.ERR latch (74F74 U719, sheet A07): a bus error during a
		 // DVMA cycle stops the channel dead until the Ethernet reset bit
		 // is asserted.  Architecture Manual section 6.13: "ERR indicates
		 // that a Bus Error occured during an 82586 channel operation,
		 // inhibiting further channel activity.  To reset the ERR
		 // condition, the RESET bit in the Ethernet control register must
		 // be activated."
		 //
		 input 		   ether_reset,
		 output reg 	   dvma_err
		 );

   //
   // Byte order
   // ----------
   // The boot PROM's driver already byte-swaps every scalar in software
   // (to_ieaddr, to_ieoff, and byte-swapped IECMD_* constants), so what is in
   // memory is Intel little-endian *at matching byte addresses*.  All the
   // hardware has to guarantee is:
   //
   //     the 82586's byte address N reaches the same memory byte the 68010
   //     calls byte address N.
   //
   // A 68010 puts the even byte of a word on D[15:8] (UDS); an Intel part puts
   // it on D[7:0].  Crossing the lanes is what makes those agree -- it cancels
   // the addressing mismatch rather than adding a second swap on top of the
   // software one.  So:
   //
   //   Wishbone byte     68010
   //   sel[0] dat[7:0]   byte addr +0, even -> UDS -> D[15:8]
   //   sel[1] dat[15:8]  byte addr +1, odd  -> LDS -> D[7:0]
   //   sel[2] dat[23:16] byte addr +2, even -> UDS -> D[15:8]
   //   sel[3] dat[31:24] byte addr +3, odd  -> LDS -> D[7:0]
   //
   // which splits one 32-bit Wishbone access into at most two 68010 word
   // cycles: the low half at {wb_adr_i, 1'b0} carrying sel[1:0], the high half
   // at {wb_adr_i, 1'b1} carrying sel[3:2].  A half with no selected byte is
   // skipped, so every SEL pattern the MAC produces -- including the awkward
   // 4'b0110 tail of an unaligned frame -- comes out as ordinary 68k cycles.
   //
   // Get this backwards and it does not look like a byte order bug: the chip
   // reads SYSBUS from 0xFFFFF7 instead of 0xFFFFF6, decides the host bus is
   // 8 bits wide, and never clears the ISCP busy flag.  It looks like a chip
   // that is not there.
   //

   localparam S_IDLE   = 3'd0;
   localparam S_REQ    = 3'd1; // asking for the bus
   localparam S_ADDR   = 3'd2; // address and FC valid, AS not yet asserted
   localparam S_STROBE = 3'd3; // AS and the data strobes asserted
   localparam S_LATCH  = 3'd4; // acknowledged; strobes still on, data settling
   localparam S_DONE   = 3'd5; // strobes off, let the machine settle
   localparam S_ACK    = 3'd6; // answer the Wishbone side

   reg [2:0] 			   state;
   reg 				   half;   // which 16-bit half we are on
   reg 				   hi_todo; // the high half still needs a cycle
   reg 				   err_cyc; // this access took a bus error
   reg [15:0] 			   rd_lo, rd_hi;
   reg 				   uds_n, lds_n;
   reg 				   own;    // we hold the bus

   wire 			   lo_needed = |wb_sel_i[1:0];
   wire 			   hi_needed = |wb_sel_i[3:2];

   // Bus request.  Two-wire arbitration: hold it for as long as we want the
   // bus, and the Suska core stays in its GRANT state meanwhile.  We keep it
   // across both halves of one Wishbone access rather than re-arbitrating
   // between them as the real U214 would -- two word cycles is a short hold,
   // and it saves a second round trip through the core's arbiter.
   assign P_BR_n = ~(state != S_IDLE && state != S_ACK);

   assign dvma_active = own;
   assign dvma_a      = {wb_adr_i, half};
   assign dvma_fc     = 3'b101; // supervisor data, as the U215 PAL drives it
   assign dvma_rw_n   = ~wb_we_i;
   // AS stays asserted through S_LATCH.  A 68010 does not sample read data on
   // the edge it recognises DTACK -- it holds the cycle for another clock and
   // latches at the end of S6 -- and the machine's read path is built to that:
   // sun2_wishbone_bridge presents its data the clock after it acknowledges.
   // Capturing a clock early returns the *previous* cycle's data, which looks
   // like a chip reading plausible rubbish rather than like a timing bug.
   assign dvma_as_n   = ~(state == S_STROBE || state == S_LATCH);
   assign dvma_uds_n  = uds_n;
   assign dvma_lds_n  = lds_n;

   // Write data for the half we are on, lanes crossed.
   assign dvma_dout = half ? {wb_dat_i[23:16], wb_dat_i[31:24]}
			   : {wb_dat_i[7:0],   wb_dat_i[15:8]};

   always @(posedge CLK)
     begin
	if (RESET)
	  begin
	     state    <= S_IDLE;
	     own      <= 1'b0;
	     half     <= 1'b0;
	     hi_todo  <= 1'b0;
	     err_cyc  <= 1'b0;
	     uds_n    <= 1'b1;
	     lds_n    <= 1'b1;
	     wb_ack_o <= 1'b0;
	     wb_err_o <= 1'b0;
	     wb_dat_o <= 32'h0;
	     rd_lo    <= 16'h0;
	     rd_hi    <= 16'h0;
	     dvma_err <= 1'b0;
	  end
	else
	  begin
	     wb_ack_o <= 1'b0;
	     wb_err_o <= 1'b0;

	     // The error latch clears only on Ethernet reset, never by itself.
	     if (ether_reset)
	       dvma_err <= 1'b0;

	     case (state)
	       S_IDLE:
		 if (wb_cyc_i & wb_stb_i & ~wb_ack_o & ~wb_err_o)
		   begin
		      if (~EN_DVMA | dvma_err)
			begin
			   // DVMA disabled, or the channel is stopped after an
			   // earlier fault.  Answer with an error rather than
			   // hanging the master forever.
			   err_cyc <= 1'b1;
			   state   <= S_ACK;
			end
		      else if (~lo_needed & ~hi_needed)
			begin
			   err_cyc <= 1'b0;
			   state   <= S_ACK; // nothing selected; nothing to do
			end
		      else
			begin
			   err_cyc <= 1'b0;
			   half    <= ~lo_needed;         // skip an empty low half
			   hi_todo <= lo_needed & hi_needed;
			   state   <= S_REQ;
			end
		   end

	       S_REQ:
		 // Wait for the grant, for the CPU to finish whatever cycle it
		 // was in, and for it to actually let go.  MC68000UM 5.2.3: "No
		 // device is allowed to assume bus mastership while AS is
		 // asserted."  BUS_EN is the Suska core's own statement that it
		 // has released the address, strobes and function codes.
		 if (~P_BG_n & cpu_as_n & ~BUS_EN)
		   begin
		      own   <= 1'b1;
		      state <= S_ADDR;
		   end

	       S_ADDR:
		 begin
		    // Address, FC and R/W are valid a state before AS, exactly as
		    // S.ASON delays P.AS behind S.DMA in the U215 PAL.
		    uds_n <= half ? ~wb_sel_i[2] : ~wb_sel_i[0];
		    lds_n <= half ? ~wb_sel_i[3] : ~wb_sel_i[1];
		    state <= S_STROBE;
		 end

	       S_STROBE:
		 if (~P_BERR_n)
		   begin
		      err_cyc  <= 1'b1;
		      dvma_err <= 1'b1; // stop the channel until Ethernet reset
		      uds_n    <= 1'b1;
		      lds_n    <= 1'b1;
		      hi_todo  <= 1'b0;
		      state    <= S_DONE;
		   end
		 else if (~P_DTACK_n)
		   state <= S_LATCH;

	       S_LATCH:
		 begin
		    if (half) rd_hi <= dvma_din;
		    else      rd_lo <= dvma_din;
		    uds_n <= 1'b1;
		    lds_n <= 1'b1;
		    state <= S_DONE;
		 end

	       S_DONE:
		 // AS is negated; give the machine a cycle to clear its bus
		 // timing chain before the next strobe.
		 if (hi_todo)
		   begin
		      half    <= 1'b1;
		      hi_todo <= 1'b0;
		      state   <= S_ADDR;
		   end
		 else
		   begin
		      own   <= 1'b0;
		      state <= S_ACK;
		   end

	       S_ACK:
		 begin
		    // Uncross the lanes on the way back.  Halves that were never
		    // driven read as zero, which the master ignores: its SEL said
		    // it did not want them.
		    wb_dat_o <= {rd_hi[7:0], rd_hi[15:8], rd_lo[7:0], rd_lo[15:8]};
		    wb_ack_o <= ~err_cyc;
		    wb_err_o <= err_cyc;
		    rd_lo    <= 16'h0;
		    rd_hi    <= 16'h0;
		    state    <= S_IDLE;
		 end

	       default: state <= S_IDLE;
	     endcase
	  end
     end

endmodule
