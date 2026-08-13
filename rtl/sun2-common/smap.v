`timescale 1ns / 1ps
module smap_sram
  #(parameter DATA_WIDTH=8, IDX_WIDTH=12)
   (input CLK,
    input [IDX_WIDTH-1:0]   idx,
    input 		    WR,
    input [DATA_WIDTH-1:0]  ia_in,
    output [DATA_WIDTH-1:0] ia_out
    );
   
   sram_sync #(.DATA_WIDTH(DATA_WIDTH), .IDX_WIDTH(IDX_WIDTH)) smap (.CLK(CLK),
								     .idx(idx),
								     .WR(WR),
								     .din(ia_in),
								     .dout(ia_out)						  );
endmodule // smap_sync
