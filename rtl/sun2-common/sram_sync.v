`include "sun2_attr.vh"

module sram_sync #(parameter DATA_WIDTH=4, IDX_WIDTH=12) (input CLK,
							  input [IDX_WIDTH-1:0]       idx,
							  input 		      WR,
							  input [DATA_WIDTH-1:0]      din,
							  output reg [DATA_WIDTH-1:0] dout
							  );
   
   `SUN2_RAM_BLOCK reg [DATA_WIDTH-1:0] sram[0:(2**IDX_WIDTH)-1];

`ifdef SRAM_POWERUP_ZERO
   // What the board does.  A 7-series block RAM comes out of configuration
   // with every bit zero and its output register zero; this model leaves both
   // X, so the segment and page maps read as unknown until software writes
   // them and simulation cannot see what hardware does with an unwritten map
   // entry -- which is precisely the window the 68010's reset vector fetch
   // falls in, since that is a supervisor *data* cycle and so goes through the
   // MMU rather than coming from the boot PROM.
   integer zi;
   initial begin
      for (zi = 0; zi < (2**IDX_WIDTH); zi = zi + 1) sram[zi] = {DATA_WIDTH{1'b0}};
      dout = {DATA_WIDTH{1'b0}};
   end
`endif

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
