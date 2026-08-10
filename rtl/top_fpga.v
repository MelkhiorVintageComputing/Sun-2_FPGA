`timescale 1ns / 1ps

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
   
   
   sun2_fpga sun2(.cpu_clk(cpu_clk),
		  .clk40(clk40),
		  .C100(C100),
		  .clk4m9152(clk4m9152),
		  .sys_reset(sys_reset),
		  .P_VPA_n(P_VPA_n),
		  .P_BERR_n(P_BERR_n),
		  .P_DTACK_n(P_DTACK_n),
		  .P_BR_n(P_BR_n),
		  .P_BGACK_n(P_BGACK_n),
		  
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

   assign P_A = ADR_OUT[23:1];

   wire        P_RMC_n; // unused
   wire [31:0] PC;
   
   WF68K10_TOP suska_68k10(.CLK(C100),
			   .DATA_IN(P_DOUT), // IN for CPU, OUT for sun2
			   .BERRn(P_BERR_n),
			   .RESET_INn(RESET_INn),
			   .RESET_OUT(RESET_OUT),
			   .HALT_INn(HALT_INn),
			   .HALT_OUTn(HALT_OUTn),
			   .AVECn(1'b1),
			   .IPLn({IPL2_n, IPL1_n, IPL0_n}),
			   .DTACKn(P_DTACK_n),
			   .VPAn(P_VPA_n),
			   .BRn(P_BR_n),
			   .BGACKn(P_BGACK_n),
			   .K6800n(1'b1),
			   .ADR_OUT(ADR_OUT),
			   .DATA_OUT(P_DIN), // OUT for CPU, IN for sun2
			   .DATA_EN(DATA_EN),
			   .FC_OUT(P_FC),
			   .ASn(P_AS_n),
			   .RWn(P_RW_n),
			   .RMCn(P_RMC_n),
			   .UDSn(P_UDS_n),
			   .LDSn(P_LDS_n),
			    .DBENn(),
			   .BUS_EN(BUS_EN),
			    .E(),
			    .VMAn(),
			    .VMA_EN(),
			   .BGn(P_BG_n)
			   //,.PC(PC)
			   );

   // assign todebug = PC[7:0] ;

   //`include "check.v"
   
endmodule
