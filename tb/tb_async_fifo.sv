`timescale 1ns/1ps
//
// sun2_async_fifo, across two unrelated clocks in both orders.
//
// What simulation can check is the *logic* of the FIFO: that nothing is lost,
// duplicated or reordered; that full and empty are exact at the boundaries;
// that the head is visible without a read strobe (first word fall through);
// and that a push to a full queue or a pop from an empty one does nothing.
// What it cannot check is the *crossing* -- a simulator has no metastability,
// so a missing synchroniser stage or a binary pointer passed across the domains
// behaves perfectly here.  That half is structural and belongs to report_cdc on
// a routed netlist.
//
// Two scenarios run at once, each with its own FIFO (DEPTH 4, the smallest the
// module allows, so the boundaries are hit constantly):
//
//   A  fast writer, slow reader     7 ns against 23.3 ns
//   B  slow writer, fast reader    50 ns against  6 ns   -- cpu_clk against
//                                                          ui_clk, roughly
//
// Each runs a directed part (fill to full, try to overfill, drain to empty, try
// to underflow) then a long random part whose bias alternates between
// writer-heavy and reader-heavy stretches, so both boundaries are reached many
// times.  The random part counts how often a push met `wfull' and a pop met
// `rempty': those are its controls, and a zero in either means the run proved
// nothing about that boundary.
//

