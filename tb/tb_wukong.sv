`timescale 1ns / 1ps

//
// Board-level testbench: the Sun-2 as it will be on a QMTech Wukong V1.
//
// Unlike tb_sun2, which drives the Sun-2 core directly with ideal clocks, this
// starts from the board's 50 MHz oscillator and the reset button and goes
// through the real clock generation and reset sequencing.
//
// Two memory configurations, selected by defining BOARD_MEM_FAST or not:
//
//   BOARD_MEM_FAST   MIG and the adapter are left out of the board top, which
//                    exposes the Wishbone port; a behavioural RAM hangs off it.
//                    Boots to the monitor prompt in about the time tb_sun2
//                    takes, and is the one that stays in the regression.
//
//   (default)        the real MIG plus Micron's DDR3 model.  Proves the clocks
//                    lock, MIG calibrates and the first memory transactions
//                    work; a full boot this way is impractically slow.
//
// Plusargs match tb_sun2 where they overlap: +timeout_ms, +heartbeat_ms,
// +stop_on, +vcd, +vcd_full.
//

module tb_wukong #(
    parameter int    CPU_CLK_HZ = 12_500_000,
    parameter int    BAUD       = 9600,
    parameter string CONSOLE    = "console.log"
)();

   // ------------------------------------------------------------------
   // Board inputs
   // ------------------------------------------------------------------
   reg clk50     = 1'b0;
   reg cpu_reset = 1'b0;          // button, active low: 0 = held in reset

   always #10.0 clk50 = ~clk50;   // 50 MHz

   wire        serial_tx;
   wire        serial_rx;         // driven by uart_console below
   wire [1:0]  user_led;
   wire [7:0]  diag_leds0;

   // ------------------------------------------------------------------
   // DUT and its memory
   // ------------------------------------------------------------------
   // The MII side.  Not optional: with no transmit clock the 82586 never
   // finishes a TRANSMIT command and the boot PROM waits on that with no
   // timeout, so the machine would simply stop with nothing printed.
   wire       mii_tx_clk, mii_tx_en, mii_tx_er, mii_rx_clk, mii_rx_dv, mii_rx_er;
   wire       mii_crs, mii_col, phy_reset_n;
   // MDIO is open drain with a 1.5k pull-up on the board, so tri1.
   wire       phy_mdc;
   tri1       phy_mdio;
   wire [3:0] mii_txd, mii_rxd;

   mii_peer peer(.mii_tx_clk(mii_tx_clk), .mii_txd(mii_txd),
                 .mii_tx_en(mii_tx_en), .mii_tx_er(mii_tx_er),
                 .mii_rx_clk(mii_rx_clk), .mii_rxd(mii_rxd),
                 .mii_rx_dv(mii_rx_dv), .mii_rx_er(mii_rx_er),
                 .mii_crs(mii_crs), .mii_col(mii_col));

   // The PHY reset sequencer runs off clk50 and takes 70 ms; report it so a
   // board run that never gets there is obvious.
   always @(posedge phy_reset_n)
     $display("[%t] PHY reset released", $realtime);

`ifdef BOARD_MEM_FAST

   wire        wb_cyc, wb_stb, wb_we, wb_ack;
   wire [29:0] wb_adr;
   wire [31:0] wb_dat_m2s, wb_dat_s2m;
   wire [3:0]  wb_sel;
   wire        cpu_clk, sys_reset;

   wukong_v1_top #(.CPU_CLK_HZ(CPU_CLK_HZ)) dut (
       .clk50 (clk50), .cpu_reset (cpu_reset),
       .phy_mii_tx_clk (mii_tx_clk),
       .phy_mii_txd    (mii_txd),
       .phy_mii_tx_en  (mii_tx_en),
       .phy_mii_tx_er  (mii_tx_er),
       .phy_mii_rx_clk (mii_rx_clk),
       .phy_mii_rxd    (mii_rxd),
       .phy_mii_rx_dv  (mii_rx_dv),
       .phy_mii_rx_er  (mii_rx_er),
       .phy_mii_crs    (mii_crs),
       .phy_mii_col    (mii_col),
       .phy_gtx_clk    (),
       .phy_reset_n    (phy_reset_n),
       .phy_mdc        (phy_mdc),
       .phy_mdio       (phy_mdio),

       .serial_tx (serial_tx), .serial_rx (serial_rx),
       .user_led (user_led), .diag_leds0 (diag_leds0), .user_btn (1'b1),
       .wb_cyc_o (wb_cyc), .wb_stb_o (wb_stb), .wb_adr_o (wb_adr),
       .wb_dat_o (wb_dat_m2s), .wb_sel_o (wb_sel), .wb_we_o (wb_we),
       .wb_dat_i (wb_dat_s2m), .wb_ack_i (wb_ack),
       .cpu_clk_o (cpu_clk), .sys_reset_o (sys_reset)
   );

   wb_ram_model #(.ACK_LATENCY(0)) ram (
       .clk (cpu_clk), .reset (sys_reset),
       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb), .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat_m2s), .wb_sel_i (wb_sel), .wb_we_i (wb_we),
       .wb_dat_o (wb_dat_s2m), .wb_ack_o (wb_ack)
   );

