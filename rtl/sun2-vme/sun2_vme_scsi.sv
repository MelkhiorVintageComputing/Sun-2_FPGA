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
// **There is no SCSI protocol chip on this board, and no DMA chip either.** The
// whole interface is discrete TTL and seven PALs -- an 8303 transceiver, Am2952
// latches for the Data Register, an F280 parity generator, 'LS461 counters for
// DMA.  So there is no datasheet part to model and no register layout to look
// up: what software sees is a sixteen-byte register file, and that file *is* the
// specification.  The NCR 5380 that Inputs/Wish5380 models, and the Am9516 UDC
// beside it, are the **Sun-3** arrangement -- sundev/si.c, which
// conf.sun2/files.sun2:72 marks `not-supported' on a Sun-2.
//
// The register file, from sundev/screg.h:11-22 and confirmed against the
// schematic's byte lanes:
//
//   +0x00  8   W   data      selection bitmask, 1 << target
//   +0x00  8   R   data      the trailing odd byte after an odd-length DMA read
//   +0x02  8   RW  cmd_stat  the PIO port for *all* of COMMAND, STATUS and
//                            MESSAGE IN -- touching it generates SCSI ACK, so
//                            software never handles the handshake itself
//   +0x04  16  RW  icr       control in the low bits, the SCSI lines in the high
//   +0x08  32  W   dma_addr  a VME A24 address, 20 bits significant
//   +0x0C  16  RW  dma_count ones' complement, and it counts *up* to 0xFFFF
//   +0x0F  8   W   intvec    the VME interrupt vector
//
// Three things about that table are easy to get wrong and silent when wrong.
// `data' and `cmd_stat' are even-byte registers, so they live on D15:8 (UDS);
// `intvec' is at an odd address and lives on D7:0 (LDS).  The eight registers
// **alias every sixteen bytes** across the 2 KiB page, because the board's two
// LS138s decode only A01..A03 -- that is in the schematic and in neither manual.
// And `dma_count' is both the transfer counter and a plain read/write register:
// the *entire* existence test both drivers perform is to write 0x6789 to it and
// read it back (rsun/sys/sunstand/sd.c:63-67, sundev/sc.c:80-86), and
// sc_getstatus restores a saved value into it outside any transfer.
//
// The board occupies 4 KiB split by A11, deliberately, so that the MMU can
// protect the two halves separately -- protection is per 2 KiB page.  SCSI is
// the low half, the MM58167 the high half.  Sun put them at VME A24 0x200000
// and 0x200800; neither manual states that, it comes from the software
// (conf.sun2/GENERIC:58 and rsun/mon/kernel/sunmon.c:86,95).
//
// **The clock lives here rather than in sun2_fpga.v**, which is the historically
// correct place and also the convenient one: it leaves sun2_phy_status alone on
// device page 0xFE7, and needs no change to MATCH_RTC.  Architecture Manual 9.2
// lists the 2/120's clock page as Reserved on a Machine Type 2 precisely
// because a 2/50's clock is out here on the bus instead.
//
module sun2_vme_scsi #(
    // VME A24.  4 KiB, and the board's comparators only look at A12..A23, so
    // the granularity really is 4 KiB -- the Programmers' Manual's claim of a
    // 16 KiB boundary contradicts the schematic, and the schematic wins.
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

    output wire        int_o          // VME level 2
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

   localparam [2:0] R_DATA  = 3'd0,   // +0x00
                    R_CMD   = 3'd1,   // +0x02
                    R_ICR   = 3'd2,   // +0x04
                    R_RSVD  = 3'd3,   // +0x06, the unused decode output
                    R_ADRHI = 3'd4,   // +0x08
                    R_ADRLO = 3'd5,   // +0x0A
                    R_COUNT = 3'd6,   // +0x0C
                    R_IVEC  = 3'd7;   // +0x0E, meaningful byte at 0x0F

   wire wr_hi = mb_we & ~mb_uds_n;    // even byte, D15:8
   wire wr_lo = mb_we & ~mb_lds_n;    // odd byte,  D7:0

   // The RTC needs about a microsecond and the real board stretches its DTACK
   // with a PAL; SCSI registers answer in well under 125 ns.  Two phases for
   // SCSI, sixteen for the clock -- both far inside the machine's twelve-clock
   // timeout at the register end, and the asymmetry is the board's own.
   reg [4:0] phase;
   wire [4:0] ack_at = sel_rtc ? 5'd16 : 5'd2;
   always @(posedge CLK)
     if (RESET | ~hit_card)     phase <= 5'd0;
     else if (phase != ack_at)  phase <= phase + 5'd1;
   assign mb_ack = hit_card & (phase == ack_at);

   // One clock of "the cycle has just been acknowledged", for side effects that
   // must happen once however long the strobes stay low.
   wire fire = hit_card & (phase == ack_at - 5'd1);

   // ------------------------------------------------------------------
   // The register file
   // ------------------------------------------------------------------
   reg  [7:0]  data_w;        // selection bitmask the CPU wrote
   reg  [7:0]  data_r;        // the odd byte a DMA read left behind
   reg  [23:0] dma_addr;
   reg  [15:0] dma_count;
   reg  [7:0]  intvec;

   // ICR, control half.  screg.h:37 -- "only the following bits may usefully be
   // set by the CPU" -- and the Programmers' Manual notes every writable bit is
   // also readable, so BSET/BCHG/BCLR work on it.
   reg         icr_int_en, icr_dma_en, icr_word, icr_par_en, icr_rst, icr_sel;

   // ICR, status half.  Driven by the SCSI engine; zero until it exists.
   wire        scsi_bsy = 1'b0, scsi_par = 1'b0, scsi_io = 1'b0;
   wire        scsi_cd  = 1'b0, scsi_msg = 1'b0, scsi_req = 1'b0;
   wire        st_odd   = 1'b0;
   reg         st_int, st_buserr, st_parerr;

   wire [15:0] icr_rd = {st_parerr, st_buserr, st_odd, st_int,
                         scsi_req, scsi_msg, scsi_cd, scsi_io,
                         scsi_par, scsi_bsy, icr_sel, icr_rst,
                         icr_par_en, icr_word, icr_dma_en, icr_int_en};

   always @(posedge CLK) begin
      if (RESET) begin
         // VME SYSRESET clears the Interface Control Register: the LS273's CLR
         // pin is wired to it.  Every other register's power-on state is
         // undocumented, so nothing else is given one on purpose.
         icr_int_en <= 1'b0; icr_dma_en <= 1'b0; icr_word <= 1'b0;
         icr_par_en <= 1'b0; icr_rst    <= 1'b0; icr_sel  <= 1'b0;
         st_int     <= 1'b0; st_buserr  <= 1'b0; st_parerr <= 1'b0;
      end else if (sel_scsi & fire) begin
         case (reg_sel)
           R_DATA:  if (wr_hi) data_w <= mb_din[15:8];
           R_CMD:   ;                                    // the PIO port, below
           R_ICR:   if (wr_lo) begin
              // All six writable bits are in the low byte, at 0x05.
              icr_int_en <= mb_din[0];
              icr_dma_en <= mb_din[1];
              icr_word   <= mb_din[2];
              icr_par_en <= mb_din[3];
              icr_rst    <= mb_din[4];
              icr_sel    <= mb_din[5];
              // Bit 4 is the only way to clear the latched Bus Error -- not
              // clearing interrupt enable, not reading anything.  The
              // Programmers' Manual is explicit and it is the single most
              // non-obvious behaviour on the board.
              if (mb_din[4]) st_buserr <= 1'b0;
              // Parity Error is latched inside PAL U102 and clears only when
              // Parity Enable is momentarily dropped.
              if (!mb_din[3]) st_parerr <= 1'b0;
              // "Clearing this bit causes any pending interrupts to be
              // immediately cleared."
              if (!mb_din[0]) st_int <= 1'b0;
           end
           R_ADRHI: if (wr_lo) dma_addr[23:16] <= mb_din[7:0];   // byte 0x09
           R_ADRLO: begin
              if (wr_hi) dma_addr[15:8] <= mb_din[15:8];
              if (wr_lo) dma_addr[7:0]  <= mb_din[7:0];
           end
           R_COUNT: begin
              if (wr_hi) dma_count[15:8] <= mb_din[15:8];
              if (wr_lo) dma_count[7:0]  <= mb_din[7:0];
           end
           R_IVEC:  if (wr_lo) intvec <= mb_din[7:0];            // byte 0x0F
           default: ;
         endcase
      end
   end

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

   // ------------------------------------------------------------------
   // Reading
   // ------------------------------------------------------------------
   // The reserved slot at +0x06 is a real decode output on the board that goes
   // nowhere, so it answers rather than bus-errors.  So do the four `unused'
   // holes in the driver's struct: mdr_size is 16 and the kernel maps the whole
   // block.
   // The PIO port for COMMAND / STATUS / MESSAGE.  Nothing drives it yet; the
   // SCSI engine will.
   wire [7:0] cmd_stat_rd = 8'h00;

   reg [15:0] scsi_rd;
   always @* begin
      case (reg_sel)
        R_DATA:  scsi_rd = {data_r, 8'h00};
        R_CMD:   scsi_rd = {cmd_stat_rd, 8'h00};
        R_ICR:   scsi_rd = icr_rd;
        R_ADRHI: scsi_rd = {8'h00, dma_addr[23:16]};
        R_ADRLO: scsi_rd = dma_addr[15:0];
        R_COUNT: scsi_rd = dma_count;
        R_IVEC:  scsi_rd = {8'h00, intvec};
        default: scsi_rd = 16'h0000;
      endcase
   end

   assign mb_dout = sel_rtc ? {rtc_out, 8'h00} : scsi_rd;

   // Level 2, and only while enabled.  scpoll() claims the interrupt whenever
   // IntReq or BusError is set, so neither may stick -- a stuck bit spins the
   // kernel in its handler at spl2 for ever.
   assign int_o = icr_int_en & (st_int | st_buserr);

endmodule
