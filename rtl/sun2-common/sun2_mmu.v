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

		// Hardware maintenance of the page map's statistics bits.
		// REFMOD_WR is the qualified "this access was granted" term,
		// built in sun2_fpga beside the protection verdict it depends
		// on; P_RW_n says whether the modified bit joins the accessed
		// one.  See the comment at the pmap instantiation below.
		input 	      REFMOD_WR,
		input 	      P_RW_n,

		/* MMU outputs */
		output [15:0] ctx_out,
		// Which of the two contexts this access is translating through.
		// Purely for the debug bus: the register file shows both halves,
		// but only this says which one the segment map was indexed with.
		output [2:0]  cx_dbg,
		output [7:0]  ia_smap2pmap,
		output [11:0] ma_pmap2devices,
		output [11:0] ps_pmap2devices
);

   wire [2:0] 			 cx_ctx2smap; /* cx_ctx2smap is purely internal, ctx_out is the variant visible to the CPU */
   assign cx_dbg = cx_ctx2smap;
   
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
   //
   // The ps half has two writers: software, through control space, and the
   // MMU itself maintaining the accessed and modified bits.  They are mutually
   // exclusive by function code -- a software map access is FC 3 and REFMOD_WR
   // carries FC_GENERAL, which excludes it -- so the priority below is a
   // formality, but it is declared rather than left to chance.
   //
   // Architecture Manual 5.6.3: the accessed bit is set on any access the MMU
   // grants and the modified bit additionally on a write, and neither is ever
   // cleared by hardware.  That is exactly what the 2/50 does: A103.pal
   // computes MOD1 = MOD | WRITE and the write-back register takes its
   // accessed input from VCC, so accessed is written as 1 unconditionally.
   //
   // The rest of the entry has to be rewritten unchanged, which is free here:
   // sram_sync is read-first, so ps_pmap2devices already *is* the entry at the
   // index being written and no extra read cycle is needed.  On the real board
   // that is why register U316 exists -- the RAM nibble is 4 bits wide, so the
   // type field has to be latched and written back alongside.
   wire        ps_sw_wr = WR & MATCH_PMAP_PS & C_S6;
   wire [11:0] ps_refmod = {ps_pmap2devices[11:2],        // valid, protection, type
			    1'b1,                        // accessed: always set
			    ps_pmap2devices[0] | ~P_RW_n // modified: sticky, set on a write
			    };

   pmap_sram pmap(.CLK(CLK),
		  .idx({ia_smap2pmap,P_A[14:11]}),
		  .WR_ma(WR & MATCH_PMAP_MA & C_S6),
		  .WR_ps(ps_sw_wr | REFMOD_WR),
		  .ma_in(P_DIN[11:0]),
		  .ps_in(ps_sw_wr ? P_DIN[15:4] : ps_refmod),
		  .ma_out(ma_pmap2devices), // 12-bits output #1: physical address bits
		  .ps_out(ps_pmap2devices)  // 12-bits output #2: protection and status bits
		  );
   
  
endmodule // sun2_mmu
