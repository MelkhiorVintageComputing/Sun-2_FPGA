`timescale 1ns / 1ps

`include "sun2_attr.vh"

//
// The Sun-2 SCSI host adapter, without the bus it plugs into.
//
// Sun built this interface twice -- as a dual-height VME board with a
// battery-backed clock (rtl/sun2-vme/sun2_vme_scsi.sv) and as a MultiBus card
// with four serial ports (rtl/sun2-multibus/sun2_mb_scsi.sv) -- and the two are
// the same design.  Their own Theory of Operation says so outright: "The SCSI
// bus interface is the same for both this board (for the P796 bus) and the
// Sun-2 Single Board.  The DMA controller is largely the same for both boards,
// but the circuit implementation details differ"
// (Inputs/doc/Sun-2_SCSI/Multibus_SCSI_Theory_Of_Operation_Aug83.pdf, section 2).
//
// **The software cannot tell them apart at all**, which is the strongest
// evidence available that this split is the right one, and it is checkable
// rather than an opinion:
//
//   * Inputs/sunos-34-src/sun/sys/sundev/screg.h declares ONE struct
//     scsi_ha_reg for both machines, with `intvec' carrying the sole comment
//     "interrupt vector for VMEbus versions".
//   * msun/sys/sunstand/sc.c and rsun/sys/sunstand/sc.c are byte-identical --
//     one scdoit(), one sc_wait(), no conditional anywhere.
//
// So everything a driver touches lives here, and each card keeps only what the
// backplane decides: where its window is, how many pages it has, what else is
// on it, and whether it supplies an interrupt vector.
//
// **There is no SCSI protocol chip on either board, and no DMA chip either.**
// The whole interface is discrete TTL and PALs -- an 8303 transceiver, Am2952
// latches for the Data Register, an F280 parity generator, 'LS461 counters for
// DMA.  So there is no datasheet part to model and no register layout to look
// up: what software sees is a sixteen-byte register file, and that file *is* the
// specification.  The NCR 5380 that Inputs/Wish5380 models, and the Am9516 UDC
// beside it, are the **Sun-3** arrangement -- sundev/si.c, which
// conf.sun2/files.sun2:72 marks `not-supported' on a Sun-2.
//
// The register file, from sundev/screg.h:11-22, confirmed against both
// schematics and against the Programmers' Manual's own table (p8):
//
//   +0x00  8   W   data      selection bitmask, 1 << target
//   +0x00  8   R   data      the trailing odd byte after an odd-length DMA read
//   +0x02  8   RW  cmd_stat  the PIO port for *all* of COMMAND, STATUS and
//                            MESSAGE IN -- touching it generates SCSI ACK, so
//                            software never handles the handshake itself
//   +0x04  16  RW  icr       control in the low bits, the SCSI lines in the high
//   +0x08  32  W   dma_addr  24 bits on VME, 20 on MultiBus -- DMA_ADDR_BITS
//   +0x0C  16  RW  dma_count ones' complement, and it counts *up* to 0xFFFF
//   +0x0F  8   W   intvec    VME only; see HAS_INTVEC, which does NOT mean
//                            "bus-error there"
//
// Two things about that table are easy to get wrong and silent when wrong.
// `data' and `cmd_stat' are even-byte registers, so they live on D15:8 (UDS);
// `intvec' is at an odd address and lives on D7:0 (LDS).  And `dma_count' is
// both the transfer counter and a plain read/write register: the *entire*
// existence test every driver performs is to write 0x6789 to it and read it
// back (sunstand/sd.c:63-67, sundev/sc.c:80-86), and sc_getstatus restores a
// saved value into it outside any transfer.
//
// What is NOT here, because it belongs to the card: the window decode, the
// acknowledge counter (which answers to the machine's C_S24 timeout, not to any
// device), and whatever else shares the board -- an MM58167 on the VME card, two
// Z8530s on the MultiBus one.
//
module sun2_scsi_core #(
    // Where an address this card masters lands in the CPU's world.  The DVMA
    // window maps virtual 0xF00000 onto bus address 0 on both machines, so a
    // dma_addr of X is virtual DVMA_BASE + X -- the arrangement sun2_xy450.sv
    // uses as well.
    parameter logic [23:0] DVMA_BASE = 24'hF00000,

    // 24 on VME (A24), 20 on MultiBus.  The Programmers' Manual, p8: "Since the
    // Multibus addressing is only 20 bits, only the lower 4 bits of this
    // register are actually used for the Multibus version.  Similarly, the
    // single-board version, with 24-bit addressing, uses the lower 8 bits."
    // The counter is this wide too, so a transfer running off the end of the
    // window wraps rather than walking into the next megabyte.
    parameter int          DMA_ADDR_BITS = 24,

    // Does this card supply an interrupt vector?  Only the VME one does; the
    // MultiBus board interrupts non-vectored and the CPU autovectors it
    // (Sun-2_SCSI_Interface_Architectural_Specification.pdf, "Interrupts": "The
    // SCSI board interrupts with non-vectored Multibus interrupts").
    //
    // Zero does **not** mean the register bus-errors.  scattach() writes it
    // unconditionally on both machines -- sundev/sc.c:160-165, the autovectored
    // arm storing AUTOBASE + mc_intpri -- so a card that faulted there would
    // kill autoconfig.  Zero means the write is accepted and discarded and the
    // read returns zero, exactly like the reserved slot at +0x06.
    parameter bit          HAS_INTVEC = 1,

    // What INQUIRY reports, so a machine's console names the board it has.
    parameter logic [127:0] PRODUCT = "SUN VME SCSI SD "
) (
    input  wire        CLK,
    input  wire        RESET,

    // ---- the sixteen-byte register file -----------------------------------
    // The *window* decode is the card's; this port is one 16-byte block and
    // knows nothing above A03.
    input  wire        sel_i,        // the cycle is aimed at these registers
    input  wire        fire_i,       // one clock: the cycle is being acknowledged
    input  wire [2:0]  reg_i,        // A03..A01
    input  wire        we_i,
    input  wire        uds_n_i,      // D15:8, the even byte
    input  wire        lds_n_i,      // D7:0,  the odd byte
    input  wire [15:0] din_i,
    output reg  [15:0] dout_o,

    output wire        int_o,
    output wire [7:0]  intvec_o,

    // ---- DVMA master ------------------------------------------------------
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

   localparam [2:0] R_DATA  = 3'd0,   // +0x00
                    R_CMD   = 3'd1,   // +0x02
                    R_ICR   = 3'd2,   // +0x04
                    R_RSVD  = 3'd3,   // +0x06, the unused decode output
                    R_ADRHI = 3'd4,   // +0x08
                    R_ADRLO = 3'd5,   // +0x0A
                    R_COUNT = 3'd6,   // +0x0C
                    R_IVEC  = 3'd7;   // +0x0E, meaningful byte at 0x0F

   // How many bits of the DMA address high word are real: 8 on VME, 4 on
   // MultiBus.  Named rather than open-coded because it appears in a write
   // slice, a read slice and nowhere else, and getting the two to disagree is
   // silent.
   localparam int HI_BITS = DMA_ADDR_BITS - 16;

   wire wr_hi = we_i & ~uds_n_i;    // even byte, D15:8
   wire wr_lo = we_i & ~lds_n_i;    // odd byte,  D7:0

   // ------------------------------------------------------------------
   // The register file
   // ------------------------------------------------------------------
   reg  [7:0]  data_w;        // selection bitmask the CPU wrote
   reg  [7:0]  data_r;        // the odd byte a DMA read left behind
   reg  [DMA_ADDR_BITS-1:0] dma_addr;
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
   //
   // The PAL listing confirms it directly, and is worth quoting because this
   // project had to infer it from prose once already --
   // Inputs/doc/Sun-2_SCSI/SCSI_U108_520-1052.pdf:
   //
   //   ASSERT INTOUT
   //   OR  / BUSERR / REQ
   //   OR  / BUSERR   REGACC
   //   OR  / BUSERR / MSG   CD / IO      % status
   //   OR  / BUSERR / MSG / CD   ENDMA   % data
   //   % status or message is always an interrupt
   //   % data only interrupts if dma is disabled
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
         // A bus reset clears the Interface Control Register: the LS273's CLR
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
            dma_addr  <= dma_addr  + {{(DMA_ADDR_BITS-1){1'b0}}, 1'b1};
            dma_count <= dma_count + 16'd1;   // ones' complement, counting UP
         end
         if (dma_hold_odd) begin
            data_r <= dma_odd_byte;
            st_odd <= 1'b1;
         end
         if (dma_set_err) st_buserr <= 1'b1;

      if (sel_i & fire_i) begin
         case (reg_i)
           R_DATA:  if (wr_hi) data_w <= din_i[15:8];
           R_CMD:   ;                                    // the PIO port, below
           R_ICR:   if (wr_lo) begin
              // All six writable bits are in the low byte, at 0x05.
              icr_int_en <= din_i[0];
              icr_dma_en <= din_i[1];
              icr_word   <= din_i[2];
              icr_par_en <= din_i[3];
              icr_rst    <= din_i[4];
              icr_sel    <= din_i[5];
              // Bit 4 is the only way to clear the latched Bus Error -- not
              // clearing interrupt enable, not reading anything.  The
              // Programmers' Manual is explicit and it is the single most
              // non-obvious behaviour on the board.
              if (din_i[4]) st_buserr <= 1'b0;
              // Parity Error is latched inside the SCSI control PAL and clears
              // only when Parity Enable is momentarily dropped.  Its equation
              // says so -- SCSI_U108: "ASSERT PARERR / OR / ENPAR ..." with
              // the comment "parity error latches until cleared by clearing
              // parity enable".
              if (!din_i[3]) st_parerr <= 1'b0;
              // "Clearing this bit causes any pending interrupts to be
              // immediately cleared" -- but that is the interrupt presented to
              // the bus, not the status bit, because the same manual says
              // of bit 12 "If interrupts are disabled, this bit may still read
              // as 1".  Both PROM drivers rely on exactly that: they poll
              // IntReq with Interrupt Enable never set, so a card that cleared
              // the bit here could not boot at all.  int_o carries the gate.
           end
           // The high word of the DMA address: eight significant bits on VME,
           // four on MultiBus, and the rest of the word is not stored at all.
           R_ADRHI: if (wr_lo) dma_addr[DMA_ADDR_BITS-1:16] <= din_i[HI_BITS-1:0];
           R_ADRLO: begin
              if (wr_hi) dma_addr[15:8] <= din_i[15:8];
              if (wr_lo) dma_addr[7:0]  <= din_i[7:0];
           end
           R_COUNT: begin
              if (wr_hi) dma_count[15:8] <= din_i[15:8];
              if (wr_lo) dma_count[7:0]  <= din_i[7:0];
           end
           // On a card with no vector the write is accepted and dropped; see
           // HAS_INTVEC above for why it must not fault.
           R_IVEC:  if (HAS_INTVEC && wr_lo) intvec <= din_i[7:0];   // byte 0x0F
           default: ;
         endcase
      end
      end
   end

   // ------------------------------------------------------------------
   // Reading
   // ------------------------------------------------------------------
   // The reserved slot at +0x06 is a real decode output on the board that goes
   // nowhere, so it answers rather than bus-errors.  So do the four `unused'
   // holes in the driver's struct: mdr_size is 16 and the kernel maps the whole
   // block.
   // The PIO port for COMMAND / STATUS / MESSAGE, driven by the engine below.
   wire [7:0] cmd_stat_rd;

   always @* begin
      case (reg_i)
        R_DATA:  dout_o = {data_r, 8'h00};
        R_CMD:   dout_o = {cmd_stat_rd, 8'h00};
        R_ICR:   dout_o = icr_rd;
        R_ADRHI: dout_o = {{(16-HI_BITS){1'b0}}, dma_addr[DMA_ADDR_BITS-1:16]};
        R_ADRLO: dout_o = dma_addr[15:0];
        R_COUNT: dout_o = dma_count;
        R_IVEC:  dout_o = HAS_INTVEC ? {8'h00, intvec} : 16'h0000;
        default: dout_o = 16'h0000;
      endcase
   end

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
   // 7:5 of CDB byte 1, "for initiators that send no IDENTIFY".  Neither board
   // has an ATN driver at all -- the Programmers' Manual says ATN is not
   // implemented, "because it is useless without disconnect/reconnect" -- and
   // their drivers put the LUN in the CDB, so the two agree without a patch.
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
               .PRODUCT(PRODUCT),
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
   // The PAL says it in one line -- SCSI_U108, "ASSERT ACKOUT ... OR / REGACC
   // CD", with the comment "implicit ack when the byte packing can handle the
   // request".
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
   wire cmd_access = sel_i & fire_i & (reg_i == R_CMD);

   always @(posedge CLK) begin
      if (RESET) begin
         ack_q <= 1'b0; drive_out <= 1'b0; pio_out <= 8'h00; cmd_stat_q <= 8'h00;
      end else begin
         if (cmd_access & ~ack_q) begin
            if (wr_hi) begin
               // COMMAND out: the byte is in the even lane.
               pio_out   <= din_i[15:8];
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
   // There is no direction bit anywhere on either board.  The data phase's
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

   wire [23:0] cur_va   = DVMA_BASE + {{(24-DMA_ADDR_BITS){1'b0}}, dma_addr};
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
             // real board suppresses the address strobe so the bus cycle times
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

   // Only while enabled.  scpoll() claims the interrupt whenever IntReq or
   // BusError is set, so neither may stick -- a stuck bit spins the kernel in
   // its handler at spl2 for ever.  Which *level* this reaches is the card's
   // business: level 2 on both boards, but vectored on one and autovectored on
   // the other.
   assign int_o    = icr_int_en & (st_int | st_buserr);
   assign intvec_o = HAS_INTVEC ? intvec : 8'h00;

endmodule
