`timescale 1ns / 1ps

// For FB_WB_BASE, so the scan-out looks where the CPU writes.
`include "sun2_config.vh"

//
// Sun-2 on a QMTech Wukong, V1 or V3.
//
// One file serves both revisions, because for this design they differ in
// nothing but pin assignment: DDR3, Ethernet, the serial console and the PMOD
// are on identical balls, and both boards run from a 50 MHz oscillator.  What
// does differ -- the oscillator pin, the reset button, the two on-board LEDs,
// and the FPGA speed grade -- lives in syn/wukong_v1.xdc and syn/wukong_v3.xdc
// beside syn/wukong_common.xdc, which is where pins belong.  See the table in
// BRINGUP.md.
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

module wukong_top #(
    parameter int CPU_CLK_HZ = 12_500_000
) (
    input  wire        clk50,
    input  wire        cpu_reset,     // board button, active low

    output wire        serial_tx,
    input  wire        serial_rx,

    output wire [1:0]  user_led,      // active low on this board
    output wire [7:0]  diag_leds0,    // Sun-2 front panel, on the PMOD
    output wire [7:0]  extra_leds0,   // sun2_fpga's todebug, on the second header
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
    // The Ethernet balls below are the same on V1 and V3.
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

    // HDMI, for the 2/50's frame buffer.  Same balls on V1 and V3.  The ports
    // exist whether or not SUN2_FB is set, so syn/wukong_common.xdc can
    // constrain them unconditionally; with no frame buffer they sit idle.
    output wire [2:0]  tmds_p,           // E1 F2 G2
    output wire [2:0]  tmds_n,           // D1 E2 G1
    output wire        tmds_clk_p,       // D4
    output wire        tmds_clk_n,       // C4

`ifdef SUN2_XY450
    // The micro-SD slot the Xylogics 450's platters became: J9 on a Wukong V3,
    // and a PMOD on a V1, which has no card slot at all.  SPI mode uses four
    // of the six lines; the pins are in syn/wukong_sd_v1.xdc and
    // syn/wukong_sd_v3.xdc, which are read only when XY450=1.
    //
    // Unlike the HDMI pins these are conditional, because they are the only
    // ports on this module with nowhere to go on one of the two boards: a
    // build without a disk would leave them unconstrained and the bitstream
    // DRC would refuse it.
    output wire        sd_clk,           // CLK
    output wire        sd_cmd,           // CMD  -> MOSI
    input  wire        sd_dat0,          // DAT0 -> MISO
    output wire        sd_dat3,          // DAT3 -> /CS
    input  wire        sd_cd,            // card detect
`endif

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
   //
   // The board oscillator gets an explicit global buffer, because it is a real
   // clock here and not just an MMCM reference: the reset assembly and the PHY
   // reset sequencer below are clocked by it directly, some thirty flip-flops
   // between them.
   //
   // **Vivado will infer this -- sometimes.**  It inferred one for a MultiBus
   // build and not for the VME build of the same commit, with 13 of 32 BUFGs
   // used either way, so it was not a budget limit; the VME machine simply has
   // more clock nets competing.  Without the buffer clk50 goes to all of those
   // flops on general routing, which measured 1.264 ns of delay to one end of
   // the PHY counter and 2.191 ns to the other -- 0.93 ns of skew on a
   // same-clock path, which is a coin toss for hold and lost it by 270 ps.  The
   // failure looks nothing like its cause: an unrelated edit elsewhere in the
   // design moves the placement and the sign of the slack changes with it.
   //
   wire clk50_g;
   BUFG bufg_clk50 (.I(clk50), .O(clk50_g));

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
   always @(posedge clk50_g) begin
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
       .clk50       (clk50_g),
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
   always @(posedge clk50_g) begin
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
   //
   // From sys_reset_raw rather than sys_reset, deliberately.  sys_reset is the
   // synchronised copy, and reset_sync releases it on a cpu_clk edge -- so if
   // cpu_clk is not running (no clk50, an MMCM that never locked, a CPU_CLK_HZ
   // the MMCM cannot make) the synchroniser never clocks and this LED stays at
   // its reset value whatever the board is doing.  That is precisely the case
   // where the LED is the only instrument there is, and it would be lying.
   // sys_reset_raw is combinational from board_reset, mmcm_locked, the hold
   // counter and init_calib_complete, so it goes out as soon as those clear
   // and separates "the reset conditions never cleared" from "they cleared and
   // the machine still is not running".
   assign user_led[0] = sys_reset_raw;
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

   // Whatever sun2_fpga.v is reporting on todebug, straight out to the second
   // LED header.  Same convention as diag_leds0: driven as-is, so a 1 lights
   // the LED on the module those headers take.
   //
   // Not inside `ifdef BOARD_MEM_FAST, where this first went by mistake --
   // extra_leds0 is a real pin in every build, unlike the wb_*, cpu_clk_o and
   // sys_reset_o ports that arm carries, and the bitstream is the only thing
   // that has LEDs at all.  And here rather than up with the other LED
   // assignments, because todebug is declared below them and xvlog rejects a
   // wire used before its declaration.
   //
   // An LED cannot show a bus signal.  Anything moving at cpu_clk -- AS, DTACK,
   // a decode match -- is a blur at best and dark at worst, so what belongs on
   // todebug is levels and latched "this has happened at least once" flags.
   // See the comment on todebug in rtl/sun2-common/sun2_fpga.v.
   assign extra_leds0 = todebug;
   wire        en_boot;

   // The debug bus, and the ILA that samples it.  Field map in
   // rtl/sun2-common/sun2_fpga.v, next to the assignment; the split into eight
   // probe ports is what lets the Hardware Manager trigger on a combination of
   // fields -- ERR and P_FC == 1, say -- with the basic trigger unit rather
   // than the advanced one.
   //
   // All of it is behind the define, port included, so a build without the
   // knob is not merely equivalent but byte-identical -- see the comment on
   // dbg_bus in rtl/sun2-common/sun2_fpga.v for what the bare port cost when
   // it was not.
`ifdef SUN2_ILA
   wire [73:0] dbg_bus;

   // Named wires rather than slices straight into the core, because the
   // Hardware Manager names a probe after the net it is driven from -- and
   // eight slices of one net all get that net's name.  Vivado then called the
   // first slice it met `dbg_bus' and numbered the rest, and the slice it met
   // first was probe7: `dbg_bus_1' was the address and `dbg_bus' the verdict.
   // Every field one out, and quietly.  Measured on the board, not guessed.
   wire [22:0] dbg_addr = dbg_bus[73:51];  // P_A[23:1]
   wire [2:0]  dbg_fc   = dbg_bus[50:48];  // P_FC
   wire [5:0]  dbg_hand = dbg_bus[47:42];  // AS RW UDS LDS DTACK BERR, all low
   wire [3:0]  dbg_cs   = dbg_bus[41:38];  // C_S4 C_S6 C_S8 C_S24
   wire [7:0]  dbg_smap = dbg_bus[37:30];  // ia_smap2pmap
   wire [11:0] dbg_ps   = dbg_bus[29:18];  // ps_pmap2devices
   wire [11:0] dbg_ma   = dbg_bus[17:6];   // ma_pmap2devices
   wire [5:0]  dbg_verd = dbg_bus[5:0];    // V PROTERR_raw PROTERR TIMEOUT ERR MEM

   sun2_ila u_ila (
       .clk    (cpu_clk),
       .probe0 (dbg_addr),
       .probe1 (dbg_fc),
       .probe2 (dbg_hand),
       .probe3 (dbg_cs),
       .probe4 (dbg_smap),
       .probe5 (dbg_ps),
       .probe6 (dbg_ma),
       .probe7 (dbg_verd)
   );
`endif

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

   // ------------------------------------------------------------------
   // The disk
   // ------------------------------------------------------------------
   // blk_sd comes from Inputs/Wish5380 unchanged -- an SD card in SPI mode
   // behind the block interface its doc/block.md defines.  It was written for
   // an NCR 5380, which is a different controller for a different machine, but
   // the seam is deliberately narrow enough that neither end knows.
   //
   // The Xylogics runs on cpu_clk (sun2_fpga's C100 is cpu_clk when
   // CPU_CLK_MULTIPLE_SERIAL is off, which it is), and the block interface has
   // no clock crossing in it, so the back end runs there too.  blk_sd divides
   // that down itself: 400 kHz to bring the card up, then 25 MHz.
   // blk_req_t and blk_rsp_t are declared at file scope in wish5380_pkg.sv
   // rather than inside the package -- see the note on interfaces in
   // Inputs/Wish5380/doc/block.md -- so they are compilation-unit types and
   // there is nothing to qualify or import.  All of this is one xvlog call.
   blk_req_t blk_req;
   blk_rsp_t blk_rsp;

`ifdef SUN2_XY450
   // In picoseconds, computed in two steps: Vivado's Verilog parser rejects a
   // decimal constant of 1e12 outright -- "should be smaller than 2147483648"
   // -- and silently substitutes a negative number.  xsim takes it without a
   // murmur, so this only shows up at synthesis.
   localparam int SD_CLK_PERIOD_PS = 1_000_000_000 / (CPU_CLK_HZ / 1000);

   blk_sd #(.CLK_PERIOD_PS(SD_CLK_PERIOD_PS)) sdcard (
       .clk_i(cpu_clk),
       .rst_i(sys_reset),
       .blk_i(blk_req),
       .blk_o(blk_rsp),
       .sd_clk_o(sd_clk),
       .sd_cs_n_o(sd_dat3),
       .sd_mosi_o(sd_cmd),
       .sd_miso_i(sd_dat0)
   );
   // Card detect is an input with a pull-up and a switch to ground; nothing
   // reads it yet.  blk_sd finds out whether there is a card by talking to it,
   // which is the only answer that means anything.
   wire _unused_sd_cd = sd_cd;
