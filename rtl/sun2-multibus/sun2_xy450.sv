`timescale 1ns / 1ps

//
// A Xylogics 450 disk controller in the MultiBus card cage.
//
// Six bytes of registers in MultiBus I/O space and nothing else visible: every
// command comes from a 24-byte I/O Parameter Block that the *controller*
// fetches out of memory, and every sector moves by the controller's own DMA.
// The host writes a 16-bit offset, a 16-bit relocation, and a Go bit.
//
// Sources, and they agree: the Xylogics 450 User's Manual Rev E
// (Inputs/doc/Xylogics450/166-017-001E_..., sections 2.3 to 2.6), the boot
// PROM's driver at Inputs/sunos-34-src/sun/prom_monitor/msun/mon/prom2/xy.c
// with its register map in sys/sundev/xycreg.h, and SunOS 3.4's own
// sun/sys/sundev/xy.c -- which is much stricter about this front end than the
// PROM is, and is therefore the specification.
//
// ---------------------------------------------------------------------------
// Where the registers are, and why the byte numbering looks wrong
// ---------------------------------------------------------------------------
// The card is jumpered to a 16-bit MultiBus *I/O* address, 0xEE40 as it left
// Sun; the PROM knows 0xEE40 and 0xEE48 and probes both.  The controller
// numbers its own registers as MultiBus byte addresses:
//
//   0x40  IOPB relocation low     0x43  IOPB address high
//   0x41  IOPB relocation high    0x44  Control and Status Register
//   0x42  IOPB address low        0x45  Controller Reset / Update
//
// The 68010 sees those bytes with bit 0 of the address inverted.  MultiBus is
// little-endian -- its even byte is on DAT7:0 -- and a 68000 puts its even
// byte on D15:8, so with the data bus wired straight through the two byte
// numberings disagree by exactly one.  That is not a Sun quirk and it is not
// a bug; it is what happens when a big-endian processor and a little-endian
// bus share sixteen wires.  It is visible in SunOS's own declaration, which
// carries the controller's numbers as comments:
//
//   struct xydevice {              // I/O space registers (at EE40)
//        u_char xy_iopbrel[2];     // 1,0 - IOPB relocation
//        u_char xy_iopboff[2];     // 3,2 - IOPB offset
//        u_char xy_resupd;         // 5 - reset/update
//        u_char xy_csr;            // 4 - controller status register
//   };
//
// so `xyaddr->xy_csr = XY_GO` is a byte write to CPU offset 5 -- odd, LDS,
// D7:0 -- and lands on register 0x44.  In this module that means: the UDS lane
// carries the odd-numbered register of each pair and the LDS lane the even
// one.  Get it backwards and the PROM's first act is to reset the controller
// when it meant to read the CSR.
//
// ---------------------------------------------------------------------------
// What the software does to this front end
// ---------------------------------------------------------------------------
// The PROM's xyprobe() is only a two-byte write and read-back of the
// relocation registers -- 0x67 then 0x89 -- which exists to tell a Xylogics
// from an Interphase 2180 at the same address.  SunOS's xyprobe() is the real
// contract, in order (sun/sys/sundev/xy.c:165):
//
//   1. read register 0x45.  Must not bus-error; it starts a Controller Reset.
//   2. spin until GBSY clears, up to 0.1 s, else "controller reset failed".
//   3. write 0x67/0x89 to the relocation registers, wait, read them back.
//   4. write 0/0 to them and read back zero.
//   5. issue a NOP and require the IOPB to come back with controller type 1.
//   6. issue a Self Test.
//
// Everything the kernel writes to a register it reads back and retries on a
// miscompare, "due to a bug in the 450.  Occasionally the registers will not
// respond to a write" (xy.c:158).  A second miscompare panics the machine, so
// the registers here are ordinary flops and always take the write.
//
// The PROM's command loop has one property worth knowing before changing
// anything here: it waits on GBSY with **no timeout**.  A controller that
// sets Go and never clears it does not fail, it hangs the machine at the
// monitor prompt.
//
// ---------------------------------------------------------------------------
// How the controller reaches memory
// ---------------------------------------------------------------------------
// It is a bus master, and on a Sun-2 that means DVMA: the addresses it puts
// out are *virtual*.  Architecture Manual section 8.4 --
//
//   "DVMA responds to the low-order 256K Byte memory space on the P1-Bus.
//    This space is mapped to the low-order 256K Bytes of the top 1 MByte of
//    the system context virtual address space."
//
// -- so MultiBus address X is virtual 0xF00000 + X, supervisor data, through
// the MMU.  That is what rtl/sun2-vme/sun2_dvma.v does, and this card drives
// it through its Wishbone port: the byte at virtual address VA is the byte at
// Wishbone word VA[23:2], lane VA[1:0].
//
// The PROM builds its IOPB at MultiBus 0x000100 and takes its sector at
// 0x000200 -- addresses that only work because every boot first remaps the
// window.  commands.c:5 is "Always define it until we finger out what to do
// with DVMA", so FAKES1BOOT is unconditional, and both the `b` command and
// auto-boot run setupmap(fakemapinit2) before boot(), which puts virtual
// 0xF00000..0xF3FFFF on physical page 0x180 as ordinary memory.  In the Rev R
// image that table is at 0xEF6F04.  Without it those pages are still TYPE 2
// and the cycle would go straight back out to the bus.
//
// Nothing here checks that an address is inside the window.  It does not have
// to: above it the pages are TYPE 2, a DVMA cycle there finds no card, the
// machine's own bus timeout fires, and the Wishbone access comes back as an
// error -- which is exactly the Slave Acknowledge Error the real card reports
// for memory that did not answer.
//
// ---------------------------------------------------------------------------
// Byte order, twice over
// ---------------------------------------------------------------------------
// The same MultiBus/68000 inversion applies to everything the controller
// fetches, which is why struct xyiopb declares its bytes in swapped pairs:
//
//     IOPB byte N is at virtual address  iopb_va + (N ^ 1)
//
// Sector data is different, and the difference is real rather than an
// oversight.  The manual is explicit that "the 450 reads and writes the IOPB
// in Byte mode" (2.1), while data moves in whatever the throttle byte's BWM
// bit selects -- and no driver in the tree ever sets it, so data moves in
// *word* mode.  A word-mode transfer moves sixteen bits at a time and the
// controller decides which end of the disk word is the low half.  This one
// puts the earlier disk byte on the high half:
//
//     sector byte K is at virtual address  data_va + K
//
// which makes the image on the card a byte-for-byte copy of what the Sun sees
// in memory.  That is the convention any image anyone can actually produce
// already has, because the only way to read a Sun-2 disk is through a
// controller: `dd if=/dev/rxy0a` yields the bytes the controller put in
// memory, not the bits on the platter.  Reversing it would be a two-line
// change here and would need every image reversed with it.
//
module sun2_xy450 #(
    // The 16-bit MultiBus I/O address the card is jumpered to.  The real card
    // compares address bits F..3, so it claims eight bytes and the low three
    // select the register -- which is why 0xEE40 and 0xEE48 can be two
    // different controllers.
    parameter logic [15:0] IO_BASE = 16'hEE40,

    // Where the DVMA window starts in virtual address space.  A property of
    // the machine, not a jumper on the card; see the quote above.
    parameter logic [23:0] DVMA_BASE = 24'hF00000
) (
    input  wire        CLK,
    input  wire        RESET,          // the machine's reset, ie MultiBus INIT

    // ---- MultiBus I/O slave, page-map TYPE 3 -------------------------------
    input  wire        mbio_sel,
    input  wire [15:0] mbio_addr,      // byte address, bit 0 always 0
    input  wire        mbio_we,
    input  wire        mbio_uds_n,     // D15:8, the even CPU byte
    input  wire        mbio_lds_n,     // D7:0,  the odd CPU byte
    input  wire [15:0] mbio_din,
    output wire [15:0] mbio_dout,
    output wire        mbio_hit,
    output wire        mbio_ack,       // this card's MultiBus XACK

    // ---- interrupt ---------------------------------------------------------
    // Jumpered to INT2/ on a Sun-2, autovectored.  A level, not a pulse: it
    // stays asserted until software writes IPND back.
    output wire        int_o,

    // ---- DVMA master, a Wishbone B4 classic port into sun2_dvma ------------
    output wire        wb_cyc_o,
    output wire        wb_stb_o,
    output wire        wb_we_o,
    output wire [3:0]  wb_sel_o,
    output wire [21:0] wb_adr_o,       // word address; byte = {adr, 2'b00}
    output wire [31:0] wb_dat_o,
    input  wire [31:0] wb_dat_i,
    input  wire        wb_ack_i,
    input  wire        wb_err_i,
    // sun2_dvma latches a bus error and refuses further cycles until this is
    // asserted.  On the Ethernet side that latch is cleared by resetting the
    // 82586; here the controller clears it before each command, because a disk
    // controller reports an error and carries on.
    output wire        wb_clr_o,

    // ---- the block back end ------------------------------------------------
    // One 512-byte block at a time through a buffer that lives here; the
    // contract is Inputs/Wish5380/doc/block.md.  The back end never sees a
    // disk address and this side never sees a card.
    output wire        blk_start,      // one cycle: begin a transfer
    output wire        blk_we,         // 1 drains the buffer to the media
    output wire [31:0] blk_lba,
    output wire [7:0]  blk_buf_rdata,  // answers blk_buf_addr, one cycle late
    input  wire        blk_done,
    input  wire        blk_err,
    input  wire        blk_ready,      // media present and initialised
    input  wire [31:0] blk_count,      // capacity, in 512-byte blocks
    input  wire        blk_buf_we,
    input  wire [8:0]  blk_buf_addr,
    input  wire [7:0]  blk_buf_wdata
);

   // ------------------------------------------------------------------
   // Jumper sanity
   // ------------------------------------------------------------------
   // Eight bytes, naturally aligned, because that is the granularity the base
   // address comparator has.  A misaligned base would silently overlap the
   // neighbouring controller's address rather than fail.
   initial begin
      if (IO_BASE[2:0] != 3'h0)
        $fatal(1, "sun2_xy450: I/O base 0x%04x is not 8-byte aligned", IO_BASE);
   end

   // ==================================================================
   // The slave side
   // ==================================================================

   assign mbio_hit = mbio_sel & (mbio_addr[15:3] == IO_BASE[15:3]);

   // Three words of the four.  Word 3 (registers 0x46/0x47) does not exist on
   // the card; it is inside the comparator's eight bytes, so it answers, and
   // it reads as zero.  Nothing in the tree touches it.
   wire sel_reloc = mbio_hit & (mbio_addr[2:1] == 2'd0);   // 0x41 : 0x40
   wire sel_iopba = mbio_hit & (mbio_addr[2:1] == 2'd1);   // 0x43 : 0x42
   wire sel_ctl   = mbio_hit & (mbio_addr[2:1] == 2'd2);   // 0x45 : 0x44

   // One clock of setup and then XACK, which is far inside the machine's
   // twelve-clock bus timeout.  phase == 0 is the first cycle of an access and
   // is the one-shot every side effect keys off, so that a read of the reset
   // register resets the controller exactly once however long AS stays low.
   //
   // The real card is much slower -- "approximately 400 ns" per register, and
   // it stalls a following access by up to 20 us while its 8031 catches up
   // (manual 2.3.3).  Nothing in the tree depends on that; both drivers poll.
   reg [1:0] phase;
   always @(posedge CLK)
     if (RESET | ~mbio_hit)  phase <= 2'd0;
     else if (phase != 2'd2) phase <= phase + 2'd1;

   assign mbio_ack = mbio_hit & (phase != 2'd0);

   wire first  = mbio_hit & (phase == 2'd0);
   wire wr_hi  = first &  mbio_we & ~mbio_uds_n;   // the odd-numbered register
   wire wr_lo  = first &  mbio_we & ~mbio_lds_n;   // the even-numbered one
   wire rd_hi  = first & ~mbio_we & ~mbio_uds_n;

   reg [15:0] reloc;                  // 0x41:0x40
   reg [15:0] iopba;                  // 0x43:0x42

   reg        csr_gbsy;               // 7  GO / BUSY
   reg        csr_err;                // 6  general error
   reg        csr_derr;               // 5  double error
   reg        csr_ipnd;               // 4  interrupt pending
   reg        csr_areq;               // 2  attention request
   reg        csr_aack;               // 1  attention acknowledge
   wire       csr_drdy = blk_ready;   // 0  drive ready / on cylinder

   // ADRM is hard zero: the card is jumpered for 20-bit MultiBus addressing,
   // which is what a MultiBus machine has and what makes both drivers use the
   // 8086-style segment:offset form.
   wire [7:0] csr_rd = {csr_gbsy, csr_err, csr_derr, csr_ipnd,
                        1'b0, csr_areq, csr_aack, csr_drdy};

   assign int_o = csr_ipnd;

   // The high lane is the odd-numbered register of each pair.  A read of 0x45
   // returns nothing meaningful -- the manual gives it no read data and both
   // drivers throw the value away -- so it reads as zero and it is the *act*
   // of reading that matters.
   assign mbio_dout = sel_reloc ? reloc
                    : sel_iopba ? iopba
                    : sel_ctl   ? {8'h00, csr_rd}
                    :             16'h0000;

   // ==================================================================
   // Geometry, per drive type
   // ==================================================================
   // The controller keeps four drive-size slots, selected by the IOPB's Drive
   // Type field, and software fills them in with Set Drive Size.  Each holds
   // the *maximum* value, one less than the count -- section 2.5.12.3, "The
   // IOPB must contain the maximum value of sectors per track minus one."
   //
   // Power-up defaults are Table 2-8, and they matter: the PROM reads block 0
   // with each drive type in turn looking for a label, before it has told the
   // controller anything.
   reg [7:0]  max_head  [0:3];
   reg [7:0]  max_sect  [0:3];
   reg [10:0] max_cyl   [0:3];
   reg [5:0]  head_off  [0:3];
   reg        esd       [0:3];

   integer gi;
   initial begin
      max_head[0] = 8'd18;  max_sect[0] = 8'd31;  max_cyl[0] = 11'd822;  // CDC 9766
      max_head[1] = 8'd4;   max_sect[1] = 8'd31;  max_cyl[1] = 11'd822;  // CDC 9762
      max_head[2] = 8'd19;  max_sect[2] = 8'd45;  max_cyl[2] = 11'd841;  // Fujitsu 2351
      max_head[3] = 8'd254; max_sect[3] = 8'd127; max_cyl[3] = 11'd2046; // maximum
      for (gi = 0; gi < 4; gi = gi + 1) begin
         head_off[gi] = 6'd0;
         esd[gi]      = 1'b0;
      end
   end

   // ==================================================================
   // The sector buffer
   // ==================================================================
   // 512 bytes, one port, shared in time: the back end owns it while a block
   // transfer is in flight and the DMA engine owns it the rest of the time.
   // The two phases never overlap -- a Read fills it and then empties it into
   // memory, a Write does the reverse -- so one port is enough and a true
   // dual-port BRAM would only cost more.
   reg [7:0]  sbuf [0:511];
   reg [7:0]  buf_q;
   reg        blk_busy;

   reg [9:0]  db;                     // byte index within the sector
   reg        dma_buf_we;
   reg [7:0]  dma_buf_wdata;
   // The engine's own port address, held rather than taken from db: db has
   // already moved on by the cycle the write strobe lands, and a buffer that
   // stores every byte one place too far still reads back plausibly -- it is
   // the whole sector shifted by one, which looks like a byte-order bug.
   reg [8:0]  dma_addr;

   wire       buf_we    = blk_busy ? blk_buf_we    : dma_buf_we;
   wire [8:0] buf_addr  = blk_busy ? blk_buf_addr  : dma_addr;
   wire [7:0] buf_wdata = blk_busy ? blk_buf_wdata : dma_buf_wdata;

   always @(posedge CLK) begin
      if (buf_we) sbuf[buf_addr] <= buf_wdata;
      buf_q <= sbuf[buf_addr];
   end

   assign blk_buf_rdata = buf_q;

   // ==================================================================
   // The command engine
   // ==================================================================

   // Completion codes, Table 2-3.  ILLC is SunOS's name for it: the manual
   // calls 0x15 reserved, xyreg.h calls it "unimplemented command", and
   // nothing else claims the value.
   localparam logic [7:0] CC_OK     = 8'h00;
   localparam logic [7:0] CC_OPTO   = 8'h04;  // operation timeout
   localparam logic [7:0] CC_HDNF   = 8'h05;  // header not found: past the end
   localparam logic [7:0] CC_CADR   = 8'h07;  // illegal cylinder address
   localparam logic [7:0] CC_SADR   = 8'h0A;  // illegal sector address
   localparam logic [7:0] CC_MADR   = 8'h0E;  // slave ACK: memory did not answer
   localparam logic [7:0] CC_ILLC   = 8'h15;  // unimplemented command
   localparam logic [7:0] CC_NRDY   = 8'h16;  // drive not ready
   localparam logic [7:0] CC_0CNT   = 8'h17;  // sector count zero
   localparam logic [7:0] CC_HADR   = 8'h20;  // illegal head address

   localparam logic [3:0] CMD_NOP     = 4'h0;
   localparam logic [3:0] CMD_WRITE   = 4'h1;
   localparam logic [3:0] CMD_READ    = 4'h2;
   localparam logic [3:0] CMD_SEEK    = 4'h5;
   localparam logic [3:0] CMD_DRESET  = 4'h6;
   localparam logic [3:0] CMD_RDSTAT  = 4'h9;
   localparam logic [3:0] CMD_SETSIZE = 4'hB;
   localparam logic [3:0] CMD_SELFTST = 4'hC;

   localparam int RESET_CLOCKS = 64;

   localparam logic [4:0] E_IDLE     = 5'd0;
   localparam logic [4:0] E_FETCH    = 5'd1;
   localparam logic [4:0] E_FETCH_W  = 5'd2;
   localparam logic [4:0] E_DECODE   = 5'd3;
   localparam logic [4:0] E_LBA1     = 5'd4;
   localparam logic [4:0] E_LBA2     = 5'd5;
   localparam logic [4:0] E_SECT     = 5'd6;
   localparam logic [4:0] E_BLK_GO   = 5'd7;
   localparam logic [4:0] E_BLK_WAIT = 5'd8;
   localparam logic [4:0] E_OUT_ADDR = 5'd9;   // gather: point at a byte
   localparam logic [4:0] E_OUT_RD   = 5'd10;  // gather: let the buffer settle
   localparam logic [4:0] E_OUT_GET  = 5'd25;  // gather: take it
   localparam logic [4:0] E_OUT_REQ  = 5'd11;
   localparam logic [4:0] E_OUT_W    = 5'd12;
   localparam logic [4:0] E_IN_REQ   = 5'd13;
   localparam logic [4:0] E_IN_W     = 5'd14;
   localparam logic [4:0] E_IN_PUT   = 5'd26;  // scatter into the buffer
   localparam logic [4:0] E_SECT_END = 5'd15;
   localparam logic [4:0] E_STATUS   = 5'd16;
   localparam logic [4:0] E_WB       = 5'd17;
   localparam logic [4:0] E_WB_W     = 5'd18;
   localparam logic [4:0] E_FINISH   = 5'd19;
   localparam logic [4:0] E_IOPB_END = 5'd20;
   localparam logic [4:0] E_NEXT     = 5'd21;
   localparam logic [4:0] E_ATTN     = 5'd22;
   localparam logic [4:0] E_ATTN_REQ = 5'd23;
   localparam logic [4:0] E_ATTN_W   = 5'd24;

   // How many IOPBs one Go may execute.  The real card has a two-second
   // watchdog per IOPB and would spin on a chain that pointed back at itself;
   // this is that watchdog, counted rather than timed, and it reports the code
   // the manual gives for it.  SunOS builds chains of at most five -- one per
   // unit plus the controller's own -- so nothing legitimate comes near it.
   localparam int CHAIN_LIMIT = 64;

   reg [4:0]  est;
   reg [7:0]  iopb [0:23];
   reg [4:0]  ib;                     // IOPB byte index
   reg [7:0]  cc;                     // completion code being assembled
   reg        hard;                   // this completion is a hard error

   reg [23:0] iopb_va;
   reg [23:0] data_va;
   reg [15:0] sect_left;
   reg [31:0] lba;
   reg [10:0] cur_cyl;
   reg [7:0]  cur_head;
   reg [7:0]  cur_sect;
   reg [19:0] lba_t;

   reg        in_creset;
   reg [7:0]  creset_ctr;
   reg        clr_dvma;

   // The chain.  chain_reloc is latched at Go because every IOPB in a chain is
   // relocated by the same registers -- "All IOPBs in a chain must be located
   // within the 64K-byte memory block starting at the base address in the IOPB
   // Relocation Registers" -- and the driver writes them once at probe and
   // never again.
   reg [15:0] chain_reloc;
   reg [15:0] chain_next;   // this IOPB's Next IOPB Address, bytes 12 and 13
   reg        do_chain;     // ... and whether CHEN said to believe it
   reg [6:0]  chain_cnt;

   // ------------------------------------------------------------------
   // The bus port
   // ------------------------------------------------------------------
   // One transaction moves `bus_len` bytes, one to four, starting at
   // bus_va[1:0] within the addressed longword.  The IOPB is fetched and
   // written back a byte at a time, because its bytes are inverted
   // individually and gathering them would only move that arithmetic
   // somewhere less obvious; sector data moves four at a time.
   //
   // Four rather than two.  A 32-bit Wishbone access becomes at most two 68010
   // cycles inside sun2_dvma, and it holds the bus request across both of them
   // -- "we keep it across both halves of one Wishbone access rather than
   // re-arbitrating between them" -- so the arbitration, which is the
   // expensive half of a DVMA cycle, happens once per four bytes instead of
   // once per byte.  That is 128 round trips per sector rather than 512.
   //
   // It is worth the byte-lane algebra.  Byte-at-a-time measured about 20 KB/s
   // booting SunOS, which put the kernel load alone at some thirty seconds of
   // simulated time and four hours of wall clock.
   reg        bus_req, bus_we;
   reg [23:0] bus_va;
   reg [2:0]  bus_len;      // bytes in this transaction, 1..4
   reg [31:0] bus_wdat;     // already positioned in its lanes

   // SEL is `bus_len` contiguous bytes starting at the lane bus_va[1:0].  Five
   // bits wide on the way there because (1 << 4) - 1 is zero in four.
   wire [4:0] bus_selmask = (5'd1 << bus_len) - 5'd1;

   assign wb_cyc_o = bus_req;
   assign wb_stb_o = bus_req;
   assign wb_we_o  = bus_we;
   assign wb_adr_o = bus_va[23:2];
   assign wb_sel_o = bus_selmask[3:0] << bus_va[1:0];
   assign wb_dat_o = bus_wdat;
   assign wb_clr_o = clr_dvma;

   // A single byte, for the IOPB.  Writes replicate across all four lanes so
   // that whichever one SEL picks carries it.
   wire [7:0] bus_rd = wb_dat_i[8*bus_va[1:0] +: 8];

   // ------------------------------------------------------------------
   // Chunking a sector
   // ------------------------------------------------------------------
   // db is the offset of the *start* of the current chunk within the sector.
   // A chunk runs to the end of the longword it starts in, or to the end of
   // the sector, whichever comes first -- so an unaligned data address costs
   // one short transaction at each end and nothing else.  SunOS's buffers come
   // from the mainbus mapper and are page-aligned in practice, but the IOPB
   // can name any address and this has to be right for all of them.
   reg [2:0]  ck;           // byte index within the chunk
   reg [31:0] rd_stage;     // a read chunk, waiting to be scattered

   wire [23:0] chunk_va   = data_va + {14'h0, db};
   wire [1:0]  chunk_lane = chunk_va[1:0];
   wire [2:0]  chunk_room = 3'd4 - {1'b0, chunk_lane};
   wire [9:0]  chunk_left = 10'd512 - db;
   wire [2:0]  chunk_len  = (chunk_left >= {7'h0, chunk_room}) ? chunk_room
                                                               : chunk_left[2:0];
   wire        chunk_last = (chunk_left <= {7'h0, chunk_len});

   // Fields of the fetched IOPB, by controller byte number.
   wire       f_aud   = iopb[0][7];
   wire       f_relo  = iopb[0][6];
   wire       f_chen  = iopb[0][5];
   wire       f_ien   = iopb[0][4];
   // "INTERRUPT ON EACH IOPB -- When interrupts are enabled, and IEI is set,
   // the 450 interrupts each time it completes an IOPB."  SunOS sets IEN and
   // clears IEI (xy.c:709-716, `xy->xy_ie = 1; xy->xy_intrall = 0;`), so it
   // wants exactly one interrupt per chain; a second one arriving after the
   // driver has started the next chain is read as that chain completing.
   wire       f_iei   = iopb[1][6];
   wire [3:0] f_cmd   = iopb[0][3:0];
   wire       f_done  = iopb[2][0];
   wire [1:0] f_dt    = iopb[5][7:6];
   wire [1:0] f_unit  = iopb[5][1:0];

   // Data Transfer Address, IOPB bytes C..F.  "If RELO is clear, the 450
   // generates Multibus data addresses as 16-bit values, sets bits 16 through
   // 23 to zero, and ignores the Data Relocation Address bytes."
   wire [19:0] mb_data_addr = f_relo
        ? (({{4{1'b0}}, iopb[15], iopb[14]} << 4) + {4'h0, iopb[13], iopb[12]})
        : {4'h0, iopb[13], iopb[12]};

   wire [15:0] iopb_sectors = {iopb[11], iopb[10]};

   // The drive this IOPB names.  Only unit 0 is fitted; the other three report
   // themselves absent, which is the answer the PROM's and the kernel's probe
   // loops are built around.
   wire       drive_ok = (f_unit == 2'd0) & blk_ready;

   // Geometry for the drive type this IOPB selects.
   wire [7:0]  g_mhead = max_head[f_dt];
   wire [7:0]  g_msect = max_sect[f_dt];
   wire [10:0] g_mcyl  = max_cyl[f_dt];

   wire       is_xfer   = (f_cmd == CMD_READ) | (f_cmd == CMD_WRITE);
   wire       needs_geo = is_xfer | (f_cmd == CMD_SEEK);

   assign blk_start = (est == E_BLK_GO);
   assign blk_we    = (f_cmd == CMD_WRITE);
   assign blk_lba   = lba;

   integer wi;

   always @(posedge CLK)
     if (RESET) begin
        reloc      <= 16'h0000;
        iopba      <= 16'h0000;
        csr_gbsy   <= 1'b0;
        csr_err    <= 1'b0;
        csr_derr   <= 1'b0;
        csr_ipnd   <= 1'b0;
        csr_areq   <= 1'b0;
        csr_aack   <= 1'b0;
        in_creset  <= 1'b0;
        creset_ctr <= 8'h00;
        est        <= E_IDLE;
        bus_req    <= 1'b0;
        bus_we     <= 1'b0;
        blk_busy   <= 1'b0;
        dma_buf_we <= 1'b0;
        dma_addr   <= 9'h0;
        bus_len    <= 3'd1;
        bus_wdat   <= 32'h0;
        ck         <= 3'd0;
        rd_stage   <= 32'h0;
        clr_dvma   <= 1'b0;
        cc         <= CC_OK;
        hard       <= 1'b0;
        chain_reloc<= 16'h0000;
        chain_next <= 16'h0000;
        do_chain   <= 1'b0;
        chain_cnt  <= 7'd0;
        for (wi = 0; wi < 24; wi = wi + 1) iopb[wi] <= 8'h00;
     end else begin
        dma_buf_we <= 1'b0;
        clr_dvma   <= 1'b0;

        // ------------------------------------------------------------
        // Register writes
        // ------------------------------------------------------------
        if (wr_hi & sel_reloc) reloc[15:8] <= mbio_din[15:8];  // 0x41
        if (wr_lo & sel_reloc) reloc[7:0]  <= mbio_din[7:0];   // 0x40
        if (wr_hi & sel_iopba) iopba[15:8] <= mbio_din[15:8];  // 0x43
        if (wr_lo & sel_iopba) iopba[7:0]  <= mbio_din[7:0];   // 0x42

        // The CSR, register 0x44.  Bit 7 starts a command; bits 6 and 4 are
        // write-one-to-clear, which the manual calls Error Reset and Interrupt
        // Reset and recommends over a Controller Reset because they are three
        // times quicker; bit 2 is the attention request, which the 450 answers
        // with AACK.
        if (wr_lo & sel_ctl) begin
           if (mbio_din[6]) begin csr_err <= 1'b0; csr_derr <= 1'b0; end
           if (mbio_din[4])       csr_ipnd <= 1'b0;
           csr_areq <= mbio_din[2];
           if (~mbio_din[2])      csr_aack <= 1'b0;
        end

        // "While the controller is busy, only bits 2 and 4 of the CSR have
        // write access to the 450's registers.  Any other access attempts
        // result in a Busy Conflict error."  The kernel checks for BUSY or
        // INTR before it writes anything and panics rather than provoke this,
        // so nothing in the tree should ever see it; it is here because a
        // driver that gets it wrong should be told, not quietly obeyed.
        if (csr_gbsy &
            ((wr_hi & (sel_reloc | sel_iopba | sel_ctl)) |
             (wr_lo & (sel_reloc | sel_iopba)) |
             (wr_lo &  sel_ctl & |(mbio_din[7:0] & 8'hEB))))
          csr_err <= 1'b1;

        // ------------------------------------------------------------
        // Controller reset: a *read* of register 0x45
        // ------------------------------------------------------------
        // "the 450 clears the registers along with IPND, ERR and DERR;
        // reselects the last selected drive, latches the Ready status, and
        // releases the drive.  GBSY remains set during a Controller Reset."
        // Both drivers lean on this: the PROM reads it after every single
        // command, which is why it rewrites relocation and offset before every
        // Go, and the kernel uses it as the last step of error recovery.
        if (rd_hi & sel_ctl) begin
           reloc      <= 16'h0000;
           iopba      <= 16'h0000;
           csr_err    <= 1'b0;
           csr_derr   <= 1'b0;
           csr_ipnd   <= 1'b0;
           csr_areq   <= 1'b0;
           csr_aack   <= 1'b0;
           csr_gbsy   <= 1'b1;
           in_creset  <= 1'b1;
           creset_ctr <= RESET_CLOCKS[7:0];
           est        <= E_IDLE;
           bus_req    <= 1'b0;
           bus_we     <= 1'b0;
           blk_busy   <= 1'b0;
        end else if (in_creset) begin
           if (creset_ctr != 8'h00) creset_ctr <= creset_ctr - 8'h01;
           else begin
              in_creset <= 1'b0;
              csr_gbsy  <= 1'b0;
           end
        end else begin

           // The attention protocol.  AACK does not mean "noted", it means
           // "the chain is standing still and you may edit it", so it is
           // granted only where that is true: immediately when the controller
           // is idle, and otherwise at the boundary between IOPBs, in
           // E_IOPB_END below.  Granting it in the middle of a transfer -- as
           // this did before there was a chain to protect -- invites software
           // to rewrite links the controller is about to follow.
           //
           // SunOS 3.4 never uses any of this: XY_ATTN and XY_ACK are declared
           // in sundev/xycreg.h and referenced by no C file in the tree.  4.x
           // does, which is why it is here rather than tied off.
           if (csr_areq & ~csr_aack & (est == E_IDLE)) csr_aack <= 1'b1;

           // ---------------------------------------------------------
           // The IOPB engine
           // ---------------------------------------------------------
           case (est)
             E_IDLE:
               // `xyaddr->xy_csr = XY_GO`
               if (wr_lo & sel_ctl & mbio_din[7] & ~csr_gbsy) begin
                  csr_gbsy    <= 1'b1;
                  clr_dvma    <= 1'b1;   // forget any earlier DVMA fault
                  cc          <= CC_OK;
                  hard        <= 1'b0;
                  chain_reloc <= reloc;
                  chain_cnt   <= 7'd0;
                  // "The IOPB Address Registers and IOPB Relocation Registers
                  // combine to form a 20-bit physical memory address", and
                  // IOPB relocation happens whenever the relocation registers
                  // are non-zero, whatever RELO says.
                  iopb_va  <= DVMA_BASE +
                              {4'h0, ({reloc[15:0], 4'h0} + {4'h0, iopba[15:0]})};
                  ib       <= 5'd0;
                  est      <= E_FETCH;
               end

             // --- fetch the 24-byte IOPB, byte N at iopb_va + (N ^ 1) ---
             E_FETCH: begin
                bus_va  <= iopb_va + {19'h0, ib ^ 5'd1};
                bus_len <= 3'd1;
                bus_we  <= 1'b0;
                bus_req <= 1'b1;
                est     <= E_FETCH_W;
             end

             E_FETCH_W:
               if (wb_err_i) begin
                  bus_req <= 1'b0;
                  cc      <= CC_MADR;
                  hard    <= 1'b1;
                  est     <= E_STATUS;
               end else if (wb_ack_i) begin
                  bus_req   <= 1'b0;
                  iopb[ib]  <= bus_rd;
                  if (ib == 5'd23) est <= E_DECODE;
                  else begin ib <= ib + 5'd1; est <= E_FETCH; end
               end

             // --- decide what this IOPB asks for ---
             E_DECODE: begin
                cur_cyl  <= {iopb[9][2:0], iopb[8]};
                cur_head <= iopb[6];
                cur_sect <= iopb[7];
                data_va  <= DVMA_BASE + {4'h0, mb_data_addr};

                // Captured here because the next fetch overwrites iopb[].
                // chain_next is taken unconditionally and do_chain is what
                // gates its use: on the tail of a chain the driver clears
                // xy_chain and leaves xy_nxtoff at whatever it was when this
                // same IOPB was in the middle of an earlier chain
                // (xy.c:744-745), so believing it is a walk into a stale
                // pointer and a DMA into last time's buffer.
                do_chain   <= f_chen;
                chain_next <= {iopb[19], iopb[18]};   // bytes 13 and 12

                if (f_done) begin
                   // "System software must clear (zero) Status Bytes 1 and 2
                   // before giving the IOPB to the 450.  If DONE is set, the
                   // 450 reads the IOPB and considers it complete (therefore,
                   // it cannot execute the IOPB again)."  Considered complete,
                   // so the chain moves on rather than stopping: there is
                   // nothing to write back, but the IOPBs behind it are still
                   // owed their turn.
                   est <= E_IOPB_END;
                end else if (needs_geo & ~drive_ok) begin
                   cc <= CC_NRDY; hard <= 1'b1; est <= E_STATUS;
                end else if (needs_geo & ({iopb[9][2:0], iopb[8]} > g_mcyl)) begin
                   cc <= CC_CADR; hard <= 1'b1; est <= E_STATUS;
                end else if (needs_geo & (iopb[6] > g_mhead)) begin
                   cc <= CC_HADR; hard <= 1'b1; est <= E_STATUS;
                end else if (is_xfer & (iopb[7] > g_msect)) begin
                   cc <= CC_SADR; hard <= 1'b1; est <= E_STATUS;
                end else if (is_xfer & (iopb_sectors == 16'h0)) begin
                   cc <= CC_0CNT; hard <= 1'b1; est <= E_STATUS;
                end else begin
                   case (f_cmd)
                     CMD_READ, CMD_WRITE: begin
                        sect_left <= iopb_sectors;
                        est       <= E_LBA1;
                     end
                     CMD_NOP, CMD_SELFTST, CMD_RDSTAT, CMD_SEEK:
                       est <= E_STATUS;
                     CMD_DRESET: begin
                        // Fault clear then recalibrate, so the heads finish at
                        // cylinder 0 and the updated IOPB says so.
                        cur_cyl <= 11'd0;
                        est     <= E_STATUS;
                     end
                     CMD_SETSIZE: begin
                        max_head[f_dt] <= iopb[6];
                        max_sect[f_dt] <= iopb[7];
                        max_cyl [f_dt] <= {iopb[9][2:0], iopb[8]};
                        head_off[f_dt] <= iopb[16][5:0];
                        esd     [f_dt] <= iopb[16][7];
                        est            <= E_STATUS;
                     end
                     default: begin
                        cc <= CC_ILLC; hard <= 1'b1; est <= E_STATUS;
                     end
                   endcase
                end
             end

             // --- CHS to LBA, once; after that it only has to increment ---
             // lba = (cyl * heads + head) * sectors + sector, and the
             // controller's own carry order -- sector, then head, then
             // cylinder (2.5.2.3.7) -- is exactly what makes that linear.
             E_LBA1: begin
                lba_t <= cur_cyl * ({1'b0, g_mhead} + 9'd1) + {12'h0, cur_head};
                est   <= E_LBA2;
             end

             E_LBA2: begin
                lba <= lba_t * ({1'b0, g_msect} + 9'd1) + {24'h0, cur_sect};
                est <= E_SECT;
             end

             // --- one sector ---
             E_SECT:
               if (lba >= blk_count) begin
                  // Off the end of the media.  The real card would find no
                  // matching sector header within a revolution plus five
                  // sectors and say so, and that is the answer the PROM's
                  // drive-type probe is built to expect.
                  cc <= CC_HDNF; hard <= 1'b1; est <= E_STATUS;
               end else if (f_cmd == CMD_READ) begin
                  est <= E_BLK_GO;
               end else begin
                  db  <= 10'd0;
                  est <= E_IN_REQ;
               end

             E_BLK_GO: begin
                blk_busy <= 1'b1;
                est      <= E_BLK_WAIT;
             end

             E_BLK_WAIT:
               if (blk_done) begin
                  blk_busy <= 1'b0;
                  if (blk_err) begin
                     // The media failed.  Header Not Found is the closest the
                     // 450's vocabulary comes to "that sector did not read".
                     cc <= CC_HDNF; hard <= 1'b1; est <= E_STATUS;
                  end else if (f_cmd == CMD_READ) begin
                     db  <= 10'd0;
                     est <= E_OUT_ADDR;
                  end else begin
                     est <= E_SECT_END;
                  end
               end

             // --- Read: sector buffer out to memory ---
             // Gather the chunk out of the buffer first, then move it in one
             // transaction.  The buffer read is registered and single-ported,
             // so each byte costs an address cycle and a settling cycle -- but
             // those are local, and what they save is a DVMA round trip.
             E_OUT_ADDR: begin
                ck       <= 3'd0;
                dma_addr <= db[8:0];
                est      <= E_OUT_RD;
             end

             E_OUT_RD: est <= E_OUT_GET;

             E_OUT_GET: begin
                bus_wdat[8*({1'b0, chunk_lane} + ck) +: 8] <= buf_q;
                if (ck == chunk_len - 3'd1)
                  est <= E_OUT_REQ;
                else begin
                   dma_addr <= db[8:0] + {6'h0, ck} + 9'd1;
                   ck       <= ck + 3'd1;
                   est      <= E_OUT_RD;
                end
             end

             E_OUT_REQ: begin
                bus_va  <= chunk_va;
                bus_len <= chunk_len;
                bus_we  <= 1'b1;
                bus_req <= 1'b1;
                est     <= E_OUT_W;
             end

             E_OUT_W:
               if (wb_err_i) begin
                  bus_req <= 1'b0; bus_we <= 1'b0;
                  cc <= CC_MADR; hard <= 1'b1; est <= E_STATUS;
               end else if (wb_ack_i) begin
                  bus_req <= 1'b0; bus_we <= 1'b0;
                  db  <= db + {7'h0, chunk_len};
                  est <= chunk_last ? E_SECT_END : E_OUT_ADDR;
               end

             // --- Write: memory in to the sector buffer ---
             E_IN_REQ: begin
                bus_va  <= chunk_va;
                bus_len <= chunk_len;
                bus_we  <= 1'b0;
                bus_req <= 1'b1;
                ck      <= 3'd0;
                est     <= E_IN_W;
             end

             E_IN_W:
               if (wb_err_i) begin
                  bus_req <= 1'b0;
                  cc <= CC_MADR; hard <= 1'b1; est <= E_STATUS;
               end else if (wb_ack_i) begin
                  bus_req  <= 1'b0;
                  rd_stage <= wb_dat_i;
                  est      <= E_IN_PUT;
               end

             // One byte per cycle into the buffer.  The last one is still in
             // flight when this leaves for E_BLK_GO -- dma_buf_we is high for
             // the cycle after it is set, and blk_busy does not take the port
             // until the end of that same cycle, so it lands.
             E_IN_PUT: begin
                dma_buf_we    <= 1'b1;
                dma_addr      <= db[8:0] + {6'h0, ck};
                dma_buf_wdata <= rd_stage[8*({1'b0, chunk_lane} + ck) +: 8];
                if (ck == chunk_len - 3'd1) begin
                   db  <= db + {7'h0, chunk_len};
                   est <= chunk_last ? E_BLK_GO : E_IN_REQ;
                end else
                  ck <= ck + 3'd1;
             end

             // --- advance the disk address and go round again ---
             E_SECT_END: begin
                data_va   <= data_va + 24'd512;
                lba       <= lba + 32'd1;
                sect_left <= sect_left - 16'd1;
                if (cur_sect == g_msect) begin
                   cur_sect <= 8'd0;
                   if (cur_head == g_mhead) begin
                      cur_head <= 8'd0;
                      cur_cyl  <= cur_cyl + 11'd1;
                   end else
                      cur_head <= cur_head + 8'd1;
                end else
                  cur_sect <= cur_sect + 8'd1;

                if (sect_left == 16'd1) est <= E_STATUS;
                else                    est <= E_SECT;
             end

             // --- fill in what goes back into the IOPB ---
             E_STATUS: begin
                // Forget any fault from the transfer before writing the status
                // bytes.  sun2_dvma stops the channel dead after a bus error --
                // it was written for an 82586, where a fault means the whole
                // command block is suspect -- but a disk controller has no such
                // latch, and the address that failed was the *data* address.
                // Without this, a bad data address loses its own completion
                // code: the writeback errors too, DERR sets, and the IOPB comes
                // back with the zeroes the driver put there, which reads as
                // success.
                clr_dvma <= 1'b1;

                iopb[2] <= {hard, 2'b00, 3'b001, 1'b0, 1'b1};  // ERRS, type 450, DONE
                iopb[3] <= cc;

                if (f_cmd == CMD_RDSTAT) begin
                   // Section 2.5.10.3: the size of the Drive Type asked about,
                   // and the state of the unit asked about.
                   iopb[6]  <= g_mhead;
                   iopb[7]  <= g_msect;
                   iopb[8]  <= g_mcyl[7:0];
                   iopb[9]  <= {5'h0, g_mcyl[10:8]};
                   // Drive status, byte A.  ONCL and DRDY are active low --
                   // "true if zero" in xyreg.h -- so a ready drive sitting on
                   // a cylinder reads as zero here, and isspinning() waits
                   // until it does.
                   iopb[10] <= {~drive_ok, ~drive_ok, 6'h0};
                   iopb[11] <= 8'd3;              // firmware revision C
                   iopb[12] <= 8'h00;             // 512 bytes per sector
                   iopb[13] <= 8'h02;
                   iopb[14] <= g_msect + 8'd1;    // sectors per track, actual
                   iopb[16] <= {esd[f_dt], 1'b0, head_off[f_dt]};
                end else if (f_aud) begin
                   // "the 450 updates the current IOPB upon its completion.
                   // The Sector, Head, Cylinder, Sector Count and Data Address
                   // bytes reflect the result of IOPB execution."
                   iopb[6]  <= cur_head;
                   iopb[7]  <= cur_sect;
                   iopb[8]  <= cur_cyl[7:0];
                   iopb[9]  <= {5'h0, cur_cyl[10:8]};
                   if (is_xfer) begin
                      iopb[10] <= sect_left[7:0];
                      iopb[11] <= sect_left[15:8];
                      iopb[12] <= data_va[7:0];
                      iopb[13] <= data_va[15:8];
                   end
                end

                ib  <= 5'd2;
                est <= E_WB;
             end

             // --- and write it back, status bytes first ---
             E_WB: begin
                bus_va   <= iopb_va + {19'h0, ib ^ 5'd1};
                bus_len  <= 3'd1;
                bus_wdat <= {4{iopb[ib]}};   // SEL picks the lane
                bus_we   <= 1'b1;
                bus_req  <= 1'b1;
                est      <= E_WB_W;
             end

             E_WB_W:
               if (wb_err_i) begin
                  bus_req <= 1'b0; bus_we <= 1'b0;
                  // "DOUBLE ERROR ... usually means the 450 cannot properly
                  // DMA the Status bytes to memory as a result of an error."
                  csr_derr <= 1'b1;
                  csr_err  <= 1'b1;
                  est      <= E_FINISH;
               end else if (wb_ack_i) begin
                  bus_req <= 1'b0; bus_we <= 1'b0;
                  if (ib == 5'd3) begin
                     // Bytes 4 and 5 are the host's own throttle and drive
                     // selection; the controller never changes them.
                     if (f_aud | (f_cmd == CMD_RDSTAT)) begin
                        ib  <= 5'd6;
                        est <= E_WB;
                     end else
                       est <= E_IOPB_END;
                  end else if (ib == 5'd16) begin
                     est <= E_IOPB_END;
                  end else begin
                     ib  <= ib + 5'd1;
                     est <= E_WB;
                  end
               end

             // --- one IOPB is over; decide what the chain does next ---
             E_IOPB_END: begin
                // Per-IOPB interrupt, if this IOPB asked for one.  The
                // end-of-chain interrupt is E_FINISH's business.
                if (f_ien & f_iei) csr_ipnd <= 1'b1;

                if (hard)
                  // "The 450 terminates the chain with an error if one IOPB
                  // has a hard error."  Everything behind it is left exactly
                  // as the driver wrote it, xy_complete still clear, because
                  // xyintr() skips those and xychain() re-issues them verbatim.
                  est <= E_FINISH;
                else if (csr_areq) begin
                   csr_aack <= 1'b1;
                   est      <= E_ATTN;
                end else if (do_chain)
                  est <= E_NEXT;
                else
                  est <= E_FINISH;
             end

             // --- follow the link ---
             E_NEXT:
               if (chain_cnt == CHAIN_LIMIT[6:0]) begin
                  // A chain that points back at itself.  See CHAIN_LIMIT.
                  cc <= CC_OPTO; hard <= 1'b1; est <= E_STATUS;
               end else begin
                  chain_cnt <= chain_cnt + 7'd1;
                  iopb_va   <= DVMA_BASE +
                               {4'h0, ({chain_reloc, 4'h0} + {4'h0, chain_next})};
                  cc        <= CC_OK;
                  hard      <= 1'b0;
                  ib        <= 5'd0;
                  est       <= E_FETCH;
               end

             // --- paused for the Attention protocol ---
             // "System software may now remove those IOPBs marked complete,
             // and/or may add new IOPBs to the chain (you may modify CHEN and
             // the Next IOPB Address ...)".  GBSY stays set throughout, which
             // is the case 2.6.2.5 tells software to expect and handle.
             E_ATTN:
               if (~csr_areq) begin
                  ib  <= 5'd0;
                  est <= E_ATTN_REQ;
               end

             // Re-read this IOPB's command byte and next pointer, because
             // appending to the chain is exactly what the pause was for.
             // Acknowledging and then not looking again would drop the
             // appended IOPB with nothing to show for it.
             E_ATTN_REQ: begin
                bus_va  <= iopb_va + (ib == 5'd0 ? 24'h000001 :   // byte 00
                                      ib == 5'd1 ? 24'h000013 :   // byte 12
                                                   24'h000012);   // byte 13
                bus_len <= 3'd1;
                bus_we  <= 1'b0;
                bus_req <= 1'b1;
                est     <= E_ATTN_W;
             end

             E_ATTN_W:
               if (wb_err_i) begin
                  bus_req <= 1'b0;
                  cc <= CC_MADR; hard <= 1'b1; est <= E_STATUS;
               end else if (wb_ack_i) begin
                  bus_req <= 1'b0;
                  case (ib)
                    5'd0: do_chain          <= bus_rd[5];
                    5'd1: chain_next[7:0]   <= bus_rd;
                    default: chain_next[15:8] <= bus_rd;
                  endcase
                  if (ib == 5'd2) est <= E_IOPB_END;
                  else begin ib <= ib + 5'd1; est <= E_ATTN_REQ; end
               end

             E_FINISH: begin
                csr_gbsy <= 1'b0;
                if (hard) csr_err <= 1'b1;
                // "If set, the 450 generates a hardware interrupt, and sets
                // IPND in the CSR, after completing a single IOPB."  Neither
                // driver in the tree enables this on a MultiBus machine: the
                // PROM polls, and the kernel's xypoll() reads IPND back out.
                if (f_ien) csr_ipnd <= 1'b1;
                est <= E_IDLE;
             end

             default: est <= E_IDLE;
           endcase
        end
     end

endmodule
