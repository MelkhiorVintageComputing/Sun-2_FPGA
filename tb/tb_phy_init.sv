`timescale 1ns / 1ps

//
// phy_rtl8211_init driving wb_mdio into an independent clause-22 PHY model.
//
// What this has to prove, in order of how badly it fails on hardware if wrong:
//
//   1. The link ends up at 10 Mb/s.  Left alone the part advertises everything
//      and settles on 1000BASE-T, presenting 8-bit GMII at 125 MHz to a 4-bit
//      MII MAC -- indistinguishable, from the console, from a dead controller.
//   2. PHYCR bit 11 is cleared.  Otherwise the PHY raises carrier sense on our
//      own transmissions and every frame fails.
//   3. The identifier is read and checked, because that is the first thing that
//      will run on real hardware and the only check that proves the wiring, the
//      PHY address, the reset timing and MDIO itself in one go.
//   4. The station never drives the wire during turnaround -- the model counts
//      contention and this asserts it stayed at zero.
//
module tb_phy_init;

   localparam int CLK_HALF = 40;   // 12.5 MHz, the board's CPU clock

   logic clk = 1'b0, rst = 1'b1, enable = 1'b0;
   always #(CLK_HALF) clk = ~clk;

   logic        cyc, stb, we, ack;
   logic [3:0]  sel;
   logic [5:0]  adr;
   logic [31:0] dat_w, dat_r;

   logic [15:0] phy_id;
   logic        phy_present, cfg_done, link, full_duplex;
   logic [1:0]  speed;

   // Poll gap kept short so the test does not spend its life waiting.
   phy_rtl8211_init #(.PHY_ADDR(5'd1), .POLL_GAP(64)) dut (
       .clk(clk), .rst(rst), .enable(enable),
       .wbm_cyc_o(cyc), .wbm_stb_o(stb), .wbm_we_o(we), .wbm_sel_o(sel),
       .wbm_adr_o(adr), .wbm_dat_o(dat_w), .wbm_dat_i(dat_r), .wbm_ack_i(ack),
       .phy_id(phy_id), .phy_present(phy_present), .cfg_done(cfg_done),
       .link(link), .speed(speed), .full_duplex(full_duplex)
   );

   logic mdc, mdio_o, mdio_oe, mdio_i;

   // DIV small, so a frame is 64 MDC periods of a few clocks rather than of
   // thousands.  The real board runs it far slower.
   wb_mdio #(.DIV_RESET(1)) station (
       .clk(clk), .rst(rst),
       .wbs_cyc_i(cyc), .wbs_stb_i(stb), .wbs_we_i(we), .wbs_sel_i(sel),
       .wbs_adr_i(adr), .wbs_dat_i(dat_w), .wbs_dat_o(dat_r),
       .wbs_ack_o(ack), .wbs_err_o(),
       .mdc(mdc), .mdio_o(mdio_o), .mdio_oe(mdio_oe), .mdio_i(mdio_i)
   );

   // The board has a 1.5k pull-up on MDIO, so when neither end drives, the wire
   // reads high -- which the model produces by releasing to 1.
   wire phy_drive;

   mdio_phy_model #(.PHY_ADDR(5'd1)) phy (
       .mdc(mdc), .mdio_o(mdio_o), .mdio_oe(mdio_oe), .mdio_i(phy_drive)
   );

   assign mdio_i = mdio_oe ? mdio_o : phy_drive;

   int fail = 0, checks = 0;

   task automatic want(input bit cond, input string what);
      checks++;
      if (!cond) begin
         $display("FAIL: %s", what);
         fail++;
      end
   endtask

   initial begin
      int guard;
      $timeformat(-9, 0, " ns", 12);
      $display("=== phy_rtl8211_init against an independent PHY model ===");

      repeat (10) @(posedge clk);
      rst = 1'b0;
      repeat (10) @(posedge clk);

      // Nothing may touch MDIO before the PHY says it is ready.
      repeat (200) @(posedge clk);
      want(phy.n_reads == 0 && phy.n_writes == 0,
             "the sequencer talked to the PHY before it was enabled");

      enable = 1'b1;

      guard = 0;
      while (!cfg_done && guard < 2_000_000) begin
         @(posedge clk);
         guard++;
      end
      want(cfg_done, "the bring-up sequence never finished");

      $display("PHY id 0x%04x, present %0d", phy_id, phy_present);
      want(phy_id == 16'h001C, "PHYID1 did not read back as the Realtek OUI");
      want(phy_present, "the identifier check did not pass");

      // The whole point: gigabit withdrawn, 10BASE-T advertised, CRS-on-transmit
      // cleared, and the restart that latches the first two.
      want(phy.regs[9] == 16'h0000,
             $sformatf("GBCR is 0x%04x, expected 0 -- gigabit still advertised", phy.regs[9]));
      want(phy.regs[4] == 16'h0061,
             $sformatf("ANAR is 0x%04x, expected 0x0061", phy.regs[4]));
      want((phy.regs[16] & 16'h0800) == 16'h0000,
             $sformatf("PHYCR is 0x%04x -- assert-CRS-on-transmit still set", phy.regs[16]));

      // And the result of all that.
      guard = 0;
      while (!link && guard < 2_000_000) begin
         @(posedge clk);
         guard++;
      end
      want(link, "the link never came up");
      want(speed == 2'b00,
             $sformatf("negotiated speed code %0d, expected 0 (10 Mb/s)", speed));
      $display("link %0d, speed %0d, full duplex %0d", link, speed, full_duplex);

      want(phy.contention == 0,
             $sformatf("%0d turnaround contentions", phy.contention));
      want(phy.n_bad_addr == 0,
             $sformatf("%0d frames sent to the wrong PHY address", phy.n_bad_addr));

      $display("%0d checks, %0d PHY reads, %0d PHY writes",
               checks, phy.n_reads, phy.n_writes);
      if (fail == 0) $display("PASS: phy_rtl8211_init");
      else           $display("FAIL: %0d problems", fail);
      $finish;
   end

   initial begin
      #500_000_000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
