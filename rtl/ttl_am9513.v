//
// // Partial implementation of AMD 9513 timer module
//

`define SPLIT_DATA_BUS

// TRACE turns on a per-access register trace. It is very chatty -- it
// dominates run time on a full boot -- so it is off unless asked for.
module ttl_am9513 #(parameter TRACE = 0) (
		   input reset_n,
`ifdef SPLIT_DATA_BUS
		   input [15:0] DIN,
		   output [15:0] DOUT,
`else
		   inout [15:0] D,
`endif
		   input  CD_n,
		   input  CS_n,
		   input  RD_n,
		   input  WR_n,
		   input  X1,
		   input  X2,
		   input  FOUT,
		   input  SRC1,
		   input  SRC2,
		   input  SRC3,
		   input  SRC4,
		   input  SRC5,
		   input  SRC6,
		   input  GAT1,
		   input  GAT2,
		   input  GAT3,
		   input  GAT4,
		   input  GAT5,
		   output OUT1,
		   output OUT2,
		   output OUT3,
		   output OUT4,
		   output OUT5);

   reg [15:0] data_out;
   wire [15:0] status_out;
   wire read, write, clk;
   wire [15:0] bus_out;

   reg [15:0] cmd;

   wire [15:0] data_in;
`ifdef SPLIT_DATA_BUS
   assign data_in = DIN;
`else
   assign data_in = D;
`endif

   wire [5:0] src;
   assign src = { SRC6, SRC5, SRC4, SRC3, SRC2, SRC1 };

   wire [4:0] gat;
   assign gat = { GAT5, GAT4, GAT3, GAT2, GAT1 };

   reg [5:0] out = 0;
   assign OUT5 = out[5];
   assign OUT4 = out[4];
   assign OUT3 = out[3];
   assign OUT2 = out[2];
   assign OUT1 = out[1];

   assign clk = X2;
   assign read = ~RD_n & ~CS_n;
   assign write = ~WR_n & ~CS_n;

   assign bus_out = CD_n ? status_out : data_out;
`ifdef SPLIT_DATA_BUS
   assign DOUT = bus_out;