`else

   wire [15:0] ddr3_dq;
   wire [1:0]  ddr3_dqs_p, ddr3_dqs_n;
   wire [13:0] ddr3_addr;
   wire [2:0]  ddr3_ba;
   wire        ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n;
   wire [0:0]  ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_odt;
   wire [1:0]  ddr3_dm;

   wukong_v1_top #(.CPU_CLK_HZ(CPU_CLK_HZ)) dut (
       .clk50 (clk50), .cpu_reset (cpu_reset),
       .phy_mii_tx_clk (mii_tx_clk),
       .phy_mii_txd    (mii_txd),
       .phy_mii_tx_en  (mii_tx_en),
       .phy_mii_tx_er  (mii_tx_er),
       .phy_mii_rx_clk (mii_rx_clk),
       .phy_mii_rxd    (mii_rxd),
       .phy_mii_rx_dv  (mii_rx_dv),
       .phy_mii_rx_er  (mii_rx_er),
       .phy_mii_crs    (mii_crs),
       .phy_mii_col    (mii_col),
       .phy_gtx_clk    (),
       .phy_reset_n    (phy_reset_n),
       .phy_mdc        (phy_mdc),
       .phy_mdio       (phy_mdio),

       .serial_tx (serial_tx), .serial_rx (serial_rx),
       .user_led (user_led), .diag_leds0 (diag_leds0), .user_btn (1'b1),
       .ddr3_dq (ddr3_dq), .ddr3_dqs_p (ddr3_dqs_p), .ddr3_dqs_n (ddr3_dqs_n),
       .ddr3_addr (ddr3_addr), .ddr3_ba (ddr3_ba),
       .ddr3_ras_n (ddr3_ras_n), .ddr3_cas_n (ddr3_cas_n), .ddr3_we_n (ddr3_we_n),
       .ddr3_reset_n (ddr3_reset_n),
       .ddr3_ck_p (ddr3_ck_p), .ddr3_ck_n (ddr3_ck_n), .ddr3_cke (ddr3_cke),
       .ddr3_dm (ddr3_dm), .ddr3_odt (ddr3_odt)
   );

   // Micron's DDR3 model, taken from the Vivado install rather than committed
   // here -- it carries Micron's AS-IS licence, not an open one.  See
   // sim/run_xsim_board.sh for where it comes from.
   ddr3_model ddr3 (
       .rst_n   (ddr3_reset_n),
       .ck      (ddr3_ck_p),
       .ck_n    (ddr3_ck_n),
       .cke     (ddr3_cke),
       .cs_n    (1'b0),          // tied low on the board through R35
       .ras_n   (ddr3_ras_n),
       .cas_n   (ddr3_cas_n),
       .we_n    (ddr3_we_n),
       .dm_tdqs (ddr3_dm),
       .ba      (ddr3_ba),
       .addr    (ddr3_addr),
       .dq      (ddr3_dq),
       .dqs     (ddr3_dqs_p),
       .dqs_n   (ddr3_dqs_n),
       .tdqs_n  (),
       .odt     (ddr3_odt)
   );

`endif

   // ------------------------------------------------------------------
   // The PHY
   // ------------------------------------------------------------------
   // An RTL8211EG at the address the board straps.  Without it phy_mdio floats
   // to the pull-up, every management read returns 0xFFFF and the bring-up
   // sequencer correctly concludes there is no PHY -- which is a fine test of
   // the failure path and a useless one of everything else.
   //
   // The model wants to know when the station is driving, so it can catch a
   // station that has not let go of the wire during turnaround.  That is not
   // recoverable from the pad, so take it from inside: this testbench already
   // knows the DUT is a wukong_v1_top.
   wire phy_model_out;

   mdio_phy_model #(.PHY_ADDR(5'd1)) phymodel (
       .mdc     (phy_mdc),
       .mdio_o  (dut.mdio_o),
       .mdio_oe (dut.mdio_oe),
       .mdio_i  (phy_model_out)
   );

   assign phy_mdio = dut.mdio_oe ? 1'bz : phy_model_out;

   // ------------------------------------------------------------------
   // Console
   // ------------------------------------------------------------------
   uart_monitor #(.BAUD(BAUD), .LOGFILE(CONSOLE)) console_mon (.rx(serial_tx));
   uart_console #(.BAUD(BAUD))                   console_in  (.tx(serial_rx));

   // ------------------------------------------------------------------
   // Progress
   // ------------------------------------------------------------------
   always @(diag_leds0)
     $display("[%t] diag_leds = %02x", $realtime, diag_leds0);

   always @(user_led)
     $display("[%t] user_led = %b  (led[0] low = out of reset, led[1] low = DRAM calibrated)",
              $realtime, user_led);

   real heartbeat_ms = 10.0;
   initial begin
      void'($value$plusargs("heartbeat_ms=%f", heartbeat_ms));
      forever begin
         #(heartbeat_ms * 1000000.0);
         $display("[%t] alive: user_led=%b diag=%02x", $realtime, user_led, diag_leds0);
      end
   end

   // ------------------------------------------------------------------
   // Run control
   // ------------------------------------------------------------------
   real timeout_ms = 20.0;

   task automatic wrap_up(input string why);
      $display("");
      $display("=== %s at %t ===", why, $realtime);
      console_mon.report();
