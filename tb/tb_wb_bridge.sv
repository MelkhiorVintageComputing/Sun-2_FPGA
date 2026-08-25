`timescale 1ns/1ps
//
// sun2_wishbone_bridge, driven the way loop mode drives it.
//
// The MC68010 has a loop mode, and RD68011 implements it: a loop of one
// word-sized instruction using (An)+ followed by a DBcc back to it is held
// entirely in the prefetch queue and runs with *no instruction fetches at
// all*.  An ILA capture of a `bzero' on the board is 512 consecutive word
// writes -- a contiguous kilobyte, eight clocks each -- with not one fetch
// among them.
//
// That is the only thing on this machine that puts one memory cycle
// immediately after another.  Every other instruction stream separates two
// operand cycles with at least one fetch, and a fetch is a bus cycle in which
// MATCH_MEM drops and the bridge's per-cycle state is cleared.
//
// The bridge tracks whose transaction it is answering with `issued' and
// `done', both cleared by `~MATCH_ANY':
//
//     if (~ENABLE | ~MATCH_ANY) begin issued <= 0; done <= 0; end
//     else begin if (wb_cyc_o) issued <= 1; if (wb_ack_i & issued) done <= 1; end
//
//     assign wb_cyc_o = MATCH_ANY & ~done;
//     assign W_ACK    = (wb_ack_i & issued) | done;
//
// so if MATCH_ANY does not go low for at least one sampled clock between two
// cycles, `done' survives into the second one.  Then wb_cyc_o is 0 -- the
// request is never issued -- while W_ACK is 1 from the first clock, so the CPU
// gets an immediate DTACK for a transaction that never happened.  A write
// vanishes; a read takes the previous cycle's data out of P_DATA_OUT.
//
// This is invisible to a boot.  The MultiBus reference is byte-identical
// either way, because the failure is silent and the PROM's copies are short.
// It is invisible to Suska, which does not implement loop mode.  It needs a
// unit test, and this is it.
//
// What is swept, and why both axes matter:
//
//   GAP      clocks for which MATCH_ANY is low between cycles, 0..3.
//
//            **GAP=0 is not physically realisable on this machine, and is in
//            the sweep to pin the invariant rather than to be passed.**
//            MATCH_MEM is qualified by C_S6, and sun2_fpga clears the whole
//            C_S chain with `if (P_AS_n) C_S4..C_S24 <= 0;' -- every posedge
//            on which AS is high.  A 68010 negates AS at the end of S7 and
//            does not reassert until S2 of the next cycle, so there is always
//            at least one such posedge, after which C_S6 has to be rebuilt
//            through C_S3 and C_S4 before MATCH_MEM can come back.  The real
//            gap is therefore several clocks, never zero.
//
//            What GAP=0 measures is the *invariant the bridge depends on*: if
//            anything ever makes MATCH_ANY survive a cycle boundary, `done'
//            carries over, the next request is never issued and DTACK is
//            asserted anyway.  A future change to the C_S chain or to the
//            match terms that broke that would be caught here and nowhere
//            else -- a boot stays byte-identical through it.
//   LATENCY  the slave's wait states before it registers its ack, 1..8.  The
//            measured DDR3 figure is 7 (`make -C sim migddr3'), and a
//            one-clock memory hides races that a seven-clock one shows.
//
// Every write carries its own address in its data, so a word holding a
// neighbour's value (a cycle answered by the wrong transaction) is told apart
// from a word that was never written at all (a dropped request).
//

