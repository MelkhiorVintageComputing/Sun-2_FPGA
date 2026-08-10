`timescale 1ns / 1ps

//
// Sun-2 on a QMTech Wukong V1 (XC7A100T-2FGG676).
//
// The synthesis top: board pins in, Sun-2 out.  This is what the LiteX SoC
// wrapper used to do -- clocks, DDR3 controller, Wishbone clock crossing, DRAM
// init and reset sequencing -- with none of the LiteX.
//
//     clk50 ---> wukong_clkgen ---> 166.667 MHz  sys_clk  ) MIG
//                                   200     MHz  clk_ref  )
//                                   CPU_CLK_HZ   cpu_clk  -> Sun-2 core
//                                   4.9152  MHz  serial   -> SCC
//
//     top (Sun-2 + 68010) --Wishbone--> wb_to_mig_ui --UI--> sun2_mig --> DDR3
//
// The DDR3 port names must match MIG's exactly: its generated XDC constrains
// them by name at the top level.
//
// BOARD_MEM_FAST replaces MIG and the adapter with nothing, exposing the
// Wishbone port so a testbench can hang a behavioural RAM on it.  It is for
// simulation only -- with it set the design has no memory and will not build
// into a working bitstream.
//

module wukong_v1_top #(
    parameter int CPU_CLK_HZ = 12_500_000
) (
    input  wire        clk50,
    input  wire        cpu_reset,     // board button, active low (J8)

    output wire        serial_tx,
    input  wire        serial_rx,

    output wire [1:0]  user_led,      // active low on this board
    output wire [7:0]  diag_leds0,    // Sun-2 front panel, on the PMOD
    input  wire        user_btn,

`ifdef BOARD_MEM_FAST
    // Simulation only: the Wishbone port, straight out
    output wire        wb_cyc_o,
    output wire        wb_stb_o,
    output wire [29:0] wb_adr_o,
    output wire [31:0] wb_dat_o,
    output wire [3:0]  wb_sel_o,
    output wire        wb_we_o,
    input  wire [31:0] wb_dat_i,
    input  wire        wb_ack_i,
    output wire        cpu_clk_o,     // so the testbench can clock its RAM
    output wire        sys_reset_o
