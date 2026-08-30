`timescale 1ns / 1ps
//
// sun2_trace: does the trigger fire where it should, and does the circular
// buffer unwrap to the sequence that went in?
//
// Both halves matter and only one of them is obvious.  A recorder that
// triggers correctly and hands back its samples rotated is worse than no
// recorder, because the capture still looks plausible -- this project has
// already read four versions of a memory checker that reported confident
// nonsense, and the thing that caught each was a known-good expectation.  So
// every sample carries a serial number in its low bits and the test checks the
// whole sequence, not just the trigger.
//
module tb_sun2_trace;

   localparam WIDTH = 118, DL2 = 4, DEPTH = 1 << DL2, POST = 8;
   // Samples before the trigger sample = DEPTH - POST - 1.
   localparam PRE = DEPTH - POST - 1;
   localparam [12:0] PAGE = 13'h1DC5;
   localparam [2:0]  TRIG_FC = 3'd5;

   reg clk = 0, rst = 1;
   always #5 clk = ~clk;

   reg  [WIDTH-1:0] bus;
   reg  [DL2-1:0]   rd_addr = 0;
   wire [WIDTH-1:0] rd_data;
   wire [DL2-1:0]   wr_ptr;
   wire             triggered, done;

   // The DVMA qualifier, off for the cases below and exercised on its own
   // at the end: with it set, a cycle on the right page and function code
   // must still be ignored unless an alternate master is driving.
   logic trig_dvma_en = 1'b0;
   logic trig_phys_en = 1'b0;

   sun2_trace #(.WIDTH(WIDTH), .DEPTH_LOG2(DL2), .POST(POST))
   dut (.clk(clk), .rst(rst), .dbg_bus(bus),
	.trig_page(PAGE), .trig_fc(TRIG_FC), .trig_fc_en(1'b1),
       .trig_dvma_en(trig_dvma_en),
       .trig_phys_en(trig_phys_en),
	.arm(1'b1), .rd_addr(rd_addr),
	.rd_data(rd_data), .wr_ptr(wr_ptr), .triggered(triggered), .done(done));

   integer checks = 0, fails = 0;
   task ck(input cond, input [511:0] name);
      begin
	 checks = checks + 1;
	 if (!cond) begin fails = fails + 1; $display("FAIL: %0s", name); end
	 else $display("  ok: %0s", name);
      end
   endtask

   // A dbg_bus word: AS_n at 47, A[23:11] at 73:61, a serial number in 15:0.
   function [WIDTH-1:0] mk(input as_n, input [12:0] page, input [15:0] serial);
      begin mk = mkfc(as_n, page, TRIG_FC, serial); end
   endfunction

   function [WIDTH-1:0] mkfc(input as_n, input [12:0] page, input [2:0] fc,
			     input [15:0] serial);
      begin
	 mkfc = {WIDTH{1'b0}};
	 mkfc[47]    = as_n;
	 mkfc[73:61] = page;
	 mkfc[50:48] = fc;
	 mkfc[15:0]  = serial;
      end
   endfunction

   // The same, with the page map's output set explicitly.  Note this lands on
   // top of the serial number's upper bits, which only matters here: nothing
   // else in this test uses the physical trigger.
   function [WIDTH-1:0] mkpp(input as_n, input [12:0] vpage, input [11:0] pp);
      begin
	 mkpp = mkfc(as_n, vpage, TRIG_FC, 16'd0);
	 mkpp[17:6] = pp;
      end
   endfunction

   // The same, plus dbg_dvma_active -- bit 101, which is the one thing
   // sun2_fpga cannot reconstruct from the bus and therefore packs explicitly.
   function [WIDTH-1:0] mkdv(input as_n, input [12:0] page, input [15:0] serial);
      begin
	 mkdv = mkfc(as_n, page, TRIG_FC, serial);
	 mkdv[101] = 1'b1;
      end
   endfunction

   integer i, idx, n;
   reg [15:0] got, want;
   integer trig_at;

   // What was driven, in order.  Recording it beats recomputing it: the first
   // version of this test derived the expected serials in closed form, got the
   // arithmetic wrong in two places, and reported seventeen failures against a
   // recorder that was very nearly right.  An expectation you can get wrong
   // independently of the thing under test is not much of an expectation.
   reg [15:0] drove [0:255];
   reg        was_done;

   // Driven on the falling edge, sampled on the rising one.  Assigning `bus'
   // immediately after @(posedge clk) puts the assignment at the same
   // simulation time as the edge the DUT samples on, which is a race: the
   // recorder saw each value one clock later than this task recorded it, and
   // the capture then looked shifted by one when it was exactly right.  A
   // testbench that changes stimulus on the active edge is testing the
   // scheduler.
   task drive(input as_n, input [12:0] page, input [15:0] serial);
      begin
	 @(negedge clk);
	 bus = mk(as_n, page, serial);
	 // Whether this sample gets written is decided by done_q *before* the
	 // edge, not after it: the last write and the setting of done happen on
	 // the same edge, so reading done afterwards drops exactly one sample --
	 // the most interesting one.
	 was_done = done;
	 @(posedge clk);
	 // Settle before anyone reads triggered/done.  They are assigned
	 // non-blockingly on this edge, so reading them in the same instant is
	 // the same race in miniature -- and it costs no clock, because the
	 // next drive waits for the falling edge.
	 #1;
	 if (!was_done) begin drove[n] = serial; n = n + 1; end
      end
   endtask

   initial begin
      n = 0;
      bus = mk(1'b1, 13'h0000, 16'd0);
      repeat (4) @(posedge clk);
      rst = 0;
      @(posedge clk);

      trig_at = 100;
      for (i = 0; i < 40; i = i + 1) drive(1'b0, 13'h0123, i[15:0]);

      // The right page but AS *high* must not trigger -- the bus is idle and
      // the address lines mean nothing.  This is the check a bare address
      // compare would fail.
      drive(1'b1, PAGE, 16'd99);
      ck(!triggered, "an idle bus on the trigger page does not trigger");

      // The right page and a live bus, but the wrong function code.  This is
      // the case that actually bit: the PROM's page-map write lands on the
      // device page's own address in control space, so without this qualifier
      // the trigger fires on the map setup and never sees the probe.
      begin
	 @(negedge clk);
	 bus = mkfc(1'b0, PAGE, 3'd3, 16'd98);
	 was_done = done;
	 @(posedge clk); #1;
	 if (!was_done) begin drove[n] = 16'd98; n = n + 1; end
      end
      ck(!triggered, "the right page at the wrong FC does not trigger");

      drive(1'b0, PAGE, trig_at[15:0]);
      ck(triggered, "AS low on the trigger page and FC triggers");

      for (i = 0; i < 40; i = i + 1) drive(1'b0, 13'h0456, 16'd200 + i[15:0]);
      ck(done, "capture stops after POST more samples");
      ck(n == 40 + 1 + 1 + 1 + POST, "exactly POST samples written after the trigger");

      // Nothing may be written after done.
      for (i = 0; i < 20; i = i + 1) drive(1'b0, 13'h1FFF, 16'hDEAD);

      // Unwrap: the oldest sample is the one wr_ptr points at.
      for (i = 0; i < DEPTH; i = i + 1) begin
	 idx = (wr_ptr + i) % DEPTH;
	 rd_addr = idx[DL2-1:0];
	 @(posedge clk); @(posedge clk);
	 got  = rd_data[15:0];
	 want = drove[n - DEPTH + i];
	 if (got !== want)
	   $display("     sample %0d: got %0d want %0d", i, got, want);
	 ck(got === want, "sample in order");
	 if (i == PRE) ck(got == trig_at, "the trigger sample sits at DEPTH-POST-1");
      end

      // ---- the DVMA qualifier ------------------------------------------
      // With it set, the right page and the right function code are not
      // enough: the cycle has to be an alternate master's.  This is the only
      // way to catch a card's transfer into a page software also touches,
      // which is every DVMA buffer there is.
      begin
         rst = 1'b1; trig_dvma_en = 1'b1;
         @(posedge clk); @(negedge clk); rst = 1'b0;
         repeat (2) @(posedge clk);

         // A CPU cycle on the trigger page: matches page and FC, no master.
         @(negedge clk); bus = mk(1'b0, PAGE, 16'd200);
         repeat (4) @(posedge clk);
         ck(!triggered, "dvma qualifier: a CPU cycle on the page does not trigger");

         // ...and the same cycle with a master driving does.
         @(negedge clk); bus = mkdv(1'b0, PAGE, 16'd201);
         repeat (4) @(posedge clk);
         ck(triggered, "dvma qualifier: a master's cycle on the page does");
      end

      // ---- the physical-page trigger ------------------------------------
      // Software maps a device where it likes, so a virtual trigger can watch
      // only the mapping it was told about.  The page map's output is the same
      // whoever set it up.
      begin
         rst = 1'b1; trig_dvma_en = 1'b0; trig_phys_en = 1'b1;
         @(posedge clk); @(negedge clk); rst = 1'b0;
         repeat (2) @(posedge clk);

         // The right virtual page, translated somewhere else: must be ignored.
         @(negedge clk); bus = mkpp(1'b0, PAGE, 12'h123);
         repeat (4) @(posedge clk);
         ck(!triggered, "physical trigger: the virtual page alone does not fire it");

         // A different virtual page that translates to the one asked for.
         @(negedge clk); bus = mkpp(1'b0, 13'h0555, PAGE[11:0]);
         repeat (4) @(posedge clk);
         ck(triggered, "physical trigger: the translation is what matches");
         trig_phys_en = 1'b0;
      end

      $display("=== %0d checks, %0d failed ===", checks, fails);
      if (fails == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end
endmodule
