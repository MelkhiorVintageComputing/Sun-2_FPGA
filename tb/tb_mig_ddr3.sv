`timescale 1ns / 1ps

//
// wb_to_mig_ui against the real MIG and Micron's DDR3 model.
//
// tb_wb_to_mig_ui checks the adapter against a behavioural model of MIG's user
// interface, and tb_wukong (BOARD_MEM=ddr3) shows MIG calibrating against the
// DDR3 model.  Neither covers the join: the adapter talking to the actual
// controller.  The Sun-2 cannot do it for us -- the boot PROM does not touch
// main memory until L_M_MAP, some 600 ms in, which at the speed a full MIG plus
// DDR3 model simulates would take days.
//
// So drive the Wishbone side directly: wait for calibration, then write and
// read back through the whole path.  A few hundred microseconds is enough.
//
// Under SUN2_WB_FIFO (make -C sim migddr3fifo) the stimulus drives the Sun-2
// side of sun2_fifo_bridge instead, one 68010 word cycle per half of each
// longword, and the bridge's Wishbone side runs on ui_clk into wb_mig_sync --
// so the latency reported is what the machine waits, phase to DTACK, for reads
// and for writes, and can be set beside the synchronous path's STB-to-ACK.
//

module tb_mig_ddr3;

   localparam int N_WORDS = 24;

   reg clk50     = 1'b0;
   reg board_rst = 1'b1;

   always #10.0 clk50 = ~clk50;     // 50 MHz

   // ------------------------------------------------------------------
   // Clocks -- the real MMCMs, since MIG needs its input clocks exact
   // ------------------------------------------------------------------
   wire clk_mig_sys, clk_idelay, cpu_clk, serial_clk, mmcm_locked;

   wukong_clkgen #(.CPU_CLK_HZ(12_500_000)) clkgen (
       .clk50 (clk50), .reset (board_rst),
       .clk_mig_sys (clk_mig_sys), .clk_idelay (clk_idelay),
       .clk_cpu (cpu_clk), .clk_serial (serial_clk), .locked (mmcm_locked)
   );

   // ------------------------------------------------------------------
   // Wishbone master, driven by the stimulus below
   // ------------------------------------------------------------------
   reg         wb_cyc = 1'b0, wb_stb = 1'b0, wb_we = 1'b0;
   reg  [29:0] wb_adr = '0;
   reg  [31:0] wb_dat_w = '0;
   reg  [3:0]  wb_sel = 4'hF;
   wire [31:0] wb_dat_r;
   wire        wb_ack;

   wire        init_calib_complete, ui_clk, ui_clk_sync_rst;
   wire [27:0] app_addr;
   wire [2:0]  app_cmd;
   wire        app_en, app_rdy;
   wire [127:0] app_wdf_data, app_rd_data;
   wire [15:0] app_wdf_mask;
   wire        app_wdf_wren, app_wdf_end, app_wdf_rdy;
   wire        app_rd_data_valid, app_rd_data_end;

   wire rst_wb = ~mmcm_locked | ~init_calib_complete;

   wire [27:0]  c0_addr, c1_addr;
   wire         c0_we, c0_req, c0_done, c1_done;
   wire [127:0] c0_wdata, c0_rdata, c1_rdata;
   wire [15:0]  c0_wmask;
   reg          c1_req = 1'b0;

`ifdef SUN2_WB_FIFO
   // The Sun-2 side of the FIFO bridge, driven by the stimulus below.
   reg         set_enable = 1'b0;
   reg  [23:1] p_adr = '0;
   reg  [15:0] p_din = '0;
   wire [15:0] p_dout;
   reg         p_rw_n = 1'b1, p_uds = 1'b0, p_lds = 1'b0, p_match = 1'b0;
   wire        w_ack;
   wire        f_cyc, f_stb, f_we, f_ack;
   wire [29:0] f_adr;
   wire [31:0] f_dat_w, f_dat_r;
   wire [3:0]  f_sel;

   wire [127:0] f_line;