`else
    // DDR3, names fixed by MIG's generated XDC
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_p,
    inout  wire [1:0]  ddr3_dqs_n,
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [1:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt
`endif
);

   // ------------------------------------------------------------------
   // Clocks
   // ------------------------------------------------------------------
   wire board_reset = ~cpu_reset;      // button is active low

   wire clk_mig_sys, clk_idelay, cpu_clk, serial_clk, mmcm_locked;

   wukong_clkgen #(.CPU_CLK_HZ(CPU_CLK_HZ)) clkgen (
       .clk50       (clk50),
       .reset       (board_reset),
       .clk_mig_sys (clk_mig_sys),
       .clk_idelay  (clk_idelay),
       .clk_cpu     (cpu_clk),
       .clk_serial  (serial_clk),
       .locked      (mmcm_locked)
   );

   // ------------------------------------------------------------------
   // Reset sequencing
   // ------------------------------------------------------------------
   // Same chain the LiteX build used, which is known to work: hold the machine
   // down until the MMCMs are locked, a counter has run out, and -- crucially
   // -- the DRAM controller has finished calibrating.  Without that last term
   // the boot PROM starts probing memory that is not answering yet.
   wire init_calib_complete;

   reg [7:0] hold_ctr = 8'hFF;
   always @(posedge clk50) begin
      if (board_reset || !mmcm_locked) hold_ctr <= 8'hFF;
      else if (hold_ctr != 8'h00)      hold_ctr <= hold_ctr - 8'd1;
   end

   wire sys_reset_raw = board_reset | ~mmcm_locked | (hold_ctr != 8'h00)
                      | ~init_calib_complete;

   // sys_reset_raw is assembled from things in three different clock domains,
   // so release it synchronously to the domain that uses it.  Without this the
   // registers it clears come out of reset at slightly different times, and
   // the recovery/removal checks into the SCC genuinely fail.
   wire sys_reset;
   reset_sync rst_cpu (
       .clk           (cpu_clk),
       .rst_async_in  (sys_reset_raw),
       .rst_sync_out  (sys_reset)
   );

   // Wukong LEDs are active low: lit means running.
   assign user_led[0] = sys_reset;
   assign user_led[1] = ~init_calib_complete;

   // ------------------------------------------------------------------
   // The Sun-2
   // ------------------------------------------------------------------
   wire        wb_cyc, wb_stb, wb_we, wb_ack;
   wire [29:0] wb_adr;
   wire [31:0] wb_dat_m2s, wb_dat_s2m;
   wire [3:0]  wb_sel;
   wire [7:0]  todebug;
   wire        en_boot;

   top machine (
       .cpu_clk    (cpu_clk),
       // clk40 is unused inside sun2_fpga -- the only thing that ever read it
       // was the disabled CPU_CLK_MULTIPLE_SERIAL path, and the LiteX build
       // wired it to the CPU clock with the comment "wrong freq, don't use".
       .clk40      (1'b0),
       .clk4m9152  (serial_clk),
       .sys_reset  (sys_reset),

       .tx         (serial_tx),
       .rx         (serial_rx),

       .diag_leds  (diag_leds0),
       .en_boot    (en_boot),
       .todebug    (todebug),

       .wb_cyc_o   (wb_cyc),
       .wb_stb_o   (wb_stb),
       .wb_adr_o   (wb_adr),
       .wb_dat_o   (wb_dat_m2s),
       .wb_sel_o   (wb_sel),
       .wb_we_o    (wb_we),
       .wb_dat_i   (wb_dat_s2m),
       .wb_ack_i   (wb_ack)
   );

   // ------------------------------------------------------------------
   // Main memory
   // ------------------------------------------------------------------
`ifdef BOARD_MEM_FAST

   assign wb_cyc_o    = wb_cyc;
   assign wb_stb_o    = wb_stb;
   assign wb_adr_o    = wb_adr;
   assign wb_dat_o    = wb_dat_m2s;
   assign wb_sel_o    = wb_sel;
   assign wb_we_o     = wb_we;
   assign wb_dat_s2m  = wb_dat_i;
   assign wb_ack      = wb_ack_i;
   assign cpu_clk_o   = cpu_clk;
   assign sys_reset_o = sys_reset;
   assign init_calib_complete = 1'b1;   // nothing to calibrate

`else

   wire         ui_clk, ui_clk_sync_rst;
   wire [27:0]  app_addr;
   wire [2:0]   app_cmd;
   wire         app_en, app_rdy;
   wire [127:0] app_wdf_data;
   wire [15:0]  app_wdf_mask;
   wire         app_wdf_wren, app_wdf_end, app_wdf_rdy;
   wire [127:0] app_rd_data;
   wire         app_rd_data_valid, app_rd_data_end;

   wb_to_mig_ui adapter (
       .clk_wb  (cpu_clk),
       .rst_wb  (sys_reset),

       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb), .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_m2s), .wb_sel_i (wb_sel), .wb_we_i (wb_we),
       .wb_dat_o (wb_dat_s2m), .wb_ack_o (wb_ack),

       .ui_clk (ui_clk), .ui_rst (ui_clk_sync_rst),
       .init_calib_complete (init_calib_complete),

       .app_addr (app_addr), .app_cmd (app_cmd), .app_en (app_en), .app_rdy (app_rdy),
       .app_wdf_data (app_wdf_data), .app_wdf_mask (app_wdf_mask),
       .app_wdf_wren (app_wdf_wren), .app_wdf_end (app_wdf_end),
       .app_wdf_rdy (app_wdf_rdy),
       .app_rd_data (app_rd_data), .app_rd_data_valid (app_rd_data_valid)
   );

   // MIG's sys_rst is active low (SysResetPolarity in the .prj).
   sun2_mig ddr3 (
       .ddr3_dq       (ddr3_dq),
       .ddr3_dqs_p    (ddr3_dqs_p),
       .ddr3_dqs_n    (ddr3_dqs_n),
       .ddr3_addr     (ddr3_addr),
       .ddr3_ba       (ddr3_ba),
       .ddr3_ras_n    (ddr3_ras_n),
       .ddr3_cas_n    (ddr3_cas_n),
       .ddr3_we_n     (ddr3_we_n),
       .ddr3_reset_n  (ddr3_reset_n),
       .ddr3_ck_p     (ddr3_ck_p),
       .ddr3_ck_n     (ddr3_ck_n),
       .ddr3_cke      (ddr3_cke),
       .ddr3_dm       (ddr3_dm),
       .ddr3_odt      (ddr3_odt),

       .sys_clk_i     (clk_mig_sys),
       .clk_ref_i     (clk_idelay),
       .sys_rst       (~board_reset),

       .app_addr      (app_addr),
       .app_cmd       (app_cmd),
       .app_en        (app_en),
       .app_rdy       (app_rdy),
       .app_wdf_data  (app_wdf_data),
       .app_wdf_end   (app_wdf_end),
       .app_wdf_mask  (app_wdf_mask),
       .app_wdf_wren  (app_wdf_wren),
       .app_wdf_rdy   (app_wdf_rdy),
       .app_rd_data       (app_rd_data),
       .app_rd_data_end   (app_rd_data_end),
       .app_rd_data_valid (app_rd_data_valid),

       .app_sr_req    (1'b0),
       .app_ref_req   (1'b0),
       .app_zq_req    (1'b0),
       .app_sr_active (),
       .app_ref_ack   (),
       .app_zq_ack    (),

       .ui_clk            (ui_clk),
       .ui_clk_sync_rst   (ui_clk_sync_rst),
       .init_calib_complete (init_calib_complete),
       .device_temp       ()
   );

`endif

endmodule
