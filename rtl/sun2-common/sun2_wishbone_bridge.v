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

   assign wb_cyc_o = ~ENABLE ? 1'b0 : (MATCH_ANY) & ~wb_ack_i_prev;
   assign wb_stb_o = ~ENABLE ? 1'b0 : (MATCH_ANY) & ~wb_ack_i_prev;
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
   assign W_ACK = ~ENABLE ? 1'b0 : wb_ack_i;


   always @(posedge CLK)
     begin
	wb_ack_i_prev <= ~ENABLE ? 1'b0 : wb_ack_i;

	if (~RESET_n) ENABLE <= 1'b0;
	if (SET_ENABLE) ENABLE <= 1'b1; // one-shot trigger: once seen, the wishbone stays up until next (board) reset

	if (~ENABLE)
	  P_DATA_OUT <= 32'h00000000;

	if (ENABLE)
	  if(wb_ack_i & ~wb_we_o)
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