module tb_wb_bridge;

   localparam integer NWORD = 64;      // longwords exercised per run

   reg CLK = 1'b0;
   always #10 CLK = ~CLK;              // 50 MHz, arbitrary: everything here is clocks

   reg          RESET_n = 1'b0;
   reg          SET_ENABLE = 1'b0;

   reg  [23:1]  P_ADR_IN = 23'h0;
   reg  [15:0]  P_DATA_IN = 16'h0;
   wire [15:0]  P_DATA_OUT;
   reg          P_RW_n = 1'b1;
   reg          EN_LBYTE = 1'b1, EN_UBYTE = 1'b1;
   reg          MATCH_MEM = 1'b0;
   wire         MATCH_FB = 1'b0;
   wire         W_ACK;

   wire         wb_cyc_o, wb_stb_o, wb_we_o;
   wire [29:0]  wb_adr_o;
   wire [31:0]  wb_dat_o;
   wire [3:0]   wb_sel_o;
   reg  [31:0]  wb_dat_i = 32'h0;
   reg          wb_ack_i = 1'b0;

   sun2_wishbone_bridge dut (
       .SET_ENABLE (SET_ENABLE), .RESET_n (RESET_n), .CLK (CLK),
       .P_ADR_IN (P_ADR_IN), .P_DATA_IN (P_DATA_IN), .P_DATA_OUT (P_DATA_OUT),
       .P_RW_n (P_RW_n), .EN_LBYTE (EN_LBYTE), .EN_UBYTE (EN_UBYTE),
       .FB_PAGE (6'h0),
       .MATCH_MEM (MATCH_MEM), .MATCH_FB (MATCH_FB), .W_ACK (W_ACK),
       .wb_cyc_o (wb_cyc_o), .wb_stb_o (wb_stb_o), .wb_adr_o (wb_adr_o),
       .wb_dat_o (wb_dat_o), .wb_sel_o (wb_sel_o), .wb_we_o (wb_we_o),
       .wb_dat_i (wb_dat_i), .wb_ack_i (wb_ack_i));

   // ----------------------------------------------------------------------
   // A Wishbone slave with a settable number of wait states.
   //
   // It registers its acknowledgement, as every slave in this design does --
   // the bridge's comment leans on that ("it can never arrive in the same
   // clock the request goes out"), so the model must not cheat and ack
   // combinationally.  It also counts, so the test can say how many
   // transactions actually reached memory rather than only what memory holds.
   // ----------------------------------------------------------------------
   integer LATENCY = 7;
   reg [31:0] mem [0:1023];
   integer    n_wr, n_rd;
   integer    wait_cnt;

   always @(posedge CLK) begin
      if (~RESET_n) begin
         wb_ack_i <= 1'b0; wait_cnt <= 0;
      end else begin
         wb_ack_i <= 1'b0;
         if (wb_cyc_o & wb_stb_o & ~wb_ack_i) begin
            if (wait_cnt >= LATENCY) begin
               wait_cnt <= 0;
               wb_ack_i <= 1'b1;
               if (wb_we_o) begin
                  n_wr = n_wr + 1;
                  if (wb_sel_o[0]) mem[wb_adr_o[9:0]][ 7: 0] <= wb_dat_o[ 7: 0];
                  if (wb_sel_o[1]) mem[wb_adr_o[9:0]][15: 8] <= wb_dat_o[15: 8];
                  if (wb_sel_o[2]) mem[wb_adr_o[9:0]][23:16] <= wb_dat_o[23:16];
                  if (wb_sel_o[3]) mem[wb_adr_o[9:0]][31:24] <= wb_dat_o[31:24];
               end else begin
                  n_rd = n_rd + 1;
                  wb_dat_i <= mem[wb_adr_o[9:0]];
               end
            end else
              wait_cnt <= wait_cnt + 1;
         end else if (~wb_cyc_o)
           wait_cnt <= 0;
      end
   end

   // ----------------------------------------------------------------------
   // One 68010 memory cycle, as the machine presents it to the bridge.
   //
   // MATCH_MEM is what sun2_fpga asserts once the MMU has settled (it is
   // qualified by C_S6), and it stays up for the rest of the bus cycle.  The
   // cycle ends when the CPU sees DTACK; MATCH_MEM then drops for `gap'
   // clocks, which is the whole variable under test.
   // ----------------------------------------------------------------------
   // Declared ahead of the task that increments it: xvlog rejects a use before
   // its declaration where Vivado merely warns and invents an implicit wire.
   integer n_timeout;
   integer n_invariant, n_gap0_ok;

   task automatic bus_cycle (input [23:1] adr, input rw_n,
                             input [15:0] wdata, input integer gap,
                             output [15:0] rdata);
      integer guard;
      begin
         @(posedge CLK);
         P_ADR_IN  <= adr;
         P_RW_n    <= rw_n;
         P_DATA_IN <= wdata;
         EN_UBYTE  <= 1'b1;
         EN_LBYTE  <= 1'b1;
         MATCH_MEM <= 1'b1;

         guard = 0;
         // The CPU samples DTACK on a clock edge and ends the cycle.
         while (W_ACK !== 1'b1 && guard < 200) begin
            @(posedge CLK);
            guard = guard + 1;
         end
         if (guard >= 200) begin
            $display("  TIMEOUT: no W_ACK for %s at %06x",
                     rw_n ? "read" : "write", {adr, 1'b0});
            n_timeout = n_timeout + 1;
         end
         @(posedge CLK);
         rdata = P_DATA_OUT;

         MATCH_MEM <= 1'b0;
         for (guard = 0; guard < gap; guard = guard + 1) @(posedge CLK);
      end
   endtask

   // ----------------------------------------------------------------------
   // The runs
   // ----------------------------------------------------------------------
   integer i, gap, lat, bad_w, bad_r, total_fail;
   reg [15:0] rd;
   reg [15:0] expect_w;

   // Address i as a word address; data carries the address so a stray value is
   // traceable to the cycle that produced it.
   function [15:0] pattern (input integer k);
      pattern = 16'hC000 | k[11:0];
   endfunction

   initial begin
      n_timeout = 0; total_fail = 0; n_invariant = 0; n_gap0_ok = 0;
      $display("=== tb_wb_bridge: back-to-back cycles, as loop mode issues them ===");

      RESET_n = 1'b0;
      repeat (4) @(posedge CLK);
      RESET_n = 1'b1;
      SET_ENABLE = 1'b1;      // the bridge's one-shot ENABLE
      @(posedge CLK);
      SET_ENABLE = 1'b0;
      repeat (2) @(posedge CLK);

      for (lat = 1; lat <= 8; lat = lat + 1) begin
         for (gap = 0; gap <= 3; gap = gap + 1) begin
            LATENCY = lat;
            for (i = 0; i < 1024; i = i + 1) mem[i] = 32'hDEADBEEF;
            n_wr = 0; n_rd = 0;
            bad_w = 0; bad_r = 0;

            // A run of back-to-back writes, one word each, ascending -- a
            // `movew %d0,%a0@+ / dbra' loop.
            for (i = 0; i < NWORD; i = i + 1)
              bus_cycle(23'h000100 + i, 1'b0, pattern(i), gap, rd);

            // Every one must have reached the slave.
            if (n_wr != NWORD) begin
               $display("  lat=%0d gap=%0d: %0d of %0d writes reached memory -- %0d LOST",
                        lat, gap, n_wr, NWORD, NWORD - n_wr);
               bad_w = NWORD - n_wr;
            end

            // ... and must be in the right place with the right value.
            // The bridge puts A1=0 on sel[1:0]/wb_dat_o[15:0] and A1=1 on the
            // high half, and its read path undoes it the same way -- so the
            // pairing is self-consistent and this check has to follow it
            // rather than follow 68000 byte order.  Getting it the other way
            // round makes every word look wrong at every gap, which is a
            // testbench failing, not the bridge.
            for (i = 0; i < NWORD; i = i + 1) begin
               expect_w = pattern(i);
               if ((23'h000100 + i) & 23'h1) begin
                  if (mem[(23'h000100 + i) >> 1][31:16] !== expect_w) bad_r = bad_r + 1;
               end else begin
                  if (mem[(23'h000100 + i) >> 1][15:0] !== expect_w) bad_r = bad_r + 1;
               end
            end

            // A run of back-to-back reads over the same words.
            n_rd = 0;
            for (i = 0; i < NWORD; i = i + 1) begin
               bus_cycle(23'h000100 + i, 1'b1, 16'h0, gap, rd);
               if (rd !== pattern(i)) begin
                  if (bad_r < 4)
                    $display("  lat=%0d gap=%0d: read %0d returned %04x, want %04x",
                             lat, gap, i, rd, pattern(i));
                  bad_r = bad_r + 1;
               end
            end
            if (n_rd != NWORD)
              $display("  lat=%0d gap=%0d: %0d of %0d reads reached memory",
                       lat, gap, n_rd, NWORD);

            if (bad_w || bad_r) begin
               // gap=0 cannot happen on the machine (see the header): report
               // it, and count it only as the invariant it documents.
               $display("  lat=%0d gap=%0d  %s  writes lost %0d, words wrong %0d",
                        lat, gap, (gap == 0) ? "invariant" : "FAIL",
                        bad_w, bad_r);
               if (gap != 0) total_fail = total_fail + 1;
               else          n_invariant = n_invariant + 1;
            end else begin
               $display("  lat=%0d gap=%0d  ok", lat, gap);
               if (gap == 0) n_gap0_ok = n_gap0_ok + 1;
            end
         end
      end

      $display("=== checks: %0d combinations, %0d failing, %0d timeouts ===",
               8*4, total_fail, n_timeout);
      $display("=== gap=0 (unreachable on the machine): %0d showed the carry-over, %0d did not ===",
               n_invariant, n_gap0_ok);
      if (total_fail == 0 && n_timeout == 0)
        $display("PASS");
      else
        $display("FAIL");
      $finish;
   end

endmodule
