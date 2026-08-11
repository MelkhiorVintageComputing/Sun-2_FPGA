//
// // Partial implementation of AMD 9513 timer module
//

`define SPLIT_DATA_BUS

// TRACE turns on a per-access register trace. It is very chatty -- it
// dominates run time on a full boot -- so it is off unless asked for.
module ttl_am9513 #(parameter TRACE = 0) (
		   input CLK, // bus-side clock; the real chip has no such pin
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

   // Declared here rather than with armed_bits below: the OUT assignments
   // just underneath use it, and xvlog rejects use-before-declaration.
   reg [7:0]  output_bits;

   // The counter outputs.  output_bits[n] is set when counter n reaches its
   // terminal count and cleared by a CLEAR OUTPUT command -- a level, not a
   // pulse, which is what the boot monitor expects: its NMI handler starts
   // with "movw #CLK_CLEAR+TIMER_NMI, TIMER_BASE+clk_cmd | Reset interrupt"
   // (mon/kernel/trap.s) and only then counts the tick.
   //
   // These used to come from a separate `out' register that nothing ever
   // assigned, so every OUT pin was stuck low and no timer interrupt could
   // reach the CPU.  Counter 1 drives level 7, the NMI that advances
   // g_nmiclock, so nothing that waits on wall-clock time could ever finish.
   assign OUT5 = output_bits[5];
   assign OUT4 = output_bits[4];
   assign OUT3 = output_bits[3];
   assign OUT2 = output_bits[2];
   assign OUT1 = output_bits[1];

   assign clk = CLK;
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
		    
   assign status_out = { 2'b11, output_bits[5], output_bits[4], output_bits[3], output_bits[2], output_bits[1], byteptr };

   wire [4:0] decode1;
   wire [2:0] decode2;
   wire [2:0] bitnum;
   
   assign decode1 = { data_in[7], data_in[6], data_in[5], data_in[4], data_in[3] };
   assign decode2 = { data_in[7], data_in[6], data_in[5] };
   assign bitnum = { data_in[2], data_in[1], data_in[0] };

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
   
   // The frequency scaler.  On the real chip F1 is the X1/X2 crystal
   // oscillator -- 4.9152 MHz on a Sun-2, the same clock the SCCs get -- and
   // F2..F5 are each a further divide by 16.  Here the register interface runs
   // on the bus clock, so X2 arrives as an ordinary (slower) input and F1
   // becomes a one-cycle enable at each of its rising edges.  That is exact as
   // long as the bus clock is more than twice the oscillator: at 12.5 MHz the
   // 101.7 ns half-period is longer than the 80 ns sample period, so no edge
   // can be missed.
   reg 	      x2_d;
   wire       f1_tick;
   assign f1_tick = X2 & ~x2_d;

   reg [3:0]  presc2, presc3, presc4, presc5;
   wire [5:1] f_tick;
   assign f_tick[1] = f1_tick;
   assign f_tick[2] = f_tick[1] & (presc2 == 4'hf);
   assign f_tick[3] = f_tick[2] & (presc3 == 4'hf);
   assign f_tick[4] = f_tick[3] & (presc4 == 4'hf);
   assign f_tick[5] = f_tick[4] & (presc5 == 4'hf);

   always @(posedge clk)
     if (~reset_n)
       begin
	  x2_d   <= 1'b0;
	  presc2 <= 4'h0; presc3 <= 4'h0; presc4 <= 4'h0; presc5 <= 4'h0;
       end
     else
       begin
	  x2_d <= X2;
	  if (f_tick[1]) presc2 <= presc2 + 4'b1;
	  if (f_tick[2]) presc3 <= presc3 + 4'b1;
	  if (f_tick[3]) presc4 <= presc4 + 4'b1;
	  if (f_tick[4]) presc5 <= presc5 + 4'b1;
       end

   // Counter mode register bits 11-8 select the count source: 0xB..0xF are
   // F1..F5.  0x0 (TCN-1) and 0x1..0xA (the SRC and GATE pins) are not
   // modelled -- nothing on a Sun-2 drives those pins -- and a counter that
   // selects one simply does not count.  The boot monitor uses only F1
   // (CLKM_DIV_BY_1 = 0x0B00) and F2 (CLKM_DIV_BY_16 = 0x0C00).
   // Value landing in a counter register on a data write.  Master mode bit 13
   // is the data bus width, and the boot monitor sets it to 16 with CLK_16BIT
   // before touching anything else -- in that mode one access carries the whole
   // register.  Only in 8-bit mode does the byte pointer steer half at a time.
   //
   // This used to be byte-at-a-time unconditionally, so a 16-bit write stored
   // just the low byte -- and stored it in the *high* half whenever the byte
   // pointer happened to be set.  The monitor's NMI timer mode word 0x0C22
   // (CLKM_DIV_BY_16 + CLKM_REPEAT + CLKM_TOGGLE) became 0x2200, whose source
   // select field reads as SRC2 -- an input pin nothing drives.  The counter
   // was armed and simply never counted, so the NMI clock never ticked.
   function [15:0] wr_val;
      input [15:0] old;
      begin
	 if (mm[13])       wr_val = data_in;
	 else if (byteptr) wr_val = { data_in[7:0], old[7:0] };
	 else              wr_val = { old[15:8], data_in[7:0] };
      end
   endfunction

   function src_tick;
      input [15:0] mode;
      begin
	 case (mode[11:8])
	   4'hb:    src_tick = f_tick[1];
	   4'hc:    src_tick = f_tick[2];
	   4'hd:    src_tick = f_tick[3];
	   4'he:    src_tick = f_tick[4];
	   4'hf:    src_tick = f_tick[5];
	   default: src_tick = 1'b0;
	 endcase
      end
   endfunction

   always @(posedge clk) begin
     if (~reset_n) begin
	for (i = 1; i <= 5; i = i + 1)
	  begin
	     ctr_mode[i] <= 0;
	     ctr_load[i] <= 0;
	     ctr_hold[i] <= 0;
	     ctr_cntr[i] <= 0;
	  end
	ctr_mode[1] <= 16'h0b00; // CLKM_DEFAULT: the monitor reads this back to
				 // tell a power-up from a warm reset
	data_out <= 0;
	cmd <= 0;
	// These had no reset at all, so every OUT pin and every armed flag
	// started as X and stayed X until software happened to write them.
	armed_bits <= 6'h0;
	output_bits <= 8'h0;
	mm <= 16'h0;
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
		       ctr_mode[group] <= wr_val(ctr_mode_group);
		       if (TRACE) $display("am9513: ctr_mode[%d] <- %x", group, wr_val(ctr_mode_group));
		    end

		    2'b01: begin
		       ctr_load[group] <= wr_val(ctr_load_group);
		       if (TRACE) $display("am9513: ctr_load[%d] <- %x", group, wr_val(ctr_load_group));
		    end

		    2'b10: begin
		       ctr_hold[group] <= wr_val(ctr_hold_group);
		       if (TRACE) $display("am9513: ctr_hold[%d] <- %x", group, wr_val(ctr_hold_group));
		    end
		  endcase

		  // In 16-bit mode the whole register moved, so step the element
		  // pointer and leave the byte pointer alone.
		  if (mm[13])
		    data_ptr <= { group, element + 2'b1, 1'b0 };
		  else
		    data_ptr <= { group, {element, byteptr} + 3'b1 };
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
     // The counters.  Each advances only on a tick of its selected source.
     //
     // Mode register bits, from the Am9513 data sheet -- and these were wrong
     // here before, which is why the timer never behaved:
     //
     //   11-8  count source (see src_tick above)
     //      6  reload source        (not modelled: always the Load register)
     //      5  repetition  1 = reload and carry on, 0 = one shot then disarm
     //      3  direction   1 = up, 0 = down
     //    2-0  output control: 001 active-high TC pulse, 010 TC toggled
     //
     // The boot monitor programs CLKM_REPEAT (bit 5) + CLKM_TOGGLE (bits 2-0
     // = 010) and counts down.  Its NMI handler clears the output by hand
     // after each interrupt -- see the comment in mon/h/sunmon.h -- so the
     // toggle produces one interrupt per terminal count rather than a square
     // wave.

	if (armed_bits[1] & src_tick(ctr_mode1))
	  begin
	     if (ctr_mode1[3])
	       ctr_cntr[1] <= ctr_cntr[1] + 16'b1;
	     else
	       ctr_cntr[1] <= ctr_cntr[1] - 16'b1;

	     if (ctr_cntr[1] == 16'b0)
	       begin
		  if (ctr_mode1[5])
		    ctr_cntr[1] <= ctr_load[1];
		  else
		    armed_bits[1] <= 1'b0;

		  case (ctr_mode1[2:0])
		    3'b001, 3'b101: output_bits[1] <= 1'b1;
		    3'b010:         output_bits[1] <= ~output_bits[1];
		    default:        ;
		  endcase

		  if (TRACE) $display("am9513: counter 1 terminal count, output now %b",
				      ctr_mode1[2:0] == 3'b010 ? ~output_bits[1] : 1'b1);
	       end
	  end

	if (armed_bits[2] & src_tick(ctr_mode2))
	  begin
	     if (ctr_mode2[3])
	       ctr_cntr[2] <= ctr_cntr[2] + 16'b1;
	     else
	       ctr_cntr[2] <= ctr_cntr[2] - 16'b1;

	     if (ctr_cntr[2] == 16'b0)
	       begin
		  if (ctr_mode2[5])
		    ctr_cntr[2] <= ctr_load[2];
		  else
		    armed_bits[2] <= 1'b0;

		  case (ctr_mode2[2:0])
		    3'b001, 3'b101: output_bits[2] <= 1'b1;
		    3'b010:         output_bits[2] <= ~output_bits[2];
		    default:        ;
		  endcase

		  if (TRACE) $display("am9513: counter 2 terminal count, output now %b",
				      ctr_mode2[2:0] == 3'b010 ? ~output_bits[2] : 1'b1);
	       end
	  end

	if (armed_bits[3] & src_tick(ctr_mode3))
	  begin
	     if (ctr_mode3[3])
	       ctr_cntr[3] <= ctr_cntr[3] + 16'b1;
	     else
	       ctr_cntr[3] <= ctr_cntr[3] - 16'b1;

	     if (ctr_cntr[3] == 16'b0)
	       begin
		  if (ctr_mode3[5])
		    ctr_cntr[3] <= ctr_load[3];
		  else
		    armed_bits[3] <= 1'b0;

		  case (ctr_mode3[2:0])
		    3'b001, 3'b101: output_bits[3] <= 1'b1;
		    3'b010:         output_bits[3] <= ~output_bits[3];
		    default:        ;
		  endcase

		  if (TRACE) $display("am9513: counter 3 terminal count, output now %b",
				      ctr_mode3[2:0] == 3'b010 ? ~output_bits[3] : 1'b1);
	       end
	  end

	if (armed_bits[4] & src_tick(ctr_mode4))
	  begin
	     if (ctr_mode4[3])
	       ctr_cntr[4] <= ctr_cntr[4] + 16'b1;
	     else
	       ctr_cntr[4] <= ctr_cntr[4] - 16'b1;

	     if (ctr_cntr[4] == 16'b0)
	       begin
		  if (ctr_mode4[5])
		    ctr_cntr[4] <= ctr_load[4];
		  else
		    armed_bits[4] <= 1'b0;

		  case (ctr_mode4[2:0])
		    3'b001, 3'b101: output_bits[4] <= 1'b1;
		    3'b010:         output_bits[4] <= ~output_bits[4];
		    default:        ;
		  endcase

		  if (TRACE) $display("am9513: counter 4 terminal count, output now %b",
				      ctr_mode4[2:0] == 3'b010 ? ~output_bits[4] : 1'b1);
	       end
	  end

	if (armed_bits[5] & src_tick(ctr_mode5))
	  begin
	     if (ctr_mode5[3])
	       ctr_cntr[5] <= ctr_cntr[5] + 16'b1;
	     else
	       ctr_cntr[5] <= ctr_cntr[5] - 16'b1;

	     if (ctr_cntr[5] == 16'b0)
	       begin
		  if (ctr_mode5[5])
		    ctr_cntr[5] <= ctr_load[5];
		  else
		    armed_bits[5] <= 1'b0;

		  case (ctr_mode5[2:0])
		    3'b001, 3'b101: output_bits[5] <= 1'b1;
		    3'b010:         output_bits[5] <= ~output_bits[5];
		    default:        ;
		  endcase

		  if (TRACE) $display("am9513: counter 5 terminal count, output now %b",
				      ctr_mode5[2:0] == 3'b010 ? ~output_bits[5] : 1'b1);
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