module fifo_scenario #(
   parameter real   WHALF = 3.5,
   parameter real   RHALF = 11.65,
   parameter [31:0] SEED  = 32'h1234_5678,
   parameter string NAME  = "?"
) (
   output bit done,
   output int checks,
   output int fails
);
   localparam int N_RANDOM = 4000;

   bit wclk = 0, rclk = 0;
   always #(WHALF) wclk = ~wclk;
   always #(RHALF) rclk = ~rclk;

   bit          wrst = 1, rrst = 1;
   bit          wr_en = 0, rd_en = 0;
   logic [15:0] wr_data = 16'h0;
   wire  [15:0] rd_data;
   wire         wfull, rempty;

   sun2_async_fifo #(.WIDTH(16), .ADDR(2)) dut (
      .wclk(wclk), .wrst(wrst), .wr_en(wr_en), .wr_data(wr_data), .wfull(wfull),
      .rclk(rclk), .rrst(rrst), .rd_en(rd_en), .rd_data(rd_data), .rempty(rempty));

   task automatic check(input string what, input bit cond);
      checks++;
      if (!cond) begin
         fails++;
         if (fails <= 12) $display("  %s: FAIL %s", NAME, what);
      end
   endtask

   // Deterministic pseudo-random bits, so a failure reproduces.
   logic [31:0] lfsr_w, lfsr_r;
   function automatic logic [31:0] step(input logic [31:0] x);
      step = {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]};
   endfunction

   // ---- random phase: the writer pushes 0,1,2,... and the reader expects them ----
   bit          running = 0;
   int          pushed = 0, popped = 0;
   int          full_hits = 0, empty_hits = 0, x_seen = 0, order_bad = 0;
   int          bias = 0;          // 0 writer-heavy, 1 reader-heavy

   always @(posedge wclk) if (running) begin
      if (wr_en && !wfull) pushed <= pushed + 1;
      if (wr_en &&  wfull) full_hits <= full_hits + 1;
      lfsr_w <= step(lfsr_w);
      if (pushed + (wr_en && !wfull) < N_RANDOM) begin
         wr_en   <= (lfsr_w[3:0] < (bias == 0 ? 4'd13 : 4'd4));
         wr_data <= 16'(pushed + (wr_en && !wfull));
      end else
         wr_en   <= 1'b0;
   end

   always @(posedge rclk) if (running) begin
      if (!rempty && $isunknown(rd_data)) x_seen <= x_seen + 1;
      if (rd_en && !rempty) begin
         if (rd_data !== 16'(popped)) begin
            if (order_bad < 4)
              $display("  %s: pop %0d returned %0d", NAME, popped, rd_data);
            order_bad <= order_bad + 1;
         end
         popped <= popped + 1;
      end
      if (rd_en && rempty) empty_hits <= empty_hits + 1;
      lfsr_r <= step(lfsr_r);
      rd_en  <= (lfsr_r[3:0] < (bias == 0 ? 4'd4 : 4'd13));
   end

   initial begin
      int got;
      lfsr_w = SEED; lfsr_r = ~SEED;
      repeat (6) @(posedge wclk);
      repeat (6) @(posedge rclk);
      @(posedge wclk) wrst <= 0;
      @(posedge rclk) rrst <= 0;
      repeat (8) @(posedge wclk);
      repeat (8) @(posedge rclk);

      // ---- directed: empty and not full out of reset ----
      check("empty out of reset", rempty === 1'b1);
      check("not full out of reset", wfull === 1'b0);

      // ---- directed: fill to full with the reader stalled ----
      got = 0;
      for (int i = 0; i < 8; i++) begin
         @(posedge wclk);
         if (wr_en && !wfull) got++;
         wr_en <= 1'b1; wr_data <= 16'hA000 | 16'(got);
      end
      @(posedge wclk); if (wr_en && !wfull) got++;
      wr_en <= 1'b0;
      @(posedge wclk);
      check("exactly DEPTH (4) pushes accepted before full", got == 4);
      check("full after four pushes", wfull === 1'b1);

      // ---- first word fall through: the head is visible with no read ----
      repeat (4) @(posedge rclk);
      check("not empty once the pushes have crossed", rempty === 1'b0);
      check("the head is visible without a read strobe", rd_data === 16'hA000);

      // ---- drain, in order ----
      for (int i = 0; i < 4; i++) begin
         @(posedge rclk);
         check($sformatf("drain %0d returns the value pushed %0dth", i, i),
               !rempty && rd_data === (16'hA000 | 16'(i)));
         rd_en <= 1'b1;
         @(posedge rclk);
         rd_en <= 1'b0;
      end
      repeat (3) @(posedge rclk);
      check("empty after draining all four", rempty === 1'b1);
      repeat (4) @(posedge wclk);
      check("not full once the reads have crossed back", wfull === 1'b0);

      // ---- underflow: a read strobe on an empty queue does nothing ----
      @(posedge rclk) rd_en <= 1'b1;
      repeat (6) @(posedge rclk);
      rd_en <= 1'b0;
      @(posedge wclk) begin wr_en <= 1'b1; wr_data <= 16'h5A5A; end
      @(posedge wclk) wr_en <= 1'b0;
      repeat (6) @(posedge rclk);
      check("after reading an empty queue, the next push is still the head",
            !rempty && rd_data === 16'h5A5A);
      @(posedge rclk) rd_en <= 1'b1;
      @(posedge rclk) rd_en <= 1'b0;
      repeat (4) @(posedge rclk);
      check("and it drains to empty", rempty === 1'b1);

      // ---- random: 4000 values, bias flipping every 150 clocks of the slower side ----
      running = 1;
      fork
         begin
            while (popped < N_RANDOM) begin
               repeat (150) @(posedge (WHALF > RHALF ? wclk : rclk));
               bias = 1 - bias;
            end
         end
         begin
            automatic int guard = 0;
            while (popped < N_RANDOM && guard < 2_000_000) begin @(posedge rclk); guard++; end
         end
      join_any
      disable fork;
      running = 0;
      repeat (8) @(posedge rclk);

      check($sformatf("all %0d values pushed", N_RANDOM), pushed == N_RANDOM);
      check($sformatf("all %0d values popped, none lost or duplicated", N_RANDOM), popped == N_RANDOM);
      check("every pop returned the next value in order", order_bad == 0);
      check("no X on the head while not empty", x_seen == 0);
      check("empty once the stream is drained", rempty === 1'b1);
      $display("  %s: pushed %0d, popped %0d; control: push met full %0d times, pop met empty %0d times",
               NAME, pushed, popped, full_hits, empty_hits);
      check("control: the random stream reached full", full_hits > 0);
      check("control: the random stream reached empty", empty_hits > 0);
      done = 1;
   end
endmodule

module tb_async_fifo;
   bit  done_a, done_b;
   int  checks_a, checks_b, fails_a, fails_b;

   fifo_scenario #(.WHALF(3.5),  .RHALF(11.65), .SEED(32'h1234_5678), .NAME("A fast writer"))
      a (.done(done_a), .checks(checks_a), .fails(fails_a));
   fifo_scenario #(.WHALF(25.0), .RHALF(3.0),   .SEED(32'hCAFE_F00D), .NAME("B slow writer"))
      b (.done(done_b), .checks(checks_b), .fails(fails_b));

   initial begin
      $display("=== tb_async_fifo: sun2_async_fifo, DEPTH 4, two unrelated clocks each way ===");
      wait (done_a && done_b);
      $display("=== %0d checks, %0d failures ===", checks_a + checks_b, fails_a + fails_b);
      if (fails_a + fails_b == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin #50_000_000; $display("FAIL: timeout"); $finish; end
endmodule
