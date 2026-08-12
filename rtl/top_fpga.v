`timescale 1ns / 1ps

`include "sun2_config.vh"

module top(input         cpu_clk,
	   input 	 clk40,
	   input 	 clk4m9152,
	   input 	 sys_reset,
	   /* serial */
	   output 	 tx,
	   input 	 rx,

	   /* debug */
	   output [7:0]  diag_leds,
	   output 	 en_boot,
	   output [7:0]  todebug,

	   /* Ethernet diagnostics, for the board top to surface: a PHY that
	    holds carrier sense asserted stops transmission dead, and it is the
	    one failure the machine cannot otherwise report. */
	   output 	 eth_crs_stuck,

	   /* MII, for the on-board Ethernet of a VME machine.  Nothing on the
	    Wukong drives these yet; in simulation they go to tb/mii_peer.sv. */
	   input 	 mii_tx_clk,
	   output [3:0]  mii_txd,
	   output 	 mii_tx_en,
	   output 	 mii_tx_er,
	   input 	 mii_rx_clk,
	   input [3:0] 	 mii_rxd,
	   input 	 mii_rx_dv,
	   input 	 mii_rx_er,
	   input 	 mii_crs,
	   input 	 mii_col,

	   /* wishbone */
	   output 	 wb_cyc_o,
	   output 	 wb_stb_o,
	   output [29:0] wb_adr_o,
	   output [31:0] wb_dat_o,
	   output [3:0]  wb_sel_o,
	   output 	 wb_we_o,
	   input [31:0]  wb_dat_i,
	   input 	 wb_ack_i
	   );
   wire C100;
   wire P_VPA_n;
   wire P_BERR_n;
   wire P_DTACK_n;
   wire P_BR_n;
   wire P_BGACK_n;

   wire P_RESET_n;
   wire P_HALT_n;
   
   wire P_AS_n;
   wire P_RW_n;
   wire P_UDS_n;
   wire P_LDS_n;
   wire P_BG_n;
   wire BUS_EN;
   
   wire        IPL2_n;
   wire IPL1_n;
   wire IPL0_n;
   
   wire [2:0] P_FC;
   
   wire [23:1] P_A;
   wire [15:0] P_DIN;
   wire [15:0] P_DOUT;
   wire        DATA_EN;
   wire [31:0] ADR_OUT;

   // The CPU's own bus outputs, before the DVMA mux below.
   wire [2:0]  cpu_fc;
   wire        cpu_as_n, cpu_rw_n, cpu_uds_n, cpu_lds_n;
   wire [15:0] cpu_dout;

   // The alternate master's, and the Ethernet control register's signals.
   wire        EN_DVMA, dvma_active, dvma_as_n, dvma_rw_n, dvma_uds_n, dvma_lds_n;
   wire [23:1] dvma_a;
   wire [2:0]  dvma_fc;
   wire [15:0] dvma_dout;
   wire        ether_core_reset_n, ether_loopback_n, ether_ca, ether_int_en;
   wire        ether_int, ether_bus_err;
   
   
   sun2_fpga sun2(.cpu_clk(cpu_clk),
		  .clk40(clk40),
		  .C100(C100),
		  .clk4m9152(clk4m9152),
		  .sys_reset(sys_reset),
		  .P_VPA_n(P_VPA_n),
		  .P_BERR_n(P_BERR_n),
		  .P_DTACK_n(P_DTACK_n),
		  
  		  .P_RESET_n(P_RESET_n),
		  .P_HALT_n(P_HALT_n),
		  
		  .P_AS_n(P_AS_n),
		  .P_RW_n(P_RW_n),
		  .P_UDS_n(P_UDS_n),
		  .P_LDS_n(P_LDS_n),
		  .P_BG_n(P_BG_n),
		  .DATA_EN(DATA_EN),
		  
		  .IPL2_n(IPL2_n),
		  .IPL1_n(IPL1_n),
		  .IPL0_n(IPL0_n),
		  
		  .P_FC(P_FC),
		  
		  .P_A(P_A),
		  
		  .P_DIN(P_DIN),
		  .P_DOUT(P_DOUT),
		  .BUS_EN(BUS_EN),

		  .tx(tx),
		  .rx(rx),

		  .EN_DVMA_o(EN_DVMA),
		  .ether_core_reset_n(ether_core_reset_n),
		  .ether_loopback_n(ether_loopback_n),
		  .ether_ca(ether_ca),
		  .ether_int_en(ether_int_en),
		  .ether_int(ether_int),
		  .ether_bus_err(ether_bus_err),

		  .diag_leds(diag_leds),
		  .en_boot(en_boot),
		  .todebug(todebug),
		  //.todebug(),
				
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
   
   wire        RESET_INn;
   wire        HALT_INn;
   wire        RESET_OUT;
   wire        HALT_OUTn; // ignored
   
   assign RESET_INn = ~sys_reset; /* board reset => reset CPU */
   assign P_RESET_n = ~sys_reset;// & ~RESET_OUT; /* board reset or CPU reset => reset system */
   assign HALT_INn = ~sys_reset;// & ~RESET_OUT; /* board reset => reset CPU (HALTn seem needed) */

   //
   // The bus mux: CPU, or the alternate master doing DVMA.
   //
   // Everything downstream of these wires -- the MMU, the protection check, the
   // bus timing chain, DTACK, the bus error register, every device decode --
   // is shared, which is exactly how the real machine works.  Schematic sheet
   // A03 and Architecture Manual section 7: DVMA cycles are translated and
   // protected identically to CPU cycles, so a DVMA cycle is a supervisor-data
   // CPU cycle as far as anything past this point can tell.
   //
   // dvma_active is only ever asserted after the Suska core has granted the bus
   // *and* dropped BUS_EN, so the two never drive together.
   //
   assign P_A     = dvma_active ? dvma_a     : ADR_OUT[23:1];
   assign P_FC    = dvma_active ? dvma_fc    : cpu_fc;
   assign P_AS_n  = dvma_active ? dvma_as_n  : cpu_as_n;
   assign P_RW_n  = dvma_active ? dvma_rw_n  : cpu_rw_n;
   assign P_UDS_n = dvma_active ? dvma_uds_n : cpu_uds_n;
   assign P_LDS_n = dvma_active ? dvma_lds_n : cpu_lds_n;
   assign P_DIN   = dvma_active ? dvma_dout  : cpu_dout;

   // Two-wire arbitration, as on the 2/50: BGACK is tied high and a master
   // holds BR for as long as it wants the bus.  MC68000UM section 5.2 requires
   // BGACK pulled high for this, and the Suska core's arbiter handles it in its
   // GRANT state.  Deliberate, not a stub.
   assign P_BGACK_n = 1'b1;

   wire        P_RMC_n; // unused
   wire [31:0] PC;
   
   WF68K10_TOP suska_68k10(.CLK(C100),
			   .DATA_IN(P_DOUT), // IN for CPU, OUT for sun2
			   .BERRn(P_BERR_n),
			   .RESET_INn(RESET_INn),
			   .RESET_OUT(RESET_OUT),
			   .HALT_INn(HALT_INn),
			   .HALT_OUTn(HALT_OUTn),
			   // A real 68010 has one VPA pin doing two jobs: 6800-style
			   // peripheral cycles, and autovectoring an interrupt
			   // acknowledge.  Suska splits them, so the Sun-2's VPA --
			   // asserted for every CPU-space cycle, i.e. every IACK --
			   // belongs on AVECn, not on VPAn.
			   //
			   // Wired the other way round, as it was, AVECn stayed
			   // deasserted and the core took the interrupt vector off
			   // the data bus instead: the read mux's 16'hDEAD
			   // fall-through gave vector 0xAD, and the monitor reported
			   // "Exception 2B4" (173 * 4).  It went unnoticed because
			   // no interrupt had ever reached the CPU -- the timer's
			   // OUT pins were tied to a register nothing drove.
			   //
			   // VPAn stays deasserted: there are no 6800 peripherals on
			   // a Sun-2, and asserting it starts an E/VMA cycle.
			   .AVECn(P_VPA_n),
			   .IPLn({IPL2_n, IPL1_n, IPL0_n}),
			   .DTACKn(P_DTACK_n),
			   .VPAn(1'b1),
			   .BRn(P_BR_n),
			   .BGACKn(P_BGACK_n),
			   .K6800n(1'b1),
			   .ADR_OUT(ADR_OUT),
			   .DATA_OUT(cpu_dout), // OUT for CPU, IN for sun2
			   .DATA_EN(DATA_EN),
			   .FC_OUT(cpu_fc),
			   .ASn(cpu_as_n),
			   .RWn(cpu_rw_n),
			   .RMCn(P_RMC_n),
			   .UDSn(cpu_uds_n),
			   .LDSn(cpu_lds_n),
			    .DBENn(),
			   .BUS_EN(BUS_EN),
			    .E(),
			    .VMAn(),
			    .VMA_EN(),
			   .BGn(P_BG_n)
			   //,.PC(PC)
			   );

   //
   // DVMA bus master.  Nothing requests through it yet -- the 82586 goes in
   // next -- so dvma_active stays low and the machine behaves exactly as it did
   // before the mux above existed.
   //
`ifdef SUN2_VME
   sun2_ethernet ethernet(.CLK(C100),
			  .RESET(sys_reset),

			  .core_reset_n(ether_core_reset_n),
			  .loopback_n(ether_loopback_n),
			  .ca(ether_ca),
			  .int_en(ether_int_en),
			  .int_o(ether_int),
			  .bus_err_o(ether_bus_err),
			  .crs_stuck_o(eth_crs_stuck),

			  .EN_DVMA(EN_DVMA),
			  .P_BR_n(P_BR_n),
			  .P_BG_n(P_BG_n),
			  .BUS_EN(BUS_EN),
			  .cpu_as_n(cpu_as_n),

			  .dvma_active(dvma_active),
			  .dvma_a(dvma_a),
			  .dvma_fc(dvma_fc),
			  .dvma_as_n(dvma_as_n),
			  .dvma_rw_n(dvma_rw_n),
			  .dvma_uds_n(dvma_uds_n),
			  .dvma_lds_n(dvma_lds_n),
			  .dvma_dout(dvma_dout),
			  .dvma_din(P_DOUT),
			  .P_DTACK_n(P_DTACK_n),
			  .P_BERR_n(P_BERR_n),

			  .mii_tx_clk(mii_tx_clk),
			  .mii_txd(mii_txd),
			  .mii_tx_en(mii_tx_en),
			  .mii_tx_er(mii_tx_er),
			  .mii_rx_clk(mii_rx_clk),
			  .mii_rxd(mii_rxd),
			  .mii_rx_dv(mii_rx_dv),
			  .mii_rx_er(mii_rx_er),
			  .mii_crs(mii_crs),
			  .mii_col(mii_col)
			  );
`else
   //
   // MultiBus: no on-board Ethernet.  The 2/120's equivalent I/O page is an
   // 80287 socket, so there is nothing here to request the bus and the mux
   // above folds away entirely.
   //
   assign ether_int     = 1'b0;
   assign ether_bus_err = 1'b0;
   assign eth_crs_stuck = 1'b0;
   assign mii_txd       = 4'h0;
   assign mii_tx_en     = 1'b0;
   assign mii_tx_er     = 1'b0;

   sun2_dvma dvma(.CLK(C100),
		  .RESET(sys_reset),

		  .wb_cyc_i(1'b0),
		  .wb_stb_i(1'b0),
		  .wb_we_i(1'b0),
		  .wb_sel_i(4'h0),
		  .wb_adr_i(22'h0),
		  .wb_dat_i(32'h0),
		  .wb_dat_o(),
		  .wb_ack_o(),
		  .wb_err_o(),

		  .EN_DVMA(EN_DVMA),
		  .P_BR_n(P_BR_n),
		  .P_BG_n(P_BG_n),
		  .BUS_EN(BUS_EN),
		  .cpu_as_n(cpu_as_n),

		  .dvma_active(dvma_active),
		  .dvma_a(dvma_a),
		  .dvma_fc(dvma_fc),
		  .dvma_as_n(dvma_as_n),
		  .dvma_rw_n(dvma_rw_n),
		  .dvma_uds_n(dvma_uds_n),
		  .dvma_lds_n(dvma_lds_n),
		  .dvma_dout(dvma_dout),

		  .dvma_din(P_DOUT),
		  .P_DTACK_n(P_DTACK_n),
		  .P_BERR_n(P_BERR_n),

		  .ether_reset(~ether_core_reset_n),
		  .dvma_err()
		  );
`endif

   // assign todebug = PC[7:0] ;

   //`include "check.v"
   
endmodule
