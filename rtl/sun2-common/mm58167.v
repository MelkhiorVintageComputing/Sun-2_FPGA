`timescale 1ns / 1ps

//
// National Semiconductor MM58167 microprocessor real time clock.
//
// The Sun-2/120's time-of-day chip, on-board I/O page 7.  Architecture Manual
// 8.2 lists it for Machine Type 1 as "[0x003800] 7 REAL-TIME CLOCK, 4..8 wait
// states"; Machine Type 2 has "[0x7F3800] Reserved" instead and no clock at
// all, which is why this is instantiated only on the MultiBus machine.  Manual
// 6.11: "The Real-Time Clock maintains time of day and a calendar. A battery
// powers the clock when the main power is off. ... addressed as 32 byte
// locations.  Initialization: none.  Interrupts: none."  The interrupt pin is
// not wired on a Sun-2, so the interrupt registers here are storage and a
// status latch and drive nothing.
//
// This is a software-compatible replica, not a gate-level one.  What that has
// to mean is set by the two drivers that exist, and both of them check things a
// naive "32 bytes of RAM" model gets wrong:
//
//   SunOS 4.0.3, sys/sundev/tod.c todprobe():
//       if ((m1 = peekc(&t->tod_counter[TOD_MSEC].val)) == -1) return (0);
//       if (t->tod_status <= 1 && (m1&0xF) == 0) {
//               m1 = t->tod_counter[TOD_MSEC].val;
//               DELAY(2000);
//               if (m1 != t->tod_counter[TOD_MSEC].val) {
//     -- the read must not bus error, the status register's bits 1..7 must
//     read zero, register 0's *low nibble* must read zero, and register 0 must
//     have changed within 2 ms.  A frozen counter fails this probe.
//
//   NetBSD 2.0, dev/ic/mm58167.c mm58167_gettime():
//       } while ((mm58167_read(sc, mm58167_status) & 1) == 0);
//     -- that loop exits only when the rollover bit reads ONE.  It is inverted
//     with respect to its own comment ("until we get a coherent read ... status
//     stays zero") and to the datasheet, and it means a status bit that never
//     sets hangs NetBSD at boot.  SunOS's todget() wants the opposite: it
//     retries while the bit is set and gives up after 100 tries with "TOD chip
//     has gone berserk".
//
// Both are satisfied by reading the status bit as "has a 1 kHz tick happened
// since you last read address 14H" -- set every millisecond, cleared by the
// read, returning the pre-clear value.  SunOS's read pass is a few microseconds
// and sees it clear; NetBSD's loop cannot wait more than a millisecond.
//
// Register map, datasheet Table III.  The Sun-2 wires the chip on every *other*
// byte -- sys/sundev/todreg.h is `struct { u_char val; u_char :8; }' throughout
// and NetBSD's sun2/tod.h has STATUS 40, GO 42, BANK_SZ 48 -- so datasheet
// address N is at byte offset 2N and `addr' here is P_A[5:1].
//
//   00      counter, milliseconds        BCD digit in D4..D7, D0..D3 ALWAYS 0
//   01      counter, hundredths (D0..D3) and tenths (D4..D7) of seconds
//   02..04  counter, seconds / minutes / hours
//   05..07  counter, day of week / day of month / month
//   08..0F  RAM, same order; 56 bits, not 64 -- Table II has no RAM for the
//           low nibble of 08 or the high nibble of 0D
//   10      interrupt status, read only, read clears
//   11      interrupt control, write only
//   12      counters reset      13      RAM reset
//   14      status bit (rollover) on D0, D1..D7 zero, read clears
//   15      GO command          16      standby interrupt enable
//   1F      test mode -- not implemented, see below
//
// Not implemented, deliberately: the POWER DOWN pin (no such signal here), and
// Test Mode at 1F, which the datasheet describes as a *held* state ("The chip
// select and write lines must be low and the address must be held at 1FH")
// rather than a write strobe.  Nothing addresses it -- Sun's todreg.h even puts
// tod_test at the wrong offset, 17H, with a "/* test mode - ??? */" comment, so
// on a Sun-2 the real chip never enters it either.
//
// The chip has no year register and does not know about leap years -- the
// datasheet's feature list says "Four-year calendar (no leap year)".  todreg.h
// is blunt about what that is worth: "This brain damaged chip insists on
// keeping the time in MM/DD HH:MM:SS format, even though it doesn't know about
// leap years and Feb. 29, thus making it nearly worthless. ... We always load
// the chip with the UNIX time modulo SECDAY."  Day-of-month rollover here uses
// the ordinary month lengths with February always 28.
//
module mm58167
  #(
    // What the counters hold at configuration.  A real chip has a battery; an
    // FPGA has to start somewhere.  Plain decimals, converted to BCD at
    // elaboration, because a value has to survive -verilog_define and 8'hXX
    // does not.  The default is fixed rather than build-dependent so that a
    // simulation run is reproducible; synthesis passes the build date.
    parameter INIT_MON  = 1,
    parameter INIT_DAY  = 1,
    parameter INIT_WDAY = 1,
    parameter INIT_HOUR = 0,
    parameter INIT_MIN  = 0,
    parameter INIT_SEC  = 0
    )
   (input            CLK,       // bus-side clock; the real chip has no such pin
    input 	     reset_n,   // por_reset only -- a battery-backed clock is
			        // not disturbed by a button or the watchdog
    input [7:0]      DIN,
    output reg [7:0] DOUT,
    input [4:0]      addr,      // P_A[5:1]: datasheet address, byte offset / 2
    input 	     CS_n,
    input 	     RD_n,
    input 	     WR_n,
    input 	     X2         // the 4.9152 MHz crystal, shared with the SCCs
    );

   // ------------------------------------------------------------------
   // Timebase
   // ------------------------------------------------------------------
   //
   // No clock domain crossing, for the same reason ttl_am9513.v has none: the
   // register interface runs on the bus clock and the crystal arrives as an
   // ordinary slower input, edge-detected into a one-cycle enable.  That is
   // exact as long as the bus clock is more than twice the oscillator, and
   // 12.5 MHz -- the slowest CPU this board builds -- is 2.54x 4.9152 MHz.
   //
   // 4915200 / 150 = 32768 exactly, the crystal the real chip wants.  The
   // board's MMCM actually makes 4.915170 MHz (615.625 / 125.25), so the tick
   // is 6.2 ppm slow, about half a second a day -- the same error the SCC's
   // baud rate already carries, and well inside a watch crystal's tolerance.
   // Synchronised, for the reason ttl_am9513.v now carries at length: X2 comes
   // from mmcm_b and this runs on cpu_clk from mmcm_a, the two are in
   // different asynchronous groups in the XDC, and using the raw X2 in a
   // combinational term beside its own sampling flop puts an unsynchronised
   // signal into the counter enables.  That cost the Am9513 a level 5 clock
   // running at 5.6 Hz instead of 100 on a board where simulation was clean.
   // The sampling-rate argument below is still what makes two flops enough.
   (* ASYNC_REG = "TRUE" *) reg x2_s1, x2_s2;
   reg 		     x2_d;
   wire 	     f_tick = x2_s2 & ~x2_d;

   reg [7:0] 	     div150;
   wire 	     tick32k = f_tick & (div150 == 8'd149);

   // Datasheet Figure 7 divides the 32768 Hz crystal by 32.768 to get the 1 kHz
   // that clocks the milliseconds digit -- a non-integer ratio.  An accumulator
   // gives it exactly: 1000 ms-ticks for every 32768 crystal ticks, with no
   // long-term error and at worst one crystal period of jitter.
   reg [15:0] 	     acc;
   wire 	     ms_tick = tick32k & (acc >= 16'd31768); // acc+1000 >= 32768

   // ------------------------------------------------------------------
   // The counter chain, one BCD digit per register field
   // ------------------------------------------------------------------
   reg [3:0] 	     r_ms;                 // 00 D4..D7, milliseconds 0..9
   reg [3:0] 	     r_hun, r_ten;         // 01 D0..D3 / D4..D7
   reg [3:0] 	     r_sec_u;  reg [2:0] r_sec_t;
   reg [3:0] 	     r_min_u;  reg [2:0] r_min_t;
   reg [3:0] 	     r_hour_u; reg [1:0] r_hour_t;
   reg [2:0] 	     r_wday;               // 1..7
   reg [3:0] 	     r_day_u;  reg [1:0] r_day_t;
   reg [3:0] 	     r_mon_u;  reg       r_mon_t;

   reg [7:0] 	     ram[0:7];
   reg [7:0] 	     r_isr, r_icr;
   reg 		     r_status;
   reg 		     r_standby;

   // Elaboration-time decimal -> BCD.
   localparam [7:0]  BCD_MON  = ((INIT_MON  / 10) << 4) | (INIT_MON  % 10);
   localparam [7:0]  BCD_DAY  = ((INIT_DAY  / 10) << 4) | (INIT_DAY  % 10);
   localparam [7:0]  BCD_HOUR = ((INIT_HOUR / 10) << 4) | (INIT_HOUR % 10);
   localparam [7:0]  BCD_MIN  = ((INIT_MIN  / 10) << 4) | (INIT_MIN  % 10);
   localparam [7:0]  BCD_SEC  = ((INIT_SEC  / 10) << 4) | (INIT_SEC  % 10);
   localparam [7:0]  BCD_WDAY = INIT_WDAY;

   // How many days this month has.  No leap year, per the datasheet.
   reg [5:0] 	     days_in_month;
   always @(*)
     case ({r_mon_t, r_mon_u})
       5'h02:   days_in_month = 6'h28;                       // February, BCD 28
       5'h04, 5'h06, 5'h09, 5'h11: days_in_month = 6'h30;    // Apr Jun Sep Nov
       default: days_in_month = 6'h31;
     endcase

   // ------------------------------------------------------------------
   // Bus interface
   // ------------------------------------------------------------------
   //
   // Both strobes are edge-detected, and the read one is not optional.  A
   // 68010 cycle holds the data strobes for several bus clocks and sun2_fpga
   // ties CS_n low, so `read' and `write' each stand for a run of clocks.
   // ttl_am9513.v:211-229 records what that cost when only writes were
   // affected -- one write ran the body several times and walked the data
   // pointer, leaving the monitor's NMI at 99 Hz for the life of the project.
   // Here reads have side effects too: 10H and 14H are read-to-clear, and a
   // level would clear them again on every clock of the cycle.
   //
   // The leading edge rather than the trailing one, as there: the 68010 drives
   // data in S3 and asserts the strobes in S4, so data is already valid when
   // the strobe rises and is being released when it falls.
   wire 	     read  = ~RD_n & ~CS_n;
   wire 	     write = ~WR_n & ~CS_n;
   reg 		     read_d, write_d;
   wire 	     read_stb  = read  & ~read_d;
   wire 	     write_stb = write & ~write_d;

   // What a read returns.  Every bit the datasheet calls unused reads as zero
   // (Table I: "Any unused bits are held at a logical zero during a read and
   // ignored during a write") -- including the whole low nibble of register 0,
   // which is what SunOS's todprobe() tests, and bits 1..7 of the status
   // register, which is the other half of the same test.
   reg [7:0] 	     read_data;
   always @(*)
     case (addr)
       5'h00: read_data = {r_ms, 4'h0};
       5'h01: read_data = {r_ten, r_hun};
       5'h02: read_data = {1'b0, r_sec_t, r_sec_u};
       5'h03: read_data = {1'b0, r_min_t, r_min_u};
       5'h04: read_data = {2'b0, r_hour_t, r_hour_u};
       5'h05: read_data = {5'b0, r_wday};
       5'h06: read_data = {2'b0, r_day_t, r_day_u};
       5'h07: read_data = {3'b0, r_mon_t, r_mon_u};
       // RAM.  Table II has no cell for the low nibble of 08 or the high
       // nibble of 0D, so those read as zero.
       5'h08: read_data = {ram[0][7:4], 4'h0};
       5'h09, 5'h0A, 5'h0B, 5'h0C, 5'h0E, 5'h0F:
	      read_data = ram[addr[2:0]];
       5'h0D: read_data = {4'h0, ram[5][3:0]};
       5'h10: read_data = r_isr;
       5'h14: read_data = {7'b0, r_status};
       // 11 write-only, 12/13/15 strobes, 16 write-only, everything else
       // unused.  The datasheet does not say what these return.
       default: read_data = 8'h00;
     endcase

   // The RAM/counter comparator, datasheet page 3: "The data in the RAM can be
   // compared to the real time counter on a digit basis. ... If the two most
   // significant bits of any RAM digit are ones, then this RAM location will
   // always compare.  The unused bits in the real time counter will compare
   // only to zeros in the RAM."  Nothing in either driver uses this.
   function digit_match;
      input [3:0] ramd;
      input [3:0] cntd;
      begin
	 digit_match = (ramd[3:2] == 2'b11) | (ramd == cntd);
      end
   endfunction

   wire compare = digit_match(ram[0][7:4], r_ms)             &
		  digit_match(ram[1][3:0], r_hun)            &
		  digit_match(ram[1][7:4], r_ten)            &
		  digit_match(ram[2][3:0], r_sec_u)          &
		  digit_match(ram[2][7:4], {1'b0, r_sec_t})  &
		  digit_match(ram[3][3:0], r_min_u)          &
		  digit_match(ram[3][7:4], {1'b0, r_min_t})  &
		  digit_match(ram[4][3:0], r_hour_u)         &
		  digit_match(ram[4][7:4], {2'b0, r_hour_t}) &
		  digit_match(ram[5][3:0], {1'b0, r_wday})   &
		  digit_match(ram[6][3:0], r_day_u)          &
		  digit_match(ram[6][7:4], {2'b0, r_day_t})  &
		  digit_match(ram[7][3:0], r_mon_u)          &
		  digit_match(ram[7][7:4], {3'b0, r_mon_t});
   reg 	     compare_d;

   // Carry chain, evaluated at the millisecond tick.
   wire c_ms   = ms_tick   & (r_ms   == 4'd9);
   wire c_hun  = c_ms      & (r_hun  == 4'd9);
   wire c_ten  = c_hun     & (r_ten  == 4'd9);
   wire c_secu = c_ten     & (r_sec_u  == 4'd9);
   wire c_sec  = c_ten     & (r_sec_t == 3'd5) & (r_sec_u == 4'd9);
   wire c_minu = c_sec     & (r_min_u  == 4'd9);
   wire c_min  = c_sec     & (r_min_t == 3'd5) & (r_min_u == 4'd9);
   wire c_houru= c_min     & (r_hour_u == 4'd9);
   wire c_hour = c_min     & (r_hour_t == 2'd2) & (r_hour_u == 4'd3);
   wire c_day  = c_hour    & ({r_day_t, r_day_u} == days_in_month[5:0]);
   wire c_dayu = c_hour    & (r_day_u == 4'd9);
   wire c_mon  = c_day     & ({r_mon_t, r_mon_u} == 5'h12);
   wire c_monu = c_day     & (r_mon_u == 4'd9);

   integer i;

   always @(posedge CLK)
     begin
	// Before the reset arm, so reset still wins.
	x2_s1   <= X2;
	x2_s2   <= x2_s1;
	x2_d    <= x2_s2;
	read_d  <= read;
	write_d <= write;

	if (~reset_n) begin
	   x2_s1    <= 1'b0;
	   x2_s2    <= 1'b0;
	   x2_d     <= 1'b0;
	   read_d   <= 1'b0;
	   write_d  <= 1'b0;
	   div150   <= 8'd0;
	   acc      <= 16'd0;
	   DOUT     <= 8'h00;

	   r_ms     <= 4'd0;
	   r_hun    <= 4'd0;
	   r_ten    <= 4'd0;
	   r_sec_u  <= BCD_SEC[3:0];   r_sec_t  <= BCD_SEC[6:4];
	   r_min_u  <= BCD_MIN[3:0];   r_min_t  <= BCD_MIN[6:4];
	   r_hour_u <= BCD_HOUR[3:0];  r_hour_t <= BCD_HOUR[5:4];
	   r_wday   <= BCD_WDAY[2:0];
	   r_day_u  <= BCD_DAY[3:0];   r_day_t  <= BCD_DAY[5:4];
	   r_mon_u  <= BCD_MON[3:0];   r_mon_t  <= BCD_MON[4];

	   r_isr     <= 8'h00;
	   r_icr     <= 8'h00;
	   r_status  <= 1'b0;
	   r_standby <= 1'b0;
	   compare_d <= 1'b0;
	   for (i = 0; i < 8; i = i + 1) ram[i] <= 8'h00;
	end
	else begin
	   // ---- timebase ----
	   if (f_tick)
	     div150 <= (div150 == 8'd149) ? 8'd0 : div150 + 8'd1;
	   if (tick32k)
	     acc <= (acc >= 16'd31768) ? (acc + 16'd1000 - 16'd32768)
		                       : (acc + 16'd1000);

	   // ---- the counter chain ----
	   if (ms_tick) begin
	      r_ms <= c_ms ? 4'd0 : r_ms + 4'd1;
	      if (c_ms)   r_hun <= c_hun ? 4'd0 : r_hun + 4'd1;
	      if (c_hun)  r_ten <= c_ten ? 4'd0 : r_ten + 4'd1;
	      if (c_ten) begin
		 r_sec_u <= c_secu ? 4'd0 : r_sec_u + 4'd1;
		 if (c_secu) r_sec_t <= c_sec ? 3'd0 : r_sec_t + 3'd1;
	      end
	      if (c_sec) begin
		 r_min_u <= c_minu ? 4'd0 : r_min_u + 4'd1;
		 if (c_minu) r_min_t <= c_min ? 3'd0 : r_min_t + 3'd1;
	      end
	      if (c_min) begin
		 r_hour_u <= (c_houru | c_hour) ? 4'd0 : r_hour_u + 4'd1;
		 if (c_houru | c_hour) r_hour_t <= c_hour ? 2'd0 : r_hour_t + 2'd1;
	      end
	      if (c_hour) begin
		 r_wday  <= (r_wday == 3'd7) ? 3'd1 : r_wday + 3'd1;
		 r_day_u <= c_day ? 4'd1 : (c_dayu ? 4'd0 : r_day_u + 4'd1);
		 if (c_day)       r_day_t <= 2'd0;
		 else if (c_dayu) r_day_t <= r_day_t + 2'd1;
	      end
	      if (c_day) begin
		 r_mon_u <= c_mon ? 4'd1 : (c_monu ? 4'd0 : r_mon_u + 4'd1);
		 if (c_mon)       r_mon_t <= 1'b0;
		 else if (c_monu) r_mon_t <= 1'b1;
	      end

	      // "The status bit is set if this 1 kHz clock occurs during or
	      // after any counter read", i.e. a tick has happened since the
	      // last time software looked.
	      r_status <= 1'b1;

	      // Interrupt status: "the corresponding counter's rollover to its
	      // reset state or the compare becoming valid" (Note 1).
	      if (c_hun)                r_isr[1] <= 1'b1;   // 10 Hz
	      if (c_ten)                r_isr[2] <= 1'b1;   // once per second
	      if (c_sec)                r_isr[3] <= 1'b1;   // once per minute
	      if (c_min)                r_isr[4] <= 1'b1;   // once per hour
	      if (c_hour)               r_isr[5] <= 1'b1;   // once per day
	      if (c_hour & (r_wday == 3'd7)) r_isr[6] <= 1'b1; // once per week
	      if (c_day)                r_isr[7] <= 1'b1;   // once per month
	      compare_d <= compare;
	      if (compare & ~compare_d) r_isr[0] <= 1'b1;
	   end

	   // ---- reads ----
	   //
	   // DOUT is loaded once, at the leading edge, and held for the rest of
	   // the cycle.  That is what makes a read-to-clear register return its
	   // pre-clear value: the CPU latches data at C_S8, several clocks
	   // after the strobe rose, so a combinational read port would hand it
	   // the value from *after* the clear.  It also means a read is a
	   // snapshot rather than something that can ripple mid-cycle.
	   if (read_stb) begin
	      DOUT <= read_data;
	      // "Removing the read will reset the interrupt" (page 3) and "The
	      // trailing edge of the read at address 14H will reset the status
	      // bit" (page 5).  Modelled at the leading edge because DOUT is
	      // already captured above; the software-visible result is the same.
	      if (addr == 5'h10) r_isr    <= 8'h00;
	      if (addr == 5'h14) r_status <= 1'b0;
	   end

	   // ---- writes ----
	   if (write_stb) begin
	      case (addr)
		// Unused bits "ignored during a write": the value written is
		// masked to the digits that exist, so a read back gives what
		// the datasheet says it gives.
		5'h00: r_ms  <= DIN[7:4];
		5'h01: begin r_hun <= DIN[3:0]; r_ten <= DIN[7:4]; end
		5'h02: begin r_sec_u  <= DIN[3:0]; r_sec_t  <= DIN[6:4]; end
		5'h03: begin r_min_u  <= DIN[3:0]; r_min_t  <= DIN[6:4]; end
		5'h04: begin r_hour_u <= DIN[3:0]; r_hour_t <= DIN[5:4]; end
		5'h05: r_wday <= DIN[2:0];
		5'h06: begin r_day_u <= DIN[3:0]; r_day_t <= DIN[5:4]; end
		5'h07: begin r_mon_u <= DIN[3:0]; r_mon_t <= DIN[4];    end

		5'h08: ram[0][7:4] <= DIN[7:4];
		5'h09, 5'h0A, 5'h0B, 5'h0C, 5'h0E, 5'h0F:
		       ram[addr[2:0]] <= DIN;
		5'h0D: ram[5][3:0] <= DIN[3:0];

		5'h11: r_icr <= DIN;

		// "The counters and RAM can be reset by writing all 1's (FF) at
		// address 12H or 13H respectively."  Sun's todreg.h calls these
		// tod_creset/tod_lreset -- "counter reset mask" / "latch reset
		// mask" -- so a set bit clears the corresponding register,
		// which degenerates to the documented FF = reset everything.
		// Nothing in either driver writes them.
		5'h12: begin
		   if (DIN[0]) r_ms <= 4'd0;
		   if (DIN[1]) begin r_hun <= 4'd0; r_ten <= 4'd0; end
		   if (DIN[2]) begin r_sec_u  <= 4'd0; r_sec_t  <= 3'd0; end
		   if (DIN[3]) begin r_min_u  <= 4'd0; r_min_t  <= 3'd0; end
		   if (DIN[4]) begin r_hour_u <= 4'd0; r_hour_t <= 2'd0; end
		   if (DIN[5]) r_wday <= 3'd0;
		   if (DIN[6]) begin r_day_u <= 4'd0; r_day_t <= 2'd0; end
		   if (DIN[7]) begin r_mon_u <= 4'd0; r_mon_t <= 1'b0;  end
		end
		5'h13: for (i = 0; i < 8; i = i + 1)
		  if (DIN[i]) ram[i] <= 8'h00;

		// "A write pulse at address 15H will reset the thousandths,
		// hundredths, tenths, units, and tens of seconds counters. ...
		// If the seconds counter is at a value greater than 39 when the
		// GO is issued, the minute counter will increment".  The data
		// on the bus is ignored.  NetBSD's mm58167_settime() issues
		// this before loading the time.
		5'h15: begin
		   r_ms <= 4'd0; r_hun <= 4'd0; r_ten <= 4'd0;
		   r_sec_u <= 4'd0; r_sec_t <= 3'd0;
		   if ((r_sec_t > 3'd3) || (r_sec_t == 3'd3 && r_sec_u > 4'd9))
		     begin
			// seconds > 39: carry into minutes, with the ordinary
			// ripple onwards.
			if (r_min_u == 4'd9) begin
			   r_min_u <= 4'd0;
			   if (r_min_t == 3'd5) r_min_t <= 3'd0;
			   else                 r_min_t <= r_min_t + 3'd1;
			end
			else r_min_u <= r_min_u + 4'd1;
		     end
		end

		5'h16: r_standby <= DIN[0];
		default: ; // 10 and 14 are read-only, 17..1F unused
	      endcase
	   end
	end
     end

endmodule
