module sun2_mmu(input CLK,
		/* matching */
		input 	      MATCH_CTX,
		input 	      MATCH_SMAP,
		input 	      MATCH_PMAP_PS,
		input 	      MATCH_PMAP_MA,
		input 	      WR,
		input 	      RD,
		/* CPU signals */
		input [15:0]  P_DIN,
		input [23:1]  P_A,
		input [2:0]   P_FC,
		// The two context registers share a word and are written a byte
		// at a time, so ctx_reg needs to know which half was selected.
		input 	      P_UDS_n,
		input 	      P_LDS_n,

		/* timing signals */
		input 	      C_S4,
		input 	      C_S6,

		/* MMU outputs */
		output [15:0] ctx_out,
		output [7:0]  ia_smap2pmap,
		output [11:0] ma_pmap2devices,
		output [11:0] ps_pmap2devices
);

   wire [2:0] 			 cx_ctx2smap; /* cx_ctx2smap is purely internal, ctx_out is the variant visible to the CPU */
   
   // Context register
   ctx_reg ctx(.CLK(CLK),
	       .din(P_DIN),
	       .USER_n(P_FC[2]),
	       .WR(WR & MATCH_CTX & C_S4),
	       .UDS_n(P_UDS_n),
	       .LDS_n(P_LDS_n),
	       .dout(ctx_out), // 16-bits output (3 lsb used in each byte)
	       .cx(cx_ctx2smap) // 3-bits output (selected User:Supervisor by P_FC[2])
	       );
   
   // Segment Map
   smap_sram smap(.CLK(CLK),
		  .idx({P_A[23:15],cx_ctx2smap}),
		  .WR(WR & MATCH_SMAP & C_S4),
		  .ia_in(P_DIN[7:0]),
		  .ia_out(ia_smap2pmap) // 8-bits outputs: index in the PMap
		  );
   // Page Map
   pmap_sram pmap(.CLK(CLK),
		  .idx({ia_smap2pmap,P_A[14:11]}),
		  .WR_ma(WR & MATCH_PMAP_MA & C_S6),
		  .WR_ps(WR & MATCH_PMAP_PS & C_S6),
		  .ma_in(P_DIN[11:0]),
		  .ps_in(P_DIN[15:4]),
		  .ma_out(ma_pmap2devices), // 12-bits output #1: physical address bits
		  .ps_out(ps_pmap2devices)  // 12-bits output #2: protection and status bits
		  );
   
  
endmodule // sun2_mmu
