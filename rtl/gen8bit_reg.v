`timescale 1ns / 1ps

module gen8bit_reg(input CLK,
		   input [7:0] 	    din,
		   input 	    WR,
		   output reg [7:0] dout,
		   input 	    CLR_n
		   );
   reg [7:0] 			 data;
   initial
     begin
        data = $random;
     end
   
   always @(posedge CLK)
     begin
	if (WR) data <= din;
	if (~CLR_n) data <= 8'h00;
	dout <= data;
     end
   
endmodule
