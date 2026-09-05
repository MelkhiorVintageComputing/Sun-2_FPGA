`timescale 1ns / 1ps
//
// sun2_dvma_probe: does it call a healthy pairing healthy, and catch the two
// ways it breaks?
//
// The instrument this project shipped without a testbench reported a correctly
// copied file as 74% corrupt and named two innocent sectors as the culprits.
// This one is going to be used to accuse a specific pair of registers of a
// fault nothing else can see, so the false-positive case matters as much as the
// detection: a probe that fires on healthy traffic would condemn the pairing on
// its first readout.
//
module tb_dvma_probe;

   reg clk = 0, rst = 1;
   always #5 clk = ~clk;

   reg         brg_load = 0, dvma_latch = 0, dvma_busy = 0;
   reg         brg_half = 0;
   reg  [15:0] dvma_din = 0;
   reg  [23:1] dvma_a   = 0;

   wire [15:0] n_latch, n_no_load, n_late_load, first_d, n_half_bad;
   wire [15:0] n_pat_a, n_pat_bad, n_pat_first;
   wire [23:1] first_a;
   wire        seen;

   sun2_dvma_probe dut (
       .clk(clk), .rst(rst),
       .brg_load(brg_load), .brg_half(brg_half),
       .dvma_busy(dvma_busy), .dvma_latch(dvma_latch),
       .dvma_din(dvma_din), .dvma_a(dvma_a),
       .n_latch(n_latch), .n_no_load(n_no_load), .n_late_load(n_late_load),
       .n_clk(), .n_load(), .n_half_bad(n_half_bad),
       .n_pat_a(n_pat_a), .n_pat_b(), .n_pat_bad(n_pat_bad),
       .n_pat_first(n_pat_first), .n_pat_faddr(),
       .first_a(first_a), .first_d(first_d), .seen(seen));

   integer checks = 0, errors = 0;
   task ck(input cond, input [511:0] name);
      begin
         checks = checks + 1;
         if (cond) $display("ok:   %0s", name);
         else begin $display("FAIL: %0s", name); errors = errors + 1; end
      end
   endtask

   // A healthy cycle: the strobes go on, the bridge loads once somewhere
   // inside it, and the master takes the data at the end.  The load is placed
   // several clocks before the capture on purpose -- that is what the machine
   // does, and checking only the clock before is the mistake this model was
   // built to stop repeating.
   task healthy(input [23:1] a, input [15:0] d);
      begin
         dvma_a <= a;                       // the address is up before the load
         @(posedge clk); dvma_busy <= 1'b1;
         @(posedge clk); brg_load  <= 1'b1; brg_half <= a[1];
         @(posedge clk); brg_load  <= 1'b0;
         repeat (3) @(posedge clk);
         dvma_latch <= 1'b1; dvma_a <= a; dvma_din <= d;
         @(posedge clk); dvma_latch <= 1'b0; dvma_busy <= 1'b0;
         @(posedge clk);
      end
   endtask

   // A cycle in which the bridge never loaded: the master takes whatever
   // P_DATA_OUT held from an earlier transaction.
   task no_load(input [23:1] a, input [15:0] d);
      begin
         @(posedge clk); dvma_busy <= 1'b1;
         repeat (4) @(posedge clk);
         dvma_latch <= 1'b1; dvma_a <= a; dvma_din <= d;
         @(posedge clk); dvma_latch <= 1'b0; dvma_busy <= 1'b0;
         @(posedge clk);
      end
   endtask

   // Two loads inside one cycle: the second overwrote this cycle's data.
   task late_load(input [23:1] a, input [15:0] d);
      begin
         dvma_a <= a; brg_half <= a[1];     // the half the master asked for
         @(posedge clk); dvma_busy <= 1'b1;
         @(posedge clk); brg_load  <= 1'b1;
         @(posedge clk); brg_load  <= 1'b0;
         @(posedge clk); brg_load  <= 1'b1;
         @(posedge clk); brg_load  <= 1'b0;
         @(posedge clk);
         dvma_latch <= 1'b1; dvma_a <= a; dvma_din <= d;
         @(posedge clk); dvma_latch <= 1'b0; dvma_busy <= 1'b0;
         @(posedge clk);
      end
   endtask

   // The counters are non-blocking assignments in the DUT, so a check written
   // straight after the @(posedge) that produced them reads the value from
   // before the edge.  Settle first, every time.
   task settle; begin @(posedge clk); #1; end endtask

   // One capture carrying the pattern word for its address, and one carrying
   // rubbish, so the check can be armed and then tripped.
   task healthy_pat(input [23:1] a);
      begin
         dvma_a <= a;
         @(posedge clk); dvma_busy <= 1'b1;
         @(posedge clk); brg_load  <= 1'b1; brg_half <= a[1];
         @(posedge clk); brg_load  <= 1'b0;
         repeat (2) @(posedge clk);
         dvma_latch <= 1'b1; dvma_din <= {8'h80, a[8:1]};
         @(posedge clk); dvma_latch <= 1'b0; dvma_busy <= 1'b0;
         @(posedge clk);
      end
   endtask

   task healthy_bad(input [23:1] a);
      begin
         dvma_a <= a;
         @(posedge clk); dvma_busy <= 1'b1;
         @(posedge clk); brg_load  <= 1'b1; brg_half <= a[1];
         @(posedge clk); brg_load  <= 1'b0;
         repeat (2) @(posedge clk);
         dvma_latch <= 1'b1; dvma_din <= 16'hDEAD;
         @(posedge clk); dvma_latch <= 1'b0; dvma_busy <= 1'b0;
         @(posedge clk);
      end
   endtask

   integer i;

   initial begin
      $display("=== sun2_dvma_probe ===");
      repeat (3) @(posedge clk);
      rst <= 1'b0; @(posedge clk);

      ck(n_latch == 0 && n_no_load == 0 && n_late_load == 0 && !seen,
         "quiet before any traffic");

      // ---- healthy traffic must not accuse anything ----
      for (i = 0; i < 20; i = i + 1) healthy(23'h001000 + i[22:0], 16'hA000 + i[15:0]);
      settle;
      ck(n_latch == 20,      "twenty captures counted");
      ck(n_no_load == 0,     "healthy traffic raises no no-load");
      ck(n_late_load == 0,   "healthy traffic raises no late-load");
      ck(!seen,              "and latches no first event");

      // ---- a capture with no preceding load ----
      no_load(23'h00BEEF, 16'h1234);
      settle;
      ck(n_no_load == 1,     "a capture with no load before it is caught");
      ck(n_latch == 21,      "and still counted as a capture");
      ck(seen,               "the first event is latched");
      ck(first_a == 23'h00BEEF, "with the address it happened at");
      ck(first_d == 16'h1234,   "and the word the master took");

      // ---- a load on the same edge ----
      late_load(23'h00CAFE, 16'h5678);
      settle;
      ck(n_late_load == 1,   "two loads in one cycle are caught");
      settle;
      ck(n_no_load == 1,
         "and is not also counted as a no-load: the two are exclusive");

      // ---- the first event is not overwritten ----
      no_load(23'h001111, 16'h9999);
      settle;
      ck(n_no_load == 2,        "a second no-load still counts");
      ck(first_a == 23'h00BEEF, "but the first event's address survives");
      ck(first_d == 16'h1234,   "and its data");

      // ---- a load that took the wrong half of the word ----
      // The bridge picks by P_ADR_IN[1] and the master asks for dvma_a[1].  A
      // disagreement hands the master sixteen bits of the neighbouring word --
      // the granule the corruption actually has -- and the one-load-per-cycle
      // check cannot see it, because a load did happen.
      begin
         dvma_a <= 23'h001001;                                  // half = 1
         @(posedge clk); dvma_busy <= 1'b1;
         @(posedge clk); brg_load <= 1'b1; brg_half <= 1'b0;    // wrong half
         @(posedge clk); brg_load <= 1'b0;
         repeat (3) @(posedge clk);
         dvma_latch <= 1'b1; dvma_din <= 16'hDEAD;
         @(posedge clk); dvma_latch <= 1'b0; dvma_busy <= 1'b0;
         @(posedge clk);
      end
      settle;
      ck(n_half_bad == 1, "a load that took the wrong half is caught");
      settle;
      ck(n_no_load == 2,  "and not as a missing load: one did happen");

      // ---- healthy traffic after a violation stays quiet ----
      for (i = 0; i < 10; i = i + 1) healthy(23'h002000 + i[22:0], 16'hB000 + i[15:0]);
      settle;
      ck(n_no_load == 2 && n_late_load == 1,
         "healthy traffic after a violation adds nothing");

      // ---- the pattern check at the capture ----
      // Four consecutive matches arm it; a later word that does not match is
      // then flagged.  The run requirement is what stops ordinary traffic
      // arming it, so it is checked both ways: a short run must NOT arm, and a
      // long one must.
      begin
         integer k;
         for (k = 0; k < 3; k = k + 1) healthy_pat(23'h001000 + k[22:0]);
         healthy_bad(23'h001003);
         settle;
         ck(n_pat_bad == 0, "a short run does not arm the pattern check");

         for (k = 0; k < 6; k = k + 1) healthy_pat(23'h002000 + k[22:0]);
         settle;
         ck(n_pat_a >= 6, "matching pattern words are counted");
         // An isolated miss, closed by a matching word, is a real corruption.
         healthy_bad(23'h002006);
         healthy_pat(23'h002007);
         settle;
         ck(n_pat_bad == 1, "an isolated wrong word is caught");
         settle;
         ck(n_pat_first == 16'hDEAD, "with the word the master actually took");

         // A run of non-pattern words is ordinary traffic, not corruption.
         // Without this the board reported 1018 of them as bad.
         for (k = 0; k < 8; k = k + 1) healthy_bad(23'h003000 + k[22:0]);
         settle;
         ck(n_pat_bad == 1, "a run of non-pattern words is not counted");
      end

      // ---- a load with no capture is not a violation ----
      // The CPU's own reads load P_DATA_OUT constantly and the master is not
      // involved; counting those would drown the signal.
      @(posedge clk); brg_load <= 1'b1;
      repeat (5) @(posedge clk);
      brg_load <= 1'b0; @(posedge clk);
      settle;
      ck(n_latch == 54 && n_no_load == 2 && n_late_load == 1,
         "bridge loads without a capture are ignored");

      $display("=== %0d checks, %0d failures ===", checks, errors);
      if (errors == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

endmodule