`ifdef SUN2_WB_CACHE
   // The cached bridge (make -C sim migddr3cached): reads that hit are
   // answered from the cache, misses bring a whole line back.
   sun2_cached_fifo_bridge bridge (
       .wb_line_i (f_line),
`else
   sun2_fifo_bridge bridge (
`endif
       .SET_ENABLE (set_enable), .RESET_n (~rst_wb), .CLK (cpu_clk),
       .P_ADR_IN (p_adr), .P_DATA_IN (p_din), .P_DATA_OUT (p_dout),
       .P_RW_n (p_rw_n), .EN_LBYTE (p_lds), .EN_UBYTE (p_uds), .FB_PAGE (6'h0),
       .MATCH_MEM (p_match), .MATCH_FB (1'b0), .W_ACK (w_ack),
       .WB_CLK (ui_clk), .WB_RESET (ui_clk_sync_rst),
       .wb_cyc_o (f_cyc), .wb_stb_o (f_stb), .wb_adr_o (f_adr), .wb_dat_o (f_dat_w),
       .wb_sel_o (f_sel), .wb_we_o (f_we), .wb_dat_i (f_dat_r), .wb_ack_i (f_ack));

   wb_mig_sync adapter_sync (
       .wb_cyc_i (f_cyc), .wb_stb_i (f_stb), .wb_adr_i (f_adr),
       .wb_dat_i (f_dat_w), .wb_sel_i (f_sel), .wb_we_i (f_we),
       .wb_dat_o (f_dat_r), .wb_ack_o (f_ack), .wb_line_o (f_line),
       .c_addr (c0_addr), .c_we (c0_we), .c_wdata (c0_wdata), .c_wmask (c0_wmask),
       .c_req (c0_req), .c_done (c0_done), .c_rdata (c0_rdata)
   );
   assign wb_dat_r = 32'h0;
   assign wb_ack   = 1'b0;
`else
   wb_to_mig_ui adapter (
       .clk_wb (cpu_clk), .rst_wb (rst_wb),
       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb), .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_w), .wb_sel_i (wb_sel), .wb_we_i (wb_we),
       .wb_dat_o (wb_dat_r), .wb_ack_o (wb_ack),
       .ui_clk (ui_clk), .ui_rst (ui_clk_sync_rst),
       .c_addr (c0_addr), .c_we (c0_we), .c_wdata (c0_wdata), .c_wmask (c0_wmask),
       .c_req (c0_req), .c_done (c0_done), .c_rdata (c0_rdata)
   );
