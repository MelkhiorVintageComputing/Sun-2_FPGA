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

    //
    // Ethernet, to the RTL8211EG in bank 34.  Present on both machine types so
    // the board top keeps one port list; a MultiBus build drives the outputs
    // idle, because a 2/120 has no on-board Ethernet.
    //
    // The PHY is strapped for GMII and runs from its own 25 MHz crystal, but a
    // Sun-2 is a 10 Mb/s machine: at 10 and 100 Mb/s the part presents the
    // 4-bit MII and sources both clocks itself, which is what this uses.
    //
    // phy_mii_rx_dv, phy_mii_rx_er and phy_mii_col are also PHY configuration
    // straps, latched when its reset releases.  They are inputs and must stay
    // inputs -- driving them would change the PHY's address or put it into
    // RGMII mode, where nothing would ever work in a way that looked like a
    // MAC fault.
    //
    input  wire        phy_mii_tx_clk,   // M2, PHY-sourced, 2.5 MHz at 10 Mb/s
    output wire [3:0]  phy_mii_txd,      // R2 P1 N2 N1
    output wire        phy_mii_tx_en,    // T2
    output wire        phy_mii_tx_er,    // J1
    input  wire        phy_mii_rx_clk,   // P4, PHY-sourced
    input  wire [3:0]  phy_mii_rxd,      // M4 N3 N4 P3
    input  wire        phy_mii_rx_dv,    // L3  -- also PHY_AD2
    input  wire        phy_mii_rx_er,    // U5  -- also AN1
    input  wire        phy_mii_crs,      // U2
    input  wire        phy_mii_col,      // U4  -- also Mode
    output wire        phy_gtx_clk,      // U1, gigabit only: held low here
    output wire        phy_reset_n,      // R1, active low, no external circuit
    output wire        phy_mdc,          // H2
    inout  wire        phy_mdio,         // H1, 1.5k pull-up on the board

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

   wire eth_crs_stuck;

   //
   // PHY reset.  Nothing external drives it -- no pull-up, no RC, no
   // supervisor -- so R1 is undefined from power-on until this bitstream is
   // live, and the PHY has already latched its straps and begun negotiating by
   // then.  Assert it deliberately, hold it well past the part's minimum, and
   // leave a long settle before anything talks MDIO: a read of 0xFFFF because
   // the PHY was still resetting is the classic first-bring-up failure.
   //
   // 20 ms low, then 50 ms more before MDIO is allowed, counted on clk50.
   //
   localparam int PHY_RST_CYCLES  = 50_000 * 20;   // 20 ms of 50 MHz
   localparam int PHY_WAIT_CYCLES = 50_000 * 50;   // 50 ms more
   reg [21:0] phy_rst_ctr  = 22'h0;
   reg        phy_rst_done = 1'b0;
   reg        phy_mdio_ok  = 1'b0;
   always @(posedge clk50) begin
      if (board_reset) begin
         phy_rst_ctr  <= 22'h0;
         phy_rst_done <= 1'b0;
         phy_mdio_ok  <= 1'b0;
      end else if (phy_rst_ctr != PHY_RST_CYCLES[21:0] + PHY_WAIT_CYCLES[21:0]) begin
         phy_rst_ctr <= phy_rst_ctr + 22'h1;
         if (phy_rst_ctr == PHY_RST_CYCLES[21:0]) phy_rst_done <= 1'b1;
      end else begin
         phy_mdio_ok <= 1'b1;
      end
   end
   assign phy_reset_n = phy_rst_done;

   // Gigabit only, and this board cannot do gigabit anyway: the PHY's CLK125
   // is not routed to the FPGA.  Held low rather than left floating into it.
   assign phy_gtx_clk = 1'b0;

   wire clk_mig_sys, clk_idelay, cpu_clk, serial_clk, mmcm_locked;

   // PHY management, declared here so the LED and the instances below can all
   // see them; xvlog rejects a wire used before it is declared.
   wire        mdio_cyc, mdio_stb, mdio_we, mdio_ack;
   wire [3:0]  mdio_sel;
   wire [5:0]  mdio_adr;
   wire [31:0] mdio_dat_w, mdio_dat_r;
   wire        mdio_o, mdio_oe, mdio_i;
   wire [15:0] phy_id;
   wire        phy_present, phy_cfg_done, phy_link, phy_fd;
   wire [1:0]  phy_speed;


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
   // Until DRAM is calibrated that is the interesting question; after it, the
   // Ethernet link is.  Active low, so 0 is lit.
   assign user_led[1] = phy_cfg_done ? ~phy_link : ~init_calib_complete;

   // ------------------------------------------------------------------
   // The Sun-2
   // ------------------------------------------------------------------
   wire        wb_cyc, wb_stb, wb_we, wb_ack;
   wire [29:0] wb_adr;
   wire [31:0] wb_dat_m2s, wb_dat_s2m;
   wire [3:0]  wb_sel;
   wire [7:0]  todebug;
   wire        en_boot;

   //
   // PHY management.  None of this exists on a Sun-2 -- the 82586 drove an 8502
   // Manchester encoder straight onto an AUI cable and nothing in the machine
   // knew what a PHY was -- so it lives here rather than in the machine.  See
   // phy_rtl8211_init for what it does and why the order matters.
   //
   // MDC well under the 2.5 MHz the standard allows, and deliberately slower
   // than it needs to be: management bandwidth buys nothing here, and a slow
   // bus is far more tolerant of whatever capacitance is on the trace.
   // 12.5 MHz / (2 * (49 + 1)) = 125 kHz.
   wb_mdio #(.DIV_RESET(49)) mdio_station (
       .clk        (cpu_clk),
       .rst        (sys_reset),
       .wbs_cyc_i  (mdio_cyc),
       .wbs_stb_i  (mdio_stb),
       .wbs_we_i   (mdio_we),
       .wbs_sel_i  (mdio_sel),
       .wbs_adr_i  (mdio_adr),
       .wbs_dat_i  (mdio_dat_w),
       .wbs_dat_o  (mdio_dat_r),
       .wbs_ack_o  (mdio_ack),
       .wbs_err_o  (),
       .mdc        (phy_mdc),
       .mdio_o     (mdio_o),
       .mdio_oe    (mdio_oe),
       .mdio_i     (mdio_i)
   );

   IOBUF mdio_pad (.O(mdio_i), .IO(phy_mdio), .I(mdio_o), .T(~mdio_oe));

   // phy_mdio_ok is assembled in the clk50 domain; the station runs on cpu_clk.
   (* ASYNC_REG = "TRUE" *) reg phy_ok_s1, phy_ok_s2;
   always @(posedge cpu_clk) begin
      phy_ok_s1 <= phy_mdio_ok;
      phy_ok_s2 <= phy_ok_s1;
   end
   wire phy_mdio_ok_sync = phy_ok_s2;

   phy_rtl8211_init #(.PHY_ADDR(5'd1)) phy_init (
       .clk         (cpu_clk),
       .rst         (sys_reset),
       .enable      (phy_mdio_ok_sync),
       .wbm_cyc_o   (mdio_cyc),
       .wbm_stb_o   (mdio_stb),
       .wbm_we_o    (mdio_we),
       .wbm_sel_o   (mdio_sel),
       .wbm_adr_o   (mdio_adr),
       .wbm_dat_o   (mdio_dat_w),
       .wbm_dat_i   (mdio_dat_r),
       .wbm_ack_i   (mdio_ack),
       .phy_id      (phy_id),
       .phy_present (phy_present),
       .cfg_done    (phy_cfg_done),
       .link        (phy_link),
       .speed       (phy_speed),
       .full_duplex (phy_fd)
   );

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

       .eth_crs_stuck (eth_crs_stuck),

       .mii_tx_clk (phy_mii_tx_clk),
       .mii_txd    (phy_mii_txd),
       .mii_tx_en  (phy_mii_tx_en),
       .mii_tx_er  (phy_mii_tx_er),
       .mii_rx_clk (phy_mii_rx_clk),
       .mii_rxd    (phy_mii_rxd),
       .mii_rx_dv  (phy_mii_rx_dv),
       .mii_rx_er  (phy_mii_rx_er),
       .mii_crs    (phy_mii_crs),
       .mii_col    (phy_mii_col),

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
