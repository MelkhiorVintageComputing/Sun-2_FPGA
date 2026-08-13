`timescale 1ns / 1ps

module ctx_reg(input CLK,
	       input [15:0] 	 din,
	       input 		 USER_n,
	       input 		 WR,
	       output reg [15:0] dout,
	       output [2:0] 	 cx
	       );
   reg [7:0] 			 ctx;
   
   initial
     begin
        ctx = $random;
     end
   
   always @(posedge CLK)
     begin
	if (WR) ctx <= {din[11:8],din[3:0]};
	dout <= {4'h0, ctx[7:4], 4'h0, ctx[3:0]};
     end
   assign cx = USER_n ? dout[10:8] : dout[2:0];
   
endmodule // ctx_reg