`else
   assign blk_rsp = '0;
`endif

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
`ifdef SUN2_ILA
       .dbg_bus    (dbg_bus),
`endif

       .eth_crs_stuck (eth_crs_stuck),

       // ... and back down again, into the status register in device page
       // 0xFE7, so the running machine can report what the PHY negotiated.
       .phy_id      (phy_id),
       .phy_present (phy_present),
       .phy_cfg_done(phy_cfg_done),
       .phy_link    (phy_link),
       .phy_fd      (phy_fd),
       .phy_speed   (phy_speed),

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

       // The Xylogics 450's media: the micro-SD slot, through blk_sd.
       .blk_start     (blk_req.start),
       .blk_we        (blk_req.we),
       .blk_lba       (blk_req.lba),
       .blk_buf_rdata (blk_req.buf_rdata),
       .blk_done      (blk_rsp.done),
       .blk_err       (blk_rsp.err),
       .blk_ready     (blk_rsp.ready),
       .blk_count     (blk_rsp.count),
       .blk_buf_we    (blk_rsp.buf_we),
       .blk_buf_addr  (blk_rsp.buf_addr),
       .blk_buf_wdata (blk_rsp.buf_wdata),

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

   // The two DDR3 masters and the arbiter between them.  The adapter keeps its
   // instance name and its place in the hierarchy: syn/wukong_common.xdc names
   // adapter/req_tgl_reg and three more of its registers by path, and a
   // get_cells that matches nothing is dropped silently rather than erroring.
   wire [27:0]  c0_addr, c1_addr;
   wire         c0_we, c0_req, c0_done, c1_req, c1_done;
   wire [127:0] c0_wdata, c0_rdata, c1_rdata;
   wire [15:0]  c0_wmask;

   wb_to_mig_ui adapter (
       .clk_wb  (cpu_clk),
       .rst_wb  (sys_reset),

       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb), .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_m2s), .wb_sel_i (wb_sel), .wb_we_i (wb_we),
       .wb_dat_o (wb_dat_s2m), .wb_ack_o (wb_ack),

       .ui_clk (ui_clk), .ui_rst (ui_clk_sync_rst),

       .c_addr (c0_addr), .c_we (c0_we), .c_wdata (c0_wdata), .c_wmask (c0_wmask),
       .c_req (c0_req), .c_done (c0_done), .c_rdata (c0_rdata)
   );

   mig_arb arbiter (
       .ui_clk (ui_clk), .ui_rst (ui_clk_sync_rst),
       .init_calib_complete (init_calib_complete),

       .c0_addr (c0_addr), .c0_we (c0_we), .c0_wdata (c0_wdata), .c0_wmask (c0_wmask),
       .c0_req (c0_req), .c0_done (c0_done), .c0_rdata (c0_rdata),

       .c1_addr (c1_addr), .c1_req (c1_req), .c1_done (c1_done), .c1_rdata (c1_rdata),

       .app_addr (app_addr), .app_cmd (app_cmd), .app_en (app_en), .app_rdy (app_rdy),
       .app_wdf_data (app_wdf_data), .app_wdf_mask (app_wdf_mask),
       .app_wdf_wren (app_wdf_wren), .app_wdf_end (app_wdf_end),
       .app_wdf_rdy (app_wdf_rdy),
       .app_rd_data (app_rd_data), .app_rd_data_valid (app_rd_data_valid)
   );

   // ------------------------------------------------------------------
   // The frame buffer on HDMI
   // ------------------------------------------------------------------
   wire [2:0] tmds;
   wire       tmds_clock;

