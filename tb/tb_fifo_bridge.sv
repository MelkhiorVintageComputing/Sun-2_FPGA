`timescale 1ns/1ps
//
// sun2_fifo_bridge, driven as the machine drives a bridge, with its Wishbone
// side on a clock of its own.
//
// Two scenarios run at once, identical but for the Wishbone clock:
//
//   fast  83 MHz against a 20 MHz CPU clock -- MIG's ui_clk against cpu_clk
//   slow  7 MHz, *slower* than the CPU      -- nothing builds this, which is
//                                              why it is worth having
//
// What each checks, and why:
//
//   0  nothing reaches memory before ENABLE, however long a cycle waits
//   1  back-to-back writes then reads, across slave latencies 0..63: every
//      word lands and reads back; writes are acknowledged within two clocks
//      of their data phase unless the request FIFO is full, and at high
//      latency it must fill -- that is the control that says the
//      backpressure path was exercised at all
//   2  a read straight after a write to the same word, with the write still
//      queued behind a slow slave: the read must see the write.  This is the
//      correctness argument of acknowledging writes early, tested directly
//   3  a read abandoned before its answer arrives, then another read: the
//      late answer carries the old tag and must be discarded, not taken by
//      the new cycle -- the orphan-acknowledgement class of bug, by design
//      impossible here.  Control: stale answers were actually dropped
//   4  a read-modify-write in RD68011's order: one read and one write issued,
//      and the write lands
//   5  byte-wide writes on each strobe and each half, against the lane
//      mapping sun2_wishbone_bridge uses
//   6  the frame buffer's address is formed from FB_PAGE as the old bridge
//      forms it
//
// Throughout, a read's data is taken one clock after DTACK, as sun2_dvma's
// S_LATCH and the 68010 cores take it.
//

module fifo_bridge_scenario #(
   parameter real   WBH  = 6.0,
   parameter string NAME = "?"
) (
   output bit done,
   output int checks,
   output int fails
);
   localparam [29:0] FB_BASE = 30'h03E00000;

   bit CLK = 0, WB_CLK = 0;
   always #25    CLK    = ~CLK;
   always #(WBH) WB_CLK = ~WB_CLK;

   bit          RESET_n = 0, SET_ENABLE = 0, WB_RESET = 1;
   logic [23:1] P_ADR_IN = '0;
   logic [15:0] P_DATA_IN = '0;
   wire  [15:0] P_DATA_OUT;
   bit          P_RW_n = 1, EN_LBYTE = 0, EN_UBYTE = 0, MATCH_MEM = 0, MATCH_FB = 0;
   logic  [5:0] FB_PAGE = '0;
   wire         W_ACK;

   wire         wb_cyc_o, wb_stb_o, wb_we_o;
   wire  [29:0] wb_adr_o;
   wire  [31:0] wb_dat_o;
   wire   [3:0] wb_sel_o;
   logic [31:0] wb_dat_i = '0;
   bit          wb_ack_i = 0;

   sun2_fifo_bridge #(.FB_WB_BASE(FB_BASE)) dut (
      .SET_ENABLE(SET_ENABLE), .RESET_n(RESET_n), .CLK(CLK),
      .P_ADR_IN(P_ADR_IN), .P_DATA_IN(P_DATA_IN), .P_DATA_OUT(P_DATA_OUT),
      .P_RW_n(P_RW_n), .EN_LBYTE(EN_LBYTE), .EN_UBYTE(EN_UBYTE),
      .FB_PAGE(FB_PAGE), .MATCH_MEM(MATCH_MEM), .MATCH_FB(MATCH_FB), .W_ACK(W_ACK),
      .WB_CLK(WB_CLK), .WB_RESET(WB_RESET),
      .wb_cyc_o(wb_cyc_o), .wb_stb_o(wb_stb_o), .wb_adr_o(wb_adr_o),
      .wb_dat_o(wb_dat_o), .wb_sel_o(wb_sel_o), .wb_we_o(wb_we_o),
      .wb_dat_i(wb_dat_i), .wb_ack_i(wb_ack_i));

   task automatic check(input string what, input bit cond);
      checks++;
      if (!cond) begin
         fails++;
         if (fails <= 16) $display("  %s: FAIL %s", NAME, what);
      end
   endtask

   // ---- a registered Wishbone slave on WB_CLK, with settable wait states ----
   int          LAT = 0;
   logic [31:0] mem [0:1023];
   int          n_wr = 0, n_rd = 0, wcnt = 0;
   logic [29:0] last_adr;

   always @(posedge WB_CLK) begin
      wb_ack_i <= 1'b0;
      if (wb_cyc_o && wb_stb_o && !wb_ack_i) begin
         if (wcnt >= LAT) begin
            wcnt <= 0;
            wb_ack_i <= 1'b1;
            last_adr <= wb_adr_o;
            if (wb_we_o) begin
               n_wr++;
               if (wb_sel_o[0]) mem[wb_adr_o[9:0]][ 7: 0] <= wb_dat_o[ 7: 0];
               if (wb_sel_o[1]) mem[wb_adr_o[9:0]][15: 8] <= wb_dat_o[15: 8];
               if (wb_sel_o[2]) mem[wb_adr_o[9:0]][23:16] <= wb_dat_o[23:16];
               if (wb_sel_o[3]) mem[wb_adr_o[9:0]][31:24] <= wb_dat_o[31:24];
            end else begin
               n_rd++;
               wb_dat_i <= mem[wb_adr_o[9:0]];
            end
         end else
            wcnt <= wcnt + 1;
      end else if (!wb_cyc_o)
         wcnt <= 0;
   end

   // Stale answers dropped, counted from the bridge itself.
   int n_stale = 0;
   always @(posedge CLK) if (dut.rs_stale) n_stale++;

   // ---- one data phase, as the machine presents it ------------------------------
   task automatic bus_cycle(input logic [23:1] adr, input bit rw_n, input logic [15:0] wdata,
                            input bit ub, input bit lb, input bit fb, input int gap,
                            output logic [15:0] rdata, output int nclk);
      int guard;
      begin
         @(posedge CLK);
         P_ADR_IN <= adr; P_RW_n <= rw_n; P_DATA_IN <= wdata;
         EN_UBYTE <= ub;  EN_LBYTE <= lb;
         MATCH_MEM <= ~fb; MATCH_FB <= fb;
         guard = 0;
         do begin @(posedge CLK); guard++; end while (W_ACK !== 1'b1 && guard < 2000);
         nclk = guard;
         check($sformatf("%s at %06x acknowledged", rw_n ? "read" : "write", {adr, 1'b0}),
               guard < 2000);
         @(posedge CLK);
         rdata = P_DATA_OUT;                 // the clock after DTACK
         MATCH_MEM <= 0; MATCH_FB <= 0; EN_UBYTE <= 0; EN_LBYTE <= 0; P_RW_n <= 1;
         repeat (gap) @(posedge CLK);
      end
   endtask

   function automatic logic [15:0] pattern(input int k);
      pattern = 16'hC000 | 16'(k & 12'hFFF);
   endfunction

   initial begin
      logic [15:0] rd;
      int nclk, bad, slow_acks, max_free_ack, wr0, rd0;

      for (int i = 0; i < 1024; i++) mem[i] = 32'hDEADBEEF;
      repeat (6) @(posedge CLK);
      repeat (6) @(posedge WB_CLK);
      WB_RESET = 0;
      @(posedge CLK) RESET_n <= 1;
      repeat (8) @(posedge CLK);

      // ---- 0: nothing before ENABLE ----
      @(posedge CLK);
      P_ADR_IN <= 23'h000100; P_RW_n <= 1; EN_UBYTE <= 1; EN_LBYTE <= 1; MATCH_MEM <= 1;
      begin
         automatic bit acked = 0;
         repeat (40) begin @(posedge CLK); if (W_ACK === 1'b1) acked = 1; end
         check("0: no acknowledgement before ENABLE", !acked);
      end
      MATCH_MEM <= 0; EN_UBYTE <= 0; EN_LBYTE <= 0;
      repeat (40) @(posedge WB_CLK);
      check("0: nothing reached memory before ENABLE", n_wr == 0 && n_rd == 0);
      @(posedge CLK) SET_ENABLE <= 1;
      @(posedge CLK) SET_ENABLE <= 0;
      repeat (4) @(posedge CLK);

      // ---- 1: back-to-back writes then reads, across latencies ----
      slow_acks = 0; max_free_ack = 0;
      // 63 wait states is far slower than any memory here: it is there so the
      // request queue fills even against the fast Wishbone clock.
      for (int li = 0; li < 5; li++) begin
         automatic int lat = (li == 0) ? 0 : (li == 1) ? 3 : (li == 2) ? 7 : (li == 3) ? 15 : 63;
         for (int gap = 1; gap <= 2; gap++) begin
            LAT = lat;
            for (int i = 0; i < 1024; i++) mem[i] = 32'hDEADBEEF;
            wr0 = n_wr; bad = 0;
            for (int i = 0; i < 64; i++) begin
               bus_cycle(23'h000100 + i, 0, pattern(i), 1, 1, 0, gap, rd, nclk);
               // Edges sampled until DTACK: the phase is enqueued on the
               // first, `done' registers on the second, and DTACK is seen on
               // the third.  More than that is a write held back by a full
               // request queue.
               if (nclk > 3) slow_acks++;
               else if (nclk > max_free_ack) max_free_ack = nclk;
            end
            // Let the queue drain before reading memory directly: up to four
            // writes can still be queued behind a slave this slow, and they
            // were acknowledged long ago.
            begin
               automatic int g = 0;
               while ((n_wr - wr0 < 64 || dut.busy) && g < 200000) begin @(posedge CLK); g++; end
            end
            check($sformatf("1: lat %0d gap %0d: all 64 writes reached memory", lat, gap),
                  n_wr - wr0 == 64);
            for (int i = 0; i < 64; i++) begin
               automatic logic [23:1] a = 23'h000100 + i;
               automatic logic [15:0] got = a[1] ? mem[a >> 1][31:16] : mem[a >> 1][15:0];
               if (got !== pattern(i)) bad++;
            end
            check($sformatf("1: lat %0d gap %0d: every word landed with the right value", lat, gap), bad == 0);
            bad = 0;
            for (int i = 0; i < 64; i++) begin
               bus_cycle(23'h000100 + i, 1, 16'h0, 1, 1, 0, gap, rd, nclk);
               if (rd !== pattern(i)) begin
                  if (bad < 3) $display("  %s: lat %0d read %0d returned %04x, want %04x",
                                        NAME, lat, i, rd, pattern(i));
                  bad++;
               end
            end
            check($sformatf("1: lat %0d gap %0d: every read returned its word", lat, gap), bad == 0);
         end
      end
      $display("  %s: writes with room in the queue saw DTACK on sampled edge %0d; %0d waited on a full queue",
               NAME, max_free_ack, slow_acks);
      check("1: a write with room in the queue is acknowledged the clock after it is queued",
            max_free_ack == 3);
      check("1: control: the request FIFO filled and held a write back", slow_acks > 0);

      // ---- 2: read straight after a write to the same word, write still queued ----
      LAT = 15; bad = 0;
      for (int i = 0; i < 32; i++) begin
         automatic logic [15:0] v = 16'h7100 ^ 16'(i * 16'h0123);
         bus_cycle(23'h000180 + 2*i, 0, v, 1, 1, 0, 1, rd, nclk);
         bus_cycle(23'h000180 + 2*i, 1, 16'h0, 1, 1, 0, 1, rd, nclk);
         if (rd !== v) begin
            if (bad < 3) $display("  %s: read after write returned %04x, want %04x", NAME, rd, v);
            bad++;
         end
      end
      check("2: a read queued behind an unperformed write sees the write (32 of 32)", bad == 0);

      // ---- 3: an abandoned read's late answer is discarded ----
      LAT = 20; bad = 0;
      mem[23'h000300 >> 1] = 32'hAAAA_1111;
      mem[23'h000302 >> 1] = 32'hBBBB_2222;
      repeat (400) @(posedge CLK);
      for (int k = 0; k < 8; k++) begin
         // Start a read of one word, and walk away before it is answered.
         @(posedge CLK);
         P_ADR_IN <= 23'h000300 >> 1 << 1; P_RW_n <= 1; EN_UBYTE <= 1; EN_LBYTE <= 1; MATCH_MEM <= 1;
         repeat (3) @(posedge CLK);
         MATCH_MEM <= 0; EN_UBYTE <= 0; EN_LBYTE <= 0;
         @(posedge CLK);
         // Another read, of a different word, while the first is still out.
         bus_cycle(23'h000302 >> 1 << 1 | 23'h1, 1, 16'h0, 1, 1, 0, 1, rd, nclk);
         if (rd !== 16'hBBBB) begin
            if (bad < 3) $display("  %s: second read returned %04x, want bbbb", NAME, rd);
            bad++;
         end
      end
      $display("  %s: stale answers dropped: %0d", NAME, n_stale);
      check("3: a read after an abandoned one returns its own word (8 of 8)", bad == 0);
      check("3: control: the abandoned reads' answers arrived and were dropped", n_stale >= 8);

      // ---- 4: read-modify-write, RD68011's order ----
      for (int li = 0; li < 2; li++) begin
         LAT = li ? 7 : 0;
         mem[23'h000200 >> 1] = 32'h11112222;
         repeat (400) @(posedge CLK);
         wr0 = n_wr; rd0 = n_rd;
         @(posedge CLK);
         P_ADR_IN <= 23'h000200; P_RW_n <= 1; EN_UBYTE <= 1; EN_LBYTE <= 1; MATCH_MEM <= 1;
         begin automatic int g = 0; do begin @(posedge CLK); g++; end while (W_ACK !== 1'b1 && g < 2000); end
         @(posedge CLK);
         rd = P_DATA_OUT;
         EN_UBYTE <= 0; EN_LBYTE <= 0;          // MATCH_MEM stays: AS is held
         repeat (2) @(posedge CLK);
         P_RW_n <= 0; P_DATA_IN <= rd | 16'h0080;
         @(posedge CLK);
         EN_UBYTE <= 1; EN_LBYTE <= 1;
         begin automatic int g = 0; do begin @(posedge CLK); g++; end while (W_ACK !== 1'b1 && g < 2000); end
         @(posedge CLK);
         MATCH_MEM <= 0; EN_UBYTE <= 0; EN_LBYTE <= 0; P_RW_n <= 1;
         repeat (400) @(posedge CLK);
         check($sformatf("4: lat %0d: RMW issues one read and one write, and the write lands", LAT),
               n_rd - rd0 == 1 && n_wr - wr0 == 1 && mem[23'h000200 >> 1][15:0] === (rd | 16'h0080)
               && rd === 16'h2222);
      end

      // ---- 5: byte lanes ----
      LAT = 1;
      mem[23'h000280 >> 1] = 32'h0;
      bus_cycle(23'h000280, 0, 16'hA1B2, 1, 0, 0, 1, rd, nclk);   // UDS, A1=0
      bus_cycle(23'h000280, 0, 16'hC3D4, 0, 1, 0, 1, rd, nclk);   // LDS, A1=0
      bus_cycle(23'h000281, 0, 16'hE5F6, 1, 0, 0, 1, rd, nclk);   // UDS, A1=1
      bus_cycle(23'h000281, 0, 16'h0718, 0, 1, 0, 1, rd, nclk);   // LDS, A1=1
      repeat (100) @(posedge CLK);
      check($sformatf("5: byte writes follow the old lane mapping (memory %08x, want e518a1d4)",
                      mem[23'h000280 >> 1]), mem[23'h000280 >> 1] === 32'hE518A1D4);
      bus_cycle(23'h000280, 1, 16'h0, 1, 1, 0, 1, rd, nclk);
      check("5: the low half reads back", rd === 16'hA1D4);
      bus_cycle(23'h000281, 1, 16'h0, 1, 1, 0, 1, rd, nclk);
      check("5: the high half reads back", rd === 16'hE518);

      // ---- 6: frame buffer addressing ----
      FB_PAGE = 6'h2A;
      bus_cycle(23'h000123, 0, 16'h1234, 1, 1, 1, 1, rd, nclk);
      repeat (100) @(posedge CLK);
      check($sformatf("6: the frame buffer address is FB_WB_BASE | page | offset (%08x)", last_adr),
            last_adr === (FB_BASE | {15'h0, 6'h2A, 9'(23'h000123 >> 1)}));

      done = 1;
   end
endmodule

module tb_fifo_bridge;
   bit done_f, done_s;
   int checks_f, checks_s, fails_f, fails_s;

   fifo_bridge_scenario #(.WBH(6.0),  .NAME("fast WB clock")) f (.done(done_f), .checks(checks_f), .fails(fails_f));
   fifo_bridge_scenario #(.WBH(71.0), .NAME("slow WB clock")) s (.done(done_s), .checks(checks_s), .fails(fails_s));

   initial begin
      $display("=== tb_fifo_bridge: sun2_fifo_bridge, CPU at 20 MHz, Wishbone at 83 and 7 MHz ===");
      wait (done_f && done_s);
      $display("=== %0d checks, %0d failures ===", checks_f + checks_s, fails_f + fails_s);
      if (fails_f + fails_s == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end
   initial begin #2_000_000_000; $display("FAIL: timeout"); $finish; end
endmodule
