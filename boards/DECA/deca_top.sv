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
`include "sun2_attr.vh"

module deca_top #(
    // Declared here as well as on deca_clkgen, and forwarded to the instance.
    // A generic passed at synthesis reaches the top level and nothing below it;
    // this project has produced three builds whose banner disagreed with their
    // logic for exactly that reason.
    parameter int CPU_CLK_HZ = 12_500_000,
    parameter int CPU_DIV    = 0,
    parameter int CPU_DUTY   = 50,
    // The trace recorder's trigger, as A[23:11] -- the 2 KiB page a bus cycle
    // is on.  0x1DC5 is 0xEE2800, the Sun-2/50's SCSI registers, which is what
    // sdprobe touches and what stops raising a bus error above 12.5 MHz.
    parameter int TRACE_PAGE = 'h1DC5,
    parameter int TRACE_POST = 192,
    // Function code to qualify the trigger on, and whether to.  Defaults to 5,
    // supervisor data, which is what a device probe is -- the untypical case
    // is wanting *any* function code, not wanting one.
    parameter int TRACE_FC    = 5,
    parameter int TRACE_FC_EN = 1
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
    inout  wire        NET_MDIO,

    // DDR3.  MT41K256M16, 512 MB, 16-bit.  Pin assignments and I/O standards
    // come from BrianHG's own DECA project via syn/deca_ddr3_pins.qsf.
    output wire        DDR3_RESET_n,
    output wire        DDR3_CK_p,
    output wire        DDR3_CK_n,
    output wire        DDR3_CKE,
    output wire        DDR3_CS_n,
    output wire        DDR3_RAS_n,
    output wire        DDR3_CAS_n,
    output wire        DDR3_WE_n,
    output wire        DDR3_ODT,
    output wire [14:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    inout  wire [1:0]  DDR3_DM,
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS_p,
    inout  wire [1:0]  DDR3_DQS_n
);

   // ------------------------------------------------------------------
   // Clocks
   // ------------------------------------------------------------------
   wire cpu_clk, clk_serial, pll_locked;

   deca_clkgen #(.CPU_CLK_HZ(CPU_CLK_HZ), .CPU_DIV(CPU_DIV),
                 .CPU_DUTY(CPU_DUTY)) clkgen (
       .clk50      (MAX10_CLK1_50),
       .reset      (~KEY[0]),
       .clk_cpu    (cpu_clk),
       .clk_serial (clk_serial),
       .locked     (pll_locked)
   );

   // ------------------------------------------------------------------
   // Reset
   //
   // The Wukong's chain (wukong_top.sv:230-250), including its
   // init_calib_complete term -- which this file previously omitted, with a
   // comment saying on-chip RAM needs no calibration.  That was true of the
   // M9K build and is not true now: DDR3 calibrates, and a machine that starts
   // fetching before DDR3_READY reads whatever the controller happens to
   // return.  ddr3_ready is that term, under its own name.
   //
   // The hold counter stays for the reason it exists there: a reset released
   // one clock early is a class of fault that only shows on hardware.
   // ------------------------------------------------------------------
   reg [15:0] hold_ctr = 16'hFFFF;
   always @(posedge cpu_clk or negedge pll_locked)
     if (!pll_locked)          hold_ctr <= 16'hFFFF;
     else if (hold_ctr != 0)   hold_ctr <= hold_ctr - 16'd1;

   // Everything that goes into the reset is synchronised into cpu_clk first,
   // and the result is a register rather than a combinational net.
   //
   // This is the Wukong's CDC-10 bug, and it was reproduced here in a worse
   // form before anyone looked: board_reset was five terms OR'd together --
   // KEY[0] (a button), pll_locked (asynchronous), hold_ctr (cpu_clk),
   // jtag_reset (the TCK domain, through ISSP) and ddr3_ready (the DDR3
   // domain) -- driving reset_sync's *asynchronous* reset input in three
   // places, the PHY's reset pin and the DDR3 controller's.  When two terms
   // move in opposite directions on one edge the skew between their routes is
   // a glitch on an async reset, and whether it is wide enough to take depends
   // on placement.  CLAUDE.md records what that cost on the other board: a
   // machine that froze part-way through an NFS read, with WNS *better* in the
   // builds that failed.
   //
   // Quartus says the same thing its own way.  report_metastability puts
   // DDR3_READY at the top of the synchroniser list and gives the design a
   // worst-case MTBF of 8.07e+03 seconds -- about two hours.
   `SUN2_ASYNC_REG reg key_s1, key_s2;
   `SUN2_ASYNC_REG reg rdy_s1, rdy_s2;
   `SUN2_ASYNC_REG reg jrst_s1, jrst_s2;

   always @(posedge cpu_clk) begin
      key_s1  <= ~KEY[0];    key_s2  <= key_s1;
      rdy_s1  <= ddr3_ready; rdy_s2  <= rdy_s1;
      jrst_s1 <= jtag_reset; jrst_s2 <= jrst_s1;
   end

   // Both start asserted, so the machine is held until cpu_clk actually runs --
   // which cannot happen before the PLL locks, so there is no window where a
   // stale register releases the design early.
   reg board_reset_raw_q = 1'b1;
   reg board_reset_q     = 1'b1;

   always @(posedge cpu_clk) begin
      board_reset_raw_q <= key_s2 | ~pll_locked | (hold_ctr != 16'd0) | jrst_s2;
      board_reset_q     <= board_reset_raw_q | ~rdy_s2;
   end

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

   // Two resets, and the split is load-bearing.  board_reset_raw is what the
   // DDR3 controller is held in; board_reset additionally waits for it to come
   // out of calibration and is what the machine sees.  Feeding ~ddr3_ready back
   // into the controller's own reset would be circular -- it would never
   // calibrate, because calibrating requires not being in reset.
   wire board_reset_raw = board_reset_raw_q;
   wire board_reset     = board_reset_q;

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
   wire        mdio_cyc, mdio_stb, mdio_we, mdio_ack;
   wire [3:0]  mdio_sel;
   wire [5:0]  mdio_adr;
   wire [31:0] mdio_dat_w, mdio_dat_r;
   wire [15:0] phy_id;
   wire        phy_present, phy_cfg_done, phy_link, phy_fd;
   wire [1:0]  phy_speed;
   wire        ev_rx_valid, ev_wr_data, ev_rd_valid, ev_tx_start;
`ifdef SUN2_ILA
   wire [117:0] dbg_bus;
`endif

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
       .dbg_bus        (dbg_bus),
`endif
       .eth_crs_stuck  (eth_crs_stuck),
       .fb_video_en    (fb_video_en),

       .phy_id         (phy_id),
       .phy_present    (phy_present),
       .phy_cfg_done   (phy_cfg_done),
       .phy_link       (phy_link),
       .phy_fd         (phy_fd),
       .phy_speed      (phy_speed),

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
   // Main memory: the board's 512 MB of DDR3.
   //
   // This replaces the 64 KiB of on-chip M9K that got the machine to its
   // monitor prompt and no further -- the boot loader's buffer is at 0x0a0462,
   // 640 KiB up, so netbooting needs real memory and Ethernet needs netbooting.
   // deca_wb_ocram.sv is kept in the tree because it is still the right answer
   // for a build that wants no external dependency, and because it is the
   // reference the DDR3 path is checked against.
   // ------------------------------------------------------------------
   localparam int PORT_ADDR_SIZE  = 29;
   localparam int PORT_CACHE_BITS = 128;

   wire                         cmd_clk, ddr3_ready, ddr3_cal_pass, ddr3_rst_out;
   wire [7:0]                   ddr3_rdcal;

   wire                         cmd_busy_a       [0:0];
   wire                         cmd_ena_a        [0:0];
   wire                         cmd_write_ena_a  [0:0];
   wire [PORT_ADDR_SIZE-1:0]    cmd_addr_a       [0:0];
   wire [PORT_CACHE_BITS-1:0]   cmd_wdata_a      [0:0];
   wire [PORT_CACHE_BITS/8-1:0] cmd_wmask_a      [0:0];
   wire                         cmd_rready_a     [0:0];
   wire [PORT_CACHE_BITS-1:0]   cmd_rdata_a      [0:0];
   wire [7:0]                   cmd_rvec_out_a   [0:0];

   wire                         w_cmd_ena, w_cmd_we;
   wire [PORT_ADDR_SIZE-1:0]    w_cmd_addr;
   wire [PORT_CACHE_BITS-1:0]   w_cmd_wdata;
   wire [PORT_CACHE_BITS/8-1:0] w_cmd_wmask;

   assign cmd_ena_a[0]       = w_cmd_ena;
   assign cmd_write_ena_a[0] = w_cmd_we;
   assign cmd_addr_a[0]      = w_cmd_addr;
   assign cmd_wdata_a[0]     = w_cmd_wdata;
   assign cmd_wmask_a[0]     = w_cmd_wmask;

   deca_wb_to_ddr3 #(.PORT_ADDR_SIZE(PORT_ADDR_SIZE),
                     .PORT_CACHE_BITS(PORT_CACHE_BITS)) memif (
       .clk_wb   (cpu_clk),
       .rst_wb   (sys_reset),
       .wb_cyc_i (wb_cyc),
       .wb_stb_i (wb_stb),
       .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_w),
       .wb_sel_i (wb_sel),
       .wb_we_i  (wb_we),
       .wb_dat_o (wb_dat_r),
       .wb_ack_o (wb_ack),

       .cmd_clk        (cmd_clk),
       .cmd_rst        (ddr3_rst_out),
       .ddr3_ready     (ddr3_ready),
       .CMD_busy       (cmd_busy_a[0]),
       .CMD_ena        (w_cmd_ena),
       .CMD_write_ena  (w_cmd_we),
       .CMD_addr       (w_cmd_addr),
       .CMD_wdata      (w_cmd_wdata),
       .CMD_wmask      (w_cmd_wmask),
       .CMD_read_ready (cmd_rready_a[0]),
       .CMD_read_data  (cmd_rdata_a[0])
   );

   BrianHG_DDR3_CONTROLLER_v16_top #(
       .FPGA_VENDOR     ("Altera"),
       .FPGA_FAMILY     ("MAX 10"),
       .CLK_KHZ_IN      (50000),
       // 250 MHz, not the 400 their own DECA project uses: on Quartus 25.1 the
       // fitter refuses DDR3_CK_p at 800 Mbps against a 600 Mbps rating for
       // Differential 1.5-V SSTL Class I.  See test/deca_ddr3.
       .CLK_IN_MULT     (20),
       .CLK_IN_DIV      (4),
       .INTERFACE_SPEED ("Half"),
       .DDR3_SIZE_GB    (4),          // MT41K256M16, the DECA's part
       .DDR3_WIDTH_DQ   (16),
       .DDR3_NUM_CHIPS  (1),
       .PORT_TOTAL      (1),

       // **No caching.**  The controller's defaults hold a write in a write
       // cache for up to 256 CMD_CLK and treat a read cache line as fresh for
       // another 256, with PORT_CACHE_SMART supposed to push a write into any
       // read cache line covering the same address.  On this machine that
       // combination produces a **read-after-write hazard**, caught on the
       // board with rtl/sun2-common/sun2_trace.v: the boot PROM's sdprobe
       // wrote 2 to its loop counter at 0x000F28 and the `cmpi.l #2' that
       // follows read the same address back as **1** forty-seven clocks later,
       // so the loop's bound check failed, it indexed one past the end of
       // sdstd[], probed address 0x0C in low RAM -- which answers -- and
       // reported a SCSI controller that does not exist.  The same location
       // read correctly 41 clocks after that, which is what says stale cache
       // rather than lost write.
       //
       // The caches buy this client nothing.  A 12.5 MHz 68010 issues one
       // 32-bit access at a time and stalls on DTACK until it is answered, so
       // there is no burst to coalesce and no latency to hide -- the whole
       // reason deca_wb_to_ddr3 is single-transaction-in-flight.  0 means
       // immediate writes and always read from DDR3, which is the semantics a
       // CPU bus actually needs.  BrianHG's own note on PORT_CACHE_SMART --
       // "Disable when designing a memory read/write testing algorithm" -- is
       // the same warning from the other direction.
       .PORT_W_CACHE_TOUT ('{16{9'd0}}),
       .PORT_R_CACHE_TOUT ('{16{9'd0}}),
       .PORT_CACHE_SMART  ('{16{1'b0}})
   ) ddr3 (
       .RST_IN   (board_reset_raw),
       .CLK_IN   (MAX10_CLK1_50),
       .DDR3_CLK (), .DDR3_CLK_50 (), .DDR3_CLK_25 (),
       .CMD_CLK      (cmd_clk),
       .RST_OUT      (ddr3_rst_out),
       .DDR3_READY   (ddr3_ready),
       .SEQ_CAL_PASS (ddr3_cal_pass),
       .PLL_LOCKED   (),
       .RDCAL_data   (ddr3_rdcal),

       .CMD_busy            (cmd_busy_a),
       .CMD_ena             (cmd_ena_a),
       .CMD_write_ena       (cmd_write_ena_a),
       .CMD_addr            (cmd_addr_a),
       .CMD_wdata           (cmd_wdata_a),
       .CMD_wmask           (cmd_wmask_a),
       .CMD_read_vector_in  ('{8'h00}),
       .CMD_read_ready      (cmd_rready_a),
       .CMD_read_data       (cmd_rdata_a),
       .CMD_read_vector_out (cmd_rvec_out_a),
       .CMD_priority_boost  ('{1'b0}),
       .SEQ_refresh_hold    (1'b0),

       .DDR3_RESET_n (DDR3_RESET_n), .DDR3_CK_p (DDR3_CK_p), .DDR3_CK_n (DDR3_CK_n),
       .DDR3_CKE (DDR3_CKE), .DDR3_CS_n (DDR3_CS_n), .DDR3_RAS_n (DDR3_RAS_n),
       .DDR3_CAS_n (DDR3_CAS_n), .DDR3_WE_n (DDR3_WE_n), .DDR3_ODT (DDR3_ODT),
       .DDR3_A (DDR3_A), .DDR3_BA (DDR3_BA), .DDR3_DM (DDR3_DM),
       .DDR3_DQ (DDR3_DQ), .DDR3_DQS_p (DDR3_DQS_p), .DDR3_DQS_n (DDR3_DQS_n)
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

   // The two panels go on the probe as well as on the headers.
   //
   // `todebug' is this project's primary board instrument -- BRINGUP.md says to
   // read it before building anything -- and it was only reachable by looking
   // at a GPIO header, which is no use to anyone working remotely.  Bit 0
   // seen_stall alone splits a memory fault in half: set means a bus cycle went
   // unanswered, clear exonerates the memory path outright.  That is the
   // reading that stopped a day of wrong theories on the Wukong.
   //
   //   todebug 7 heartbeat  6 in reset  5 seen_err  4:2 fc of the first error
   //           1 diag written  0 seen_stall
   //   diag_leds  the Sun-2 front panel: how far the PROM got
   //
   // ddr3_cal_pass and ddr3_ready are here too, because "the memory never came
   // up" and "the memory came up and then misbehaved" are different faults that
   // look identical from a machine that will not boot.
   altsource_probe #(
       .sld_auto_instance_index ("YES"),
       .instance_id             ("SUN2"),
       .probe_width             (64),
       .source_width            (1),
       .source_initial_value    ("0"),
       // source_clk is what clocks the hardening registers this asks for.  It
       // was left unconnected, which meant the JTAG source bit crossed from the
       // TCK domain into an asynchronous reset with no synchroniser at all --
       // "enable_metastability" with nothing to clock it is a comment, not a
       // synchroniser.  It is still resynchronised in the reset assembly above,
       // because two flops in the right domain beat one megafunction parameter.
       .enable_metastability    ("YES")
   ) u_issp (
       .source_clk (cpu_clk),
       .probe  ({ddr3_rdcal,                          // 63:56
                 ddr3_cal_pass, ddr3_ready, phy_link, // 55:53
                 phy_present, phy_cfg_done, phy_speed, phy_fd, // 52:48
                 todebug,                             // 47:40
                 diag_leds,                           // 39:32
                 n_wr[7:0], n_rd[7:0], n_rx[7:0], n_tx[7:0]}),
       .source (jtag_reset)
   );

