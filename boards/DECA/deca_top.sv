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
//    console goes over the on-board USB-Blaster II through a JTAG UART --
//    deca_jtag_console.sv -- read on the host with `juart-terminal'.  The
//    machine's bit-serial tx/rx are kept as they are and bridged, rather than
//    tapping bytes out of the SCC, because the SCC's baud generator running
//    correctly off a MAX 10 PLL is precisely what this board has to prove.
//    `tx' also goes out on GPIO0_D[0] = PIN_W18, which is the DECA's own
//    UART_TXD, so a USB-TTL cable is the fallback and costs no gateware.
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

   // A reset that can be asserted over JTAG, because the DECA's only reset is a
   // physical button and this machine is worked on remotely.
   //
   // It also solves a real observation problem: configuring the FPGA tears down
   // any open JTAG UART session, so a terminal cannot be attached *before* the
   // machine starts printing -- and the boot banner is about 60 characters,
   // which is the size of the JTAG UART's write FIFO.  Attach the terminal,
   // pulse this, and the boot is watched from its first byte instead of from
   // wherever the FIFO happened to overflow.
   wire jtag_reset;

   wire board_reset = ~KEY[0] | ~pll_locked | (hold_ctr != 16'd0) | jtag_reset;

   wire sys_reset;
   reset_sync rst_cpu (.clk(cpu_clk),
                       .rst_async_in (board_reset),
                       .rst_sync_out (sys_reset));

   // ------------------------------------------------------------------
   // The machine
   // ------------------------------------------------------------------
   wire [7:0]  diag_leds, todebug;
   wire        en_boot, eth_crs_stuck, fb_video_en;
   wire        sun_tx, sun_rx;
   wire        con_dropped, con_frame_err;
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
   wire        ev_rx_valid, ev_wr_data, ev_rd_valid, ev_tx_start;

   top machine (
       .cpu_clk        (cpu_clk),
       .clk40          (1'b0),          // dead on both boards: its only reader
                                        // was a path that is compiled out
       .clk4m9152      (clk_serial),
       .sys_reset      (sys_reset),

       .tx             (sun_tx),
       .rx             (sun_rx),

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
   // Console
   //
   // clk_serial, so the bit period is exactly 512 clocks whatever CPU_HZ is --
   // see deca_jtag_console.sv.  The reset is sys_reset resynchronised into the
   // serial domain: it is released in the cpu_clk domain and this is a
   // different clock, so feeding it straight in would leave the release
   // unsynchronised, which is the whole reason reset_sync exists.
   // ------------------------------------------------------------------
   // The console runs on cpu_clk, not clk_serial, and that is a measurement
   // rather than a preference.
   //
   // clk_serial is the tidier choice on paper -- the SCC's own domain, and
   // 4915254/9600 = 512.005 makes a bit exactly 512 clocks.  It does not work.
   // The JTAG Atlantic inside altera_avalon_jtag_uart crosses into the TCK
   // domain, which the timing report puts at 10 MHz, and with a 4.915 MHz user
   // clock -- slower than TCK -- the host reads each byte twice and out of
   // order.  Measured with in-system probes: for 8 bytes the design's own
   // counters read 8 receives, 8 writes, 8 reads and 8 transmits, one of each
   // per byte, while both juart-terminal and nios2-terminal showed ten
   // characters.  A design writing sequentially into a FIFO cannot produce
   // out-of-order output; only something downstream can.  Moving to 12.5 MHz
   // fixed it with the counters unchanged at 8/8/8/8.
   //
   // The cost is that a bit is 12500000/9600 = 1302.08 clocks and 1302 is used
   // -- a 0.006% rate error, four hundred times smaller than the +/-2% the
   // receiver is tested to tolerate.  Note this makes the console's framing
   // depend on CPU_HZ, which is exactly what putting it on clk_serial avoided;
   // if CPU_DIV changes, CLKS_PER_BIT must change with it.
   wire con_rst;
   reset_sync rst_con (.clk(cpu_clk),
                       .rst_async_in (board_reset),
                       .rst_sync_out (con_rst));

   deca_jtag_console #(.CLKS_PER_BIT(CPU_CLK_HZ / 9600)) console (
       .clk       (cpu_clk),
       .rst       (con_rst),
       .sun_tx    (sun_tx),
       .sun_rx    (sun_rx),
       .dropped   (con_dropped),
       .frame_err (con_frame_err),
       .ev_rx_valid (ev_rx_valid),
       .ev_wr_data  (ev_wr_data),
       .ev_rd_valid (ev_rd_valid),
       .ev_tx_start (ev_tx_start)
   );

   // ------------------------------------------------------------------
   // In-System Sources and Probes: a reset in, four event counters out.
   //
   // The counters are what found the console's clock fault -- they said the
   // design did exactly one receive, write, read and transmit per byte while
   // the host showed each byte twice, which is what moved the search
   // downstream.  They stay because that class of question recurs and a probe
   // cannot be attached after the fact without a rebuild.
   // ------------------------------------------------------------------
   reg [15:0] n_rx, n_wr, n_rd, n_tx;
   always @(posedge cpu_clk)
     if (con_rst) begin
        n_rx <= 16'd0; n_wr <= 16'd0; n_rd <= 16'd0; n_tx <= 16'd0;
     end else begin
        if (ev_rx_valid) n_rx <= n_rx + 16'd1;
        if (ev_wr_data)  n_wr <= n_wr + 16'd1;
        if (ev_rd_valid) n_rd <= n_rd + 16'd1;
        if (ev_tx_start) n_tx <= n_tx + 16'd1;
     end

   altsource_probe #(
       .sld_auto_instance_index ("YES"),
       .instance_id             ("SUN2"),
       .probe_width             (64),
       .source_width            (1),
       .source_initial_value    ("0"),
       .enable_metastability    ("YES")
   ) u_issp (
       .probe  ({n_tx, n_rd, n_wr, n_rx}),
       .source (jtag_reset)
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
   // GPIO0_D[0] is the console transmit line -- PIN_W18 is the DECA's own
   // UART_TXD, so a USB-TTL cable on P8 pin 3 reads the monitor with no
   // gateware change, which is the fallback if the JTAG path misbehaves.
   // [1] and [2] are the console's two health flags: a byte lost because
   // nothing was listening, and a framing error, which would mean the PLL
   // ratio is wrong.  Both are sticky.
   assign GPIO0_D = {diag_leds[7:3], con_frame_err, con_dropped, sun_tx};
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
