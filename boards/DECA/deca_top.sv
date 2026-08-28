//
// The Sun-2 on an Arrow DECA (MAX 10 10M50DAF484C6GES).
//
// The twin of boards/Wukong/wukong_top.sv: board pins in, the machine seam out.
// Everything below `top' is shared between the two boards -- rtl/ contains no
// vendor primitive and no vendor IP, and these two files are the evidence.
//
// What this board does NOT have, and what follows from that:
//
//  * **No hard memory controller.**  A MAX 10 has none, and the DECA's 512 MB
//    of DDR3 needs Altera's soft UniPHY, which no DECA design in the reference
//    material actually instantiates.  Main memory is on-chip M9K here --
//    deca_wb_ocram.sv -- which the machine can do because the boot PROM reaches
//    its prompt in 32 KiB.  It cannot netboot on chip; see that file.
//
//  * **No UART.**  Nothing on the DECA brings a serial port to the FPGA.  The
//    console goes over the on-board USB-Blaster II through a JTAG UART, which
//    arrives in M4; until then `tx' is brought out on a GPIO header pin so a
//    scope or a USB-TTL cable can see it, and `rx' is tied idle.
//
//  * **Eight LEDs where the Wukong build uses sixteen.**  SW[0] picks which
//    panel they show.  Both are levels and latched "this happened at least
//    once" flags (sun2_fpga.v), never edges, so a switch is a legitimate
//    instrument rather than a race -- and both go out on the GPIO headers
//    unconditionally, so a logic analyser gets everything at once.
//
// The MII pins are connected even though nothing brings the PHY up yet.  That
// is deliberate: tying mii_tx_clk/mii_rx_clk to constants lets Quartus prune
// most of the 82586's receive unit, and then every logic-element, M9K and Fmax
// number describes a design that is not the one which will eventually run.
// Seventeen pins and no logic is a cheap price for honest numbers.
//
`timescale 1ns / 1ps

`include "sun2_config.vh"

