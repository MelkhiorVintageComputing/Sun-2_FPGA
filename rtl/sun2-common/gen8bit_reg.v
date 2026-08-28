`timescale 1ns / 1ps

module gen8bit_reg(input CLK,
		   input [7:0] 	    din,
		   input 	    WR,
		   output reg [7:0] dout,
		   input 	    CLR_n
		   );
   reg [7:0] 			 data;
   // Simulation only: powering up unknown is deliberate, and Quartus rejects
   // $random for synthesis where Vivado ignores it.  See ctx_reg.v.
`ifdef SUN2_SIM
   initial
     begin
        data = $random;
     end
`endif
   
   always @(posedge CLK)
     begin
	if (WR) data <= din;
	if (~CLR_n) data <= 8'h00;
	dout <= data;
     end
   
endmodule