`endif

   mig_arb arbiter (
       .ui_clk (ui_clk), .ui_rst (ui_clk_sync_rst),
       .init_calib_complete (init_calib_complete),
       .c0_addr (c0_addr), .c0_we (c0_we), .c0_wdata (c0_wdata), .c0_wmask (c0_wmask),
       .c0_req (c0_req), .c0_done (c0_done), .c0_rdata (c0_rdata),
       .c1_addr (c1_addr), .c1_req (c1_req), .c1_done (c1_done), .c1_rdata (c1_rdata),
       .app_addr (app_addr), .app_cmd (app_cmd), .app_en (app_en), .app_rdy (app_rdy),
       .app_wdf_data (app_wdf_data), .app_wdf_mask (app_wdf_mask),
       .app_wdf_wren (app_wdf_wren), .app_wdf_end (app_wdf_end), .app_wdf_rdy (app_wdf_rdy),
       .app_rd_data (app_rd_data), .app_rd_data_valid (app_rd_data_valid)
   );

   // ------------------------------------------------------------------
   // A stand-in for the frame buffer scan-out, so the number below is
   // measured under contention rather than in an empty interface.
   // ------------------------------------------------------------------
   // +fb_traffic reproduces what fb_scanout will actually ask for: a
   // 1152x900 line is 144 bytes = 9 beats of 16, once per HDMI line.  At
   // 1080p60 a line is 2200 pixel clocks of 148.4375 MHz = 14.82 us, which is
   // 1235 ui_clk.  +fb_saturate instead keeps the request permanently
   // asserted, which is far more than the scan-out can ever want and is there
   // as a hard upper bound.
   localparam int FB_BEATS_PER_LINE = 9;
   localparam int FB_LINE_UI_CLK    = 1235;

   bit fb_traffic  = 1'b0;
   bit fb_saturate = 1'b0;
   int fb_gap = 0, fb_left = 0, fb_n = 0;
   reg [27:0] fb_addr = 28'h7C00000;   // the top 8 MiB, where the pixels live

   assign c1_addr = fb_addr;

   always @(posedge ui_clk) begin
      if (ui_clk_sync_rst) begin
         c1_req  <= 1'b0;
         fb_left <= 0;
         fb_gap  <= 0;
      end else if (fb_saturate) begin
         c1_req <= 1'b1;
         if (c1_done) begin fb_addr <= fb_addr + 28'd8; fb_n <= fb_n + 1; end
      end else if (fb_traffic) begin
         if (fb_left > 0) begin
            c1_req <= 1'b1;
            if (c1_done) begin
               fb_addr <= fb_addr + 28'd8;
               fb_n    <= fb_n + 1;
               fb_left <= fb_left - 1;
               if (fb_left == 1) begin
                  c1_req <= 1'b0;
                  fb_gap <= FB_LINE_UI_CLK;
               end
            end
         end else if (fb_gap > 0) begin
            fb_gap <= fb_gap - 1;
         end else begin
            fb_left <= FB_BEATS_PER_LINE;
         end
      end
   end

   // ------------------------------------------------------------------
   // The real controller and the real DRAM model
   // ------------------------------------------------------------------
   wire [15:0] ddr3_dq;
   wire [1:0]  ddr3_dqs_p, ddr3_dqs_n, ddr3_dm;
   wire [13:0] ddr3_addr;
   wire [2:0]  ddr3_ba;
   wire        ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n;
   wire [0:0]  ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_odt;

   sun2_mig ddr3_ctrl (
       .ddr3_dq (ddr3_dq), .ddr3_dqs_p (ddr3_dqs_p), .ddr3_dqs_n (ddr3_dqs_n),
       .ddr3_addr (ddr3_addr), .ddr3_ba (ddr3_ba),
       .ddr3_ras_n (ddr3_ras_n), .ddr3_cas_n (ddr3_cas_n), .ddr3_we_n (ddr3_we_n),
       .ddr3_reset_n (ddr3_reset_n),
       .ddr3_ck_p (ddr3_ck_p), .ddr3_ck_n (ddr3_ck_n), .ddr3_cke (ddr3_cke),
       .ddr3_dm (ddr3_dm), .ddr3_odt (ddr3_odt),
       .sys_clk_i (clk_mig_sys), .clk_ref_i (clk_idelay), .sys_rst (~board_rst),
       .app_addr (app_addr), .app_cmd (app_cmd), .app_en (app_en), .app_rdy (app_rdy),
       .app_wdf_data (app_wdf_data), .app_wdf_end (app_wdf_end),
       .app_wdf_mask (app_wdf_mask), .app_wdf_wren (app_wdf_wren),
       .app_wdf_rdy (app_wdf_rdy),
       .app_rd_data (app_rd_data), .app_rd_data_end (app_rd_data_end),
       .app_rd_data_valid (app_rd_data_valid),
       .app_sr_req (1'b0), .app_ref_req (1'b0), .app_zq_req (1'b0),
       .app_sr_active (), .app_ref_ack (), .app_zq_ack (),
       .ui_clk (ui_clk), .ui_clk_sync_rst (ui_clk_sync_rst),
       .init_calib_complete (init_calib_complete), .device_temp ()
   );

   ddr3_model ddr3 (
       .rst_n (ddr3_reset_n), .ck (ddr3_ck_p), .ck_n (ddr3_ck_n), .cke (ddr3_cke),
       .cs_n (1'b0),                    // tied low on the board through R35
       .ras_n (ddr3_ras_n), .cas_n (ddr3_cas_n), .we_n (ddr3_we_n),
       .dm_tdqs (ddr3_dm), .ba (ddr3_ba), .addr (ddr3_addr),
       .dq (ddr3_dq), .dqs (ddr3_dqs_p), .dqs_n (ddr3_dqs_n),
       .tdqs_n (), .odt (ddr3_odt)
   );

   // ------------------------------------------------------------------
   // Latency measurement
   // ------------------------------------------------------------------
   // Two numbers, and nothing in this repo had ever recorded either:
   //
   //   L_mig  the controller's own read latency, from the cycle it accepts a
   //          read command to the cycle it returns data, in ui_clk cycles.
   //   L_wb   what the Sun-2 actually waits: Wishbone STB to ACK, in cpu_clk
   //          cycles, which is what DTACK is built from.
   //
   // L_wb is the one that matters for DVMA.  Every simulation of this design
   // so far has used wb_ram_model with ACK_LATENCY(0) -- a one-cycle memory --
   // so the Ethernet's bus budget has never been tested against the real path.
   int  mig_lat_min = 1000, mig_lat_max = 0, mig_lat_sum = 0, mig_lat_n = 0;
   int  wb_lat_min  = 1000, wb_lat_max  = 0, wb_lat_sum  = 0, wb_lat_n  = 0;
   int  mig_cnt = 0;
   bit  mig_pending = 1'b0;

   always @(posedge ui_clk) begin
      if (ui_clk_sync_rst) begin
         mig_pending <= 1'b0;
      end else begin
         if (mig_pending) mig_cnt <= mig_cnt + 1;
         // a read command accepted by the controller
         if (app_en && app_rdy && app_cmd == 3'b001) begin
            mig_pending <= 1'b1;
            mig_cnt     <= 0;
         end
         if (mig_pending && app_rd_data_valid) begin
            mig_pending <= 1'b0;
            mig_lat_n   <= mig_lat_n + 1;
            mig_lat_sum <= mig_lat_sum + mig_cnt;
            if (mig_cnt < mig_lat_min) mig_lat_min <= mig_cnt;
            if (mig_cnt > mig_lat_max) mig_lat_max <= mig_cnt;
         end
      end
   end

   // Writes as well as reads: acknowledging writes early is the whole point
   // of the FIFO bridge, so both paths report both.
   int  ww_lat_min = 1000, ww_lat_max = 0, ww_lat_sum = 0, ww_lat_n = 0;
   // A cache hit is answered in the phase's first clock; everything else is
   // a trip to memory.  Kept apart, because their mean says nothing.
   int  rh_n = 0;
   int  wb_cnt = 0;
   bit  wb_busy = 1'b0, wb_busy_we = 1'b0;
`ifdef SUN2_WB_FIFO
   // A data phase starts when the stimulus raises MATCH with a strobe, and is
   // answered by W_ACK -- DTACK, on the machine.
   wire meas_start = p_match & (p_uds | p_lds);
   wire meas_we    = ~p_rw_n;
   wire meas_ack   = w_ack;
