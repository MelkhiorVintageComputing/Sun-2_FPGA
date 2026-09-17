`timescale 1ns / 1ps

//
// tb_orphan_ack -- a bus-errored memory access, and the memory cycle after it.
//
// What the bus-history capture of 2026-09-13 showed on the board:
//
//   * a user-mode read at a page the MMU refuses: AS, C_S4, C_S6, then BERR,
//     no DTACK;
//   * in the clock after AS negates, C_S6 is still set -- the chain clears on
//     the posedge after AS goes away -- while MMU_REFUSE, which is gated by
//     ~P_AS_n, has already dropped.  MATCH_MEM is `... & MMU_OK & ... & C_S6'
//     and is NOT gated by AS, so it is true for that one clock, and the bridge
//     issues a Wishbone request for the refused access;
//   * the DDR3 adapter latches a request on its first clock and runs it to
//     completion, and ignores any new request while it is busy;
//   * the master's next memory cycle raises its own request, which the adapter
//     ignores, and the orphaned read's acknowledge arrives inside that cycle.
//     The bridge takes `wb_ack_i & issued' as its own, loads the refused
//     page's word and sets `done', so the new cycle's read is never issued.
//
// That hands a master program text -- the refused page's contents -- in the
// first halfword of a longword, which is the whole signature of the disk
// corruption.
//
// None of that is reachable from tb_sun2: its wb_ram_model counts wait states
// only while CYC and STB are held, so a one-clock request simply resets it.
// The real adapters latch.  So this drives the *real* sun2_fpga -- MMU, C_S
// chain, MATCH_MEM and bridge -- with a 68010 bus-functional driver, into the
// real wb_to_mig_ui, mig_arb and a MIG UI model.
//
// The checks, each of which fails on the RTL that corrupts:
//
//   1. a refused read issues no Wishbone request at all;
//   2. a valid read starting `gap' clocks after a refused one returns its own
//      page's data, for gaps from 0 to 12 clocks -- with a valid first read
//      over the same gaps as the control;
//   3. a refused write does not reach memory.
//

