`timescale 1ns / 1ps

//
// A clause-22 MDIO slave, behaving as an RTL8211EG at the address it is given.
//
// Written to the standard and to the datasheet rather than to wb_mdio, because
// a model written alongside the thing it checks shares its assumptions.  That
// is not a hypothetical worry here: the MAC's own MDIO model held the
// turnaround bit a bit time too long while its station sampled a bit time late,
// the two errors cancelled, and reading a register back returned the right
// answer while both disagreed with clause 22.  It took an outside
// implementation to break the symmetry.
//
// So the bit accounting below is stated the way the standard states it, and the
// timings are the ones the RTL8211EG datasheet gives:
//
//   * A frame is 64 bit times.  Bit time N ends at MDC rising edge N:
//     preamble 1-32, start 33-34, opcode 35-36, PHY address 37-41, register
//     address 42-46, turnaround 47-48, data 49-64.
//   * The station drives through bit time 46 of a read and must be off the wire
//     for both turnaround bits.
//   * The PHY drives from bit time 48 -- the turnaround zero -- through 64.
//   * A PHY presents bit time N in the interval after edge N-1, taking up to
//     TURNAROUND_NS to do it (Table 62 t6 max, 300 ns) and holding it until the
//     next edge.  Driving late is what catches a station that samples early.
//   * Preamble suppression is the RTL8211EG's default, so a frame may begin
//     without 32 ones; this model accepts either.
//
module mdio_phy_model #(
    parameter logic [4:0]  PHY_ADDR      = 5'd1,
    parameter logic [15:0] PHYID1        = 16'h001C,  // Realtek OUI
    parameter logic [15:0] PHYID2        = 16'hC915,  // RTL8211EG-VB
    parameter int          TURNAROUND_NS = 250        // how late the PHY drives
) (
    input  wire  mdc,
    input  wire  mdio_o,     // from the station
    input  wire  mdio_oe,    // station is driving
    output logic mdio_i      // to the station
);

   // The register file.  Only what a bring-up touches is modelled; everything
   // else reads back what was written, so a mistaken address is visible as a
   // value nobody set rather than as a plausible zero.
   logic [15:0] regs [0:31];

   // Autonegotiation result, recomputed whenever the advertisement is restarted.
   logic [15:0] physr;

   int    n_reads = 0, n_writes = 0, n_bad_addr = 0;
   int    contention = 0;

   localparam logic [15:0] BMCR_DEFAULT  = 16'h1140;  // AN enable, 1000, full
   localparam logic [15:0] BMSR_DEFAULT  = 16'h7949;
   localparam logic [15:0] ANAR_DEFAULT  = 16'h05E1;
   localparam logic [15:0] GBCR_DEFAULT  = 16'h0200;  // advertises 1000 full
   // PHYCR bit 11 "Assert CRS on Transmit" comes up SET in GMII mode, which is
   // the whole reason a bring-up has to touch this register.
   localparam logic [15:0] PHYCR_DEFAULT = 16'h0800;

   task automatic hard_reset();
      for (int i = 0; i < 32; i++) regs[i] = 16'h0000;
      regs[0]  = BMCR_DEFAULT;
      regs[1]  = BMSR_DEFAULT;
      regs[2]  = PHYID1;
      regs[3]  = PHYID2;
      regs[4]  = ANAR_DEFAULT;
      regs[9]  = GBCR_DEFAULT;
      regs[16] = PHYCR_DEFAULT;
      physr    = 16'h0000;          // nothing resolved yet
      regs[17] = physr;
   endtask

   initial begin
      hard_reset();
      mdio_i = 1'b1;
   end

   // Autonegotiation, reduced to what matters: the fastest ability advertised
   // in registers 4 and 9 wins, and the result appears in PHYSR (0x11).
   task automatic negotiate();
      logic [1:0] speed;
      logic       fd;
      if (regs[9][9] || regs[9][8]) begin
         speed = 2'b10; fd = regs[9][9];               // 1000
      end else if (regs[4][8] || regs[4][7]) begin
         speed = 2'b01; fd = regs[4][8];               // 100
      end else if (regs[4][6] || regs[4][5]) begin
         speed = 2'b00; fd = regs[4][6];               // 10
      end else begin
         speed = 2'b00; fd = 1'b0;
      end
      // 17.15:14 speed, 17.13 duplex, 17.11 resolved, 17.10 link
      physr    = {speed, fd, 1'b0, 1'b1, 1'b1, 10'h0};
      regs[17] = physr;
      regs[1]  = BMSR_DEFAULT | 16'h0024;              // link up, AN complete
   endtask

   // ------------------------------------------------------------------
   // The frame
   // ------------------------------------------------------------------
   // One convention throughout, because getting it slightly wrong is the whole
   // hazard here: `cur' is the bit time whose value is on the wire at this
   // rising edge, and edge N ends bit time N.  So the station drives bit time
   // cur, and a field that ends at bit time N is complete when cur == N.
   //
   //   35-36 opcode   37-41 PHY address   42-46 register
   //   47-48 turnaround           49-64 data
   //
   logic        in_frame = 1'b0;
   logic [1:0]  sof = 2'b11;
   int          edge_n = 0;
   logic [15:0] shifter = 16'h0;
   logic        f_read;
   logic [4:0]  f_phy, f_reg;
   logic        addressed = 1'b0;
   logic [15:0] rd_shift;

   always @(posedge mdc) begin
      automatic logic b   = mdio_oe ? mdio_o : 1'b1;
      automatic int   cur = edge_n + 1;

      if (!in_frame) begin
         // Preamble suppression is this part's default, so hunt for the 01
         // start rather than counting 32 ones.  Its second bit is bit time 34.
         sof <= {sof[0], b};
         if ({sof[0], b} == 2'b01) begin
            in_frame  <= 1'b1;
            edge_n    <= 34;
            addressed <= 1'b0;
         end
      end else begin
         edge_n  <= cur;
         shifter <= {shifter[14:0], b};

         if (cur == 36) f_read <= shifter[0];              // 10 = read, 01 = write
         if (cur == 41) f_phy  <= {shifter[3:0], b};
         if (cur == 46) begin
            f_reg     <= {shifter[3:0], b};
            addressed <= (f_phy == PHY_ADDR);
            if (f_phy != PHY_ADDR) begin
               n_bad_addr++;
               $display("[%t] mdio_phy_model: frame for PHY %0d, not me (%0d)",
                        $realtime, f_phy, PHY_ADDR);
            end
         end

         // The station must be off the wire for both turnaround bit times.
         if (f_read && addressed && (cur == 47 || cur == 48) && mdio_oe) begin
            contention++;
            $display("[%t] mdio_phy_model: CONTENTION -- station driving in turnaround",
                     $realtime);
         end

         if (cur == 64) begin
            if (addressed && !f_read) begin
               automatic logic [15:0] d = {shifter[14:0], b};
               n_writes++;
               if (f_reg == 5'd0) begin
                  regs[0] <= d & ~16'h8000;                // reset bit self-clears
                  // Writes to 0, 4 and 9 latch on a reset or an AN restart.
                  if (d[15] || d[9]) negotiate();
               end else begin
                  regs[f_reg] <= d;
               end
            end
            in_frame <= 1'b0;
            edge_n   <= 0;
            sof      <= 2'b11;
         end
      end
   end

   // ------------------------------------------------------------------
   // Driving the answer
   // ------------------------------------------------------------------
   // A PHY presents bit time N in the interval after edge N-1, taking up to
   // TURNAROUND_NS and holding it until the next edge.  So the turnaround zero
   // (bit time 48) goes out after edge 47 and the first data bit after edge 48.
   // Driving deliberately late is what catches a station that samples early.
   always @(posedge mdc) begin
      automatic int cur = edge_n + 1;
      if (in_frame && f_read && addressed) begin
         if (cur == 47) begin
            rd_shift <= regs[f_reg];
            n_reads++;
            #(TURNAROUND_NS) mdio_i <= 1'b0;               // turnaround
         end else if (cur >= 48 && cur <= 63) begin
            #(TURNAROUND_NS) mdio_i <= rd_shift[15];
            rd_shift <= {rd_shift[14:0], 1'b0};
         end else if (cur >= 64) begin
            #(TURNAROUND_NS) mdio_i <= 1'b1;               // released
         end
      end else begin
         #(TURNAROUND_NS) mdio_i <= 1'b1;
      end
   end

endmodule
