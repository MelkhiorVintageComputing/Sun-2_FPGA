`timescale 1ns / 1ps

`include "sun2_config.vh"

module bootrom(input CLK,
	       input [13:0] idx,
	       output reg [15:0] dout
	       );

  always @(posedge CLK)
    begin
       case(idx)
`include `BOOTROM_FILE
       endcase // case (idx)
    end

endmodule // bootrom