`else
   assign D = read ? bus_out : 16'bz;
`endif

   reg [7:0] data_ptr = 0;
   reg [15:0] mm = 0;

   wire [2:0] group;
   wire [1:0] element;
   wire       byteptr;
   assign group = { data_ptr[5], data_ptr[4], data_ptr[3] };
   assign element = { data_ptr[2], data_ptr[1] };
   assign byteptr = data_ptr[0];
		    
   assign status_out = { 2'b11, out[5], out[4], out[3], out[2], out[1], byteptr };

   wire [4:0] decode1;
   wire [2:0] decode2;
   wire [2:0] bitnum;
   
   assign decode1 = { data_in[7], data_in[6], data_in[5], data_in[4], data_in[3] };
   assign decode2 = { data_in[7], data_in[6], data_in[5] };
   assign bitnum = { data_in[2], data_in[1], data_in[0] };

   reg [7:0]  output_bits;
   reg [5:0]  armed_bits;

   reg [15:0] ctr_mode[5:1];
   reg [15:0] ctr_load[5:1];
   reg [15:0] ctr_hold[5:1];
   reg [15:0] ctr_cntr[5:1];
   
   wire [15:0] ctr_mode_group, ctr_load_group, ctr_hold_group;
   wire [15:0] ctr_mode1, ctr_mode2, ctr_mode3, ctr_mode4, ctr_mode5;

   reg [2:0]  i;
   /*
   initial
     begin
	for (i = 1; i <= 5; i = i + 1)
	  begin
	     ctr_mode[i] = 0;
	     ctr_load[i] = 0;
	     ctr_hold[i] = 0;
	     ctr_cntr[i] = 0;
	  end
     end
    */
   
   always @(posedge clk) begin
     if (~reset_n) begin
	for (i = 1; i <= 5; i = i + 1)
	  begin
	     ctr_mode[i] <= 0;
	     ctr_load[i] <= 0;
	     ctr_hold[i] <= 0;
	     ctr_cntr[i] <= 0;
	  end
	ctr_mode[1] <= 16'h0b00;
	data_out <= 0;
	cmd <= 0;
     end
   
     if (write) begin
	if (CD_n)   // command write
	  begin
	     if (TRACE) $display("am9513: cmd write; %b", data_in[7:0]);
	     casex (data_in[7:0])
	       8'he8,
	       8'he0:
		 begin
		    mm[14] <= data_in[3];
		    if (TRACE) $display("am9514: mm12 <- %b", data_in[3]);
		 end
	       
	       8'hee,
	       8'he6:
		 begin
		    mm[12] <= data_in[3];
		    if (TRACE) $display("am9513: mm12 <- %b", data_in[3]);
		 end

	       8'hef,
               8'he7:
		 begin
		    mm[13] <= data_in[3];
		    if (TRACE) $display("am9513: mm13 <- %b", data_in[3]);
		 end

	       8'b000xxxx:
		 begin
		    data_ptr <= { data_in[2], data_in[1], data_in[0],
				  data_in[4], data_in[3], 1'b1 };
		    #1 if (TRACE) $display("am9513: data_ptr e%d g%d -> %x",
				{ data_in[4], data_in[3] },
				{ data_in[2], data_in[1], data_in[0] },
				data_ptr);
		 end

	       8'b001xxxxx,
               8'b010xxxxx,
	       8'b011xxxxx:
		 begin
		    if (data_in[5])
		      begin
			 if (TRACE) $display("am9513: set armed bits %b", data_in[4:0]);
			 armed_bits <= armed_bits | { data_in[4:0], 1'b0 };
		      end

		    if (data_in[6])
		      begin
			 if (TRACE) $display("am9513: cntr <- load; bits %b", data_in[4:0]);
			 if (data_in[0])  ctr_cntr[1] <= ctr_load[1];
			 if (data_in[1])  ctr_cntr[2] <= ctr_load[2];
			 if (data_in[2])  ctr_cntr[3] <= ctr_load[3];
			 if (data_in[3])  ctr_cntr[4] <= ctr_load[4];
			 if (data_in[4])  ctr_cntr[5] <= ctr_load[5];
		      end
		 end
	       
	       8'b100xxxxx,
 	       8'b101xxxxx,
 	       8'b110xxxxx:
		 begin
		    if (~data_in[5])
		      begin
			 if (TRACE) $display("am9513: reset armed bits %b", data_in[4:0]);
			 armed_bits <= armed_bits & ~{ data_in[4:0], 1'b0 };
		      end

		    if (~data_in[6])
		      begin
			 if (TRACE) $display("am9513: load <- cntr; bits %b", data_in[4:0]);
			 if (data_in[0]) ctr_load[1] <= ctr_cntr[1];
			 if (data_in[1]) ctr_load[2] <= ctr_cntr[2];
			 if (data_in[2]) ctr_load[3] <= ctr_cntr[3];
			 if (data_in[3]) ctr_load[4] <= ctr_cntr[4];
			 if (data_in[4]) ctr_load[5] <= ctr_cntr[5];
		      end
		 end
	       
	       8'b11101xxx:
		 begin
		    output_bits[bitnum] <= 1'b1;
		    if (TRACE) $display("am9513: output[%d] <- 1 (reg)", bitnum);
		 end

	       8'b11100xxx:
		 begin
		    output_bits[bitnum] <= 1'b0;
		    if (TRACE) $display("am9513: output[%d] <- 0 (reg)", bitnum);
		 end
		    
	     endcase
`ifdef SPLIT_DATA_BUS
	     cmd <= DIN;
`else
	     cmd <= D;
`endif
	  end
     end
   
     if (write) begin
	if (~CD_n)   // data write
	  begin
	     if (TRACE) $display("am9513: data write; group %d element %d", group, element);
	     if (group == 1 || group == 2 || group == 3 || group == 4 || group == 5)
	       begin
		  case (element)
		    2'b00: begin
		       if (byteptr)
			 ctr_mode[group] <= { data_in[7:0], ctr_mode_group[7:0] };
		       else
			 ctr_mode[group] <= { ctr_mode_group[15:7], data_in[7:0] };

		       if (TRACE) $display("am9513: ctr_mode[%d] <- %x", group,
				byteptr ? { data_in[7:0], ctr_mode_group[7:0] } :
				{ ctr_mode_group[15:7], data_in[7:0] });
		    end
		    
		    2'b01: begin
		       if (byteptr)
			 ctr_load[group] <= { data_in[7:0], ctr_load_group[7:0] };
		       else
			 ctr_load[group] <= { ctr_load_group[15:7], data_in[7:0] };

		       if (TRACE) $display("am9513: ctr_load[%d] <- %x", group,
				byteptr ? { data_in[7:0], ctr_load_group[7:0] } :
				{ ctr_load_group[15:7], data_in[7:0] });
		    end
		    
		    2'b10: begin
		       if (byteptr)
			 ctr_hold[group] <= { data_in[7:0], ctr_hold_group[7:0] };
		       else
			 ctr_hold[group] <= { ctr_hold_group[15:7], data_in[7:0] };
		    end
		  endcase

		  data_ptr <= { group, {element, byteptr} + 3'b1 };
		  if (TRACE) $display("am9513: data_ptr -> %x", { group, {element, byteptr} + 3'b1 });
	       end
	  end
     end

     if (read) begin
	if (~CD_n)   // data read
	  begin
	     if (TRACE) $display("am9513: data read; group %d element %d", group, element);

	     case (element)
	       2'b00:
		 begin
		    data_out <= ctr_mode[group];
		    if (TRACE) $display("am9513: read mode[%d] -> %x", group, ctr_mode[group]);
		 end
	       
	       2'b01:
		 begin
		    data_out <= ctr_load[group];
		    if (TRACE) $display("am9513: read load[%d] -> %x", group, ctr_load[group]);
		 end

	       2'b10:
		 begin
		    data_out <= ctr_hold[group];
		    if (TRACE) $display("am9513: read hold[%d] -> %x", group, ctr_hold[group]);
		 end
	     endcase
	     
	  end
     end

     begin
	if (armed_bits[1])
	  begin
	     if (ctr_mode1[0])
	       ctr_cntr[1] <= ctr_cntr[1] + 16'b1;
	     else
	       ctr_cntr[1] <= ctr_cntr[1] - 16'b1;

	     if (ctr_cntr[1] == 16'b0)
	       begin
		  if (ctr_mode1[6])
		    ctr_cntr[1] <= ctr_load[1];
		  
		  if (~output_bits[1])
		    if (TRACE) $display("am9513: output[1] <- 1 (cntr)");

		  output_bits[1] <= 1'b1;
	       end
	  end

	if (armed_bits[2])
	  begin
	     if (ctr_mode2[0])
	       ctr_cntr[2] <= ctr_cntr[2] + 16'b1;
	     else
	       ctr_cntr[2] <= ctr_cntr[2] - 16'b1;

	     if (ctr_cntr[2] == 16'b0)
	       begin
		  if (ctr_mode2[6])
		    ctr_cntr[2] <= ctr_load[1];

		  if (~output_bits[2])
		    if (TRACE) $display("am9513: output[2] <- 1");

		  output_bits[2] <= 1'b1;
	       end
	  end

	if (armed_bits[3])
	  begin
	     if (ctr_mode3[0])
	       ctr_cntr[3] <= ctr_cntr[3] + 16'b1;
	     else
	       ctr_cntr[3] <= ctr_cntr[3] - 16'b1;

	     if (ctr_cntr[3] == 16'b0)
	       begin
		  if (ctr_mode3[6])
		    ctr_cntr[3] <= ctr_load[3];

		  if (~output_bits[3])
		    if (TRACE) $display("am9513: output[3] <- 1");

		  output_bits[3] <= 1'b1;
	       end
	  end

	if (armed_bits[4])
	  begin
	     if (ctr_mode4[0])
	       ctr_cntr[4] <= ctr_cntr[4] + 16'b1;
	     else
	       ctr_cntr[4] <= ctr_cntr[4] - 16'b1;

	     if (ctr_cntr[4] == 16'b0)
	       begin
		  if (ctr_mode4[6])
		    ctr_cntr[4] <= ctr_load[4];

		  if (~output_bits[4])
		    if (TRACE) $display("am9513: output[4] <- 1");

		  output_bits[4] <= 1'b1;
	       end
	  end

	if (armed_bits[5])
	  begin
	     if (ctr_mode5[0])
	       ctr_cntr[5] <= ctr_cntr[5] + 16'b1;
	     else
	       ctr_cntr[5] <= ctr_cntr[5] - 16'b1;

	     if (ctr_cntr[5] == 16'b0)
	       begin
		  if (ctr_mode5[6])
		    ctr_cntr[5] <= ctr_load[5];
		  
		  if (~output_bits[5])
		    if (TRACE) $display("am9513: output[5] <- 1");

		  output_bits[5] <= 1'b1;
	       end
	  end
     end
   end // always @ (posedge clk)

   always @(posedge read) if (TRACE) $display("am9513: read cd_n %b; dout %x din %x (mm13=%b)", CD_n, bus_out, data_in, mm[13]);
   always @(posedge write) if (TRACE) $display("am9513: write cd_n %b; dout %x din %x (mm13=%b)", CD_n, bus_out, data_in, mm[13]);
				    
   assign ctr_mode_group = ctr_mode[group];
   assign ctr_load_group = ctr_load[group];
   assign ctr_hold_group = ctr_hold[group];
   
   assign ctr_mode1 = ctr_mode[1];
   assign ctr_mode2 = ctr_mode[2];
   assign ctr_mode3 = ctr_mode[3];
   assign ctr_mode4 = ctr_mode[4];
   assign ctr_mode5 = ctr_mode[5];
   
endmodule