`ifdef SUN2_TRACE
   // ------------------------------------------------------------------
   // The MMU trace recorder, read out over JTAG.
   //
   // The Wukong has an ILA on exactly this bus and the DECA cannot: SignalTap
   // is a GUI artefact, `quartus_stp' will run an acquisition but will not
   // create one, and this project's flow is scripted end to end.  So the
   // buffer is plain RTL -- see rtl/sun2-common/sun2_trace.v -- and comes out
   // through In-System Sources and Probes, which tools/deca_reset.tcl already
   // uses and tools/deca_trace.tcl decodes.
   //
   // Fitted only under TRACE=1.  The bare dbg_bus port cost the Wukong 8 LUTs
   // and 17 ps of hold margin in a build with no ILA in it, and the same
   // argument applies here with a 30 kbit buffer attached to it.
   // ------------------------------------------------------------------
   // 1024 samples, not 256.  A 68010 bus-error frame is 29 words and each push
   // is nine clocks, so the whole exception is about 260 clocks -- and the
   // words that matter (status register, PC, format/vector, special status
   // word, fault address) are pushed *last*, at the bottom of the frame.  A
   // 256-sample buffer catches the top of the frame and stops exactly before
   // the interesting part, which is how the first capture of it read.
   localparam TRC_DEPTH_LOG2 = 10;
   localparam TRC_POST       = 960;

   wire [117:0] trc_rd_data;
   wire [TRC_DEPTH_LOG2-1:0] trc_wr_ptr;
   wire         trc_triggered, trc_done;
   wire [29:0]  trc_src;

   // The source carries the whole instrument's controls, not just a read
   // address:
   //
   //   [9:0]   sample index          [11:10] which word: 0 low, 1 high, 2 status
   //   [24:12] trigger page          [25]    hold (clears and holds the capture)
   //   [28:26] trigger function code [29]    qualify on it
   //
   // The status word carries DEPTH_LOG2 and POST as well as the pointer, so the
   // reader never has to be told the buffer's shape.  The first version had
   // them as constants in the Tcl, which is two places for one fact and the
   // sort of drift that makes a capture silently point at the wrong sample.
   //
   // `hold' rather than `arm' so that a source of all zeros -- which is what a
   // freshly configured device has, and what a boot with nobody attached runs
   // with -- means *running, on the page the bitstream was built with*.  An
   // arm-high polarity would have made every unattended capture empty.
   wire [12:0] trc_page = (trc_src[24:12] != 13'd0) ? trc_src[24:12]
                                                    : TRACE_PAGE[12:0];

   sun2_trace #(.WIDTH(118), .DEPTH_LOG2(TRC_DEPTH_LOG2),
                .POST(TRC_POST)) u_trace (
       .clk       (cpu_clk),
       .rst       (board_reset),
       .dbg_bus   (dbg_bus),
       .trig_page (trc_page),
       // As with the page: the source wins when the host has set it, and the
       // build-time default applies until then -- which is the only thing that
       // works for a *cold* boot, where configuring the device zeroes the
       // source and the probe happens before any host can write one.  A JTAG
       // reset is no substitute: it is a warm reset, and the PROM's
       // non-power-up path skips the device probes entirely.
       .trig_fc   (trc_src[29] ? trc_src[28:26] : TRACE_FC[2:0]),
       .trig_fc_en(trc_src[29] | (TRACE_FC_EN != 0)),
       .arm       (~trc_src[25]),
       .rd_addr   (trc_src[9:0]),
       .rd_data   (trc_rd_data),
       .wr_ptr    (trc_wr_ptr),
       .triggered (trc_triggered),
       .done      (trc_done));

   // 118 bits does not fit a 64-bit probe, so the source's top bit picks the
   // half.  The status rides in the high half rather than in a third read,
   // because a reader that has to issue three transfers per sample to learn
   // whether the capture even finished will issue them 256 times.
   altsource_probe #(
       .sld_auto_instance_index ("YES"),
       .instance_id             ("TRAC"),
       .probe_width             (64),
       .source_width            (30),
       .source_initial_value    ("0"),
       .enable_metastability    ("YES")
   ) u_trace_issp (
       .source_clk (cpu_clk),
       .probe  ((trc_src[11:10] == 2'd0) ? trc_rd_data[63:0]
              : (trc_src[11:10] == 2'd1) ? {10'd0, trc_rd_data[117:64]}
              : {trc_done, trc_triggered, trc_wr_ptr,
                 TRC_DEPTH_LOG2[3:0], TRC_POST[15:0], 32'd0}),
       .source (trc_src)
   );
`endif

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

   // ------------------------------------------------------------------
   // PHY management
   //
   // MDC well under the 2.5 MHz the standard allows, and deliberately slower
   // than it needs to be: management bandwidth buys nothing and a slow bus
   // tolerates whatever capacitance is on the trace.
   // 12.5 MHz / (2 * (49 + 1)) = 125 kHz.
   // ------------------------------------------------------------------
   wb_mdio #(.DIV_RESET(49)) mdio_station (
       .clk       (cpu_clk),
       .rst       (sys_reset),
       .wbs_cyc_i (mdio_cyc),
       .wbs_stb_i (mdio_stb),
       .wbs_we_i  (mdio_we),
       .wbs_sel_i (mdio_sel),
       .wbs_adr_i (mdio_adr),
       .wbs_dat_i (mdio_dat_w),
       .wbs_dat_o (mdio_dat_r),
       .wbs_ack_o (mdio_ack),
       .wbs_err_o (),
       .mdc       (NET_MDC),
       .mdio_o    (mdio_o),
       .mdio_oe   (mdio_oe),
       .mdio_i    (mdio_i)
   );

   // Quartus infers the tristate; there is no IOBUF to instantiate as there is
   // on the Wukong, which is one of the few places the Altera side is simpler.
   assign NET_MDIO = mdio_oe ? mdio_o : 1'bz;
   assign mdio_i   = NET_MDIO;

   // The DP83620 needs RESET_N low for only 1 us (datasheet 6.6), which the
   // hold counter covers many times over -- unlike the RTL8211's 10 ms plus
   // 30 ms of settling.  `enable' is simply "we are out of reset".
   reg [15:0] phy_wait;
   always @(posedge cpu_clk)
     if (board_reset)          phy_wait <= 16'd0;
     else if (!phy_wait[15])   phy_wait <= phy_wait + 16'd1;

   phy_dp83620_init #(.PHY_ADDR(5'd1)) phy_init (
       .clk         (cpu_clk),
       .rst         (sys_reset),
       .enable      (phy_wait[15]),
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

   assign NET_RESET_n = ~board_reset_raw;
   // PCF_EN low disables the power-control-frame feature, which a Sun-2 knows
   // nothing about.
   assign NET_PCF_EN  = 1'b0;

   // Tie-offs that exist so nothing above is silently unconnected.  Quartus
   // reports an assigned-but-never-read object, which is the warning we want:
   // it names a signal that is deliberately unused rather than one that got
   // lost.
   wire _unused = &{1'b0, en_boot, eth_crs_stuck, fb_video_en, blk_start,
                    blk_we_o, blk_lba, blk_buf_rdata,
                    KEY[1], SW[1], ddr3_cal_pass, ddr3_rdcal, 1'b0};

endmodule
