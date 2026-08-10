`timescale 1ns / 1ps

module sram_sync_16bits_bytewritable #(parameter IDX_WIDTH=18) (input CLK,
								input [IDX_WIDTH-1:0] idx,
								input 		      WRl,
								input 		      WRu,
								input [15:0] 	      din,
								output [15:0] 	      dout
								);

   sram_sync #(.DATA_WIDTH(8), .IDX_WIDTH(IDX_WIDTH)) lowbyte (.CLK(CLK),
							       .idx(idx),
							       .WR(WRl),
							       .din(din[7:0]),
							       .dout(dout[7:0])
							       );
   sram_sync #(.DATA_WIDTH(8), .IDX_WIDTH(IDX_WIDTH)) highbyte (.CLK(CLK),
								.idx(idx),
								.WR(WRu),
								.din(din[15:8]),
								.dout(dout[15:8])
								);
   
endmodule // sram_sync_16bits_bytewritable