`ifdef BOARD_MEM_FAST
      ram.report();
`endif
      $finish;
   endtask

   initial begin
      $timeformat(-9, 0, " ns", 12);
      void'($value$plusargs("timeout_ms=%f", timeout_ms));

      $display("=== Sun-2 on QMTech Wukong V1 ===");
`ifdef BOARD_MEM_FAST
      $display("memory: behavioural Wishbone RAM (BOARD_MEM_FAST)");
`else
      $display("memory: MIG 7 Series + Micron DDR3 model");
`endif
      $display("CPU clock %0d Hz, timeout %0.1f ms", CPU_CLK_HZ, timeout_ms);

      if ($test$plusargs("vcd_full")) begin
         $dumpfile("wukong.vcd");
         $dumpvars(0, tb_wukong);
      end else if ($test$plusargs("vcd")) begin
         $dumpfile("wukong.vcd");
         $dumpvars(0, dut.machine.sun2.tolog);
      end

      // Hold the button down briefly, as a person would.
      #2000 cpu_reset = 1'b1;

      #(timeout_ms * 1000000.0);
      wrap_up("TIMEOUT");
   end

   always @(posedge console_mon.stop_seen) begin
      #1000000;
      wrap_up("STOP STRING SEEN");
   end

   // ------------------------------------------------------------------
   // Asking the machine what the PHY did
   // ------------------------------------------------------------------
   // +phy_probe types at the monitor prompt, the way a person with the board
   // on a bench would.  This is the whole justification for the status
   // register in device page 0xFE7 existing, so it is worth proving that a
   // stock boot PROM can actually be made to read it.
   //
   // Run it with the stop string turned off, or the run ends at the first
   // prompt before anything is typed:
   //
   //   make -C sim board MACHINE=vme STOP_ON= XSIMARGS="-testplusarg phy_probe"
   //
   // The PROM leaves 0xEE0800 -- ROP_BASE, the RasterOp processor a VME machine
   // does not have -- mapped valid, permissions none, main memory page 0.  Its
   // segment is therefore already in a real pmeg and repointing the one page
   // disturbs nothing: sunmon.c's VME table puts it there precisely because
   // nothing uses it.  The page map entry wanted is
   //
   //   valid 1 | permissions 0x3F | type 1 (VPM_IO) | page 0xFE7  =  FE400FE7
   //
   // and then two reads: the identifier the sequencer got back over MDIO, and
   // the status word.  Against tb/mdio_phy_model those are 001C and F000
   // (configured, identifier matched, link up, full duplex, 10 Mb/s, carrier
   // sense never stuck).
   //
`ifdef SUN2_VME
   initial begin
      bit ok;
      if ($test$plusargs("phy_probe")) begin
         console_mon.wait_for(">", 6000_000_000.0, ok);
         if (!ok) begin
            $display("phy_probe: never reached the monitor prompt");
            wrap_up("PHY PROBE FAILED");
         end

         // Let the prompt settle -- the PROM is still echoing.
         #2_000_000;
         $display("\n[%t] phy_probe: mapping device page 0xFE7 at 0xEE0800",
                  $realtime);
         console_in.send_line("pee0800 fe400fe7");
         console_mon.wait_for(">", 200_000_000.0, ok);
         if (!ok) wrap_up("PHY PROBE FAILED: page map command hung");

         #2_000_000;
         console_in.send_line("eee0800");
         console_mon.wait_for("? ", 200_000_000.0, ok);   // +0, the identifier
         if (!ok) wrap_up("PHY PROBE FAILED: no answer from 0xEE0800");

         console_in.send_line("");                        // CR steps to +2
         console_mon.wait_for("? ", 200_000_000.0, ok);   // +2, the status word
         if (!ok) wrap_up("PHY PROBE FAILED: no answer from 0xEE0802");

         console_in.send_line("q");                       // non-hex ends the command
         console_mon.wait_for(">", 200_000_000.0, ok);

         #2_000_000;
         wrap_up("PHY PROBE COMPLETE");
      end
   end
`endif

endmodule
