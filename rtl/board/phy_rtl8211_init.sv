`timescale 1ns / 1ps

//
// Bring the RTL8211EG down to something a Sun-2 recognises, and then watch it.
//
// A real Sun-2 has no PHY: the 82586 drives an 8502 Manchester encoder straight
// onto an AUI cable at 10 Mb/s, and nothing in the machine knows what a
// management interface is.  All of this is an artifact of putting a modern
// gigabit part where that transceiver was, so it belongs in the board layer and
// not in the machine.
//
// Three things have to happen before the Ethernet can work at all:
//
//   * The link must come up at 10 Mb/s.  The board straps AN[1:0] = 11, so out
//     of reset the part advertises everything and will settle on 1000BASE-T --
//     at which point it presents 8-bit GMII with 125 MHz clocks to a MAC built
//     for 4-bit MII, which looks exactly like a MAC that is not working.
//     Advertising only 10BASE-T fixes that.  Advertising rather than forcing:
//     a forced link sends no advertisement, so the partner parallel-detects and
//     falls back to half duplex, giving a duplex mismatch that also looks like
//     a MAC fault.
//
//   * PHYCR bit 11, "Assert CRS on Transmit", comes up SET in GMII mode
//     (datasheet Table 38).  The PHY would then raise carrier sense whenever
//     *we* transmit, full duplex included, and a MAC that defers on carrier
//     defers on its own frame.  Every transmit would fail.
//
//   * Nothing may touch the management interface until the part is ready:
//     PHYRSTB low for at least 10 ms and then at least 30 ms of settling
//     (datasheet section 7.16).  That timing lives in wukong_v1_top, which owns
//     the reset pin; `enable` here is its statement that the wait is over.
//
// Ordering is not free choice.  Writes to registers 0, 4 and 9 take effect only
// on a reset or an autonegotiation restart, and a reset returns them to values
// derived from the straps -- so the restart has to come last, and there is no
// software reset here at all.  The board has already done a hardware one, which
// is stronger.
//
module phy_rtl8211_init #(
    parameter logic [4:0]  PHY_ADDR = 5'd1,   // strapped 001 on this board
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
    output logic [15:0] phy_id,        // PHYID1, 0x001C on a Realtek part
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
   localparam logic [4:0] R_BMCR  = 5'd0;
   localparam logic [4:0] R_PHYID1 = 5'd2;
   localparam logic [4:0] R_ANAR  = 5'd4;
   localparam logic [4:0] R_GBCR  = 5'd9;
   localparam logic [4:0] R_PHYCR = 5'd16;
   localparam logic [4:0] R_PHYSR = 5'd17;

   localparam logic [15:0] PHYCR_ASSERT_CRS_ON_TX = 16'h0800;   // bit 11
   localparam logic [15:0] BMCR_AN_RESTART        = 16'h1200;   // enable + restart
   localparam logic [15:0] REALTEK_OUI_MSB        = 16'h001C;

   // The sequence.  Each step is one MDIO transaction; the value written at
   // step 4 depends on what step 3 read, which is why this is a case and not a
   // table of constants.
   localparam int S_ID     = 0;   // read  PHYID1 -- also the smoke test
   localparam int S_GBCR   = 1;   // write GBCR  = 0, withdrawing 1000BASE-T
   localparam int S_ANAR   = 2;   // write ANAR  = 10BASE-T only
   localparam int S_RD_PHYCR = 3; // read  PHYCR
   localparam int S_WR_PHYCR = 4; // write PHYCR with CRS-on-transmit cleared
   localparam int S_BMCR   = 5;   // write BMCR  = restart, latching the above
   localparam int S_POLL   = 6;   // read  PHYSR, for ever

   logic [2:0]  step;
   logic [15:0] phycr;

   wire         is_read  = (step == S_ID) || (step == S_RD_PHYCR) || (step == S_POLL);
   logic [4:0]  reg_addr;
   logic [15:0] wr_data;

   always_comb begin
      case (step)
        S_ID:        begin reg_addr = R_PHYID1; wr_data = 16'h0000; end
        S_GBCR:      begin reg_addr = R_GBCR;   wr_data = 16'h0000; end
        S_ANAR:      begin reg_addr = R_ANAR;   wr_data = ANAR_VALUE; end
        S_RD_PHYCR:  begin reg_addr = R_PHYCR;  wr_data = 16'h0000; end
        S_WR_PHYCR:  begin reg_addr = R_PHYCR;  wr_data = phycr & ~PHYCR_ASSERT_CRS_ON_TX; end
        S_BMCR:      begin reg_addr = R_BMCR;   wr_data = BMCR_AN_RESTART; end
        default:     begin reg_addr = R_PHYSR;  wr_data = 16'h0000; end
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
         phycr       <= 16'h0;
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
                     phy_present <= (wbm_dat_i[15:0] == REALTEK_OUI_MSB);
                  end
                  S_RD_PHYCR: phycr <= wbm_dat_i[15:0];
                  default: begin
                     // PHYSR: 17.15:14 speed, 17.13 duplex, 17.10 link
                     speed       <= wbm_dat_i[15:14];
                     full_duplex <= wbm_dat_i[13];
                     link        <= wbm_dat_i[10];
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
