`timescale 1ns / 1ps

`include "sun2_config.vh"

module sun2_fpga(input         cpu_clk,
		 input 	       clk40,
		 input 	       clk4m9152,
		 output        C100,
		 input 	       sys_reset, // board reset => also CPU reset
		 output        P_VPA_n,
		 output        P_BERR_n,
		 output        P_DTACK_n,
		 output        P_BR_n,
		 output        P_BGACK_n,

		 input 	       P_RESET_n, // CPU reset, not full board
		 output        P_HALT_n, // checkme

		 input 	       P_AS_n,
		 input 	       P_RW_n,
		 input 	       P_UDS_n,
		 input 	       P_LDS_n,
		 input 	       P_BG_n,
		 input 	       BUS_EN,

		 output        IPL2_n,
		 output        IPL1_n,
		 output        IPL0_n,

		 input [2:0]   P_FC,
   
		 input [23:1]  P_A,

		 input [15:0]  P_DIN,
		 output [15:0] P_DOUT,
		 input 	       DATA_EN,
		 /* serial */
		 output        tx,
		 input 	       rx,
		 /* debug */
		 output [7:0]  diag_leds,
		 output        en_boot,
		 output [7:0]  todebug,
		 /* wishbone */
		 output        wb_cyc_o,
		 output        wb_stb_o,
		 output [29:0] wb_adr_o,
		 output [31:0] wb_dat_o,
		 output [3:0]  wb_sel_o,
		 output        wb_we_o,
		 input [31:0]  wb_dat_i,
		 input 	       wb_ack_i
		   );
   // 180° clock
   wire 	       C100_n;

   assign P_BR_n = 1'b1; // FIXME for actual devices
   assign P_BGACK_n = 1'b1; // FIXME for actual devices
   
   assign P_HALT_n = 1'b1; // FIXME ?

   wire CLK;
   assign CLK = C100;

   reg 	POR_n;
   initial
     begin
	POR_n = 1'b1;
	#5 POR_n = 1'b0;
	#2000 POR_n = 1'b1;
     end
   assign P_HALT_n = POR_n;

   // layers shortcuts
   wire FC_CTRLLAYER;
   wire FC_CPUCYCLE;
   wire FC_SPROG;
   wire FC_GENERAL;
   
   assign FC_CTRLLAYER = (P_FC == 3'h3);
   assign FC_CPUCYCLE  = (P_FC == 3'h7);
   assign FC_SPROG     = (P_FC == 3'h6);
   assign FC_GENERAL   = ~FC_CTRLLAYER & ~FC_CPUCYCLE;

   assign P_VPA_n = ~(FC_CPUCYCLE);

   // Declared here rather than with the other match wires below because the
   // bus timeout logic just underneath uses MATCH_MEM, and xvlog rejects
   // use-before-declaration.
   wire 			 MATCH_MEM, MATCH_MEMX;

   // P_AS_n timing
   reg C_S3, C_S5, C_S7, C_S9;
   always @(negedge C100)
     begin
	if (~P_AS_n)        C_S3 <= 1'b1;
	if (~P_AS_n & C_S3) C_S5 <= 1'b1;
	if (~P_AS_n & C_S5) C_S7 <= 1'b1;
	if (~P_AS_n & C_S7) C_S9 <= 1'b1;
	if ( P_AS_n)
	  begin
	     C_S3 <= 1'b0;
	     C_S5 <= 1'b0;
	     C_S7 <= 1'b0;
	     C_S9 <= 1'b0;
	  end
     end
   reg C_S4, C_S6, C_S8, C_S10, C_S12, C_S14, C_S16, C_S18, C_S20, C_S22, C_S24, TIMEOUT;
   always @(posedge C100)
     begin
	if (~P_AS_n & C_S3) C_S4 <= 1'b1;
	if (~P_AS_n & C_S4) C_S6 <= 1'b1;
	if (~P_AS_n & C_S6) C_S8 <= 1'b1;
	if (~P_AS_n & C_S8) C_S10 <= 1'b1;
	if (~P_AS_n & C_S10) C_S12 <= 1'b1;
	if (~P_AS_n & C_S12) C_S14 <= 1'b1;
	if (~P_AS_n & C_S14) C_S16 <= 1'b1;
	if (~P_AS_n & C_S16) C_S18 <= 1'b1;
	if (~P_AS_n & C_S18) C_S20 <= 1'b1;
	if (~P_AS_n & C_S20) C_S22 <= 1'b1;
	if (~P_AS_n & C_S22) C_S24 <= 1'b1;
	if (~P_AS_n & C_S24 & ~MATCH_MEM) TIMEOUT <= 1'b1;
	if ( P_AS_n)
	  begin
	     C_S4 <= 1'b0;
	     C_S6 <= 1'b0;
	     C_S8 <= 1'b0;
	     C_S10 <= 1'b0;
	     C_S12 <= 1'b0;
	     C_S14 <= 1'b0;
	     C_S16 <= 1'b0;
	     C_S18 <= 1'b0;
	     C_S20 <= 1'b0;
	     C_S22 <= 1'b0;
	     C_S24 <= 1'b0;
	     TIMEOUT <= 1'b0;
	  end
     end

   // match wire for the control/mmu space
   // can match early because they only depend on the P_A address
   wire 			 MATCH_CTX, MATCH_SMAP, MATCH_PMAP_PS, MATCH_PMAP_MA;
   wire 			 MATCH_IDPROM, MATCH_DIAG, MATCH_BERR, MATCH_SYSEN;

   assign MATCH_PMAP_PS = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h0); // Long, MSW
   assign MATCH_PMAP_MA = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h1); // Long, LSW
   assign MATCH_SMAP    = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h2);
   assign MATCH_CTX     = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h3);
   assign MATCH_IDPROM  = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h4);
   assign MATCH_DIAG    = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h5);
   assign MATCH_BERR    = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h6);
   assign MATCH_SYSEN   = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h7);

   wire [23:0] 			 pa_forshow; // more readbable as a wave, no functional use
   // MMU & control layers
   wire [15:0] 			 ctx_out;
   wire [7:0] 			 ia_smap2pmap;
   wire [11:0] 			 ma_pmap2devices;
   wire [11:0] 			 ps_pmap2devices;
   
   assign pa_forshow = {1'b0, ma_pmap2devices, P_A[10:1], 1'b0};

   wire 			 MATCH_PROM_BOOT, BOOT_n;
   assign MATCH_PROM_BOOT  = ((FC_SPROG) & (~BOOT_n)); // at boot (bit from SYSEN): all Supervisor Program are from the PROM
   assign en_boot = ~BOOT_n;

   wire 			 WR;
   assign WR = (~P_UDS_n | ~P_LDS_n) & ~P_AS_n & ~P_RW_n;
   wire 			 RD;
   assign RD = (~P_UDS_n | ~P_LDS_n) & ~P_AS_n &  P_RW_n;


   sun2_mmu mmu(.CLK(C100),
		/* matching */
		.MATCH_CTX(MATCH_CTX),
		.MATCH_SMAP(MATCH_SMAP),
		.MATCH_PMAP_PS(MATCH_PMAP_PS),
		.MATCH_PMAP_MA(MATCH_PMAP_MA),
		.WR(WR),
		.RD(RD),
		/* CPU signals */
		.P_DIN(P_DIN),
		.P_A(P_A),
		.P_FC(P_FC),
		/* timing signals */
		.C_S4(C_S4),
		.C_S6(C_S6),
		/* MMU outputs */
		.ctx_out(ctx_out),
		.ia_smap2pmap(ia_smap2pmap),
		.ma_pmap2devices(ma_pmap2devices),
		.ps_pmap2devices(ps_pmap2devices)
	    );
   
   /* split the 12 protection/status bits by name */
   wire VALID, PROT5, PROT4, PROT3, PROT2, PROT1, PROT0, ACC, MOD;
   wire [2:0] TYPE;
   
   assign VALID = ps_pmap2devices[11];
   assign PROT5 = ps_pmap2devices[10];
   assign PROT4 = ps_pmap2devices[9];
   assign PROT3 = ps_pmap2devices[8];
   assign PROT2 = ps_pmap2devices[7];
   assign PROT1 = ps_pmap2devices[6];
   assign PROT0 = ps_pmap2devices[5];
   assign TYPE  = ps_pmap2devices[4:2];
   assign ACC   = ps_pmap2devices[1];
   assign MOD   = ps_pmap2devices[0];
   

   // combinatorial protection check on Page Map output, valid alongside ps_pmap2devices
   wire       PROTERR; //, PROTERR_n;
   wire       PROTERR_raw, PROTERR_raw_n;
   assign PROTERR   = PROTERR_raw   &  C_S8 & FC_GENERAL; // can't have a protection error unless the MMU is doing its job
   //assign PROTERR_n = PROTERR_raw_n | ~C_S8 & FC_GENERAL;
   
   ttl_74F151 gen_proterr(.D0(ps_pmap2devices[8]),
			  .D1(ps_pmap2devices[7]),
			  .D2(ps_pmap2devices[6]),
			  .D3(1'b0),
			  .D4(ps_pmap2devices[11]),
			  .D5(ps_pmap2devices[10]),
			  .D6(ps_pmap2devices[9]),
			  .D7(1'b0),
			  .A(~P_RW_n),
			  .B(P_FC[1]),
			  .C(P_FC[2]),
			  .Y(PROTERR_raw),
			  .W(PROTERR_raw_n),
			  .S(1'b0));

   // IDPROM, read-only
   wire [7:0] 			 idprom_out;
   idprom idprom(.CLK(CLK),
		 .idx(P_A[15:11]), // one byte per page...
		 .dout(idprom_out)
		 );

   // Diagnostic register, write-only
   wire [7:0] 			 leds;
   gen8bit_reg diag(.CLK(CLK),
		    .din(P_DIN[7:0]),
		    .WR(WR & MATCH_DIAG & C_S4),
		    .dout(leds),
		    //.CLR_n(1'b1)
		    .CLR_n(~sys_reset)
		    );
   assign diag_leds = ~leds;
   
   // Bus Error Register, read-only
   wire [7:0] 			 berr_in;
   wire [7:0] 			 berr_out;
   //assign berr_in = {C_S4, 1'b0, 1'b0, AEN, PROTERR, TIMEOUT, PARRERRU, PARRERRL};
   assign berr_in = {1'b0, 1'b0, 1'b0, 1'b0, PROTERR, TIMEOUT, 1'b0, 1'b0}; // FIXME: partial
   wire 			 ERR;
   assign ERR = (PROTERR | TIMEOUT) & C_S4; // FIXME: partial
   gen8bit_reg berr(.CLK(CLK),
		    .din(berr_in),
		    .WR(ERR),
		    .dout(berr_out),
		    .CLR_n(1'b1)
		    );
   assign P_BERR_n = ~ERR;

   // System Enable register
   wire [7:0] 			 sys_out;
   gen8bit_reg sys(.CLK(CLK),
		   .din(P_DIN[7:0]),
		   .WR(WR & MATCH_SYSEN & C_S4),
		   .dout(sys_out),
		   .CLR_n(POR_n)
		   );
   /* split the 8 system bits by name */
   wire 			 EN_PAR, EN_INT1, EN_INT2, EN_INT3, EN_PARERR, EN_DVMA, EN_INT;
   assign EN_PAR    = sys_out[0];
   assign EN_INT1   = sys_out[1];
   assign EN_INT2   = sys_out[2];
   assign EN_INT3   = sys_out[3];
   assign EN_PARERR = sys_out[4];
   assign EN_DVMA   = sys_out[5];
   assign EN_INT    = sys_out[6];
   assign BOOT_n    = sys_out[7];

   // output readable info when we change sysen
   always @(sys_out) begin
      $display("System Enable Register updated");
      $display("\tEnable Parity Generation: %x", EN_PAR);
      $display("\tCause Interrupt on Level 1: %x", EN_INT1);
      $display("\tCause Interrupt on Level 2: %x", EN_INT2);
      $display("\tCause Interrupt on Level 3: %x", EN_INT3);
      $display("\tEnable Parity Error ChecKing: %x", EN_PARERR);
      $display("\tEnable Direct Virtual Memory Access: %x", EN_DVMA);
      $display("\tEnable all Interrupts: %x", EN_INT);
      $display("\tBoot State (O => boot, 1 => normal): %x", BOOT_n);
   end // always @ (sys_out)

   // PROM (two access modes: at boot using P_A, or mapped but matched through MA), read-only
   // handled by the two match signals in the bus section, the PROM itself always output whatever is addressed
   wire [15:0] 			 prom_out;
   bootrom bootrom(.CLK(CLK),
		   .idx({1'b0, P_A[14:1]}),
		   .dout(prom_out)
		   );

   // match wire for devices
   // matching late as we need to be sure the MA is now valid, two clocks after the address is valid
   // that happens on entry in S2 (rising edge), so on that edge IA becomes valid
   // then on entry in S4 MA becomes valid
   // Device space is eight 2 KiB pages in the same order on both Sun-2 buses,
   // but at a different base: page 0x000 on MultiBus, 0xFE0 (byte 0x7F0000) on
   // VME -- see the device space map in the Architecture Manual.  DEV_PAGE_BASE
   // selects which, so the same decode serves both machines.
   wire 			 MATCH_DEV;
   assign MATCH_DEV      = (FC_GENERAL) & (TYPE == 3'h1) & C_S6 &
                           (ma_pmap2devices[11:3] == (`DEV_PAGE_BASE >> 3));

   wire 			 MATCH_PROM, MATCH_RSVD, MATCH_DPC, MATCH_PARALLEL, MATCH_SERIAL, MATCH_TIMER, MATCH_ROPS, MATCH_RTC;
   assign MATCH_PROM     = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h0);
   assign MATCH_RSVD     = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h1); // Ethernet on VME
   assign MATCH_DPC      = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h2); // not installed
   assign MATCH_PARALLEL = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h3); // keyboard/mouse on VME
   assign MATCH_SERIAL   = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h4);
   assign MATCH_TIMER    = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h5);
   assign MATCH_ROPS     = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h6); // not in prime
   assign MATCH_RTC      = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h7); // not in prime
   
`ifdef MEM_SIM_ONLY
   assign MATCH_MEM      = (FC_GENERAL) & (TYPE == 3'h0) & (ma_pmap2devices[11:8] == 4'h0) & C_S6; // "physically" installed (simulation => reduced)
`else
   // "physically" installed memory, in 2 KiB pages -- see MEM_PAGES in sun2_config.vh
   assign MATCH_MEM      = (FC_GENERAL) & (TYPE == 3'h0) & (ma_pmap2devices[11:0] < `MEM_PAGES) & C_S6;
`endif
   assign MATCH_MEMX     = (FC_GENERAL) & (TYPE == 3'h0) & (ma_pmap2devices[11:0] < 12'hE00) & C_S6; // addressable, for DTACK (so auto-sizing works, as it uses "wrong values" rather than bus error in the Rev R ROM)

   wire [15:0] 			 timer_out;
   wire 			 FOUT, timer_int[5:1]; /* FOUT for completeness, not et implemented in the TTL code */
   ttl_am9513 timer (
		     .reset_n(~sys_reset),
		   .DIN(P_DIN),
		   .DOUT(timer_out),
		   .CD_n(P_A[1]), // checkme: latched in the original (LA1)
		   .CS_n(1'b0), // always on
		   .RD_n(~MATCH_TIMER | ~RD),
		   .WR_n(~MATCH_TIMER | ~WR),
		   .X1(),
		   .X2(C100), // FIXME!
		   .FOUT(FOUT),
		   .SRC1(1'b0),
		   .SRC2(1'b0),
		   .SRC3(1'b0),
		   .SRC4(1'b0),
		   .SRC5(1'b0),
		   .SRC6(1'b0),
		   .GAT1(FOUT),
		   .GAT2(1'b0),
		   .GAT3(1'b0),
		   .GAT4(1'b0),
		   .GAT5(1'b0),
		   .OUT1(timer_int[1]), // FIXME: DOME
		   .OUT2(timer_int[2]),
		   .OUT3(timer_int[3]),
		   .OUT4(timer_int[4]),
		   .OUT5(timer_int[5])
		   );

`ifdef MEM_SIM_ONLY
   /* the actual memory. For now it's just synchronous RAM */
   /* should probably be moved to some "real" RAM with variable timings, which will require changing the bus mux below */
   wire [15:0] 			 mem_out;
   sram_sync_16bits_bytewritable #(.IDX_WIDTH(18)) mainmem (.CLK(C100),
							  .idx({ma_pmap2devices[7:0],P_A[10:1]}),
							  .WRl(WR & MATCH_MEM & ~P_LDS_n),
							  .WRu(WR & MATCH_MEM & ~P_UDS_n),
							  .din(P_DIN),
							  .dout(mem_out)
							  );
   /* no external memory in this configuration: park the Wishbone master */
   assign wb_cyc_o = 1'b0;
   assign wb_stb_o = 1'b0;
   assign wb_adr_o = 30'h0;
   assign wb_dat_o = 32'h0;
   assign wb_sel_o = 4'h0;
   assign wb_we_o  = 1'b0;
`else // !`ifdef SIM_ONLY
   wire [15:0] 			 wishbone_out;
   wire 			 w_ack;
   wire 				 L_M_MAP_SEEN;
   assign L_M_MAP_SEEN = (leds == 8'h8F); 
   
   sun2_wishbone_bridge wbridge(.CLK(C100),
				.RESET_n(~sys_reset), // don't reset on CPU-only reset, don't want to loose memory access then
				.SET_ENABLE(L_M_MAP_SEEN),
				.P_ADR_IN({1'h0, ma_pmap2devices[11:0], P_A[10:1]}), // full physical (4 MiB)
				.P_DATA_IN(P_DIN),
				.P_DATA_OUT(wishbone_out),
				.P_RW_n(P_RW_n),
				.EN_LBYTE(~P_LDS_n),
				.EN_UBYTE(~P_UDS_n),
				.MATCH_MEM(MATCH_MEM & ~MATCH_PROM_BOOT),
				.W_ACK(w_ack),
     
				// wishbone
				.wb_cyc_o(wb_cyc_o),
				.wb_stb_o(wb_stb_o),
				.wb_adr_o(wb_adr_o),
				.wb_dat_o(wb_dat_o),
				.wb_sel_o(wb_sel_o),
				.wb_we_o(wb_we_o),
				.wb_dat_i(wb_dat_i),
				.wb_ack_i(wb_ack_i)
				);
   
`endif

   
   /* serial port */
   wire [7:0] 			 serial_out;
   wire 			 serial_en;
   wire 			 serial_int_n; // FIXME: DOME
   wire 			 RxDA, TxDA, TxDA_EN;

   assign tx = TxDA;
   assign RxDA = rx;
  
   tolog tolog(.TxDA(TxDA)); // so we can trace only TxDA in the VCD, pulseview doesn't like too many signals
   
   z8530_scc  #(.SOFT_RESET_EN(1),
		.RR8_CTRL_POP(1),
		.BRG_SRC_A(1),
		.BRG_SRC_B(1),
		.UNIPLUS_BAUD_PATCH_B(0),
		.AUTO_ENABLES_EN(0),
		.RTXC_XTAL_FULLRATE_A(0),
		.RTXC_XTAL_FULLRATE_B(0),
		.RDWR_RESET_EN(1)
		) serial (
		// System Interface
			  .clk(C100),           // CPU/bus clock (register file, interrupts, RR mux)
			  .pclk(clk4m9152),       // Alternative BRG/serializer clock (Zilog "PCLK")
			  .sclk(clk4m9152),          // Primary BRG/serializer clock (e.g. 3.6864 MHz)
			  .reset_n(~sys_reset),       // Active low reset (async assert)
			  
			  // CPU Interface
			  .cs_n(1'b0),          // Chip select (active low)
			  .rd_n(~MATCH_SERIAL | ~RD & ~sys_reset),          // Read strobe (active low)
			  .wr_n(~MATCH_SERIAL | ~WR & ~sys_reset),          // Write strobe (active low)
			  .a_b(P_A[2]),           // Channel select: 1=A, 0=B
			  .d_c(P_A[1]),           // Data/Control: 1=Data, 0=Control
			  .data_in(P_DIN[15:8]),       // Data input
			  .data_out(serial_out),      // Data output
			  .data_oe(serial_en),       // Data output enable
			  
			  // Interrupt
			  .int_n(serial_int_n),         // Interrupt output (active low)
			  .intack_n(1'b1),      // Interrupt acknowledge
			  
			  // Channel A Serial Interface
			  .rxca(),          // Receive clock A
			  .txca(),          // Transmit clock A
			  .rxda(RxDA),          // Receive data A
			  .txda(TxDA),          // Transmit data A
			  .ctsa_n(),        // Clear to send A (active low)
			  .dcda_n(),        // Data carrier detect A (active low)
			  .synca_n(),       // Sync A (async-mode input -> RR0[4], active low)
			  .rtsa_n(),        // Request to send A (active low)
			  .dtra_n(),        // Data terminal ready A (active low)
			  
			  // Channel B Serial Interface
			  .rxcb(),          // Receive clock B
			  .txcb(),          // Transmit clock B
			  .rxdb(),          // Receive data B
			  .txdb(),          // Transmit data B
			  .ctsb_n(),        // Clear to send B (active low)
			  .dcdb_n(),        // Data carrier detect B (active low)
			  .syncb_n(),       // Sync B (async-mode input -> RR0[4], active low)
			  .rtsb_n(),        // Request to send B (active low)
			  .dtrb_n()         // Data terminal ready B (active low)
			  );
   
   
   
   // Answering the CPU
   // bus muxer. CPU has priority via DATA_EN, otherwise whomever is matched own the bus
   assign P_DOUT = DATA_EN         ? P_DIN : // loopback
		   MATCH_CTX       ? ctx_out :
		   MATCH_SMAP      ? {8'h0, ia_smap2pmap} :
		   MATCH_PMAP_PS   ? {ps_pmap2devices, 4'h0} :
		   MATCH_PMAP_MA   ? {4'h0, ma_pmap2devices} :
		   MATCH_SYSEN     ? {8'h0, sys_out} :
		   MATCH_BERR      ? {8'h0, berr_out} :
		   MATCH_IDPROM    ? {idprom_out, 8'h0} :
		   MATCH_PROM_BOOT ? prom_out :
		   MATCH_PROM      ? prom_out :
		   MATCH_TIMER     ? timer_out :
`ifdef MEM_SIM_ONLY
		   MATCH_MEM       ? mem_out :
`else
		   MATCH_MEM       ? wishbone_out :
`endif
		   MATCH_SERIAL    ? {serial_out, 8'h0} :
		   16'hDEAD;

   // DTACK generator. has knowledge of timings for all devices
   // For memory this will need updating if we use "real" (variable-timing) memory
   assign P_DTACK_n = ~(
			/* reads */
			( P_RW_n & C_S4 & (MATCH_CTX | MATCH_IDPROM | MATCH_SYSEN | MATCH_BERR | MATCH_PROM_BOOT)) | // entering S4, quick devices
			( P_RW_n & C_S4 & (MATCH_SMAP)) |  // entering S4, quick devices (CTX is 1 clock but went valid after being written, not affected by P_A)
			( P_RW_n & C_S6 & (MATCH_PMAP_PS | MATCH_PMAP_MA)) |  // entering S6, physical map needed an extra cycle
			( P_RW_n & C_S8 & (MATCH_TIMER | MATCH_PROM | MATCH_SERIAL)) | // entering S8, devices going through the MMU
`ifdef MEM_SIM_ONLY
		        ( P_RW_n & C_S8 & (MATCH_MEMX)) | // entering S8, memory going through the MMU
`else
		        ( P_RW_n & w_ack & (MATCH_MEM)) | // entering S8, memory going through the MMU
			// memory sizing doesn't like timeout ? so ack when out-of-range
		        ( P_RW_n & C_S8 & (MATCH_MEMX & ~MATCH_MEM)) | // entering S8, memory going through the MMU
`endif
			/* writes */
			(~P_RW_n & C_S4 & (MATCH_CTX | MATCH_SYSEN | MATCH_DIAG)) | // entering S4, quick devices
			(~P_RW_n & C_S4 & (MATCH_SMAP)) |  // entering S4, quick devices (CTX is 1 clock but went valid after being written, not affected by P_A)
			(~P_RW_n & C_S6 & (MATCH_PMAP_PS | MATCH_PMAP_MA)) |  // entering S6, physical map needed an extra cycle
			(~P_RW_n & C_S8 & (MATCH_TIMER |              MATCH_SERIAL)) | // entering S8, devices going through the MMU
`ifdef MEM_SIM_ONLY
		        (~P_RW_n & C_S8 & (MATCH_MEMX)) | // entering S8, memory going through the MMU
`else
		        (~P_RW_n & w_ack & (MATCH_MEMX)) | // entering S8, memory going through the MMU
		        (~P_RW_n & C_S8 & (MATCH_MEMX & ~MATCH_MEM)) | // entering S8, memory going through the MMU
`endif
			
			1'b0);
   
   
   // LEDS
   // as for the real thing, used for debugging (in simulation)
   always @(leds) begin
      $display("Leds are now %x", ~leds);
      case (~leds)
	8'hff:$display(" => L_RESET");
	8'h00:$display(" => L_RUNNING");
	8'h01:$display(" => L_INITIAL");
	8'h02:$display(" => L_USERDOG");
	8'h03:$display(" => L_GOTMEM");
	8'h04:$display(" => (initial led test only)");
	8'h07:$display(" => L_AFTERDIAG");
	8'h08:$display(" => L_HEARTBEAT");
	8'h10:$display(" => (initial led test only)");
	8'h11:$display(" => L_CONTEXT");
	8'h20:$display(" => (initial led test only)");
	8'h21:$display(" => L_SM_CONST");
	8'h23:$display(" => L_SM_DATA");
	8'h22:$display(" => L_SM_ADDR");
	8'h31:$display(" => L_PM_CONST");
	8'h33:$display(" => L_PM_DATA");
	8'h32:$display(" => L_PM_ADDR");
	8'h40:$display(" => L_PROM");
	8'h50:$display(" => L_UART");
	8'h70:$display(" => L_M_MAP");
	8'h71:$display(" => L_M_CONST");
	8'h72:$display(" => L_M_ADDR");
	8'h7F:$display(" => L_PARITY");
	8'h80:$display(" => (initial led test only)");
	8'h81:$display(" => L_TIMER");
	8'hF1:$display(" => L_SETUP_MEM");
	8'hF2:$display(" => L_SETUP_MAP");
	8'hF3:$display(" => L_SETUP_FB");
	8'hF4:$display(" => L_SETUP_KEYB");
	default: $display(" => unknown pattern!!!");
      endcase
      //$flushlog;
   end // always @ (leds)

   // CLOCKS
`ifdef CPU_CLK_MULTIPLE_SERIAL
   reg clk20;
   reg clk10;
   initial
     begin
	clk20 = 1'b0;
	clk10 = 1'b0;
     end
   always @(posedge clk40) clk20 <= ~clk20;
   always @(posedge clk20) clk10 <= ~clk10;
   assign C100 = clk10;
   assign C100_n = ~clk10;
`else
   assign C100   =  cpu_clk;
   assign C100_n = ~cpu_clk;
`endif

   // interrupts
   wire 	       INT7_n, INT6_n, INT5_n, INT4_n, INT3_n, INT2_n, INT1_n;
   // interrupts encoding
   ttl_74LS148 irq_encoder(.I_n({INT7_n, INT6_n, INT5_n, INT4_n, INT3_n, INT2_n, INT1_n, 1'b0}),
			  .A_n({IPL2_n, IPL1_n, IPL0_n}),
			  .EI_n(~EN_INT),
			  .EO_n(), // unused output
			  .GS_n() // unused output
			   );
   assign INT1_n = ~EN_INT1;
   assign INT2_n = ~EN_INT2;
   assign INT3_n = ~EN_INT3;
   assign INT4_n = 1'b1; // FIXME
   assign INT5_n = ~timer_int[2] & ~timer_int[3] & ~timer_int[4] & ~timer_int[5];
   assign INT6_n = serial_int_n;
   assign INT7_n = ~timer_int[1];

   reg 		       seen_mem_timeout;
   always @(posedge cpu_clk)
     begin
	if (sys_reset) seen_mem_timeout <= 1'b0;
	else if (MATCH_MEM & TIMEOUT) seen_mem_timeout <= 1'b1;
     end
   
   //assign todebug = { P_FC, BOOT_n,
   //		      ~P_AS_n, ~P_RW_n, ~P_DTACK_n, TIMEOUT };
   assign todebug = { ~P_AS_n, ~P_RW_n, ~P_DTACK_n, TIMEOUT,
		      1'b0, seen_mem_timeout, L_M_MAP_SEEN, MATCH_MEM };
   
   
endmodule // sun2_fpga
