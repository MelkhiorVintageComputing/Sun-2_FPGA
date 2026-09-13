// tb_clobber.sv -- sun2_clobber, one scenario per thing it claims to tell apart.
//
// Each scenario is a short script of memory writes and reads in the shape the
// kernel produces them -- a buffer filled by a sequential copy, a buffer
// refilled with something else, one foreign word -- and each ends by checking
// the *change* in every counter, not just the one it is about.  A detector
// whose `iso' fires on reuse too would pass a test that only looked at `iso'.
//
// Events are spaced at the minimum the RTL claims to handle (two clocks) in
// the scenario that exercises the table's read-after-write, and wider
// elsewhere.  The ILA pulses are counted independently and checked against
// the counters, so the trigger cannot drift from the thing it reports.

`timescale 1ns/1ps

module tb_clobber;

   localparam integer TWR  = 16;
   localparam integer TCLK = 200;

   reg CLK = 1'b0;
   always #10 CLK = ~CLK;

   reg         RESET_n = 1'b0;
   reg         wr_fire = 1'b0, rd_load = 1'b0, dvma = 1'b0;
   reg  [22:1] adr = 22'h0;
   reg  [15:0] wdat = 16'h0, rdat = 16'h0;
   reg  [1:0]  wlanes = 2'b11;
   wire [5:0]  trig;
   wire [383:0] n_flat;
   wire [127:0] rec_flat;

   sun2_clobber #(.TIMEOUT_WR(TWR), .TIMEOUT_CLK(TCLK)) dut (
      .CLK(CLK), .RESET_n(RESET_n),
      .wr_fire(wr_fire), .adr(adr), .wdat(wdat), .wlanes(wlanes), .dvma(dvma),
      .rd_load(rd_load), .rdat(rdat),
      .trig(trig), .n_flat(n_flat), .rec_flat(rec_flat));

   function [31:0] N(input integer k); N = n_flat[32*k +: 32]; endfunction

   // ---- pulse counters, independent of the RTL's own ---------------------
   integer p_cand = 0, p_iso = 0, p_lone = 0, p_harm = 0, p_ghost = 0, p_xact = 0;
   always @(posedge CLK) if (RESET_n) begin
      if (trig[0]) p_cand  = p_cand  + 1;
      if (trig[1]) p_iso   = p_iso   + 1;
      if (trig[2]) p_lone  = p_lone  + 1;
      if (trig[3]) p_harm  = p_harm  + 1;
      if (trig[4]) p_ghost = p_ghost + 1;
      if (trig[5]) p_xact  = p_xact  + 1;
   end

   integer checks = 0, fails = 0;
   task check(input [255:0] what, input [31:0] got, input [31:0] want);
      begin
         checks = checks + 1;
         if (got !== want) begin
            fails = fails + 1;
            $display("  FAIL %0s: got %0d want %0d", what, got, want);
         end else
           $display("  ok   %0s = %0d", what, got);
      end
   endtask

   integer gap = 3;       // clocks between events, including the event clock
   integer n_ev = 0;

   task idle(input integer c);
      integer k; begin for (k = 0; k < c; k = k + 1) @(posedge CLK); end
   endtask

   task wr(input [13:0] blk, input [7:0] off, input [15:0] d,
           input [1:0] lanes, input m);
      begin
         @(negedge CLK);
         adr = {blk, off}; wdat = d; wlanes = lanes; dvma = m; wr_fire = 1'b1;
         @(negedge CLK);
         wr_fire = 1'b0;
         n_ev = n_ev + 1;
         idle(gap - 1);
      end
   endtask

   task rd(input [13:0] blk, input [7:0] off, input [15:0] d, input m);
      begin
         @(negedge CLK);
         adr = {blk, off}; rdat = d; dvma = m; rd_load = 1'b1;
         @(negedge CLK);
         rd_load = 1'b0;
         n_ev = n_ev + 1;
         idle(gap - 1);
      end
   endtask

   function [15:0] PAT(input [7:0] off); PAT = {8'h80, off}; endfunction

   // A sequential copy of the pattern into [from, to] of a block.
   task copy(input [13:0] blk, input integer from, input integer to, input m);
      integer o; begin
         for (o = from; o <= to; o = o + 1) wr(blk, o[7:0], PAT(o[7:0]), 2'b11, m);
      end
   endtask

   // Every counter against a snapshot, so a scenario says what did NOT move.
   reg [31:0] s [0:11];
   task snap; integer k; begin for (k = 0; k < 12; k = k + 1) s[k] = N(k); end endtask
   task delta(input [31:0] d0, d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11);
      begin
         idle(4);   // let the last decision land
         check("   patwr",      N(0)  - s[0],  d0);
         check("   partial",    N(1)  - s[1],  d1);
         check("   cand",       N(2)  - s[2],  d2);
         check("   cand_dvma",  N(3)  - s[3],  d3);
         check("   reuse",      N(4)  - s[4],  d4);
         check("   iso",        N(5)  - s[5],  d5);
         check("   iso_behind", N(6)  - s[6],  d6);
         check("   lone",       N(7)  - s[7],  d7);
         check("   collide",    N(8)  - s[8],  d8);
         check("   rdpat",      N(9)  - s[9],  d9);
         check("   ghost",      N(10) - s[10], d10);
         check("   ghost_dvma", N(11) - s[11], d11);
      end
   endtask

   initial begin
      idle(3);
      RESET_n = 1'b1;
      idle(3);

      // 1. A buffer filled with the pattern: the control.  Nothing but patwr.
      $display("=== 1. pattern copy, a whole block ===");
      snap; copy(14'h0100, 0, 255, 0);
      delta(256,0,0,0,0,0,0,0,0,0,0,0);

      // 2. The same block refilled with text: one candidate, resolved as reuse.
      $display("=== 2. reuse: the block refilled with something else ===");
      snap;
      begin : s2 integer o; for (o = 0; o < 20; o = o + 1) wr(14'h0100, o[7:0], 16'h4e75, 2'b11, 0); end
      delta(0,0,1,0,1,0,0,0,0,0,0,0);

      // 3. One foreign word behind the copy head: the corruption.
      $display("=== 3. iso, behind: a foreign word below where the copy has reached ===");
      snap; copy(14'h0200, 0, 99, 0);
      wr(14'h0200, 8'd50, 16'h584f, 2'b11, 1);
      copy(14'h0200, 100, 255, 0);
      delta(256,0,1,1,0,1,1,0,0,0,0,0);
      check("   record kind",   rec_flat[49:48], 2'd1);
      check("   record behind", rec_flat[47],    1'b1);
      check("   record dvma",   rec_flat[46],    1'b1);
      check("   record block",  rec_flat[45:32], 14'h0200);
      check("   record off",    rec_flat[31:24], 8'd50);
      check("   record next",   rec_flat[23:16], 8'd100);
      check("   record data",   rec_flat[15:0],  16'h584f);

      // 4. One foreign word ahead of the copy head: overwritten, harmless.
      $display("=== 4. iso, ahead: a foreign word the copy will overwrite ===");
      snap; copy(14'h0300, 0, 99, 0);
      wr(14'h0300, 8'd200, 16'h2e2e, 2'b11, 0);
      copy(14'h0300, 100, 255, 0);
      delta(256,0,1,0,0,1,0,0,0,0,0,0);

      // 5. A foreign word into a finished buffer, then traffic elsewhere.
      $display("=== 5. lone, by writes elsewhere ===");
      snap; copy(14'h0400, 0, 255, 0);
      wr(14'h0400, 8'd10, 16'h2f2d, 2'b11, 0);
      copy(14'h0500, 0, TWR + 3, 0);
      delta(256 + TWR + 4,0,1,0,0,0,0,1,0,0,0,0);
      check("   record kind",  rec_flat[49:48], 2'd2);
      check("   record block", rec_flat[45:32], 14'h0400);
      check("   record off",   rec_flat[31:24], 8'd10);
      check("   record data",  rec_flat[15:0],  16'h2f2d);

      // 6. ... and by nothing happening at all.
      $display("=== 6. lone, by the clock ===");
      snap; wr(14'h0600, 8'd3, PAT(8'd3), 2'b11, 0);   // a run of two arms it
      wr(14'h0600, 8'd4, PAT(8'd4), 2'b11, 0);
      wr(14'h0600, 8'd7, 16'h1234, 2'b11, 0);
      idle(TCLK + 10);
      delta(2,0,1,0,0,0,0,1,0,0,0,0);

      // 7. The read side.
      $display("=== 7. ghost: text read back from a pattern block ===");
      snap; copy(14'h0700, 0, 255, 0);
      rd(14'h0700, 8'd5, PAT(8'd5), 1);       // control
      rd(14'h0700, 8'd6, 16'h584f, 1);        // ghost, by a master
      rd(14'h0700, 8'd9, 16'h584f, 0);        // ghost, by the CPU
      rd(14'h0800, 8'd6, 16'h584f, 1);        // never written: nothing
      delta(256,0,0,0,0,0,0,0,0,1,2,1);
      check("   ghost record dvma",  rec_flat[102],     1'b0);
      check("   ghost record block", rec_flat[101:88],  14'h0700);
      check("   ghost record off",   rec_flat[87:80],   8'd9);
      check("   ghost record data",  rec_flat[79:64],   16'h584f);

      // 8. A pattern write with one lane.
      $display("=== 8. partial: a pattern write issued with one strobe ===");
      // The first word starts the run and is not yet counted; the next two
      // are inside it.
      snap; wr(14'h0900, 8'd2, PAT(8'd2), 2'b10, 0);
      wr(14'h0900, 8'd3, PAT(8'd3), 2'b01, 0);
      wr(14'h0900, 8'd4, PAT(8'd4), 2'b11, 0);
      wr(14'h0900, 8'd5, PAT(8'd5), 2'b10, 0);
      delta(4,2,0,0,0,0,0,0,0,0,0,0);

      // 9. Two candidates at once: the older is kept and resolves correctly.
      $display("=== 9. collide ===");
      snap; copy(14'h0a00, 0, 3, 0); copy(14'h0b00, 0, 3, 0);
      wr(14'h0a00, 8'd1, 16'hdead, 2'b11, 0);
      wr(14'h0b00, 8'd1, 16'hbeef, 2'b11, 0);
      wr(14'h0a00, 8'd4, PAT(8'd4), 2'b11, 0);
      delta(9,0,2,0,0,1,1,0,1,0,0,0);
      check("   record block", rec_flat[45:32], 14'h0a00);

      // 10. At the minimum spacing the RTL claims: the table must already hold
      //     the previous event's verdict two clocks later.
      $display("=== 10. two clocks apart ===");
      gap = 2;
      snap; wr(14'h0c00, 8'd0, PAT(8'd0), 2'b11, 0);
      wr(14'h0c00, 8'd1, PAT(8'd1), 2'b11, 0);      // armed, by the run
      wr(14'h0c00, 8'd2, 16'h4afc, 2'b11, 0);      // cand only if the table saw that
      wr(14'h0c00, 8'd3, PAT(8'd3), 2'b11, 0);      // iso, behind
      wr(14'h0c00, 8'd4, PAT(8'd4), 2'b11, 0);      // re-armed
      rd(14'h0c00, 8'd5, 16'h4afc, 0);              // ghost only if the table saw that
      delta(4,0,1,0,0,1,1,0,0,0,1,0);
      gap = 3;

      // 11. What the first bitstream got wrong on the board: a lone word that
      //     happens to look like the pattern, in a block of other data.  It
      //     must mark nothing -- no candidate, no ghost, no partial.
      $display("=== 11. a coincidental pattern-shaped word arms nothing ===");
      snap;
      begin : s11 integer o; for (o = 0; o < 10; o = o + 1) wr(14'h0d00, o[7:0], 16'h0003, 2'b11, 0); end
      wr(14'h0d00, 8'd10, PAT(8'd10), 2'b11, 0);    // coincidence
      wr(14'h0d00, 8'd11, 16'h0404, 2'b11, 0);      // not a candidate
      rd(14'h0d00, 8'd10, 16'h0003, 1);             // not a ghost
      wr(14'h0e00, 8'h80, 16'h8080, 2'b10, 0);      // a byte write of 0x80 at index 0x80
      rd(14'h0e00, 8'h81, 16'h0003, 0);             // not a ghost either
      delta(2,0,0,0,0,0,0,0,0,0,0,0);

      // 12. A copy that crosses a block boundary: word 0 of the next block is
      //     armed by word 255 of the one below, so a foreign word early in it
      //     is still seen.  Without that, the first word of every block is a
      //     blind spot until the second arrives.
      $display("=== 12. a run carries across a block boundary ===");
      snap; copy(14'h0f00, 0, 255, 0);
      wr(14'h0f01, 8'd0, PAT(8'd0), 2'b11, 0);      // armed only by the block below
      wr(14'h0f01, 8'd5, 16'h2e2e, 2'b11, 0);      // a candidate only if it was
      wr(14'h0f01, 8'd6, PAT(8'd6), 2'b11, 0);      // iso, behind
      delta(258,0,1,0,0,1,1,0,0,0,0,0);

      idle(8);
      $display("=== ILA pulses against the counters ===");
      check("cand pulses",  p_cand,  N(2));
      check("iso pulses",   p_iso,   N(5));
      check("lone pulses",  p_lone,  N(7));
      check("harm pulses",  p_harm,  N(6) + N(7));
      check("ghost pulses", p_ghost, N(10));
      check("xact pulses",  p_xact,  n_ev);

      $display("=== checks: %0d, failing: %0d ===", checks, fails);
      if (fails == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin #50_000_000; $display("FAIL: timeout"); $finish; end

endmodule
