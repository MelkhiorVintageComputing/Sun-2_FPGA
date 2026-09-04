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

   reg         brg_load = 0, dvma_latch = 0;
   reg  [15:0] dvma_din = 0;
   reg  [23:1] dvma_a   = 0;

   wire [15:0] n_latch, n_no_load, n_late_load, first_d;
   wire [23:1] first_a;
   wire        seen;

   sun2_dvma_probe dut (
       .clk(clk), .rst(rst),
       .brg_load(brg_load), .dvma_latch(dvma_latch),
       .dvma_din(dvma_din), .dvma_a(dvma_a),
       .n_latch(n_latch), .n_no_load(n_no_load), .n_late_load(n_late_load),
       .first_a(first_a), .first_d(first_d), .seen(seen));

   integer checks = 0, errors = 0;
   task ck(input cond, input [511:0] name);
      begin
         checks = checks + 1;
         if (cond) $display("ok:   %0s", name);
         else begin $display("FAIL: %0s", name); errors = errors + 1; end
      end
   endtask

   // A healthy access: the bridge loads, and the master captures one clock
   // later.  This is the shape every correct DVMA read has.
   task healthy(input [23:1] a, input [15:0] d);
      begin
         @(posedge clk); brg_load <= 1'b1;
         @(posedge clk); brg_load <= 1'b0;
                         dvma_latch <= 1'b1; dvma_a <= a; dvma_din <= d;
         @(posedge clk); dvma_latch <= 1'b0;
      end
   endtask

   // The master captures with nothing loaded in the clock before.
   task no_load(input [23:1] a, input [15:0] d);
      begin
         @(posedge clk); dvma_latch <= 1'b1; dvma_a <= a; dvma_din <= d;
         @(posedge clk); dvma_latch <= 1'b0;
      end
   endtask

   // The bridge loads on the very edge the master captures: both registered
   // off it, so the master takes the pre-load value.
   task late_load(input [23:1] a, input [15:0] d);
      begin
         @(posedge clk); brg_load <= 1'b1; dvma_latch <= 1'b1;
                         dvma_a <= a; dvma_din <= d;
         @(posedge clk); brg_load <= 1'b0; dvma_latch <= 1'b0;
      end
   endtask

   // The counters are non-blocking assignments in the DUT, so a check written
   // straight after the @(posedge) that produced them reads the value from
   // before the edge.  Settle first, every time.
   task settle; begin @(posedge clk); #1; end endtask

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
      ck(n_late_load == 1,   "a load on the capture edge is caught");
      settle;
      ck(n_no_load == 1,
         "and is not also counted as a no-load: the two are exclusive");

      // ---- the first event is not overwritten ----
      no_load(23'h001111, 16'h9999);
      settle;
      ck(n_no_load == 2,        "a second no-load still counts");
      ck(first_a == 23'h00BEEF, "but the first event's address survives");
      ck(first_d == 16'h1234,   "and its data");

      // ---- healthy traffic after a violation stays quiet ----
      for (i = 0; i < 10; i = i + 1) healthy(23'h002000 + i[22:0], 16'hB000 + i[15:0]);
      settle;
      ck(n_no_load == 2 && n_late_load == 1,
         "healthy traffic after a violation adds nothing");

      // ---- a load with no capture is not a violation ----
      // The CPU's own reads load P_DATA_OUT constantly and the master is not
      // involved; counting those would drown the signal.
      @(posedge clk); brg_load <= 1'b1;
      repeat (5) @(posedge clk);
      brg_load <= 1'b0; @(posedge clk);
      settle;
      ck(n_latch == 33 && n_no_load == 2 && n_late_load == 1,
         "bridge loads without a capture are ignored");

      $display("=== %0d checks, %0d failures ===", checks, errors);
      if (errors == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

endmodule
