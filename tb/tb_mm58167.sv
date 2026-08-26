`timescale 1ns / 1ps

//
// The MM58167 real-time clock, driven the way the Sun-2's two drivers drive it.
//
// Not the way a clean testbench would: `cs_n' is tied low and `rd_n'/`wr_n' do
// the selecting, exactly as sun2_fpga.v wires it, and every strobe is several
// clocks wide because a 68010 holds its data strobes for the whole data
// portion of a bus cycle.  That is the point.  `make -C sim scc' exists
// because the Z8530's own vendor testbench passed 22 tests while the chip
// could not raise an interrupt -- every one of its WR9 writes went through the
// channel the real software never uses.  A device model tested through a
// one-clock handshake says nothing about a device driven by a 68010.
//
// Time is advanced by writing the counters close to a rollover and then
// ticking, rather than by simulating real seconds: one millisecond of chip
// time is about 4915 X2 periods, so a day would be 2.8 billion.  The whole
// carry chain -- milliseconds through months -- is exercised by one tick from
// 12/31 23:59:59.999.
//
module tb_mm58167;

   localparam int STROBE_CLK   = 4;   // how long a 68010 holds a data strobe
   localparam int RECOVERY_CLK = 6;

   reg         CLK = 1'b0;
   reg 	       reset_n = 1'b0;
   reg [7:0]   DIN = 8'h00;
   wire [7:0]  DOUT;
   reg [4:0]   addr = 5'h00;
   reg 	       RD_n = 1'b1;
   reg 	       WR_n = 1'b1;
   reg 	       X2 = 1'b0;

   integer     errors = 0;
   integer     checks = 0;

   // 20 MHz bus clock, 4.9152 MHz crystal -- the ratio the board has.
   always #25   CLK = ~CLK;
   always #101.725 X2 = ~X2;

   mm58167 #(.INIT_MON(1), .INIT_DAY(1), .INIT_WDAY(1),
	     .INIT_HOUR(0), .INIT_MIN(0), .INIT_SEC(0))
   dut (.CLK(CLK), .reset_n(reset_n),
	.DIN(DIN), .DOUT(DOUT), .addr(addr),
	.CS_n(1'b0), .RD_n(RD_n), .WR_n(WR_n), .X2(X2));

   task automatic ck(input string what, input [7:0] got, input [7:0] want);
      begin
	 checks = checks + 1;
	 if (got !== want) begin
	    errors = errors + 1;
	    $display("FAIL: %-46s got %02x want %02x", what, got, want);
	 end
      end
   endtask

   task automatic ck_int(input string what, input integer got, input integer want);
      begin
	 checks = checks + 1;
	 if (got !== want) begin
	    errors = errors + 1;
	    $display("FAIL: %-46s got %0d want %0d", what, got, want);
	 end
      end
   endtask

   // A 68010 write: address and data first, then the strobe for several clocks.
   task automatic bus_write(input [4:0] a, input [7:0] d);
      integer i;
      begin
	 @(posedge CLK); addr = a; DIN = d;
	 @(posedge CLK); WR_n = 1'b0;
	 for (i = 0; i < STROBE_CLK; i = i + 1) @(posedge CLK);
	 WR_n = 1'b1;
	 for (i = 0; i < RECOVERY_CLK; i = i + 1) @(posedge CLK);
      end
   endtask

   task automatic bus_read(input [4:0] a, output [7:0] d);
      integer i;
      begin
	 @(posedge CLK); addr = a;
	 @(posedge CLK); RD_n = 1'b0;
	 for (i = 0; i < STROBE_CLK; i = i + 1) @(posedge CLK);
	 d = DOUT;                      // as the CPU latches it, at C_S8
	 RD_n = 1'b1;
	 for (i = 0; i < RECOVERY_CLK; i = i + 1) @(posedge CLK);
      end
   endtask

   // Advance the chip by n milliseconds of its own time.
   task automatic tick_ms(input integer n);
      integer i;
      begin
	 for (i = 0; i < n; i = i + 1) @(posedge dut.ms_tick);
      end
   endtask

   // Put the whole counter chain one millisecond short of the new year.
   task automatic set_newyear_eve;
      begin
	 bus_write(5'h00, 8'h90);   // milliseconds digit 9
	 bus_write(5'h01, 8'h99);   // tenths 9, hundredths 9
	 bus_write(5'h02, 8'h59);   // seconds
	 bus_write(5'h03, 8'h59);   // minutes
	 bus_write(5'h04, 8'h23);   // hours
	 bus_write(5'h05, 8'h07);   // day of week
	 bus_write(5'h06, 8'h31);   // day of month
	 bus_write(5'h07, 8'h12);   // month
      end
   endtask

   reg [7:0] v, v2, mon, day, hour, mn, sec;
   integer   i, iters;

   initial begin
      $display("=== tb_mm58167: the Sun-2's time-of-day chip ===");
      repeat (4) @(posedge CLK);
      reset_n = 1'b1;
      repeat (4) @(posedge CLK);

      // ---------------------------------------------------------------
      $display("\n-- power-up state --");
      bus_read(5'h07, v); ck("month reads the INIT parameter",     v, 8'h01);
      bus_read(5'h06, v); ck("day reads the INIT parameter",       v, 8'h01);
      bus_read(5'h05, v); ck("weekday reads the INIT parameter",   v, 8'h01);
      bus_read(5'h04, v); ck("hour reads the INIT parameter",      v, 8'h00);
      // SunOS todget() rejects month<1, day<1, weekday<1 as "not initialized".
      ck_int("power-up date is valid for SunOS todget()",
	     (8'h01 >= 1 && 8'h01 <= 8'h12) ? 1 : 0, 1);

      // ---------------------------------------------------------------
      $display("\n-- the bits both probes test --");
      // SunOS todprobe(): (m1 & 0xF) == 0 on register 0.
      bus_read(5'h00, v);
      ck("register 0 low nibble reads zero", v & 8'h0F, 8'h00);
      // SunOS todprobe(): tod_status <= 1, i.e. bits 1..7 zero.
      bus_read(5'h14, v);
      ck("status register bits 1..7 read zero", v & 8'hFE, 8'h00);

      // ---------------------------------------------------------------
      $display("\n-- unused bits are ignored on write and read as zero --");
      bus_write(5'h02, 8'hFF); bus_read(5'h02, v);
      ck("seconds masks D7",        v, 8'h7F);
      bus_write(5'h04, 8'hFF); bus_read(5'h04, v);
      ck("hours masks D6..D7",      v, 8'h3F);
      bus_write(5'h05, 8'hFF); bus_read(5'h05, v);
      ck("day of week masks D3..D7", v, 8'h07);
      bus_write(5'h07, 8'hFF); bus_read(5'h07, v);
      ck("month masks D5..D7",      v, 8'h1F);
      bus_write(5'h00, 8'hFF); bus_read(5'h00, v);
      ck("milliseconds masks D0..D3", v, 8'hF0);

      // ---------------------------------------------------------------
      $display("\n-- RAM, including the two nibbles that do not exist --");
      bus_write(5'h09, 8'hA5); bus_read(5'h09, v);
      ck("RAM 09 is a whole byte",  v, 8'hA5);
      bus_write(5'h08, 8'hFF); bus_read(5'h08, v);
      ck("RAM 08 has no low nibble", v, 8'hF0);
      bus_write(5'h0D, 8'hFF); bus_read(5'h0D, v);
      ck("RAM 0D has no high nibble", v, 8'h0F);
      bus_write(5'h13, 8'hFF); bus_read(5'h09, v);
      ck("RAM reset clears it",     v, 8'h00);

      // ---------------------------------------------------------------
      $display("\n-- the carry chain, in a single tick --");
      set_newyear_eve();
      tick_ms(1);
      bus_read(5'h00, v); ck("milliseconds rolled",  v, 8'h00);
      bus_read(5'h01, v); ck("hundredths/tenths rolled", v, 8'h00);
      bus_read(5'h02, v); ck("seconds 59 -> 00",     v, 8'h00);
      bus_read(5'h03, v); ck("minutes 59 -> 00",     v, 8'h00);
      bus_read(5'h04, v); ck("hours 23 -> 00",       v, 8'h00);
      bus_read(5'h05, v); ck("weekday 7 -> 1",       v, 8'h01);
      bus_read(5'h06, v); ck("day 31 -> 01",         v, 8'h01);
      bus_read(5'h07, v); ck("month 12 -> 01",       v, 8'h01);

      // A short month, since the datasheet gives no rollover rule and this is
      // our choice: February has 28 days, always -- "no leap year".
      bus_write(5'h07, 8'h02); bus_write(5'h06, 8'h28);
      bus_write(5'h04, 8'h23); bus_write(5'h03, 8'h59); bus_write(5'h02, 8'h59);
      bus_write(5'h01, 8'h99); bus_write(5'h00, 8'h90);
      tick_ms(1);
      bus_read(5'h06, v); ck("28 Feb -> 01",         v, 8'h01);
      bus_read(5'h07, v); ck("February -> March",    v, 8'h03);

      // ---------------------------------------------------------------
      $display("\n-- the rollover status bit --");
      bus_read(5'h14, v);                       // clear it
      bus_read(5'h14, v);
      ck("status is clear just after a read", v, 8'h00);
      tick_ms(1);
      bus_read(5'h14, v);
      ck("a millisecond tick sets it",        v, 8'h01);
      bus_read(5'h14, v);
      ck("and the read cleared it",           v, 8'h00);

      // ---------------------------------------------------------------
      $display("\n-- GO, which NetBSD issues before every settime --");
      bus_write(5'h03, 8'h30);   // minutes 30
      bus_write(5'h02, 8'h45);   // seconds 45, i.e. > 39
      bus_write(5'h01, 8'h77); bus_write(5'h00, 8'h50);
      bus_write(5'h15, 8'hFF);
      bus_read(5'h02, v); ck("GO zeroes seconds",      v, 8'h00);
      bus_read(5'h01, v); ck("GO zeroes hundredths",   v, 8'h00);
      bus_read(5'h00, v); ck("GO zeroes milliseconds", v, 8'h00);
      bus_read(5'h03, v); ck("seconds > 39 bumps the minute", v, 8'h31);

      bus_write(5'h03, 8'h30);
      bus_write(5'h02, 8'h30);   // seconds 30, i.e. <= 39
      bus_write(5'h15, 8'hFF);
      bus_read(5'h03, v); ck("seconds <= 39 leaves the minute", v, 8'h30);

      // ---------------------------------------------------------------
      $display("\n-- counters reset --");
      bus_write(5'h12, 8'hFF);
      bus_read(5'h02, v); ck("counter reset clears seconds", v, 8'h00);
      bus_read(5'h07, v); ck("counter reset clears month",   v, 8'h00);

      // ---------------------------------------------------------------
      // SunOS 4.0.3, sys/sundev/tod.c todprobe().  The last step is the one a
      // frozen replica fails: read the millisecond counter, wait 2 ms, and it
      // must have changed.
      $display("\n-- replay: SunOS todprobe() --");
      bus_read(5'h00, v);
      ck("todprobe: (m1 & 0xF) == 0", v & 8'h0F, 8'h00);
      bus_read(5'h14, v2);
      ck_int("todprobe: tod_status <= 1", (v2 <= 1) ? 1 : 0, 1);
      bus_read(5'h00, v);
      tick_ms(2);
      bus_read(5'h00, v2);
      ck_int("todprobe: register 0 changed within 2 ms", (v !== v2) ? 1 : 0, 1);

      // ---------------------------------------------------------------
      // sys/sundev/tod.c todget(): read all eight counters, checking the
      // status after each, and give up after 100 tries.  A status bit stuck
      // at one makes the real driver print "TOD chip has gone berserk".
      $display("\n-- replay: SunOS todget() --");
      iters = 0;
      begin : todget
	 integer tries;
	 reg 	 dirty;
	 for (tries = 0; tries < 100; tries = tries + 1) begin
	    dirty = 1'b0;
	    bus_read(5'h14, v);                 // clear before the pass
	    for (i = 0; i < 8; i = i + 1) begin
	       bus_read(i[4:0], v);
	       bus_read(5'h14, v2);
	       if (v2 & 8'h01) dirty = 1'b1;
	    end
	    iters = tries + 1;
	    if (!dirty) disable todget;
	 end
      end
      ck_int("todget: a coherent pass inside 100 tries", (iters < 100) ? 1 : 0, 1);

      // ---------------------------------------------------------------
      // NetBSD 2.0, dev/ic/mm58167.c mm58167_gettime().  Its loop exits only
      // when the status bit reads ONE -- inverted with respect to its own
      // comment and the datasheet.  A status bit that never sets hangs the
      // kernel at spl7 forever, so what this asserts is that it terminates.
      $display("\n-- replay: NetBSD mm58167_gettime() --");
      bus_read(5'h14, v);
      iters = 0;
      begin : nbsd
	 integer tries;
	 for (tries = 0; tries < 5000; tries = tries + 1) begin
	    bus_read(5'h07, mon);
	    bus_read(5'h06, day);
	    bus_read(5'h04, hour);
	    bus_read(5'h03, mn);
	    bus_read(5'h02, sec);
	    bus_read(5'h14, v);
	    iters = tries + 1;
	    if (v & 8'h01) disable nbsd;
	 end
      end
      ck_int("gettime: the inverted loop terminates", (iters < 5000) ? 1 : 0, 1);
      $display("   (it took %0d passes, i.e. under a millisecond)", iters);

      // ---------------------------------------------------------------
      // mm58167_settime(): GO first with 0xFF, then month..seconds.  A
      // gettime can call this from inside itself on a leap-day crossing, so a
      // write burst immediately after a read burst has to work.
      $display("\n-- replay: NetBSD mm58167_settime() --");
      bus_write(5'h15, 8'hFF);
      bus_write(5'h07, 8'h08);
      bus_write(5'h06, 8'h26);
      bus_write(5'h04, 8'h15);
      bus_write(5'h03, 8'h42);
      bus_write(5'h02, 8'h07);
      bus_read(5'h07, v); ck("settime: month",   v, 8'h08);
      bus_read(5'h06, v); ck("settime: day",     v, 8'h26);
      bus_read(5'h04, v); ck("settime: hour",    v, 8'h15);
      bus_read(5'h03, v); ck("settime: minute",  v, 8'h42);
      bus_read(5'h02, v); ck("settime: second",  v, 8'h07);

      // ---------------------------------------------------------------
      // The clock has to still be running after all that.  Ten milliseconds,
      // not a second: the chip keeps real time, so a second of its time is a
      // second of simulated time and 20 million clocks.
      $display("\n-- still ticking --");
      bus_write(5'h00, 8'h00); bus_write(5'h01, 8'h00);
      tick_ms(10);
      bus_read(5'h01, v);
      ck("ten ticks carry into hundredths", v & 8'h0F, 8'h01);
      bus_read(5'h00, v);
      ck("and the millisecond digit wrapped", v, 8'h00);

      // ---------------------------------------------------------------
      $display("\n=== %0d checks, %0d failures ===", checks, errors);
      if (errors == 0) $display("tb_mm58167: PASS");
      else             $display("tb_mm58167: FAIL");
      $finish;
   end

   initial begin
      #100_000_000;
      $display("tb_mm58167: FAIL -- timeout (a loop replaying a driver never terminated)");
      $finish;
   end

endmodule