`ifdef SUN2_FB
   wire clk_pixel, clk_pixel_x5, hdmi_locked;

   hdmi_clkgen hdmiclk (
       .clk50        (clk50_g),
       .reset        (board_reset),
       .clk_pixel    (clk_pixel),
       .clk_pixel_x5 (clk_pixel_x5),
       .locked       (hdmi_locked)
   );

   // The pixel domain comes out of reset once its own MMCM has locked.
   wire pix_rst;
   reset_sync rst_pix (
       .clk          (clk_pixel),
       .rst_async_in (board_reset | ~hdmi_locked),
       .rst_sync_out (pix_rst)
   );

   wire [11:0] cx;
   wire [10:0] cy;
   wire [23:0] rgb;

   fb_scanout #(.FB_APP_BASE(28'(`FB_WB_BASE * 2))) scanout (
       .ui_clk (ui_clk), .ui_rst (ui_clk_sync_rst),
       .c_addr (c1_addr), .c_req (c1_req), .c_done (c1_done), .c_rdata (c1_rdata),
       .clk_pixel (clk_pixel), .pix_rst (pix_rst),
       .cx (cx), .cy (cy), .video_en (fb_video_en), .rgb (rgb)
   );

   // DVI rather than full HDMI: no audio to send, and it costs less.  Every
   // HDMI sink accepts a DVI signal.
   hdmi #(.VIDEO_ID_CODE(16),          // 1920x1080p60
          .DVI_OUTPUT(1'b1),
          .VIDEO_REFRESH_RATE(60.0),
          .IT_CONTENT(1'b1),
          .VENDOR_NAME({"Sun     "}),
          .PRODUCT_DESCRIPTION({"Sun-2/50        "})
   ) hdmi_tx (
       .clk_pixel_x5 (clk_pixel_x5),
       .clk_pixel    (clk_pixel),
       .clk_audio    (clk_pixel),       // unused with DVI_OUTPUT
       .reset        (pix_rst),
       .rgb          (rgb),
       .audio_sample_word ('{16'd0, 16'd0}),
       .tmds         (tmds),
       .tmds_clock   (tmds_clock),
       .cx           (cx),
       .cy           (cy),
       .frame_width  (), .frame_height (), .screen_width (), .screen_height ()
   );
`else
   // No frame buffer: the arbiter sees a client that never asks, and the HDMI
   // pins sit still.
   assign c1_addr = 28'h0;
   assign c1_req  = 1'b0;
   assign tmds       = 3'b000;
   assign tmds_clock = 1'b0;
`endif

   // The hdmi module hands out single-ended TMDS; the differential buffers are
   // ours.  TMDS_33 is the right standard on a 3.3 V HR bank.
   OBUFDS obufds_d0  (.I(tmds[0]),   .O(tmds_p[0]), .OB(tmds_n[0]));
   OBUFDS obufds_d1  (.I(tmds[1]),   .O(tmds_p[1]), .OB(tmds_n[1]));
   OBUFDS obufds_d2  (.I(tmds[2]),   .O(tmds_p[2]), .OB(tmds_n[2]));
   OBUFDS obufds_clk (.I(tmds_clock), .O(tmds_clk_p), .OB(tmds_clk_n));

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
