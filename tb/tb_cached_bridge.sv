`timescale 1ns/1ps
//
// sun2_cached_fifo_bridge: a read cache in front of the FIFO bridge.
//
// The cache's whole claim is that it can never return anything the bus would
// not have returned without it.  So the heart of this test is a *bus-level
// shadow*: every write, as the bus presents it, updates the shadow the moment
// it is acknowledged, and every read, hit or miss, is compared against it.
// The Wishbone slave behind the bridge is only the backing store; the shadow is
// the architecture.
//
// Directed checks, one per rule the design relies on:
//   1  the power-on sweep: the first read of a line is a miss
//   2  a line brought in by one miss serves its other seven halfwords as hits,
//      with DTACK in the phase's first clock
//   3  a write hit updates the cached line (each byte strobe on its own)
//   4  a write miss allocates nothing, and the next read of that line sees it
//   5  two lines on the same index evict each other and both stay right
//   6  a write whose lookup cannot be trusted (address on the bus too late)
//      invalidates the line rather than leaving it stale
//   7  an abandoned read's late answer is never installed -- held under a long
//      cacheable write phase, which is when a careless install would land
//   8  frame-buffer reads are never cached, even when FB_PAGE aliases a
//      memory line on the same index and tag (the VME machine's arrangement)
// then a long randomised run of all of it, against the shadow.  The tag RAM
// starts full of false "valid" lines, so a missing power-on sweep shows.
//
// One guard is not reachable from here, deliberately: a lookup is distrusted
// if a cache write landed on the edge that registered it.  A cache write only
// happens inside a data phase (a fill, a write hit), and the next phase's
// lookup is registered at least two clocks after that phase ends, so removing
// the guard changes nothing this bus can do -- the same way tb_wb_bridge's
// gap=0 case is not physically realisable.  It is kept because it costs one
// flip-flop and the argument above is about the bus, not about the bridge.
//
// Two scenarios, Wishbone at 83 MHz and at 7 MHz against a 20 MHz CPU, each
// with an 8-line cache so that aliasing is constant rather than rare.
//

module cached_scenario #(
   parameter real   WBH  = 6.0,
   parameter string NAME = "?"
) (
   output bit done,
   output int checks,
   output int fails
);
   localparam [29:0] FB_BASE = 30'h03E00000;
   localparam int    IDX     = 3;             // 8 lines of 16 bytes

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

   wire          wb_cyc_o, wb_stb_o, wb_we_o;
   wire  [29:0]  wb_adr_o;
   wire  [31:0]  wb_dat_o;
   wire   [3:0]  wb_sel_o;
   logic [31:0]  wb_dat_i = '0;
   logic [127:0] wb_line_i = '0;
   bit           wb_ack_i = 0;

   sun2_cached_fifo_bridge #(.FB_WB_BASE(FB_BASE), .IDX(IDX)) dut (
      .SET_ENABLE(SET_ENABLE), .RESET_n(RESET_n), .CLK(CLK),
      .P_ADR_IN(P_ADR_IN), .P_DATA_IN(P_DATA_IN), .P_DATA_OUT(P_DATA_OUT),
      .P_RW_n(P_RW_n), .EN_LBYTE(EN_LBYTE), .EN_UBYTE(EN_UBYTE),
      .FB_PAGE(FB_PAGE), .MATCH_MEM(MATCH_MEM), .MATCH_FB(MATCH_FB), .W_ACK(W_ACK),
      .WB_CLK(WB_CLK), .WB_RESET(WB_RESET),
      .wb_cyc_o(wb_cyc_o), .wb_stb_o(wb_stb_o), .wb_adr_o(wb_adr_o),
      .wb_dat_o(wb_dat_o), .wb_sel_o(wb_sel_o), .wb_we_o(wb_we_o),
      .wb_dat_i(wb_dat_i), .wb_ack_i(wb_ack_i), .wb_line_i(wb_line_i));

   task automatic check(input string what, input bit cond);
      checks++;
      if (!cond) begin
         fails++;
         if (fails <= 16) $display("  %s: FAIL %s", NAME, what);
      end
   endtask

   // ---- the backing store: a registered Wishbone slave returning whole lines ----
   int          LAT = 2;
   logic [31:0] mem [int unsigned];
   int          wcnt = 0;
   function automatic logic [31:0] initword(input int unsigned a);
      initword = {a[15:0] ^ 16'hA55A, a[15:0] ^ 16'h0F0F};
   endfunction
   function automatic logic [31:0] rdw(input int unsigned a);
      rdw = mem.exists(a) ? mem[a] : initword(a);
   endfunction

   always @(posedge WB_CLK) begin
      wb_ack_i <= 1'b0;
      if (wb_cyc_o && wb_stb_o && !wb_ack_i) begin
         if (wcnt >= LAT) begin
            automatic int unsigned a = wb_adr_o;
            automatic logic [31:0] w = rdw(a);
            wcnt <= 0;
            wb_ack_i <= 1'b1;
            if (wb_we_o) begin
               if (wb_sel_o[0]) w[ 7: 0] = wb_dat_o[ 7: 0];
               if (wb_sel_o[1]) w[15: 8] = wb_dat_o[15: 8];
               if (wb_sel_o[2]) w[23:16] = wb_dat_o[23:16];
               if (wb_sel_o[3]) w[31:24] = wb_dat_o[31:24];
               mem[a] = w;
            end else begin
               wb_dat_i  <= w;
               wb_line_i <= {rdw(a | 3), rdw((a & ~3) | 2), rdw((a & ~3) | 1), rdw(a & ~3)};
            end
         end else
            wcnt <= wcnt + 1;
      end else if (!wb_cyc_o)
         wcnt <= 0;
   end

   // ---- the architecture: a bus-level shadow of every halfword ----------------
   // Keyed by {fb, halfword address}: frame buffer and memory are different
   // places even when their page numbers alias.
   logic [15:0] shadow [longint unsigned];
   function automatic logic [29:0] wbword(input bit fb, input logic [23:1] a, input logic [5:0] page);
      wbword = fb ? (FB_BASE | {15'h0, page, a[10:2]}) : {8'h0, a[23:2]};
   endfunction
   function automatic longint unsigned skey(input bit fb, input logic [23:1] a, input logic [5:0] page);
      skey = {fb, wbword(fb, a, page), a[1]};
   endfunction
   function automatic logic [15:0] expect_hw(input bit fb, input logic [23:1] a, input logic [5:0] page);
      automatic longint unsigned k = skey(fb, a, page);
      automatic logic [31:0] w = initword(wbword(fb, a, page));
      expect_hw = shadow.exists(k) ? shadow[k] : (a[1] ? w[31:16] : w[15:0]);
   endfunction

   // ---- one data phase ------------------------------------------------------
   //   setup  clocks the address is on the bus before the phase (the lookup
   //          needs one); 0 = address and strobes on the same edge
   //   hold   clocks the phase stays up after DTACK
   //   abandon  drop the phase after that many clocks, whether answered or not
   int n_rd = 0, n_bad = 0, n_first_clock_ack = 0;
   task automatic phase(input bit fb, input logic [23:1] a, input bit rw_n, input logic [15:0] d,
                        input bit ub, input bit lb, input int setup, input int hold,
                        input int abandon, output logic [15:0] q, output bit acked);
      int n;
      begin
         @(posedge CLK);
         P_ADR_IN <= a; P_RW_n <= rw_n; P_DATA_IN <= d;
         repeat (setup) @(posedge CLK);
         MATCH_MEM <= ~fb; MATCH_FB <= fb; EN_UBYTE <= ub; EN_LBYTE <= lb;
         n = 0; acked = 0;
         do begin
            @(posedge CLK); n++;
            if (W_ACK === 1'b1) acked = 1;
         end while (!acked && n < 3000 && !(abandon > 0 && n >= abandon));
         if (acked) begin
            if (n == 1 && rw_n) n_first_clock_ack++;
            @(posedge CLK);
            q = P_DATA_OUT;                         // the clock after DTACK
            if (!rw_n) begin
               automatic longint unsigned k = skey(fb, a, FB_PAGE);
               automatic logic [15:0] v = expect_hw(fb, a, FB_PAGE);
               if (ub) v[15:8] = d[15:8];
               if (lb) v[ 7:0] = d[ 7:0];
               shadow[k] = v;
            end else begin
               n_rd++;
               if (q !== expect_hw(fb, a, FB_PAGE)) begin
                  n_bad++;
                  if (n_bad <= 4)
                    $display("  %s: read %s %06x returned %04x, the bus says %04x", NAME,
                             fb ? "FB" : "mem", {a, 1'b0}, q, expect_hw(fb, a, FB_PAGE));
               end
            end
         end else if (abandon == 0)
            check($sformatf("phase at %06x acknowledged", {a, 1'b0}), 0);
         repeat (hold) @(posedge CLK);
         MATCH_MEM <= 0; MATCH_FB <= 0; EN_UBYTE <= 0; EN_LBYTE <= 0; P_RW_n <= 1;
         @(posedge CLK);
      end
   endtask

   task automatic rd(input logic [23:1] a, output logic [15:0] q);
      bit k; phase(0, a, 1, 16'h0, 1, 1, 1, 0, 0, q, k);
   endtask
   task automatic wr(input logic [23:1] a, input logic [15:0] d, input bit ub, input bit lb, input int setup);
      logic [15:0] q; bit k; phase(0, a, 0, d, ub, lb, setup, 0, 0, q, k);
   endtask

   // A line's first halfword address: 16 bytes = 8 halfwords.
   function automatic logic [23:1] L(input int line, input int hw);
      L = 23'(line * 8 + hw);
   endfunction

   // Wait for the request queue to drain.
   task automatic settle();
      int g = 0;
      while ((dut.busy || !dut.rq_empty) && g < 20000) begin @(posedge CLK); g++; end
      repeat (20) @(posedge CLK);
   endtask

   int st_hit0, st_miss0, st_fill0, st_winval0, st_whit0, st_wmiss0, stale0;
   int n_stale = 0;
   always @(posedge CLK) if (dut.rs_stale) n_stale++;

   // RAM does not power up empty on every part, and in simulation it powers
   // up X -- which makes the hit logic fall through to a miss and would hide a
   // missing sweep entirely.  So start from the worst case: every line "valid",
   // tagged as lines the test is about to read.  Only the power-on sweep stands
   // between that and a false hit returning garbage.
   initial for (int i = 0; i < (1 << IDX); i++) dut.tmem[i] = (1 << dut.TAGW) | 5;   // valid, lines 40..47

   initial begin
      logic [15:0] q;
      bit          k;
      repeat (6) @(posedge CLK);
      repeat (6) @(posedge WB_CLK);
      WB_RESET = 0;
      @(posedge CLK) RESET_n <= 1;
      repeat (40) @(posedge CLK);                   // the valid-bit sweep: 8 clocks
      @(posedge CLK) SET_ENABLE <= 1;
      @(posedge CLK) SET_ENABLE <= 0;
      repeat (4) @(posedge CLK);

      // ---- 1, 2: a fresh line misses, then serves its other halfwords ----
      st_hit0 = dut.n_hit; st_miss0 = dut.n_miss;
      for (int h = 0; h < 8; h++) rd(L(40, h), q);
      check("1: the first read of a line after the sweep is a miss",
            dut.n_miss - st_miss0 == 1);
      check($sformatf("2: the line's other seven halfwords are hits (%0d)", dut.n_hit - st_hit0),
            dut.n_hit - st_hit0 == 7);
      check($sformatf("2: a hit raises DTACK in the phase's first clock (%0d of 7)", n_first_clock_ack),
            n_first_clock_ack >= 7);

      // ---- 3: a write hit updates the line, each byte on its own ----
      st_whit0 = dut.n_whit; st_hit0 = dut.n_hit;
      wr(L(40, 2), 16'hAB00, 1, 0, 1);
      wr(L(40, 2), 16'h00CD, 0, 1, 1);
      wr(L(40, 5), 16'h1234, 1, 1, 1);
      rd(L(40, 2), q); check("3: upper then lower byte writes land in the cached line", q === 16'hABCD);
      rd(L(40, 5), q); check("3: a whole-word write lands in the cached line", q === 16'h1234);
      check("3: all three writes were hits, and both reads", dut.n_whit - st_whit0 == 3 && dut.n_hit - st_hit0 == 2);

      // ---- 4: a write miss allocates nothing, and memory has it ----
      st_wmiss0 = dut.n_wmiss; st_fill0 = dut.n_fill; st_miss0 = dut.n_miss;
      wr(L(41, 3), 16'h4141, 1, 1, 1);
      check("4: a write to an absent line is a write miss, and fills nothing",
            dut.n_wmiss - st_wmiss0 == 1 && dut.n_fill == st_fill0);
      rd(L(41, 3), q);
      check("4: the next read of that line misses and sees the write", q === 16'h4141 && dut.n_miss - st_miss0 == 1);

      // ---- 5: two lines on one index (8 lines, so line+8) evict each other ----
      st_miss0 = dut.n_miss;
      rd(L(42, 0), q); rd(L(50, 0), q); rd(L(42, 1), q); rd(L(50, 1), q);
      check("5: two lines sharing an index miss every time they alternate", dut.n_miss - st_miss0 == 4);

      // ---- 6: a write with no trustworthy lookup invalidates the line ----
      rd(L(43, 0), q);                                   // bring line 43 in
      rd(L(47, 0), q);                                   // leave another line on the bus
      st_winval0 = dut.n_winval; st_miss0 = dut.n_miss;
      // The write's address arrives with its strobes, so the RAMs are still
      // showing line 47's lookup.  (Moving only the halfword within the same
      // line would not do: the line's lookup stays valid, and is used.)
      wr(L(43, 4), 16'h6666, 1, 1, 0);
      check("6: a write whose lookup cannot be trusted invalidates", dut.n_winval - st_winval0 == 1);
      rd(L(43, 4), q);
      check("6: ... so the next read misses and sees the write", q === 16'h6666 && dut.n_miss - st_miss0 == 1);

      // ---- 7: an abandoned read's late answer is never installed ----
      LAT = (WBH > 20) ? 30 : 200;                        // well beyond the phase below
      stale0 = n_stale;
      phase(0, L(44, 0), 1, 16'h0, 1, 1, 1, 0, 3, q, k);  // read line 44, walk away
      // A long cacheable write phase to another line, held while the stale
      // answer comes back: that is when an install on any answer would land.
      phase(0, L(45, 1), 0, 16'h4545, 1, 1, 1, 400, 0, q, k);
      LAT = 2;
      settle();
      check("7: the abandoned read's answer came back and was dropped", n_stale > stale0);
      rd(L(45, 1), q);
      check("7: the line written meanwhile reads back what was written, not line 44", q === 16'h4545);
      rd(L(45, 0), q);
      check("7: ... and its other halfwords are memory's, not line 44's", q === expect_hw(0, L(45, 0), 0));

      // ---- 8: frame-buffer reads are never cached, even aliased onto a line ----
      FB_PAGE = 6'h00;
      rd(L(46, 0), q);                                    // memory line 46 cached
      st_hit0 = dut.n_hit;
      phase(1, L(46, 0), 0, 16'hFBFB, 1, 1, 1, 0, 0, q, k);   // FB write, same P_ADR_IN
      phase(1, L(46, 0), 1, 16'h0, 1, 1, 1, 0, 0, q, k);
      check("8: a frame-buffer read on a cached line's address is not a hit", dut.n_hit == st_hit0);
      check("8: ... and returns the frame buffer's word", q === 16'hFBFB);
      rd(L(46, 0), q);
      check("8: the memory line beside it is untouched by the FB write", q === expect_hw(0, L(46, 0), 0));

      // ---- random: everything, against the shadow ----
      begin
         automatic int unsigned seed = 32'hC0FFEE11;
         for (int i = 0; i < 6000; i++) begin
            automatic int r = $urandom(seed) & 32'hFFFF;
            automatic int line = 32 + ((r >> 3) & 31);        // 32 lines on 8 indices
            automatic int hw = r & 7;
            automatic bit fb = ((r >> 8) & 15) == 0;
            automatic bit w  = ((r >> 12) & 3) == 0;
            automatic int setup = ((r >> 14) & 3) == 0 ? 0 : 1 + ((r >> 5) & 1);
            automatic bit ub = w ? (((r >> 9) & 3) != 1) : 1;
            automatic bit lb = w ? (((r >> 9) & 3) != 2) : 1;
            automatic int ab = (!w && ((r >> 10) & 63) == 0) ? 2 : 0;
            seed = seed * 1103515245 + 12345;
            LAT = ((r >> 13) & 7) == 0 ? 20 : 2;
            FB_PAGE = 6'((r >> 4) & 1);
            phase(fb, L(line, hw), !w, 16'(r * 40503), ub, lb, setup, 0, ab, q, k);
         end
      end
      settle();
      $display("  %s: %0d reads checked against the bus, %0d wrong; cache: %0d hits, %0d misses, %0d uncached, %0d fills, %0d write hits, %0d write misses, %0d invalidations; %0d stale answers dropped",
               NAME, n_rd, n_bad, dut.n_hit, dut.n_miss, dut.n_uncached, dut.n_fill,
               dut.n_whit, dut.n_wmiss, dut.n_winval, n_stale);
      check("every read, hit or miss, returned what the bus says it should", n_bad == 0);
      check("control: hits, misses, fills, write hits, write misses and invalidations all happened",
            dut.n_hit > 0 && dut.n_miss > 0 && dut.n_fill > 0 && dut.n_whit > 0 && dut.n_wmiss > 0 && dut.n_winval > 0);
      check("control: stale answers were dropped", n_stale > 0);
      done = 1;
   end
endmodule

module tb_cached_bridge;
   bit done_f, done_s;
   int checks_f, checks_s, fails_f, fails_s;
   cached_scenario #(.WBH(6.0),  .NAME("fast WB clock")) f (.done(done_f), .checks(checks_f), .fails(fails_f));
   cached_scenario #(.WBH(71.0), .NAME("slow WB clock")) s (.done(done_s), .checks(checks_s), .fails(fails_s));
   initial begin
      $display("=== tb_cached_bridge: sun2_cached_fifo_bridge, 8 lines, CPU at 20 MHz, Wishbone at 83 and 7 MHz ===");
      wait (done_f && done_s);
      $display("=== %0d checks, %0d failures ===", checks_f + checks_s, fails_f + fails_s);
      if (fails_f + fails_s == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end
   initial begin #(4.0e9); $display("FAIL: timeout"); $finish; end
endmodule