module tb_orphan_ack;

   // ---- clocks and reset ------------------------------------------------
   reg cpu_clk = 1'b0, ui_clk = 1'b0, clk40 = 1'b0, clk4m9152 = 1'b0;
   always #25.0  cpu_clk   = ~cpu_clk;     // 20 MHz, as on the Wukong
   always #6.0   ui_clk    = ~ui_clk;      // 83 MHz, MIG's user clock
   always #12.7  clk40     = ~clk40;
   always #101.7 clk4m9152 = ~clk4m9152;

   reg sys_reset = 1'b1;

   // ---- the 68010 side, driven by the tasks below -------------------------
   reg  [23:1] P_A    = 23'h0;
   reg  [2:0]  P_FC   = 3'd5;
   reg         P_AS_n = 1'b1, P_RW_n = 1'b1, P_UDS_n = 1'b1, P_LDS_n = 1'b1;
   reg  [15:0] P_DIN  = 16'h0;
   wire [15:0] P_DOUT;
   wire        P_DTACK_n, P_BERR_n;

   wire        wb_cyc, wb_stb, wb_we, wb_ack;
   wire [29:0] wb_adr;
   wire [31:0] wb_dat_m2s, wb_dat_s2m;
   wire [3:0]  wb_sel;

   sun2_fpga dut (
       .cpu_clk (cpu_clk), .clk40 (clk40), .clk4m9152 (clk4m9152), .C100 (),
       .sys_reset (sys_reset), .P_VPA_n (), .P_BERR_n (P_BERR_n), .P_DTACK_n (P_DTACK_n),
       .P_RESET_n (~sys_reset), .P_HALT_n (),
       .P_AS_n (P_AS_n), .P_RW_n (P_RW_n), .P_UDS_n (P_UDS_n), .P_LDS_n (P_LDS_n),
       .P_BG_n (1'b1), .BUS_EN (1'b1),
       .IPL2_n (), .IPL1_n (), .IPL0_n (),
       .P_FC (P_FC), .P_A (P_A), .P_DIN (P_DIN), .P_DOUT (P_DOUT),
       .DATA_EN (~P_AS_n & ~P_RW_n),       // loopback: only while writing
       .tx (), .rx (1'b1),
       .EN_DVMA_o (), .ether_core_reset_n (), .ether_loopback_n (), .ether_ca (),
       .ether_int_en (), .ether_int (1'b0), .ether_bus_err (1'b0),
       .phy_id (16'h0), .phy_present (1'b0), .phy_cfg_done (1'b0), .phy_link (1'b0),
       .phy_fd (1'b0), .phy_speed (2'b0), .phy_crs_stuck (1'b0),
       .fb_video_en_o (), .mb_sel (), .por_reset_o (),
       .mb_addr (), .mb_we (), .mb_uds_n (), .mb_lds_n (), .mb_dout (),
       .mb_din (16'h0), .mb_hit (1'b0), .mb_ack (1'b0), .mb_int2 (1'b0),
       .mbio_sel (), .mbio_addr (), .mbio_we (), .mbio_uds_n (), .mbio_lds_n (),
       .mbio_dout (), .mbio_din (16'h0), .mbio_hit (1'b0), .mbio_ack (1'b0),
       .mbio_int (1'b0),
       .vec_int (1'b0), .vec_level (3'd0), .vec_num (8'h0),
       .diag_leds (), .en_boot (), .todebug (),
       .wb_cyc_o (wb_cyc), .wb_stb_o (wb_stb), .wb_adr_o (wb_adr),
       .wb_dat_o (wb_dat_m2s), .wb_sel_o (wb_sel), .wb_we_o (wb_we),
       .wb_dat_i (wb_dat_s2m), .wb_ack_i (wb_ack)
   );

   // ---- the real memory path, as on the Wukong ----------------------------
   wire [27:0]  app_addr, c0_addr;
   wire [2:0]   app_cmd;
   wire         app_en, app_rdy, app_wdf_wren, app_wdf_end, app_wdf_rdy, app_rd_data_valid;
   wire [127:0] app_wdf_data, app_rd_data, c0_wdata, c0_rdata;
   wire [15:0]  app_wdf_mask, c0_wmask;
   wire         c0_we, c0_req, c0_done;

   wb_to_mig_ui ad (
       .clk_wb (cpu_clk), .rst_wb (sys_reset),
       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb), .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_m2s), .wb_sel_i (wb_sel), .wb_we_i (wb_we),
       .wb_dat_o (wb_dat_s2m), .wb_ack_o (wb_ack),
       .ui_clk (ui_clk), .ui_rst (sys_reset),
       .c_addr (c0_addr), .c_we (c0_we), .c_wdata (c0_wdata), .c_wmask (c0_wmask),
       .c_req (c0_req), .c_done (c0_done), .c_rdata (c0_rdata)
   );

   mig_arb arbiter (
       .ui_clk (ui_clk), .ui_rst (sys_reset), .init_calib_complete (1'b1),
       .c0_addr (c0_addr), .c0_we (c0_we), .c0_wdata (c0_wdata), .c0_wmask (c0_wmask),
       .c0_req (c0_req), .c0_done (c0_done), .c0_rdata (c0_rdata),
       .c1_addr (28'h0), .c1_req (1'b0), .c1_done (), .c1_rdata (),
       .app_addr (app_addr), .app_cmd (app_cmd), .app_en (app_en), .app_rdy (app_rdy),
       .app_wdf_data (app_wdf_data), .app_wdf_mask (app_wdf_mask),
       .app_wdf_wren (app_wdf_wren), .app_wdf_end (app_wdf_end), .app_wdf_rdy (app_wdf_rdy),
       .app_rd_data (app_rd_data), .app_rd_data_valid (app_rd_data_valid)
   );

   mig_ui_model #(.READ_LATENCY (7), .STALL_PERCENT (0)) mig (
       .ui_clk (ui_clk), .ui_rst (sys_reset),
       .app_addr (app_addr), .app_cmd (app_cmd), .app_en (app_en), .app_rdy (app_rdy),
       .app_wdf_data (app_wdf_data), .app_wdf_mask (app_wdf_mask),
       .app_wdf_wren (app_wdf_wren), .app_wdf_end (app_wdf_end), .app_wdf_rdy (app_wdf_rdy),
       .app_rd_data (app_rd_data), .app_rd_data_valid (app_rd_data_valid)
   );

   // ---- what the adapter actually took --------------------------------------
   // req_tgl flips once per request the adapter latches; wb_we at that moment
   // says whether it was a write.
   int n_req = 0, n_req_wr = 0;
   reg req_tgl_q = 1'b0;
   always @(posedge cpu_clk) begin
      req_tgl_q <= ad.req_tgl;
      if (ad.req_tgl !== req_tgl_q && !sys_reset) begin
         n_req++;
         if (ad.req_we) n_req_wr++;
      end
   end

   // ---- a 68010 bus cycle ----------------------------------------------------
   // S0/S1: address, FC and R/W on a rising edge.  S2: AS and the strobes on the
   // falling edge.  The cycle ends when DTACK or BERR is seen on a rising edge;
   // data is latched and AS and the strobes released on the next falling edge,
   // which is when RD68011 released them in the board capture (BERR, then AS
   // negated a clock later).  A write keeps R/W low for a clock after AS.
   task automatic cycle(input logic [2:0] fc, input logic [23:0] addr, input bit rd,
                        input logic [15:0] wdata, output logic [15:0] rdata,
                        output bit berr, output bit ok);
      int n;
      begin
         @(posedge cpu_clk);
         P_A <= addr[23:1]; P_FC <= fc; P_RW_n <= rd; P_DIN <= wdata;
         @(negedge cpu_clk);
         P_AS_n <= 1'b0; P_UDS_n <= 1'b0; P_LDS_n <= 1'b0;
         n = 0; ok = 1'b1;
         do begin
            @(posedge cpu_clk);
            n++;
         end while (P_DTACK_n && P_BERR_n && n < 400);
         if (n >= 400) ok = 1'b0;
         berr = ~P_BERR_n;
         @(negedge cpu_clk);
         rdata = P_DOUT;
         P_AS_n <= 1'b1; P_UDS_n <= 1'b1; P_LDS_n <= 1'b1;
         @(posedge cpu_clk);
         P_RW_n <= 1'b1;
      end
   endtask

   int checks = 0, fails = 0;
   task automatic check(input string what, input bit cond);
      begin
         checks++;
         if (!cond) begin fails++; $display("  FAIL %s", what); end
      end
   endtask

   task automatic wr(input logic [2:0] fc, input logic [23:0] a, input logic [15:0] d);
      logic [15:0] r; bit be, ok;
      begin
         cycle(fc, a, 1'b0, d, r, be, ok);
         if (!ok || be) $display("  setup write FC%0d %06x <= %04x: %s", fc, a, d,
                                  !ok ? "no response" : "bus error");
      end
   endtask

   task automatic rd_(input logic [2:0] fc, input logic [23:0] a, output logic [15:0] d,
                      output bit be);
      bit ok;
      begin
         cycle(fc, a, 1'b1, 16'h0, d, be, ok);
         if (!ok) $display("  read FC%0d %06x: no response", fc, a);
      end
   endtask

   // ---- the scenario ------------------------------------------------------------
   localparam logic [23:0] V_BAD  = 24'h004000;   // segment 0, page 8
   localparam logic [23:0] V_GOOD = 24'h006000;   // segment 0, page 12
   localparam logic [15:0] PME_RWX_MEM  = 16'hFE00;  // VALID, all perms, TYPE 0
   localparam logic [15:0] PME_INVALID  = 16'h7E00;  // same, VALID clear
   localparam int N_GAP = 13;

   int stolen_refused [N_GAP], stolen_control [N_GAP], req_during [N_GAP];
   // What the wrong reads got: the refused page's word at the same offset (the
   // board's 23ed584f), or something else.
   int got_refused_word [N_GAP];
   logic [15:0] first_wrong [N_GAP];

   initial begin
      logic [15:0] d; bit be;
      int base, got_bad, got_good;
      $display("=== tb_orphan_ack: refused memory access, then the next memory cycle ===");

      repeat (20) @(posedge cpu_clk);
      sys_reset = 1'b0;
      repeat (20) @(posedge cpu_clk);

      // Context 0 both halves, segment 0 -> pmeg 0 in it, both pages mapped.
      wr(3'd3, V_BAD + 24'h6, 16'h0000);
      wr(3'd3, V_BAD + 24'h4, 16'h0000);
      wr(3'd3, V_BAD,        PME_RWX_MEM);  wr(3'd3, V_BAD  + 24'h2, 16'h0011);
      wr(3'd3, V_GOOD,       PME_RWX_MEM);  wr(3'd3, V_GOOD + 24'h2, 16'h0010);
      // LED code 0x8F arms the bridge.
      wr(3'd3, V_BAD + 24'hA, 16'h8F8F);
      repeat (4) @(posedge cpu_clk);
      check("the bridge armed at LED code 0x8F", dut.wbridge.ENABLE === 1'b1);

      // Distinct contents in both physical pages, through the real path.
      for (int i = 0; i < 128; i++) begin
         wr(3'd5, V_BAD  + 24'h100 + 2*i, 16'hBA00 | i);
         wr(3'd5, V_GOOD + 24'h100 + 2*i, 16'h6000 | i);
      end
      got_bad = 0; got_good = 0;
      for (int i = 0; i < 128; i++) begin
         rd_(3'd5, V_BAD  + 24'h100 + 2*i, d, be); if (!be && d == (16'hBA00 | i)) got_bad++;
         rd_(3'd5, V_GOOD + 24'h100 + 2*i, d, be); if (!be && d == (16'h6000 | i)) got_good++;
      end
      check("control: both pages read back what was written (128 + 128 words)",
            got_bad == 128 && got_good == 128);

      // Refuse the bad page.
      wr(3'd3, V_BAD, PME_INVALID);
      rd_(3'd5, V_BAD + 24'h100, d, be);
      check("an invalid page raises a bus error", be);
      repeat (40) @(posedge cpu_clk);

      $display("=== 1. a refused read issues no memory request ===");
      begin
         int n0;
         n0 = n_req;
         rd_(3'd5, V_BAD + 24'h102, d, be);
         repeat (40) @(posedge cpu_clk);
         $display("  adapter requests issued by one refused read: %0d", n_req - n0);
         check("a refused read issues no Wishbone request", n_req == n0);
      end

      $display("=== 2. refused read, then a valid read `gap' clocks later ===");
      for (int g = 0; g < N_GAP; g++) begin
         stolen_refused[g] = 0; stolen_control[g] = 0; req_during[g] = 0;
         got_refused_word[g] = 0; first_wrong[g] = 16'h0;
         for (int i = 4; i < 36; i++) begin
            int n0;
            logic [15:0] dg;
            // refused first
            n0 = n_req;
            rd_(3'd5, V_BAD + 24'h100 + 2*i, d, be);
            repeat (g) @(posedge cpu_clk);
            rd_(3'd5, V_GOOD + 24'h100 + 2*i, dg, be);
            if (be || dg != (16'h6000 | i)) begin
               if (stolen_refused[g] == 0) first_wrong[g] = dg;
               stolen_refused[g]++;
               if (dg == (16'hBA00 | i)) got_refused_word[g]++;
            end
            req_during[g] += (n_req - n0) - 1;     // one is the valid read's own
            repeat (40) @(posedge cpu_clk);
            // control: valid first
            rd_(3'd5, V_GOOD + 24'h180 + 2*i, d, be);
            repeat (g) @(posedge cpu_clk);
            rd_(3'd5, V_GOOD + 24'h100 + 2*i, dg, be);
            if (be || dg != (16'h6000 | i)) stolen_control[g]++;
            repeat (40) @(posedge cpu_clk);
         end
      end
      $display("  gap  wrong after refused   = refused page's word   first wrong   extra requests   wrong after valid (control)");
      for (int g = 0; g < N_GAP; g++)
        $display("  %3d        %2d / 32                %2d                 %04x           %3d                 %2d / 32",
                 g, stolen_refused[g], got_refused_word[g], first_wrong[g], req_during[g], stolen_control[g]);
      begin
         automatic int tot_r = 0, tot_c = 0;
         for (int g = 0; g < N_GAP; g++) begin tot_r += stolen_refused[g]; tot_c += stolen_control[g]; end
         check("control: a valid read after a valid read is always right", tot_c == 0);
         check("a valid read after a refused read is always right", tot_r == 0);
      end

      $display("=== 3. a refused write does not reach memory ===");
      begin
         int n0, bad;
         n0 = n_req_wr; bad = 0;
         for (int i = 40; i < 56; i++) begin
            logic [15:0] dd; bit bb, okk;
            cycle(3'd5, V_BAD + 24'h100 + 2*i, 1'b0, 16'hDEAD, dd, bb, okk);
            repeat (40) @(posedge cpu_clk);
         end
         $display("  adapter write requests issued by 16 refused writes: %0d", n_req_wr - n0);
         wr(3'd3, V_BAD, PME_RWX_MEM);       // look at what the denied page holds now
         for (int i = 40; i < 56; i++) begin
            rd_(3'd5, V_BAD + 24'h100 + 2*i, d, be);
            if (be || d != (16'hBA00 | i)) bad++;
         end
         $display("  words of the denied page changed: %0d / 16", bad);
         check("a refused write issues no Wishbone write", n_req_wr == n0);
         check("a refused write leaves the denied page unchanged", bad == 0);
      end

      // A read-modify-write cycle through the real sun2_fpga: AS held across
      // both halves, the strobes released between them, R/W turned to write.
      // This is what TAS issues, and every write half used to be lost: the
      // bridge acknowledged it with the read half's `done' and never issued it.
      $display("=== 4. read-modify-write (TAS) on memory ===");
      begin
         int n0, lost, nw0;
         lost = 0; nw0 = n_req_wr;
         for (int i = 60; i < 68; i++) begin
            logic [15:0] r1, back; bit b2;
            int n;
            n0 = n_req_wr;
            @(posedge cpu_clk);
            P_A <= (V_GOOD + 24'h100 + 2*i) >> 1; P_FC <= 3'd5; P_RW_n <= 1'b1;
            @(negedge cpu_clk);
            P_AS_n <= 1'b0; P_UDS_n <= 1'b0; P_LDS_n <= 1'b0;
            n = 0;
            do begin @(posedge cpu_clk); n++; end while (P_DTACK_n && n < 400);
            @(negedge cpu_clk);
            r1 = P_DOUT;
            P_UDS_n <= 1'b1; P_LDS_n <= 1'b1;          // AS stays asserted
            @(posedge cpu_clk);
            P_RW_n <= 1'b0; P_DIN <= r1 | 16'h0080;
            @(negedge cpu_clk);
            @(negedge cpu_clk);
            P_UDS_n <= 1'b0; P_LDS_n <= 1'b0;
            n = 0;
            do begin @(posedge cpu_clk); n++; end while (P_DTACK_n && n < 400);
            @(negedge cpu_clk);
            P_AS_n <= 1'b1; P_UDS_n <= 1'b1; P_LDS_n <= 1'b1;
            @(posedge cpu_clk);
            P_RW_n <= 1'b1;
            repeat (20) @(posedge cpu_clk);
            rd_(3'd5, V_GOOD + 24'h100 + 2*i, back, b2);
            if (back !== (r1 | 16'h0080)) lost++;
            if (i == 60)
              $display("  word %0d: read half %04x, wrote %04x, reads back %04x, write requests %0d",
                       i, r1, r1 | 16'h0080, back, n_req_wr - n0);
         end
         $display("  RMW writes lost: %0d / 8, write requests issued: %0d", lost, n_req_wr - nw0 - 0);
         check("a read-modify-write's write half reaches memory (8 of 8)", lost == 0);
      end

      $display("=== checks: %0d, failing: %0d ===", checks, fails);
      if (fails == 0) $display("PASS");
      else            $display("FAIL");
      $finish;
   end

   initial begin #400_000_000; $display("FAIL: timeout"); $finish; end

endmodule
