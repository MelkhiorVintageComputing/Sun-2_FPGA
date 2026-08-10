module sram_sync #(parameter DATA_WIDTH=4, IDX_WIDTH=12) (input CLK,
							  input [IDX_WIDTH-1:0]       idx,
							  input 		      WR,
							  input [DATA_WIDTH-1:0]      din,
							  output reg [DATA_WIDTH-1:0] dout
							  );
   
   (* ram_style = "block" *) reg [DATA_WIDTH-1:0] sram[0:(2**IDX_WIDTH)-1];

`ifdef NOT_DEFINED
   task init;
      integer a;
      begin
         for (a = 0; a < (2**IDX_WIDTH); a = a + 1) sram[a] = $random;
      end
   endtask
   
   initial
     begin
	dout = $random;
        init;
     end
 `endif
   
   always @(posedge CLK)
     begin
	if (WR) sram[idx] <= din;
	dout <= sram[idx];
     end

endmodule // smap_sync
