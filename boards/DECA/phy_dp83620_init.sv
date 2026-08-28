`timescale 1ns / 1ps

//
// Bring the TI DP83620 down to something a Sun-2 recognises, and then watch it.
//
// A real Sun-2 has no PHY: the 82586 drives an 8502 Manchester encoder straight
// onto an AUI cable at 10 Mb/s, and nothing in the machine knows what a
// management interface is.  All of this is an artifact of putting a modern part
// where that transceiver was, so it belongs in the board layer and not in the
// machine.
//
// The DECA twin of boards/Wukong/phy_rtl8211_init.sv, and a good deal simpler,
// because a 10/100 part cannot do the thing that made the RTL8211 hard.  Every
// register value below is from the DP83620 datasheet (SNLS339C), not carried
// over: the two parts agree on the clause-22 registers and on nothing else.
//
// What has to happen:
//
//   * The link must come up at 10 Mb/s.  Advertising only 10BASE-T does it.
//     Advertising rather than forcing, for the reason the Wukong file gives: a
//     forced link sends no advertisement, the partner parallel-detects and
//     falls back to half duplex, and the resulting duplex mismatch looks
//     exactly like a broken MAC.
//
//   * The part must be in MII mode, not RMII.  RBR bit 5 RMII_MODE defaults
//     from a **strap**, so what this board does is a board fact and not a
//     datasheet one.  The DECA routes TXD[3:0], RXD[3:0], TX_CLK and RX_CLK,
//     which only MII uses, so it is almost certainly strapped for MII -- and
//     "almost certainly" is not a basis for a subsystem that fails silently, so
//     this reads RBR, reports what it found, and clears the bit regardless.
//
//   * There is no gigabit register to withdraw and no "assert CRS on transmit"
//     to clear.  Both of those were GMII-specific problems on the Realtek part.
//     Nothing here stands in for them, and adding a speculative write would be
//     worse than nothing.
//
// Ordering still matters: ANAR takes effect on an autonegotiation restart, so
// BMCR comes last.  There is no software reset -- the board has done a hardware
// one, which is stronger, and a reset would return the straps.
//
module phy_dp83620_init #(
    parameter logic [4:0]  PHY_ADDR = 5'd1,   // check the board straps
    // 10BASE-T, full and half duplex, with the IEEE 802.3 selector field.
    // Offering both lets a half-duplex-only partner link rather than fail --
    // and half duplex is what a Sun-2 expects anyway.
    parameter logic [15:0] ANAR_VALUE = 16'h0061,
    parameter int          POLL_GAP   = 50_000   // clocks between status polls
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,        // the PHY has finished its reset

    // Wishbone B4 classic master, onto wb_mdio's slave port
    output logic        wbm_cyc_o,
    output logic        wbm_stb_o,
    output logic        wbm_we_o,
    output logic [3:0]  wbm_sel_o,
    output logic [5:0]  wbm_adr_o,
    output logic [31:0] wbm_dat_o,
    input  wire  [31:0] wbm_dat_i,
    input  wire         wbm_ack_i,

    // What the machine gets to see
    output logic [15:0] phy_id,        // PHYIDR1, 0x2000 on this part
    output logic        phy_present,   // ... and it matched
    output logic        cfg_done,      // the bring-up sequence finished
    output logic        link,
    output logic [1:0]  speed,         // 00 = 10, 01 = 100, 10 = 1000 Mb/s
    output logic        full_duplex
);

   // wb_mdio's register file, word-addressed.
   localparam logic [5:0] M_CTRL   = 6'd0;
   localparam logic [5:0] M_WDATA  = 6'd1;
   localparam logic [5:0] M_RDATA  = 6'd2;
   localparam logic [5:0] M_STATUS = 6'd3;

   // Clause 22 register numbers.
   localparam logic [4:0] R_BMCR   = 5'd0;
   localparam logic [4:0] R_PHYIDR1 = 5'd2;
   localparam logic [4:0] R_ANAR   = 5'd4;
   localparam logic [4:0] R_PHYSTS = 5'h10;   // 0x10, vendor status
   localparam logic [4:0] R_RBR    = 5'h17;   // 0x17, RMII and Bypass

   localparam logic [15:0] RBR_RMII_MODE = 16'h0020;   // bit 5, strap default
   localparam logic [15:0] BMCR_AN_RESTART = 16'h1200; // enable + restart
   // PHYIDR1 holds bits 3..18 of the OUI 080017h: 0x2000.  Checked rather than
   // merely "something answered", because PHY address 0 is a broadcast and a
   // wrong address decode still replies.
   localparam logic [15:0] DP83620_PHYIDR1 = 16'h2000;

   // The sequence.  Each step is one MDIO transaction; the value written at
   // step 4 depends on what step 3 read, which is why this is a case and not a
   // table of constants.
   localparam int S_ID     = 0;   // read  PHYIDR1 -- also the smoke test
   localparam int S_RD_RBR = 1;   // read  RBR, to find out what the strap did
   localparam int S_WR_RBR = 2;   // write RBR with RMII_MODE cleared
   localparam int S_ANAR   = 3;   // write ANAR = 10BASE-T only
   localparam int S_BMCR   = 4;   // write BMCR = restart, latching ANAR
   localparam int S_POLL   = 5;   // read  PHYSTS, for ever

   logic [2:0]  step;
   logic [15:0] rbr;

   wire         is_read  = (step == S_ID) || (step == S_RD_RBR) || (step == S_POLL);
   logic [4:0]  reg_addr;
   logic [15:0] wr_data;

   always_comb begin
      case (step)
        S_ID:      begin reg_addr = R_PHYIDR1; wr_data = 16'h0000; end
        S_RD_RBR:  begin reg_addr = R_RBR;     wr_data = 16'h0000; end
        S_WR_RBR:  begin reg_addr = R_RBR;     wr_data = rbr & ~RBR_RMII_MODE; end
        S_ANAR:    begin reg_addr = R_ANAR;    wr_data = ANAR_VALUE; end
        S_BMCR:    begin reg_addr = R_BMCR;    wr_data = BMCR_AN_RESTART; end
        default:   begin reg_addr = R_PHYSTS;  wr_data = 16'h0000; end
      endcase
   end

   typedef enum logic [2:0] {
      P_IDLE,       // waiting for the PHY to be ready
      P_WR_DATA,    // load WDATA (writes only)
      P_WR_CTRL,    // start the transaction
      P_POLL_BUSY,  // wait for it to finish
      P_RD_DATA,    // collect RDATA (reads only)
      P_NEXT,       // advance, or pause before polling again
      P_GAP
   } pstate_t;

   pstate_t     pstate;
   logic [31:0] gap_ctr;

   task automatic wb_put(input logic [5:0] a, input logic [31:0] d);
      begin
         wbm_adr_o <= a;
         wbm_dat_o <= d;
         wbm_we_o  <= 1'b1;
         wbm_cyc_o <= 1'b1;
         wbm_stb_o <= 1'b1;
      end
   endtask

   task automatic wb_get(input logic [5:0] a);
      begin
         wbm_adr_o <= a;
         wbm_we_o  <= 1'b0;
         wbm_cyc_o <= 1'b1;
         wbm_stb_o <= 1'b1;
      end
   endtask

   always_ff @(posedge clk) begin
      if (rst) begin
         pstate      <= P_IDLE;
         step        <= S_ID[2:0];
         wbm_cyc_o   <= 1'b0;
         wbm_stb_o   <= 1'b0;
         wbm_we_o    <= 1'b0;
         wbm_sel_o   <= 4'hF;
         wbm_adr_o   <= 6'h0;
         wbm_dat_o   <= 32'h0;
         phy_id      <= 16'h0;
         phy_present <= 1'b0;
         cfg_done    <= 1'b0;
         link        <= 1'b0;
         speed       <= 2'b00;
         full_duplex <= 1'b0;
         rbr         <= 16'h0;
         gap_ctr     <= 32'h0;
      end else begin
         case (pstate)
           P_IDLE:
             if (enable) begin
                if (is_read) begin
                   wb_put(M_CTRL, {7'h0, 1'b1, 7'h0, 1'b1, 3'h0, PHY_ADDR, 3'h0, reg_addr});
                   pstate <= P_WR_CTRL;
                end else begin
                   wb_put(M_WDATA, {16'h0, wr_data});
                   pstate <= P_WR_DATA;
                end
             end

           // WDATA loaded; now start the write.
           P_WR_DATA:
             if (wbm_ack_i) begin
                wb_put(M_CTRL, {7'h0, 1'b1, 7'h0, 1'b0, 3'h0, PHY_ADDR, 3'h0, reg_addr});
                pstate <= P_WR_CTRL;
             end

           P_WR_CTRL:
             if (wbm_ack_i) begin
                wb_get(M_STATUS);
                pstate <= P_POLL_BUSY;
             end

           P_POLL_BUSY:
             if (wbm_ack_i) begin
                if (wbm_dat_i[0]) begin
                   // still busy -- ask again
                   wb_get(M_STATUS);
                end else if (is_read) begin
                   wb_get(M_RDATA);
                   pstate <= P_RD_DATA;
                end else begin
                   wbm_cyc_o <= 1'b0;
                   wbm_stb_o <= 1'b0;
                   pstate    <= P_NEXT;
                end
             end

           P_RD_DATA:
             if (wbm_ack_i) begin
                wbm_cyc_o <= 1'b0;
                wbm_stb_o <= 1'b0;
                case (step)
                  S_ID: begin
                     phy_id      <= wbm_dat_i[15:0];
                     // A wrong address decode still answers, because PHY
                     // address 0 is a broadcast -- so check the identifier
                     // rather than merely that something replied.
                     phy_present <= (wbm_dat_i[15:0] == DP83620_PHYIDR1);
                  end
                  S_RD_RBR: rbr <= wbm_dat_i[15:0];
                  default: begin
                     // PHYSTS (0x10): bit 2 duplex, bit 1 speed, bit 0 link.
                     //
                     // **Bit 1 set means 10 Mb/s, not 100.**  The datasheet
                     // names it "Speed10" and it reads the opposite way round
                     // from every instinct; getting it backwards would report a
                     // healthy 10 Mb/s Sun-2 as running at 100.  The machine's
                     // encoding is 00 = 10, 01 = 100, 10 = 1000.
                     //
                     // Bit 0 is used rather than BMSR's link bit because this
                     // one does not clear on read, so polling cannot itself
                     // destroy the answer.
                     speed       <= wbm_dat_i[1] ? 2'b00 : 2'b01;
                     full_duplex <= wbm_dat_i[2];
                     link        <= wbm_dat_i[0];
                  end
                endcase
                pstate <= P_NEXT;
             end

           P_NEXT:
             if (step == S_POLL[2:0]) begin
                gap_ctr <= 32'h0;
                pstate  <= P_GAP;
             end else begin
                step <= step + 3'd1;
                if (step == S_BMCR[2:0]) cfg_done <= 1'b1;
                pstate <= P_IDLE;
             end

           // Status is worth having continuously, but not urgently.
           P_GAP:
             if (gap_ctr == POLL_GAP[31:0]) pstate <= P_IDLE;
             else                           gap_ctr <= gap_ctr + 32'd1;

           default: pstate <= P_IDLE;
         endcase
      end
   end

endmodule
