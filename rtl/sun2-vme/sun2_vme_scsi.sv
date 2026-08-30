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

    output wire        int_o,         // VME level 2
    // ...and the vector it supplies when that level is acknowledged.  The
    // board is a vectored interrupter: scattach() writes the number here and
    // the kernel installs its handler at it, so an autovectored acknowledge
    // reaches no handler at all.
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
   // The register file
   // ------------------------------------------------------------------
   reg  [7:0]  data_w;        // selection bitmask the CPU wrote
   reg  [7:0]  data_r;        // the odd byte a DMA read left behind
   reg  [23:0] dma_addr;
   reg  [15:0] dma_count;
   reg  [7:0]  intvec;

   // The DMA engine's state.  Declared here rather than beside the engine
   // because xvlog rejects any use ahead of its declaration, and both the
   // register file and the initiator's data mux reach into it.
   localparam [2:0] D_IDLE   = 3'd0,
                    D_IN     = 3'd1,
                    D_INACK  = 3'd2,
                    D_FLUSH  = 3'd3,
                    D_FETCH  = 3'd4,
                    D_OUT    = 3'd5,
                    D_OUTACK = 3'd6;

   reg [2:0]  dst;
   reg [31:0] stage;
   reg [3:0]  stage_sel;
   reg [21:0] chunk_adr;
   reg [1:0]  out_lane;
   reg        nbytes_odd;        // parity of the bytes moved so far
   reg        dma_ack_q;
   reg        wb_req, wb_we_r;

   // Pulses into the register file, which owns the registers these touch.
   reg        dma_adv, dma_set_err, dma_hold_odd;
   reg [7:0]  dma_odd_byte;

   wire        dma_drive    = (dst == D_OUT) | (dst == D_OUTACK);
   wire [7:0]  dma_out_byte = stage[out_lane*8 +: 8];

   // ICR, control half.  screg.h:37 -- "only the following bits may usefully be
   // set by the CPU" -- and the Programmers' Manual notes every writable bit is
   // also readable, so BSET/BCHG/BCLR work on it.
   reg         icr_int_en, icr_dma_en, icr_word, icr_par_en, icr_rst, icr_sel;

   // ICR, status half.  Six of these are the SCSI control lines read straight
   // off the bus, which is what this board offers instead of a chip's status
   // register.
   scsi_t      bus;                    // the wired-OR, as everyone sees it
   wire        scsi_bsy = bus.bsy;
   wire        scsi_par = bus.dbp;
   wire        scsi_io  = bus.io;
   wire        scsi_cd  = bus.cd;
   wire        scsi_msg = bus.msg;
   reg         st_odd;
   reg         st_buserr, st_parerr;

   // IntReq (bit 12) is *not* a latch.  The Theory of Operation is explicit:
   // "As soon as the request is acknowledged, the interrupt request goes
   // away.  The SCSI Control PAL takes care of this" -- and a request is
   // acknowledged by the host accessing the Data or Command/Status register.
   // So it is a level that follows an unserviced REQ, and it is built below
   // from req_latch rather than kept in a flip-flop of its own.
   wire        st_int;

   // ICR bit 11 is **not** a mirror of SCSI REQ.  The Programmers' Manual calls
   // it New Request: it latches an unacknowledged request, drops when that
   // request is acknowledged, and does not return until REQ has fallen and
   // risen again.  It also only asserts when the CPU actually has something to
   // do -- with DMA armed, a data-phase request is the engine's business and
   // must not appear here, or the driver's polling loops see work that is not
   // theirs.
   reg         req_latch;
   wire        data_phase = ~bus.cd;
   wire        scsi_req   = req_latch & ~(data_phase & icr_dma_en);

   // "An interrupt request will occur as a result of a REQuest from the TARGET
   // for Status or Message.  REQuests for Data result in a DMA request if DMA
   // is enabled, and an interrupt request if DMA is not enabled.  A Command
   // request never causes an interrupt request" -- Programmers' Manual, bit 12.
   // The exclusion of COMMAND is load-bearing rather than tidy: sc_cmd() sets
   // Interrupt Enable *before* it pushes the six CDB bytes by programmed I/O
   // (sundev/sc.c:320 against :331), so a card that interrupted on a command
   // request would interrupt the driver in the middle of writing its own CDB.
   wire        cmd_phase  = bus.cd & ~bus.io & ~bus.msg;
   assign      st_int     = (req_latch & ~cmd_phase &
                             ~(data_phase & icr_dma_en)) | st_buserr;

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
         st_buserr  <= 1'b0; st_parerr <= 1'b0;
         st_odd     <= 1'b0;
      end else begin
         // The engine's side effects are applied here rather than in the
         // engine itself, because these registers are the CPU's as well and a
         // register with two drivers is not a register.  The CPU's write is
         // evaluated afterwards and therefore wins, which is also what the
         // board does -- the counters are loadable at any time.
         if (dma_adv) begin
            dma_addr  <= dma_addr  + 24'd1;
            dma_count <= dma_count + 16'd1;   // ones' complement, counting UP
         end
         if (dma_hold_odd) begin
            data_r <= dma_odd_byte;
            st_odd <= 1'b1;
         end
         if (dma_set_err) st_buserr <= 1'b1;

      if (sel_scsi & fire) begin
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
              // immediately cleared" -- but that is the interrupt presented to
              // the VME bus, not the status bit, because the same manual says
              // of bit 12 "If interrupts are disabled, this bit may still read
              // as 1".  Both PROM drivers rely on exactly that: they poll
              // IntReq with Interrupt Enable never set, so a card that cleared
              // the bit here could not boot at all.  int_o carries the gate.
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
   // The PIO port for COMMAND / STATUS / MESSAGE, driven by the engine below.
   wire [7:0] cmd_stat_rd;

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

   // ------------------------------------------------------------------
   // The SCSI bus, and the drive on it
   // ------------------------------------------------------------------
   // The initiator is this board; the target is Inputs/Wish5380's scsi_targ,
   // which is a complete direct-access device -- TEST UNIT READY, REQUEST
   // SENSE, READ and WRITE, INQUIRY, READ CAPACITY, MODE SENSE -- backed by the
   // same block seam the Xylogics uses to reach the SD card.  Only the
   // initiator is new; the drive and its command set come with 120 tests.
   //
   // That reuse works because scsi_targ enters MESSAGE OUT only when ATN is
   // asserted (scsi_targ.sv:460) and otherwise takes the logical unit from bit
   // 7:5 of CDB byte 1, "for initiators that send no IDENTIFY".  This board has
   // no ATN driver at all -- the Programmers' Manual says ATN is not
   // implemented -- and its drivers put the LUN in the CDB, so the two agree
   // without a patch.
   scsi_t ini, targ;

   scsi_fabric fabric (.a_i(ini), .b_i(targ), .c_i('0), .d_i('0), .bus_o(bus));

   blk_req_t blk_req_w;
   blk_rsp_t blk_rsp_w;
   assign blk_start     = blk_req_w.start;
   assign blk_we        = blk_req_w.we;
   assign blk_lba       = blk_req_w.lba;
   assign blk_buf_rdata = blk_req_w.buf_rdata;
   always @* begin
      blk_rsp_w           = '0;
      blk_rsp_w.done      = blk_done;
      blk_rsp_w.err       = blk_err;
      blk_rsp_w.ready     = blk_ready;
      blk_rsp_w.count     = blk_count;
      blk_rsp_w.buf_we    = blk_buf_we;
      blk_rsp_w.buf_addr  = blk_buf_addr;
      blk_rsp_w.buf_wdata = blk_buf_wdata;
   end

   scsi_targ #(.TARGET_ID(0),
               .VENDOR ("SUN     "),
               .PRODUCT("SUN VME SCSI SD "),
               .REVISION("0001")) drive (
       .clk_i(CLK), .rst_i(RESET),
       .drive_o(targ), .bus_i(bus),
       .blk_o(blk_req_w), .blk_i(blk_rsp_w));

   // ------------------------------------------------------------------
   // The initiator
   // ------------------------------------------------------------------
   // Selection is the CPU's: it writes the target bitmask to `data' and then
   // sets SEL in the ICR.  The board holds both until the CPU writes an ICR
   // without SEL -- which is how SEL gets dropped, since the drivers never
   // clear it explicitly.  Note they assert **one** ID bit and not the
   // initiator's own: HOST_ADDR is 0 in screg.h, which Sun shipped that way to
   // appease a Sysgen controller even though the standard wants both.
   //
   // ACK is never software's.  Touching `cmd_stat' generates the whole REQ/ACK
   // handshake, which is why there is no acknowledge bit anywhere in the ICR.
   reg        ack_q;
   reg [7:0]  pio_out;        // the byte a COMMAND write is sending
   reg [7:0]  cmd_stat_q;     // the byte a STATUS or MESSAGE read returned
   reg        drive_out;      // this board is sourcing the data lines

   always @* begin
      ini      = '0;
      ini.sel  = icr_sel;
      ini.rst  = icr_rst;
      ini.ack  = ack_q | dma_ack_q;
      ini.data = icr_sel   ? data_w
               : drive_out ? pio_out
               : dma_drive ? dma_out_byte : 8'h00;
      // Odd parity across whatever we are driving, as the F280 generates it.
      ini.dbp  = (icr_sel || drive_out || dma_drive) ? ~(^ini.data) : 1'b0;
   end

   // A new request is one we have not acknowledged yet.
   reg req_d;
   always @(posedge CLK) begin
      if (RESET) begin
         req_latch <= 1'b0; req_d <= 1'b0;
      end else begin
         req_d <= bus.req;
         if (bus.req & ~req_d) req_latch <= 1'b1;   // a fresh REQ
         // Acknowledged -- the host touching cmd_stat is what the board
         // turns into SCSI ACK, and the Theory of Operation says the interrupt
         // request goes away with it.  Bus free clears it too: a target that
         // drops off without being answered (a bus reset, an abort) would
         // otherwise leave IntReq asserted for a request nobody can service.
         else if (ack_q | ~bus.bsy) req_latch <= 1'b0;

         // ...and a fresh request in an inbound control phase -- C/D and I/O
         // both asserted, which is STATUS or MESSAGE IN -- is the target
         // answering, so the board raises IntReq.  scdoit() waits on it after
         // *every* command, TEST UNIT READY included, and that command has no
         // data phase at all: tying IntReq to the end of a transfer means a
         // command which moves nothing can never post it and the driver spins
         // on ICR_INTERRUPT_REQUEST for ever, which is exactly what a board
         // capture showed -- ICR 0x0BC6, the target sitting in STATUS with REQ
         // asserted and IntReq clear.
         //
         // COMMAND is deliberately excluded even though it also needs the CPU.
         // There the CPU is already feeding bytes and knows it; raising IntReq
         // for each of the six would make the wait after the CDB return before
         // the command had been acted on, which is not a subtle failure -- the
         // driver then reads a residue from a transfer that has not started.
      end
   end

   // The PIO handshake.  A CPU access to cmd_stat starts it; the acknowledge
   // pulse then runs to completion on its own, so the register answers the CPU
   // in a couple of clocks while the SCSI side takes as long as it takes.  The
   // driver polls the ICR for the next request, which cannot appear until this
   // finishes, so the two stay in step without the CPU knowing.
   wire cmd_access = sel_scsi & fire & (reg_sel == R_CMD);

   always @(posedge CLK) begin
      if (RESET) begin
         ack_q <= 1'b0; drive_out <= 1'b0; pio_out <= 8'h00; cmd_stat_q <= 8'h00;
      end else begin
         if (cmd_access & ~ack_q) begin
            if (wr_hi) begin
               // COMMAND out: the byte is in the even lane.
               pio_out   <= mb_din[15:8];
               drive_out <= 1'b1;
            end else begin
               // STATUS or MESSAGE in: the target is already driving the byte
               // alongside REQ, so it can be taken now.
               cmd_stat_q <= bus.data;
            end
            ack_q <= 1'b1;
         end else if (ack_q & ~bus.req) begin
            // The target has taken it and dropped REQ; release.
            ack_q     <= 1'b0;
            drive_out <= 1'b0;
         end
      end
   end

   assign cmd_stat_rd = cmd_stat_q;

   // ------------------------------------------------------------------
   // The DMA engine
   // ------------------------------------------------------------------
   // There is no direction bit anywhere on this board.  The data phase's
   // direction is the SCSI I/O line, which the target drives, so the engine
   // reads the phase and follows it -- a driver that sets a transfer up the
   // wrong way round simply moves data the other way, exactly as the hardware
   // would.
   //
   // dma_count is a ones' complement counter that counts UP to 0xFFFF, so a
   // transfer is loaded with ~len, the residue afterwards is ~dma_count, and a
   // complete transfer ends at 0xFFFF.
   //
   // Bytes are gathered into longwords before they touch memory.  One Wishbone
   // transaction per byte is correct and useless: sun2_xy450's header records
   // that byte-at-a-time managed 20 KB/s and turned a kernel load into four
   // hours.  A chunk runs from the current address to the end of the longword
   // it lands in, so an unaligned dma_addr costs one short transaction at each
   // end and nothing else.

   wire [23:0] cur_va   = DVMA_BASE + dma_addr;
   wire [1:0]  cur_lane = cur_va[1:0];
   wire        dma_done = (dma_count == 16'hFFFF);
   wire        dma_last = (dma_count == 16'hFFFE);   // this byte is the last
   wire        dma_armed = icr_dma_en & bus.bsy & data_phase;

   // A read whose final byte has no partner.  Word mode moves sixteen bits at
   // a time, so a lone trailing byte cannot go to memory: it stays in the Data
   // Register with Odd Length set, which is where the driver looks for it.
   wire        odd_tail = icr_word & dma_last & ~nbytes_odd;


   assign wb_cyc_o = wb_req;
   assign wb_stb_o = wb_req;
   assign wb_we_o  = wb_we_r;
   assign wb_adr_o = chunk_adr;
   assign wb_sel_o = stage_sel;
   assign wb_dat_o = stage;
   // The RST bit is the only thing that clears the latched Bus Error, so it is
   // also what makes sun2_dvma forget the one it holds.  A card that does not
   // do this works exactly once.
   assign wb_clr_o = icr_rst;

   always @(posedge CLK) begin
      dma_adv      <= 1'b0;
      dma_set_err  <= 1'b0;
      dma_hold_odd <= 1'b0;

      if (RESET) begin
         dst <= D_IDLE; wb_req <= 1'b0; wb_we_r <= 1'b0;
         dma_ack_q <= 1'b0; stage_sel <= 4'h0; nbytes_odd <= 1'b0;
      end else case (dst)

        D_IDLE: begin
           stage_sel  <= 4'h0;
           nbytes_odd <= 1'b0;
           // Wait for a real request, not merely for the lines to look like
           // a data phase.  Between selection and COMMAND the target has BSY
           // up and has not yet driven C/D, which reads here as a data phase
           // that is about to end -- and leaving on that would post an
           // interrupt for a transfer that never happened.
           if (dma_armed & ~dma_done & bus.req) dst <= bus.io ? D_IN : D_FETCH;
        end

        // ---- target to memory ----
        D_IN:
          if (dma_armed & bus.req & ~dma_done) begin
             if (odd_tail) begin
                dma_odd_byte <= bus.data;
                dma_hold_odd <= 1'b1;
             end else begin
                if (stage_sel == 4'h0) chunk_adr <= cur_va[23:2];
                stage[cur_lane*8 +: 8] <= bus.data;
                stage_sel[cur_lane]    <= 1'b1;
             end
             dma_adv    <= 1'b1;
             nbytes_odd <= ~nbytes_odd;
             dma_ack_q  <= 1'b1;
             dst        <= D_INACK;
          end else if (dma_armed & bus.req & dma_done) begin
             // Count exhausted and the drive still wants to move data.  The
             // real board suppresses the address strobe so the VME cycle times
             // out, and that manufactured bus error is what stops DMA -- which
             // is the only way software tells an overrun from a short read.
             dma_set_err <= 1'b1;
             dst <= (|stage_sel) ? D_FLUSH : D_IDLE;
          end else if (~dma_armed | dma_done) begin
             if (|stage_sel) dst <= D_FLUSH;
             else dst <= D_IDLE;
          end

        D_INACK:
          if (~bus.req) begin
             dma_ack_q <= 1'b0;
             // Lane 0 again means the longword just filled.
             dst <= (cur_lane == 2'd0 && |stage_sel) ? D_FLUSH : D_IN;
          end

        D_FLUSH:
          if (~wb_req) begin
             wb_req <= 1'b1; wb_we_r <= 1'b1;
          end else if (wb_ack_i | wb_err_i) begin
             wb_req    <= 1'b0;
             stage_sel <= 4'h0;
             if (wb_err_i) begin dma_set_err <= 1'b1; dst <= D_IDLE; end
             else dst <= D_IN;
          end

        // ---- memory to target ----
        D_FETCH:
          if (~dma_armed | dma_done) begin
             dst <= D_IDLE;
          end else if (~wb_req) begin
             chunk_adr <= cur_va[23:2];
             stage_sel <= 4'hF;          // a read selects the whole longword
             wb_req    <= 1'b1; wb_we_r <= 1'b0;
          end else if (wb_ack_i | wb_err_i) begin
             wb_req <= 1'b0;
             stage  <= wb_dat_i;
             out_lane <= cur_lane;
             if (wb_err_i) begin dma_set_err <= 1'b1; dst <= D_IDLE; end
             else dst <= D_OUT;
          end

        D_OUT:
          if (~dma_armed | dma_done) begin
             dst <= D_IDLE;
          end else if (bus.req) begin
             dma_adv    <= 1'b1;
             nbytes_odd <= ~nbytes_odd;
             dma_ack_q  <= 1'b1;
             dst        <= D_OUTACK;
          end

        D_OUTACK:
          if (~bus.req) begin
             dma_ack_q <= 1'b0;
             out_lane  <= cur_lane;
             dst <= (cur_lane == 2'd0) ? D_FETCH : D_OUT;
          end

        default: dst <= D_IDLE;
      endcase
   end

   // Level 2, and only while enabled.  scpoll() claims the interrupt whenever
   // IntReq or BusError is set, so neither may stick -- a stuck bit spins the
   // kernel in its handler at spl2 for ever.
   assign int_o    = icr_int_en & (st_int | st_buserr);
   assign intvec_o = intvec;

endmodule
