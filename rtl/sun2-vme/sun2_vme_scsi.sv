`timescale 1ns / 1ps

`include "sun2_attr.vh"

//
// The Sun VME SCSI/RTC board: a disk for a 2/50, and the clock that came with it.
//
// A dual-height VME board carrying a SCSI interface and a battery-backed
// real-time clock (W. M. Bradley, 1984-09-20 -- Theory of Operation in
// Inputs/doc/Sun_VME_SCSI_RTC/).  It is what gave a Sun-2/50 a local disk,
// where a 2/120 used the Xylogics 450 that rtl/sun2-multibus/sun2_xy450.sv
// replicates.
//
// **The SCSI interface itself is not here.**  Sun built the same interface
// twice, and their own Theory of Operation says the two are the same design, so
// it lives in rtl/sun2-common/sun2_scsi_core.sv and this file is what the VME
// backplane adds to it: a 4 KiB window, a second device in the top half, and a
// vector.  rtl/sun2-multibus/sun2_mb_scsi.sv is the other card.  The register
// file, the ICR, the initiator and the DMA engine are all documented there.
//
// The board occupies 4 KiB split by A11, deliberately, so that the MMU can
// protect the two halves separately -- protection is per 2 KiB page.  SCSI is
// the low half, the MM58167 the high half.  Sun put them at VME A24 0x200000
// and 0x200800; neither manual states that, it comes from the software
// (conf.sun2/GENERIC:60 and rsun/mon/kernel/sunmon.c:95).
//
// The eight SCSI registers **alias every sixteen bytes** across the low 2 KiB,
// because the board's two LS138s decode only A01..A03 -- that is in the
// schematic and in neither manual.
//
// **The clock lives here rather than in sun2_fpga.v**, which is the historically
// correct place and also the convenient one: it leaves sun2_phy_status alone on
// device page 0xFE7, and needs no change to MATCH_RTC.  Architecture Manual 9.2
// lists the 2/120's clock page as Reserved on a Machine Type 2 precisely
// because a 2/50's clock is out here on the bus instead.  The MultiBus card
// puts a Z8530 at that same offset and takes its clock from the motherboard --
// the two boards are mirror images at +0x800.
//
module sun2_vme_scsi #(
    // VME A24.  4 KiB, and the board's comparators only look at A12..A23, so
    // the granularity really is 4 KiB -- the Programmers' Manual's claim of a
    // 16 KiB boundary is about the MultiBus card, whose three 2 KiB pages do
    // need one, and it contradicts this schematic.  The schematic wins.
    parameter logic [23:0] SCSI_BASE = 24'h200000,

    // Where a VME A24 address the card masters lands in the CPU's world.  The
    // DVMA window maps virtual 0xF00000 onto VME A24 0, so a dma_addr of X is
    // virtual DVMA_BASE + X -- the same arrangement sun2_xy450.sv uses.
    parameter logic [23:0] DVMA_BASE = 24'hF00000,

    // Passed through to the MM58167, which converts them to BCD.
    parameter int INIT_MON = 1, INIT_DAY = 1, INIT_WDAY = 1,
    parameter int INIT_HOUR = 0, INIT_MIN = 0, INIT_SEC = 0
) (
    input  wire        CLK,
    input  wire        RESET,        // the machine's reset; VME SYSRESET
    input  wire        por_reset,    // power-on only -- the clock is battery backed
    input  wire        clk4m9152,    // the 4.9152 MHz oscillator, for the RTC

    // ---- VME slave, through the machine's card port ----------------------
    // mb_addr is a byte address inside VME0's 8 MiB, so 23 bits.
    input  wire        mb_sel,
    input  wire [22:0] mb_addr,
    input  wire        mb_we,
    input  wire        mb_uds_n,     // D15:8, the even byte
    input  wire        mb_lds_n,     // D7:0,  the odd byte
    input  wire [15:0] mb_din,
    output wire [15:0] mb_dout,
    output wire        mb_hit,
    output wire        mb_ack,

    output wire        int_o,         // VME level 2
    // ...and the vector it supplies when that level is acknowledged.  The
    // board is a vectored interrupter: scattach() writes the number here and
    // the kernel installs its handler at it, so an autovectored acknowledge
    // reaches no handler at all.  This is the half the MultiBus card does not
    // have -- see sun2_scsi_core.sv's HAS_INTVEC.
    output wire [7:0]  intvec_o,

    // ---- DVMA master.  The card fetches and stores its own data, at
    //      virtual DVMA_BASE + dma_addr, exactly as sun2_xy450 does.
    output wire        wb_cyc_o,
    output wire        wb_stb_o,
    output wire        wb_we_o,
    output wire [3:0]  wb_sel_o,
    output wire [21:0] wb_adr_o,      // word address; byte = {adr, 2'b00}
    output wire [31:0] wb_dat_o,
    input  wire [31:0] wb_dat_i,
    input  wire        wb_ack_i,
    input  wire        wb_err_i,
    output wire        wb_clr_o,      // forget a latched DVMA error

    // ---- the drive's block back end, flattened the way top_fpga carries it
    output wire        blk_start,
    output wire        blk_we,
    output wire [31:0] blk_lba,
    output wire [7:0]  blk_buf_rdata,
    input  wire        blk_done,
    input  wire        blk_err,
    input  wire        blk_ready,
    input  wire [31:0] blk_count,
    input  wire        blk_buf_we,
    input  wire [8:0]  blk_buf_addr,
    input  wire [7:0]  blk_buf_wdata
);

   // ------------------------------------------------------------------
   // Decode
   // ------------------------------------------------------------------
   wire hit_card = mb_sel & (mb_addr[22:12] == SCSI_BASE[22:12]);
   wire sel_scsi = hit_card & ~mb_addr[11];
   wire sel_rtc  = hit_card &  mb_addr[11];

   assign mb_hit = hit_card;

   // Only A01..A03 inside the SCSI half, so the eight registers repeat every
   // sixteen bytes for the whole 2 KiB.  Replicated because it is real and free,
   // and because software that happens to touch a mirror should find the
   // register rather than a bus error.
   wire [2:0] reg_sel = mb_addr[3:1];

   wire wr_hi = mb_we & ~mb_uds_n;    // even byte, D15:8

   // How fast the card answers.
   //
   // Two bounds, and only one of them is real.  The machine's is real:
   // sun2_fpga.v raises TIMEOUT at C_S24, twelve clocks after AS, for card
   // space as well as everywhere that is not memory or the frame buffer --
   // because that timeout is how the PROM's probes discover empty addresses.
   // A card answering later than that has not been stretched, it has been
   // disconnected: every read of the clock would raise a bus error and
   // todprobe() would find nothing there.
   //
   // The other bound is the devices'.  A SCSI register is a flop and answers
   // at once.  The MM58167 loads its output once, at the leading edge of the
   // read strobe, and its edge detector costs a clock -- so DOUT is valid from
   // phase 2 and not before, and acknowledging earlier would hand the CPU
   // whatever the previous cycle left on the wires.
   //
   // Nothing else applies.  The real board stretches the clock's DTACK with a
   // PAL because the part needs about a microsecond, and that delay is not
   // software-visible: no code in either PROM, or in SunOS, measures how long
   // a register takes to answer.  So this replica is as fast as its devices
   // allow rather than as slow as the original, and both halves come out at
   // the same number for the same reason.
   //
   // It stays with the card rather than in the core because it answers to the
   // machine, not to the SCSI interface: the MultiBus card has three pages and
   // a different set of devices behind them.
   localparam [4:0] ACK_SCSI = 5'd2, ACK_RTC = 5'd2;
   reg [4:0] phase;
   wire [4:0] ack_at = sel_rtc ? ACK_RTC : ACK_SCSI;
   always @(posedge CLK)
     if (RESET | ~hit_card)     phase <= 5'd0;
     else if (phase != ack_at)  phase <= phase + 5'd1;
   assign mb_ack = hit_card & (phase == ack_at);

   // One clock of "the cycle has just been acknowledged", for side effects that
   // must happen once however long the strobes stay low.
   wire fire = hit_card & (phase == ack_at - 5'd1);

   // ------------------------------------------------------------------
   // The SCSI interface
   // ------------------------------------------------------------------
   wire [15:0] scsi_rd;

   sun2_scsi_core #(.DVMA_BASE    (DVMA_BASE),
                    .DMA_ADDR_BITS(24),          // VME A24
                    .HAS_INTVEC   (1),           // a vectored interrupter
                    .PRODUCT      ("SUN VME SCSI SD "))
   scsi (.CLK(CLK), .RESET(RESET),

         .sel_i(sel_scsi), .fire_i(fire), .reg_i(reg_sel),
         .we_i(mb_we), .uds_n_i(mb_uds_n), .lds_n_i(mb_lds_n),
         .din_i(mb_din), .dout_o(scsi_rd),

         .int_o(int_o), .intvec_o(intvec_o),

         .wb_cyc_o(wb_cyc_o), .wb_stb_o(wb_stb_o), .wb_we_o(wb_we_o),
         .wb_sel_o(wb_sel_o), .wb_adr_o(wb_adr_o), .wb_dat_o(wb_dat_o),
         .wb_dat_i(wb_dat_i), .wb_ack_i(wb_ack_i), .wb_err_i(wb_err_i),
         .wb_clr_o(wb_clr_o),

         .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
         .blk_buf_rdata(blk_buf_rdata),
         .blk_done(blk_done), .blk_err(blk_err), .blk_ready(blk_ready),
         .blk_count(blk_count), .blk_buf_we(blk_buf_we),
         .blk_buf_addr(blk_buf_addr), .blk_buf_wdata(blk_buf_wdata));

   // ------------------------------------------------------------------
   // The clock
   // ------------------------------------------------------------------
   // Register n at offset 2n on the upper byte lane, which is how the board
   // wires it (LS373 U802 / LS374 U804 on D08-D15) and, by coincidence of two
   // boards solving the same problem the same way, exactly what mm58167.v
   // already does for the 2/120.  So the model is reused unchanged and only the
   // decode is new.
   //
   // Reset is por_reset and not RESET: the real chip has a lithium cell and is
   // not affected by a bus reset, a watchdog or a RESET instruction.
   wire [7:0] rtc_out;
   mm58167 #(.INIT_MON (INIT_MON),  .INIT_DAY (INIT_DAY),
             .INIT_WDAY(INIT_WDAY), .INIT_HOUR(INIT_HOUR),
             .INIT_MIN (INIT_MIN),  .INIT_SEC (INIT_SEC))
   rtc (.CLK(CLK),
        .reset_n(~por_reset),
        .DIN(mb_din[15:8]),
        .DOUT(rtc_out),
        .addr(mb_addr[5:1]),
        .CS_n(1'b0),
        .RD_n(~(sel_rtc & ~mb_we)),
        .WR_n(~(sel_rtc & wr_hi)),
        .X2(clk4m9152));

   assign mb_dout = sel_rtc ? {rtc_out, 8'h00} : scsi_rd;

endmodule
