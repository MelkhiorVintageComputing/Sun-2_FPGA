`timescale 1ns / 1ps

module pmap_sram
  #(parameter MA_DATA_WIDTH=12, PS_DATA_WIDTH=12, IDX_WIDTH=12)
   (input CLK,
    input [IDX_WIDTH-1:0]  idx,
    input 	  WR_ma,
    input 	  WR_ps,
    input [MA_DATA_WIDTH-1:0]  ma_in,
    input [PS_DATA_WIDTH-1:0]  ps_in,
    output [MA_DATA_WIDTH-1:0] ma_out,
    output [PS_DATA_WIDTH-1:0] ps_out
    );

   sram_sync  #(.DATA_WIDTH(MA_DATA_WIDTH), .IDX_WIDTH(IDX_WIDTH)) datamap (.CLK(CLK),
									    .idx(idx),
									    .WR(WR_ma),
									    .din(ma_in),
									    .dout(ma_out)
									    );
							   
   sram_sync #(.DATA_WIDTH(PS_DATA_WIDTH), .IDX_WIDTH(IDX_WIDTH)) protmap (.CLK(CLK),
									   .idx(idx),
									   .WR(WR_ps),
									   .din(ps_in),
									   .dout(ps_out)
									   );
   
endmodule // pmap_sram


