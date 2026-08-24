//
// The Sun-2's memory master: 68010 bus cycles out, Wishbone in.
//
// Two apertures share it, because a CPU cycle is one or the other and never
// both:
//
//   MATCH_MEM  main memory, physical byte address straight through, based at 0
//   MATCH_FB   the 2/50's frame buffer -- 128 KiB of page-map TYPE 1 pages
//              0..63, relocated to FB_WB_BASE in DDR3.  See sun2_fb_ctl.v.
//
// Everything else -- the byte lanes, the read return, the acknowledge that
// becomes DTACK -- is identical for both, which is the whole reason the frame
// buffer comes through here rather than through a master of its own.
//
module sun2_wishbone_bridge #(
    // Word address of the frame buffer in DDR3.  Only meaningful with
    // MATCH_FB; see FB_WB_BASE in sun2_config.vh.
    parameter [29:0] FB_WB_BASE = 30'h03E00000
) (input SET_ENABLE,
			     input 	       RESET_n,
			     input 	       CLK,
			     // some CPU bus signals
			     input [23:1]      P_ADR_IN,
			     input [15:0]      P_DATA_IN,
			     output reg [15:0] P_DATA_OUT,
			     input 	       P_RW_n,
			     input 	       EN_LBYTE,
			     input 	       EN_UBYTE,
			     
			     // Physical page from the MMU, for the frame buffer
			     // aperture: pages 0..63 of TYPE 1, 2 KiB each.
			     input [5:0]       FB_PAGE,

			     // match : response
			     input 	       MATCH_MEM,
			     input 	       MATCH_FB,
			     output 	       W_ACK,
			     
			     // wishbone
			     output 	       wb_cyc_o,
			     output 	       wb_stb_o,
			     output [29:0]     wb_adr_o,
			     output [31:0]     wb_dat_o,
			     output [3:0]      wb_sel_o,
			     output 	       wb_we_o,
			     input [31:0]      wb_dat_i,
			     input 	       wb_ack_i
);

   /* this creates a wishbone master in CLK domain */

   reg 					   wb_ack_i_prev;
   reg 					   ENABLE;
   
   
   wire 				   MATCH_ANY = MATCH_MEM | MATCH_FB;

   // The frame buffer's word address within its 128 KiB aperture: the physical
   // page picks the 2 KiB, P_ADR_IN the word inside it.  FB_WB_BASE is 128 KiB
   // aligned, so this is an OR rather than an add.
   wire [29:0] 				   fb_adr = FB_WB_BASE | {15'h0, FB_PAGE, P_ADR_IN[10:2]};

   //
   // One transaction per bus cycle, and only its own acknowledgement.
   //
   // This used to be `MATCH_ANY & ~wb_ack_i_prev' for the request and a bare
   // `wb_ack_i' for W_ACK, which gave the bridge no notion of *whose* cycle it
   // was serving.  It sits on the muxed 68010 bus -- top_fpga puts the CPU and
   // DVMA on the same wires on purpose -- and mig_arb allows one transaction
   // in flight across the whole interface with nothing tagging it, so:
   //
   //   * an acknowledgement still resolving from the previous cycle, which may
   //     be the *other* master's, acknowledged the cycle now on the bus.  It
   //     reached DTACK combinationally and the CPU latched P_DATA_OUT, which
   //     still held that transaction's data.
   //   * MATCH_ANY stays asserted for the rest of a bus cycle, so ~wb_ack_i_prev
   //     suppressed re-requesting for exactly one clock and the bridge then
   //     issued the same read again, and again, each ack overwriting the one
   //     P_DATA_OUT.
   //
   // Measured on a VME 2/50 that hangs netbooting.  `moveal %a5@(1118),%a0' at
   // ef4322 reloads the Ethernet control register's address in the window
   // where the 82586, just given Channel Attention, is fetching its SCP.  The
   // ILA caught the CPU's read of 0x0A045E returning 0x0000 -- the value the
   // interposed DVMA read of 0xFFFFF6 returned -- where memory holds 0x00EE,
   // and returning it in six clocks where the uncontended read of the same
   // address took ten.  Acknowledged early, by someone else's transaction.
   // a0 came back 0x00003000 instead of 0x00EE3000, the following `bclr'
   // cleared a bit at 0x003000 instead of dropping CA, and the chip never saw
   // a second attention.  Both cores fail identically, which is what says it
   // is here and not in either of them.
   //
   // `issued' says a request has been out for at least one clock of the cycle
   // now on the bus, which is the guard: an acknowledgement is only ours if we
   // had already asked.  Slaves here register their ack -- it can never arrive
   // in the same clock the request goes out -- so this costs nothing and
   // rejects a pulse left over from the cycle before.  `done' holds DTACK for
   // the rest of the cycle once that ack has arrived, so the request drops
   // instead of repeating.  Both clear when MATCH_ANY does, which is the end
   // of the bus cycle.
   //
   reg 					   issued, done;

   // Held until this cycle's own acknowledgement, as Wishbone requires: a
   // slave counts its wait states only while CYC and STB are up, so a request
   // dropped after one clock never completes at all.  `done' is what stops it
   // repeating, where ~wb_ack_i_prev used to stop it for exactly one clock.
   assign wb_cyc_o = ~ENABLE ? 1'b0 : MATCH_ANY & ~done;
   assign wb_stb_o = wb_cyc_o;
   assign wb_adr_o = ~ENABLE ? 30'h00000000 :
		     MATCH_FB  ? fb_adr :
		     MATCH_MEM ? {8'h0, P_ADR_IN[23:2]} : // wishbone word-addressed, memory is based at 0
				 30'h0C0FFEEE;
`ifdef WB_LITTLE_ENDIAN
   assign wb_dat_o = ~ENABLE ? 32'h00000000 : {P_DATA_IN[ 7: 0], // wishbone little-endian
					       P_DATA_IN[15: 8],
					       P_DATA_IN[ 7: 0],
					       P_DATA_IN[15: 8]};
   assign wb_sel_o = ~ENABLE ? 4'h0 : (P_RW_n ? 4'hF : { EN_LBYTE & ~P_ADR_IN[1],
                                                         EN_UBYTE & ~P_ADR_IN[1],
                                                         EN_LBYTE &  P_ADR_IN[1],
                                                         EN_UBYTE &  P_ADR_IN[1]});
`else
   assign wb_dat_o = ~ENABLE ? 32'h00000000 : {P_DATA_IN, P_DATA_IN };
   assign wb_sel_o = ~ENABLE ? 4'h0 : (P_RW_n ? 4'hF : { EN_UBYTE &  P_ADR_IN[1],
                                                         EN_LBYTE &  P_ADR_IN[1],
                                                         EN_UBYTE & ~P_ADR_IN[1],
                                                         EN_LBYTE & ~P_ADR_IN[1]});
`endif
   assign wb_we_o  = ~ENABLE ? 1'b0 : ~P_RW_n;
   assign W_ACK = ~ENABLE ? 1'b0 : ((wb_ack_i & issued) | done);


   always @(posedge CLK)
     begin
	wb_ack_i_prev <= ~ENABLE ? 1'b0 : wb_ack_i;

	// The cycle owns its transaction: armed when the request goes out,
	// finished when that request is acknowledged, both cleared when the
	// cycle ends.
	if (~ENABLE | ~MATCH_ANY) begin
	   issued <= 1'b0;
	   done   <= 1'b0;
	end else begin
	   if (wb_cyc_o)          issued <= 1'b1;
	   if (wb_ack_i & issued) done   <= 1'b1;
	end

	if (~RESET_n) ENABLE <= 1'b0;
	if (SET_ENABLE) ENABLE <= 1'b1; // one-shot trigger: once seen, the wishbone stays up until next (board) reset

	if (~ENABLE)
	  P_DATA_OUT <= 32'h00000000;

	if (ENABLE)
	  if(wb_ack_i & issued & ~wb_we_o)   // ours, not the other master's
	    begin
`ifdef WB_LITTLE_ENDIAN
	       P_DATA_OUT <= P_ADR_IN[1] ? { wb_dat_i[ 7: 0], wb_dat_i[15: 8] } : {wb_dat_i[23:16], wb_dat_i[31:24]};
`else
	       P_DATA_OUT <= P_ADR_IN[1] ? { wb_dat_i[31:24], wb_dat_i[23:16] } : {wb_dat_i[15: 8], wb_dat_i[ 7: 0]};
`endif
	    end // if (wb_ack_i & ~wb_we_o)
	  //else if (P_DATA_OUT[31:16] != 16'h2BAD)
	  //  P_DATA_OUT <= 32'h2BAD0000;
	  //else P_DATA_OUT[15:0] <= P_DATA_OUT[15:0] + 1;
	
     end

endmodule // sun3_wishbone_bridge