module deca_top #(
    // Declared here as well as on deca_clkgen, and forwarded to the instance.
    // A generic passed at synthesis reaches the top level and nothing below it;
    // this project has produced three builds whose banner disagreed with their
    // logic for exactly that reason.
    parameter int CPU_CLK_HZ = 12_500_000,
    parameter int CPU_DIV    = 0
) (
    input  wire        MAX10_CLK1_50,   // PIN_M8,  2.5 V
    input  wire [1:0]  KEY,             // H21 H22, 1.5 V Schmitt, active low
    input  wire [1:0]  SW,              // J21 J22, 1.5 V Schmitt
    output wire [7:0]  LED,             // bank 8, 1.2 V, ACTIVE LOW
    output wire [7:0]  GPIO0_D,         // P8 header, 3.3 V
    output wire [7:0]  GPIO1_D,         // P9 header, 3.3 V

    // MII to the on-board TI DP83620, 2.5 V.  The PHY sources both clocks at
    // 10 Mb/s, so the FPGA drives no clock out.
    input  wire        NET_TX_CLK,
    output wire [3:0]  NET_TXD,
    output wire        NET_TX_EN,
    input  wire        NET_RX_CLK,
    input  wire [3:0]  NET_RXD,
    input  wire        NET_RX_DV,
    input  wire        NET_RX_ER,
    input  wire        NET_CRS,
    input  wire        NET_COL,
    output wire        NET_RESET_n,
    output wire        NET_MDC,
    output wire        NET_PCF_EN,
    inout  wire        NET_MDIO
);

   // ------------------------------------------------------------------
   // Clocks
   // ------------------------------------------------------------------
   wire cpu_clk, clk_serial, pll_locked;

   deca_clkgen #(.CPU_CLK_HZ(CPU_CLK_HZ), .CPU_DIV(CPU_DIV)) clkgen (
       .clk50      (MAX10_CLK1_50),
       .reset      (~KEY[0]),
       .clk_cpu    (cpu_clk),
       .clk_serial (clk_serial),
       .locked     (pll_locked)
   );

   // ------------------------------------------------------------------
   // Reset
   //
   // The Wukong's chain (wukong_top.sv:230-250) minus its init_calib_complete
   // term: on-chip RAM needs no calibration, so there is nothing to wait for
   // beyond the PLLs.  The hold counter exists for the same reason it does
   // there -- the machine must not start before the clocks are steady, and a
   // reset released one clock early is a class of fault that only shows on
   // hardware.
   // ------------------------------------------------------------------
   reg [15:0] hold_ctr = 16'hFFFF;
   always @(posedge cpu_clk or negedge pll_locked)
     if (!pll_locked)          hold_ctr <= 16'hFFFF;
     else if (hold_ctr != 0)   hold_ctr <= hold_ctr - 16'd1;

   wire board_reset = ~KEY[0] | ~pll_locked | (hold_ctr != 16'd0);

   wire sys_reset;
   reset_sync rst_cpu (.clk(cpu_clk),
                       .rst_async_in (board_reset),
                       .rst_sync_out (sys_reset));

   // ------------------------------------------------------------------
   // The machine
   // ------------------------------------------------------------------
   wire [7:0]  diag_leds, todebug;
   wire        en_boot, eth_crs_stuck, fb_video_en;
   wire        sun_tx;
   wire        wb_cyc, wb_stb, wb_we, wb_ack;
   wire [29:0] wb_adr;
   wire [31:0] wb_dat_w, wb_dat_r;
   wire [3:0]  wb_sel;

   // Block back end: a VME machine has no Xylogics, so the outputs go nowhere
   // and the inputs are tied.  Named rather than omitted -- a port left off an
   // instantiation becomes an undriven wire and reaches the board dead, which
   // is exactly how fb_video_en spent the life of the frame buffer at zero.
   wire        blk_start, blk_we_o;
   wire [31:0] blk_lba;
   wire [7:0]  blk_buf_rdata;

   wire        mdio_i, mdio_o, mdio_oe;

   top machine (
       .cpu_clk        (cpu_clk),
       .clk40          (1'b0),          // dead on both boards: its only reader
                                        // was a path that is compiled out
       .clk4m9152      (clk_serial),
       .sys_reset      (sys_reset),

       .tx             (sun_tx),
       .rx             (1'b1),          // idle until the JTAG console lands

       .diag_leds      (diag_leds),
       .en_boot        (en_boot),
       .todebug        (todebug),
`ifdef SUN2_ILA
       .dbg_bus        (),
`endif
       .eth_crs_stuck  (eth_crs_stuck),
       .fb_video_en    (fb_video_en),

       // No PHY management yet; the status register in device page 0xFE7 will
       // read "no PHY", which is true.
       .phy_id         (16'h0000),
       .phy_present    (1'b0),
       .phy_cfg_done   (1'b0),
       .phy_link       (1'b0),
       .phy_fd         (1'b0),
       .phy_speed      (2'b00),

       .mii_tx_clk     (NET_TX_CLK),
       .mii_txd        (NET_TXD),
       .mii_tx_en      (NET_TX_EN),
       .mii_tx_er      (),
       .mii_rx_clk     (NET_RX_CLK),
       .mii_rxd        (NET_RXD),
       .mii_rx_dv      (NET_RX_DV),
       .mii_rx_er      (NET_RX_ER),
       .mii_crs        (NET_CRS),
       .mii_col        (NET_COL),

       .blk_start      (blk_start),
       .blk_we         (blk_we_o),
       .blk_lba        (blk_lba),
       .blk_buf_rdata  (blk_buf_rdata),
       .blk_done       (1'b0),
       .blk_err        (1'b0),
       .blk_ready      (1'b0),
       .blk_count      (32'h0),
       .blk_buf_we     (1'b0),
       .blk_buf_addr   (9'h0),
       .blk_buf_wdata  (8'h0),

       .wb_cyc_o       (wb_cyc),
       .wb_stb_o       (wb_stb),
       .wb_adr_o       (wb_adr),
       .wb_dat_o       (wb_dat_w),
       .wb_sel_o       (wb_sel),
       .wb_we_o        (wb_we),
       .wb_dat_i       (wb_dat_r),
       .wb_ack_i       (wb_ack)
   );

   // ------------------------------------------------------------------
   // Main memory
   // ------------------------------------------------------------------
   deca_wb_ocram ram (
       .clk      (cpu_clk),
       .rst      (sys_reset),
       .wb_cyc_i (wb_cyc),
       .wb_stb_i (wb_stb),
       .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_w),
       .wb_sel_i (wb_sel),
       .wb_we_i  (wb_we),
       .wb_dat_o (wb_dat_r),
       .wb_ack_o (wb_ack)
   );

   // ------------------------------------------------------------------
   // Board outputs
   // ------------------------------------------------------------------
   // Active low, and one panel at a time.  ~SW[0] rather than SW[0] so the
   // switch in its default (down) position shows the Sun-2 front panel, which
   // is the one that means something to a person watching a boot.
   assign LED = SW[0] ? ~todebug : ~diag_leds;

   // Everything, always, on the headers.  GPIO0_D[0] doubles as the console
   // transmit line: PIN_W18 is what the DECA's own template calls UART_TXD, so
   // a USB-TTL cable on P8 pin 3 sees the monitor without any gateware change.
   assign GPIO0_D = {diag_leds[7:1], sun_tx};
   assign GPIO1_D = todebug;

   // The PHY is held out of reset and left alone.  PCF_EN low disables the
   // power-control-frame feature, which a Sun-2 knows nothing about.
   assign NET_RESET_n = ~board_reset;
   assign NET_MDC     = 1'b0;
   assign NET_PCF_EN  = 1'b0;
   assign NET_MDIO    = 1'bz;
   assign mdio_i      = NET_MDIO;

   // Tie-offs that exist so nothing above is silently unconnected.  Quartus
   // reports an assigned-but-never-read object, which is the warning we want:
   // it names a signal that is deliberately unused rather than one that got
   // lost.
   wire _unused = &{1'b0, en_boot, eth_crs_stuck, fb_video_en, blk_start,
                    blk_we_o, blk_lba, blk_buf_rdata, mdio_i, mdio_o, mdio_oe,
                    KEY[1], SW[1], 1'b0};

endmodule
