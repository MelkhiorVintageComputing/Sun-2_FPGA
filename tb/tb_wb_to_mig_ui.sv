`timescale 1ns / 1ps

//
// Equivalence test for wb_to_mig_ui.
//
// Drives the same randomised Wishbone traffic into two slaves:
//
//   * wb_to_mig_ui in front of mig_ui_model      -- the thing under test
//   * wb_ram_model                               -- the reference the step-1
//                                                   simulation already boots on
//
// and requires every read to return the same 32 bits.  The two run on different
// clocks (the adapter's whole job is to cross from cpu_clk to ui_clk), which is
// also what exercises the handshake.
//
// Coverage aimed at the things that would actually break:
//   * every wb_sel pattern, including partial and zero
//   * addresses that collide within one 128-bit MIG beat, so lane selection and
//     byte masking have to be right
//   * back-to-back accesses, and gaps
//

module tb_wb_to_mig_ui;

   localparam int N_OPS = 3000;

   // deliberately unrelated clocks, as on the board (12.5 MHz vs 83.33 MHz)
   localparam real CPU_HALF = 40.0;
   localparam real UI_HALF  = 6.0;

   reg clk_wb = 1'b0, ui_clk = 1'b0;
   reg rst    = 1'b1;

   always #(CPU_HALF) clk_wb = ~clk_wb;
   always #(UI_HALF)  ui_clk = ~ui_clk;

   // ---- Wishbone master signals ---------------------------------------
   reg         wb_cyc = 1'b0, wb_stb = 1'b0, wb_we = 1'b0;
   reg  [29:0] wb_adr = '0;
   reg  [31:0] wb_dat_w = '0;
   reg  [3:0]  wb_sel = '0;

   wire [31:0] dut_dat_r,  ref_dat_r;
   wire        dut_ack,    ref_ack;

   // ---- device under test ----------------------------------------------
   wire [27:0]  app_addr;
   wire [2:0]   app_cmd;
   wire         app_en, app_rdy;
   wire [127:0] app_wdf_data;
   wire [15:0]  app_wdf_mask;
   wire         app_wdf_wren, app_wdf_end, app_wdf_rdy;
   wire [127:0] app_rd_data;
   wire         app_rd_data_valid;

   // The adapter no longer drives MIG directly -- mig_arb does, because there
   // are two masters and one user port.  Putting the arbiter in the path here
   // means this equivalence test covers both, with the second client idle.
   wire [27:0]  c0_addr;
   wire         c0_we, c0_req, c0_done;
   wire [127:0] c0_wdata, c0_rdata;
   wire [15:0]  c0_wmask;

   wb_to_mig_ui dut (
       .clk_wb (clk_wb), .rst_wb (rst),
       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb), .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_w), .wb_sel_i (wb_sel), .wb_we_i (wb_we),
       .wb_dat_o (dut_dat_r), .wb_ack_o (dut_ack),
       .ui_clk (ui_clk), .ui_rst (rst),
       .c_addr (c0_addr), .c_we (c0_we), .c_wdata (c0_wdata), .c_wmask (c0_wmask),
       .c_req (c0_req), .c_done (c0_done), .c_rdata (c0_rdata)
   );

   mig_arb arbiter (
       .ui_clk (ui_clk), .ui_rst (rst), .init_calib_complete (1'b1),
       .c0_addr (c0_addr), .c0_we (c0_we), .c0_wdata (c0_wdata), .c0_wmask (c0_wmask),
       .c0_req (c0_req), .c0_done (c0_done), .c0_rdata (c0_rdata),
       .c1_addr (28'h0), .c1_req (1'b0), .c1_done (), .c1_rdata (),
       .app_addr (app_addr), .app_cmd (app_cmd), .app_en (app_en), .app_rdy (app_rdy),
       .app_wdf_data (app_wdf_data), .app_wdf_mask (app_wdf_mask),
       .app_wdf_wren (app_wdf_wren), .app_wdf_end (app_wdf_end), .app_wdf_rdy (app_wdf_rdy),
       .app_rd_data (app_rd_data), .app_rd_data_valid (app_rd_data_valid)
   );

   mig_ui_model mig (
       .ui_clk (ui_clk), .ui_rst (rst),
       .app_addr (app_addr), .app_cmd (app_cmd), .app_en (app_en), .app_rdy (app_rdy),
       .app_wdf_data (app_wdf_data), .app_wdf_mask (app_wdf_mask),
       .app_wdf_wren (app_wdf_wren), .app_wdf_end (app_wdf_end), .app_wdf_rdy (app_wdf_rdy),
       .app_rd_data (app_rd_data), .app_rd_data_valid (app_rd_data_valid)
   );

   // ---- reference -------------------------------------------------------
   // Same request stream; its ack is ignored, only its data is compared.
   wb_ram_model ref_ram (
       .clk (clk_wb), .reset (rst),
       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb & ~ref_ack), .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_w), .wb_sel_i (wb_sel), .wb_we_i (wb_we),
       .wb_dat_o (ref_dat_r), .wb_ack_o (ref_ack)
   );

   // ---- stimulus --------------------------------------------------------
   int n_reads = 0, n_writes = 0, mismatches = 0;

   // A small address window so accesses collide inside 128-bit beats often.
   function automatic logic [29:0] pick_addr();
      return {24'h0, $urandom_range(63)};    // 64 words = 4 MIG beats
   endfunction

   task automatic wb_write(input logic [29:0] a, input logic [31:0] d,
                           input logic [3:0]  s);
      begin
         @(posedge clk_wb);
         wb_adr <= a; wb_dat_w <= d; wb_sel <= s; wb_we <= 1'b1;
         wb_cyc <= 1'b1; wb_stb <= 1'b1;
         @(posedge clk_wb);
         while (!dut_ack) @(posedge clk_wb);
         wb_cyc <= 1'b0; wb_stb <= 1'b0; wb_we <= 1'b0;
         n_writes++;
      end
   endtask

   task automatic wb_read(input logic [29:0] a);
      logic [31:0] got, want;
      begin
         @(posedge clk_wb);
         wb_adr <= a; wb_sel <= 4'hF; wb_we <= 1'b0;
         wb_cyc <= 1'b1; wb_stb <= 1'b1;
         @(posedge clk_wb);
         while (!dut_ack) @(posedge clk_wb);
         got  = dut_dat_r;
         want = ref_ram.mem.exists(a) ? ref_ram.mem[a] : 32'h0;
         wb_cyc <= 1'b0; wb_stb <= 1'b0;
         n_reads++;
         if (got !== want) begin
            $display("MISMATCH at word %06x: adapter %08x, reference %08x",
                     a, got, want);
            mismatches++;
         end
      end
   endtask

   initial begin
      $timeformat(-9, 0, " ns", 12);
      $display("=== wb_to_mig_ui vs wb_ram_model, %0d operations ===", N_OPS);

      repeat (20) @(posedge clk_wb);
      rst = 1'b0;
      repeat (20) @(posedge clk_wb);

      // Seed every word we will read, so reads have something definite to
      // compare, then hammer with mixed traffic.
      for (int a = 0; a < 64; a++)
        wb_write(a[29:0], $urandom, 4'hF);

      for (int i = 0; i < N_OPS; i++) begin
         automatic logic [29:0] a = pick_addr();
         if ($urandom_range(1)) begin
            // Partial writes are where lane selection and masking get tested.
            automatic logic [3:0] s = $urandom_range(15);
            wb_write(a, $urandom, s);
         end else begin
            wb_read(a);
         end
         if ($urandom_range(3) == 0) repeat ($urandom_range(3)) @(posedge clk_wb);
      end

      // Final sweep: read everything back.
      for (int a = 0; a < 64; a++)
        wb_read(a[29:0]);

      $display("%0d writes, %0d reads, %0d mismatches", n_writes, n_reads, mismatches);
      mig.report();
      if (mismatches == 0) $display("PASS: adapter matches the reference model");
      else                 $fatal(1, "FAIL: %0d mismatches", mismatches);
      $finish;
   end

   initial begin
      #50_000_000;
      $fatal(1, "tb_wb_to_mig_ui: timed out");
   end

endmodule
