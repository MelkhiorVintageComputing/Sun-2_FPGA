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

   wb_to_mig_ui adapter (
       .clk_wb (cpu_clk), .rst_wb (rst_wb),
       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb), .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_w), .wb_sel_i (wb_sel), .wb_we_i (wb_we),
       .wb_dat_o (wb_dat_r), .wb_ack_o (wb_ack),
       .ui_clk (ui_clk), .ui_rst (ui_clk_sync_rst),
       .init_calib_complete (init_calib_complete),
       .app_addr (app_addr), .app_cmd (app_cmd), .app_en (app_en), .app_rdy (app_rdy),
       .app_wdf_data (app_wdf_data), .app_wdf_mask (app_wdf_mask),
       .app_wdf_wren (app_wdf_wren), .app_wdf_end (app_wdf_end), .app_wdf_rdy (app_wdf_rdy),
       .app_rd_data (app_rd_data), .app_rd_data_valid (app_rd_data_valid)
   );

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
   // Stimulus
   // ------------------------------------------------------------------
   int errors = 0;
   logic [31:0] expect_mem [int];

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

   initial begin
      logic [31:0] got, want;
      $timeformat(-9, 0, " ns", 12);
      $display("=== wb_to_mig_ui against the real MIG and DDR3 model ===");

      #2000 board_rst = 1'b0;

      wait (init_calib_complete === 1'b1);
      $display("[%t] MIG calibration complete", $realtime);
      repeat (20) @(posedge cpu_clk);

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
      if (errors == 0) $display("PASS: the adapter works against the real controller");
      else             $fatal(1, "FAIL: %0d mismatches", errors);
      $finish;
   end

   initial begin
      #2_000_000;
      $fatal(1, "tb_mig_ddr3: timed out (calibration never completed?)");
   end

endmodule
