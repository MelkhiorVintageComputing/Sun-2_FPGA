`timescale 1ns / 1ps

module idprom(input CLK,
	      input [4:0]	 idx,
	      output reg [7:0] dout
	      );

   always @(posedge CLK)   
     case (idx)
       5'h00: dout <= 8'h01; // format
       5'h01: dout <= 8'h01; // machine type
       5'h02: dout <= 8'h08; // ethernet address (6 bytes)
       5'h03: dout <= 8'h00;
       5'h04: dout <= 8'h20;
       5'h05: dout <= 8'h01;
       5'h06: dout <= 8'h06;
       5'h07: dout <= 8'he0;
       5'h08: dout <= 8'h1a; // date (4 bytes)
       5'h09: dout <= 8'he4;
       5'h0a: dout <= 8'h23;
       5'h0b: dout <= 8'h3b;
       5'h0c: dout <= 8'h00; // serial number (3 bytes)
       5'h0d: dout <= 8'h0d;
       5'h0e: dout <= 8'h72;
       5'h0f: dout <= 8'h56; // checksum 
       5'h10: dout <= 8'hff; // reserved (16 bytes)
       5'h11: dout <= 8'hff;
       5'h12: dout <= 8'hff;
       5'h13: dout <= 8'hff;
       5'h14: dout <= 8'hff;
       5'h15: dout <= 8'hff;
       5'h16: dout <= 8'hff;
       5'h17: dout <= 8'hff;
       5'h18: dout <= 8'hff;
       5'h19: dout <= 8'hff;
       5'h1a: dout <= 8'hff;
       5'h1b: dout <= 8'hff;
       5'h1c: dout <= 8'hff;
       5'h1d: dout <= 8'hff;
       5'h1e: dout <= 8'hff;
       5'h1f: dout <= 8'hff;
     endcase
endmodule