`else
   wire meas_start = wb_cyc & wb_stb;
   wire meas_we    = wb_we;
   wire meas_ack   = wb_ack;
`endif
   always @(posedge cpu_clk) begin
      if (wb_busy) begin
         wb_cnt <= wb_cnt + 1;
         if (meas_ack) begin
            wb_busy <= 1'b0;
            if (wb_busy_we) begin
               ww_lat_n   <= ww_lat_n + 1;
               ww_lat_sum <= ww_lat_sum + wb_cnt;
               if (wb_cnt < ww_lat_min) ww_lat_min <= wb_cnt;
               if (wb_cnt > ww_lat_max) ww_lat_max <= wb_cnt;
            end else begin
               wb_lat_n   <= wb_lat_n + 1;
               wb_lat_sum <= wb_lat_sum + wb_cnt;
               if (wb_cnt < wb_lat_min) wb_lat_min <= wb_cnt;
               if (wb_cnt > wb_lat_max) wb_lat_max <= wb_cnt;
            end
         end
      end else if (meas_start && meas_ack && !meas_we) begin
         rh_n <= rh_n + 1;                    // answered in its first clock
      end else if (meas_start && !meas_ack) begin
         wb_busy    <= 1'b1;
         wb_busy_we <= meas_we;
         wb_cnt     <= 1;
      end
   end

   task automatic report_latency();
      real cpu_ns;
      begin
         cpu_ns = 1.0e9 / 12.5e6;   // the 12.5 MHz CPU clock this runs at
         $display("");
         $display("--- measured latency ---");
         if (mig_lat_n > 0)
           $display("MIG read, command accepted to data valid: min %0d, max %0d, mean %0.1f ui_clk (%0.1f ns at 83.33 MHz)",
                    mig_lat_min, mig_lat_max, real'(mig_lat_sum)/mig_lat_n,
                    (real'(mig_lat_sum)/mig_lat_n) * 12.0);
         if (ww_lat_n > 0)
`ifdef SUN2_WB_FIFO
           $display("FIFO bridge write, phase to DTACK:        min %0d, max %0d, mean %0.1f cpu_clk",
`else
           $display("Wishbone write, STB to ACK:               min %0d, max %0d, mean %0.1f cpu_clk",
`endif
                    ww_lat_min, ww_lat_max, real'(ww_lat_sum)/ww_lat_n);
`ifdef SUN2_WB_CACHE
         $display("Cached bridge read hit, phase to DTACK:   1 cpu_clk (DTACK in the phase's first clock), %0d reads", rh_n);
`endif
         if (wb_lat_n > 0) begin
`ifdef SUN2_WB_CACHE
            $display("Cached bridge read miss, phase to DTACK:  min %0d, max %0d, mean %0.1f cpu_clk, %0d reads",
                     wb_lat_min, wb_lat_max, real'(wb_lat_sum)/wb_lat_n, wb_lat_n);
`else
`ifdef SUN2_WB_FIFO
            $display("FIFO bridge read, phase to DTACK:         min %0d, max %0d, mean %0.1f cpu_clk (%0.1f ns at 12.5 MHz)",
`else
            $display("Wishbone read, STB to ACK:                min %0d, max %0d, mean %0.1f cpu_clk (%0.1f ns at 12.5 MHz)",
`endif
                     wb_lat_min, wb_lat_max, real'(wb_lat_sum)/wb_lat_n,
                     (real'(wb_lat_sum)/wb_lat_n) * cpu_ns);
`endif
            $display("");
            $display("=> set wb_ram_model ACK_LATENCY to %0d to model this bus in the board simulation",
                     (wb_lat_sum + wb_lat_n/2) / wb_lat_n);
            // A 32-bit DVMA word is two 68010 cycles, each waiting this long
            // plus arbitration; at 10 Mb/s the MAC needs one every 3.2 us.
            $display("scan-out stand-in: %0d transactions completed", fb_n);
            $display("=> a 32-bit DVMA word costs about %0.1f us; at 10 Mb/s the budget is 3.2 us",
                     2.0 * ((real'(wb_lat_sum)/wb_lat_n) + 5.0) * cpu_ns / 1000.0);
         end
      end
   endtask

   // ------------------------------------------------------------------
   // Stimulus
   // ------------------------------------------------------------------
   int errors = 0;
   logic [31:0] expect_mem [int];

`ifdef SUN2_WB_FIFO
   // One 68010 word cycle on the bridge's Sun-2 side.  A1=0 is the low half of
   // the 32-bit word, A1=1 the high half, as sun2_wishbone_bridge pairs them.
   task automatic phase(input logic [29:0] a, input bit a1, input bit rw_n,
                        input logic [15:0] d, input bit uds, input bit lds,
                        output logic [15:0] q);
      begin
         // The address a clock before the phase, as the machine puts it
         // (tb_sun2 measures that): what the cached bridge's lookup needs.
         @(posedge cpu_clk);
         p_adr <= {a[21:0], a1}; p_rw_n <= rw_n; p_din <= d;
         @(posedge cpu_clk);
         p_uds <= uds; p_lds <= lds; p_match <= 1'b1;
         @(posedge cpu_clk);
         while (!w_ack) @(posedge cpu_clk);
         @(posedge cpu_clk);
         q = p_dout;                          // the clock after DTACK
         p_match <= 1'b0; p_uds <= 1'b0; p_lds <= 1'b0; p_rw_n <= 1'b1;
         @(posedge cpu_clk);
      end
   endtask

   task automatic wb_write(input logic [29:0] a, input logic [31:0] d,
                           input logic [3:0] s);
      logic [15:0] q;
      begin
         if (s[1:0] != 2'b00) phase(a, 1'b0, 1'b0, d[15:0],  s[1], s[0], q);
         if (s[3:2] != 2'b00) phase(a, 1'b1, 1'b0, d[31:16], s[3], s[2], q);
      end
   endtask

   task automatic wb_read(input logic [29:0] a, output logic [31:0] d);
      logic [15:0] lo, hi;
      begin
         phase(a, 1'b0, 1'b1, 16'h0, 1'b1, 1'b1, lo);
         phase(a, 1'b1, 1'b1, 16'h0, 1'b1, 1'b1, hi);
         d = {hi, lo};
      end
   endtask
`else
   task automatic wb_write(input logic [29:0] a, input logic [31:0] d,
                           input logic [3:0] s);
      begin
         @(posedge cpu_clk);
         wb_adr <= a; wb_dat_w <= d; wb_sel <= s; wb_we <= 1'b1;
         wb_cyc <= 1'b1; wb_stb <= 1'b1;
         @(posedge cpu_clk);
         while (!wb_ack) @(posedge cpu_clk);
         wb_cyc <= 1'b0; wb_stb <= 1'b0; wb_we <= 1'b0;
      end
   endtask

   task automatic wb_read(input logic [29:0] a, output logic [31:0] d);
      begin
         @(posedge cpu_clk);
         wb_adr <= a; wb_sel <= 4'hF; wb_we <= 1'b0;
         wb_cyc <= 1'b1; wb_stb <= 1'b1;
         @(posedge cpu_clk);
         while (!wb_ack) @(posedge cpu_clk);
         d = wb_dat_r;
         wb_cyc <= 1'b0; wb_stb <= 1'b0;
      end
   endtask
`endif

   initial begin
      logic [31:0] got, want;
      $timeformat(-9, 0, " ns", 12);
      fb_traffic  = $test$plusargs("fb_traffic");
      fb_saturate = $test$plusargs("fb_saturate");
      if (fb_saturate)     $display("scan-out stand-in: saturated (upper bound)");
      else if (fb_traffic) $display("scan-out stand-in: %0d beats every %0d ui_clk, as at 1080p60",
                                    FB_BEATS_PER_LINE, FB_LINE_UI_CLK);
      else                 $display("scan-out stand-in: idle");
      $display("=== wb_to_mig_ui against the real MIG and DDR3 model ===");

      #2000 board_rst = 1'b0;

      wait (init_calib_complete === 1'b1);
      $display("[%t] MIG calibration complete", $realtime);
      repeat (20) @(posedge cpu_clk);
`ifdef SUN2_WB_FIFO
      @(posedge cpu_clk) set_enable <= 1'b1;
      @(posedge cpu_clk) set_enable <= 1'b0;
      $display("=== ... through sun2_fifo_bridge and wb_mig_sync ===");
`endif

      // Writes spread across two 128-bit beats and both halves of each, so
      // lane selection and the byte mask are all exercised against the real
      // controller rather than a model of it.
      for (int i = 0; i < N_WORDS; i++) begin
         automatic logic [31:0] d = 32'hA5000000 | i;
         expect_mem[i] = d;
         wb_write(i[29:0], d, 4'hF);
      end

      // A partial write: only the middle two bytes.
      wb_write(30'd3, 32'h1234_5678, 4'b0110);
      expect_mem[3] = (expect_mem[3] & 32'hFF0000FF) | (32'h1234_5678 & 32'h00FFFF00);

      for (int i = 0; i < N_WORDS; i++) begin
         wb_read(i[29:0], got);
         want = expect_mem[i];
         if (got !== want) begin
            $display("MISMATCH at word %0d: got %08x, expected %08x", i, got, want);
            errors++;
         end
      end

      $display("[%t] %0d words written and read back, %0d errors",
               $realtime, N_WORDS, errors);
      report_latency();
      if (errors == 0) $display("PASS: the adapter works against the real controller");
      else             $fatal(1, "FAIL: %0d mismatches", errors);
      $finish;
   end

   initial begin
      #2_000_000;
      $fatal(1, "tb_mig_ddr3: timed out (calibration never completed?)");
   end

endmodule
