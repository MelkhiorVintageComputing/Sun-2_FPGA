//
// phy_dp83620_init + wb_mdio against a clause-22 PHY model.
//
// The DECA twin of tb_phy_init.sv, and it checks a different set of things
// because the DP83620 is a different part.  What is under test is a handful of
// values transcribed from Inputs/doc/dp83620.pdf (SNLS339C), each of which is
// wrong in a way that is quiet rather than loud:
//
//   * PHYIDR1 is 0x2000, not the Realtek 0x001C.  Get it wrong and phy_present
//     reads false for ever on a perfectly good board, and the machine's PHY
//     status register in device page 0xFE7 says "no PHY".
//
//   * RBR bit 5 RMII_MODE comes from a **strap**, so the board decides it and
//     the datasheet cannot.  If the DECA straps RMII, the MAC's four-bit MII
//     sees nothing at all -- which looks exactly like a dead MAC.  The
//     sequencer clears it regardless, and this checks that it does.
//
//   * PHYSTS bit 1 is named "Speed10" and is set for **10** Mb/s, the opposite
//     way round from instinct.  Reported backwards, a healthy 10 Mb/s Sun-2
//     claims to be running at 100 and nothing else complains.
//
// The last of those is why the speed check below drives the model both ways.
//
`timescale 1ns / 1ps

module tb_phy_dp83620;

   localparam logic [15:0] DP_PHYIDR1 = 16'h2000;
   localparam logic [15:0] DP_PHYIDR2 = 16'h5CE1;   // OUI 080017h, model 14, rev 1

   reg clk = 1'b0;   always #40 clk = ~clk;          // 12.5 MHz
   reg rst = 1'b1;
   reg enable = 1'b0;

   int pass = 0, fail = 0;
   task want(input logic cond, input string what);
      if (cond) begin pass++; $display("  ok:   %s", what); end
      else      begin fail++; $display("  FAIL: %s", what); end
   endtask

   // ---------------------------------------------------------- the plumbing
   wire        cyc, stb, we, ack;
   wire [3:0]  sel;
   wire [5:0]  adr;
   wire [31:0] dat_w, dat_r;
   wire        mdc, mdio_o, mdio_oe;
   wire        mdio_line;

   wire [15:0] phy_id;
   wire        phy_present, cfg_done, link, full_duplex;
   wire [1:0]  speed;

   wb_mdio #(.DIV_RESET(3)) station (      // fast, so the test is not slow
       .clk (clk), .rst (rst),
       .wbs_cyc_i (cyc), .wbs_stb_i (stb), .wbs_we_i (we), .wbs_sel_i (sel),
       .wbs_adr_i (adr), .wbs_dat_i (dat_w), .wbs_dat_o (dat_r),
       .wbs_ack_o (ack), .wbs_err_o (),
       .mdc (mdc), .mdio_o (mdio_o), .mdio_oe (mdio_oe), .mdio_i (mdio_line)
   );

   phy_dp83620_init #(.PHY_ADDR(5'd1), .POLL_GAP(200)) dut (
       .clk (clk), .rst (rst), .enable (enable),
       .wbm_cyc_o (cyc), .wbm_stb_o (stb), .wbm_we_o (we), .wbm_sel_o (sel),
       .wbm_adr_o (adr), .wbm_dat_o (dat_w), .wbm_dat_i (dat_r), .wbm_ack_i (ack),
       .phy_id (phy_id), .phy_present (phy_present), .cfg_done (cfg_done),
       .link (link), .speed (speed), .full_duplex (full_duplex)
   );

   // The model's port names are from the *station's* point of view: mdio_o is
   // what the station drives (an input here) and mdio_i is what the PHY drives
   // back (an output here).  Wiring them the other way round leaves the line
   // floating and every register reads 0xzzzz, which is what the first version
   // of this file did.  tb_phy_init.sv does the same muxing for the same reason.
   wire phy_drive;

   mdio_phy_model #(.PHY_ADDR(5'd1),
                    .PHYID1(DP_PHYIDR1),
                    .PHYID2(DP_PHYIDR2)) phy (
       .mdc (mdc), .mdio_o (mdio_o), .mdio_oe (mdio_oe), .mdio_i (phy_drive)
   );

   assign mdio_line = mdio_oe ? mdio_o : phy_drive;

   initial begin
      $display("=== phy_dp83620: bring-up against a clause-22 model ===");

      // The strap left RMII mode ON, which is the case that must not be
      // assumed away: if the sequencer does not clear it the MAC is deaf.
      phy.regs[5'h17] = 16'h0020;     // RBR, RMII_MODE set
      phy.regs[5'h10] = 16'h0000;     // PHYSTS: no link yet

      repeat (20) @(posedge clk);
      rst = 1'b0;
      repeat (20) @(posedge clk);
      enable = 1'b1;

      wait (cfg_done);
      repeat (200) @(posedge clk);

      want(phy_id == DP_PHYIDR1,
           $sformatf("PHYIDR1 read back as 0x%04x", phy_id));
      want(phy_present,
           "phy_present set -- the identifier matched, not merely a reply");
      want((phy.regs[5'h17] & 16'h0020) == 16'h0000,
           $sformatf("RBR is 0x%04x -- RMII_MODE cleared, so the MII is live",
                     phy.regs[5'h17]));
      want(phy.regs[5'd4] == 16'h0061,
           $sformatf("ANAR is 0x%04x -- 10BASE-T full and half only",
                     phy.regs[5'd4]));
      want(phy.regs[5'd0] == 16'h1200,
           $sformatf("BMCR is 0x%04x -- autonegotiation enabled and restarted",
                     phy.regs[5'd0]));

      // ---- the speed inversion, both ways round -------------------------
      // PHYSTS bit 1 SET means 10 Mb/s.  The machine's encoding is
      // 00 = 10, 01 = 100.
      phy.regs[5'h10] = 16'h0007;     // link + speed10 + full duplex
      repeat (4000) @(posedge clk);
      want(link,               "link follows PHYSTS bit 0");
      want(speed == 2'b00,     $sformatf("speed reads %02b for Speed10 set = 10 Mb/s", speed));
      want(full_duplex,        "full duplex follows PHYSTS bit 2");

      phy.regs[5'h10] = 16'h0001;     // link, speed10 clear = 100 Mb/s, half
      repeat (4000) @(posedge clk);
      want(speed == 2'b01,     $sformatf("speed reads %02b for Speed10 clear = 100 Mb/s", speed));
      want(!full_duplex,       "half duplex follows PHYSTS bit 2 clear");

      phy.regs[5'h10] = 16'h0000;     // link down
      repeat (4000) @(posedge clk);
      want(!link,              "link drops when PHYSTS bit 0 clears");

      $display("=== phy_dp83620: %0d checks, %0d passed, %0d failed ===",
               pass + fail, pass, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      #50_000_000;
      $display("FAIL: timeout -- the sequence never reached cfg_done");
      $finish;
   end

endmodule
