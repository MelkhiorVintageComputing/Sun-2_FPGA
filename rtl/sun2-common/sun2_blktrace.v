`timescale 1ns / 1ps

//
// Every block transfer the machine asks for, in order: read or write, which
// LBA, and a signature of the bytes that moved.
//
// This exists to settle one question.  Large file writes come back corrupted
// from the micro-SD card and small ones do not, on all three disk controllers,
// and there are two surviving explanations that no test so far separates:
//
//   * the data is damaged somewhere between memory and the card, or
//   * the block is written, intact, to the **wrong LBA** -- which would leave
//     the file's own blocks holding whatever was there before *and* clobber
//     somebody else's, and both of those have been seen.
//
// The discriminator is ground truth on each side.  This gives one half: where
// the machine really wrote.  The other half comes from the filesystem itself,
// by reading the file's inode block list off the card afterwards.  If the two
// agree, misdirection is dead and the corruption is in transit; if one traced
// LBA differs, it says exactly where the block went.
//
// ---- Why it free-runs -----------------------------------------------------
//
// There is no trigger and no arming, deliberately.  Arming would have to come
// over In-System Sources and Probes, and ISSP and juart-terminal cannot both
// hold the JTAG chain -- so a probe armed from the host is a probe that cannot
// be armed while anyone is typing the command that provokes the fault.  A
// circular buffer needs no host at all: run the workload, halt the machine,
// then take the chain and read out the last DEPTH transfers.
//
// ---- Depth ----------------------------------------------------------------
//
// A 104 KB file is thirteen 8 KiB filesystem blocks, and each is sixteen
// sectors, so one `cp' is about 208 entries before sync and the halt add more.
// 1024 is comfortable; the 256 the ILA-style trace defaults to is not.
//
// ---- The signature --------------------------------------------------------
//
// Sixteen bits folded over the 512 bytes as they pass.  The LBAs alone answer
// "where was it written", but not "which block was that" -- and if block N of a
// file turns up at the wrong address, the signature is what proves it was that
// block rather than an inference from ordering.
//
// It is taken at the block seam, which is the one place both directions are
// visible: on a read blk_sd fills the sector buffer and buf_we strobes each
// byte, and on a write it walks buf_addr and the controller answers on
// buf_rdata.  The write side therefore folds on a *change of address* rather
// than on a strobe, because there is no strobe to fold on -- which is exact so
// long as blk_sd visits each address once, and it does.
//
module sun2_blktrace #(
    parameter integer DEPTH_LOG2 = 10          // 1024 entries
) (
    input  wire        clk,
    input  wire        rst,

    // ---- the block seam, watched and not touched ------------------------
    input  wire        blk_start,
    input  wire        blk_we,
    input  wire [31:0] blk_lba,
    input  wire        blk_done,
    input  wire        blk_buf_we,
    input  wire [8:0]  blk_buf_addr,
    input  wire [7:0]  blk_buf_wdata,   // card -> buffer, on a read
    input  wire [7:0]  blk_buf_rdata,   // buffer -> card, on a write

    // ---- readout --------------------------------------------------------
    input  wire [DEPTH_LOG2-1:0] rd_addr,
    input  wire                  rd_half,   // 0: {we, lba}; 1: signature
    output wire [31:0]           rd_data,
    output wire [15:0]           wr_ptr,    // next entry to be written
    output wire [15:0]           n_xfer     // transfers seen, mod 65536
);

   localparam integer DEPTH = (1 << DEPTH_LOG2);

   // ------------------------------------------------------------------
   // The signature
   // ------------------------------------------------------------------
   // A rotate-and-add fold rather than a plain XOR: XOR alone cannot tell two
   // blocks apart when they hold the same bytes in a different order, and a
   // sector of a file and a sector of zeroes-with-one-byte-set are exactly the
   // pair this has to distinguish.
   reg [15:0] sig;
   reg [8:0]  last_addr;
   reg        busy;

   // The two directions fold on different events, and each must be inhibited
   // during the other.  A read strobes buf_we once per byte and leaves the
   // address standing in between -- which the address-change detector below
   // reads as a byte of its own, folding the buffer's *stale* contents into a
   // read's signature.  So the write side is gated on the transfer direction
   // rather than on buf_we alone.
   // The write side folds on a change of address, and it has to know where the
   // walk *starts* or it folds a byte that is not part of the sector.
   //
   // blk_sd parks sbuf_addr at 0 before the data phase (blk_sd.sv:683) and then
   // walks 0,1,..,511 and wraps back to 0, consuming the byte for address A in
   // the clock it sets A+1.  So the 512 folds wanted are the 512 transitions
   // *after* the address reaches 0, and `armed' is what waits for that.  Seeding
   // last_addr with a sentinel instead folds sbuf[0] twice (513 bytes, measured
   // on a board: 255 of 585 written sectors matched s0,s0,s1..511 where 83
   // matched the plain 512), and seeding it with whatever the address happens to
   // hold at blk_start folds a byte of the *previous* transfer whenever a write
   // follows a read, which leaves the address at 511.
   reg        is_write;
   reg        armed;
   wire       park     = busy && is_write && !armed && (blk_buf_addr == 9'd0);
   wire       rd_byte  = blk_buf_we && !is_write;          // card -> buffer
   wire       wr_seen  = busy && is_write && armed && !blk_buf_we &&
                         (blk_buf_addr != last_addr);      // buffer -> card

   // Fold rdata **in the cycle the address changes**, which looks off by one and
   // is not.  buf_rdata answers buf_addr one cycle late
   // (Inputs/Wish5380/doc/block.md:58), and blk_sd consumes the byte for address
   // A in the same clock it increments to A+1 (blk_sd.sv:709-714) -- so in the
   // clock the change appears, rdata is still answering A, and that is exactly
   // the byte just consumed.  The two lateness cancel.
   //
   // This was "corrected" once to fold a cycle later and that rotated every
   // write signature by one byte, which is what the board then showed: 109 of
   // 642 written sectors matched a source file rotated by one and 18 matched it
   // plain, against ~20 expected by chance.  The reads, whose path is unchanged,
   // matched 183 of 184 in the same capture and were what proved the arithmetic
   // and the source files right while the write side was wrong.
   wire [7:0] the_byte = blk_buf_we ? blk_buf_wdata : blk_buf_rdata;

   wire [15:0] sig_next = {sig[14:0], sig[15]} + {8'h00, the_byte};

   // ------------------------------------------------------------------
   // The buffer
   // ------------------------------------------------------------------
   reg [31:0] t_key  [0:DEPTH-1];      // {we, lba[30:0]}
   reg [15:0] t_sig  [0:DEPTH-1];

   reg [DEPTH_LOG2-1:0] wp;
   reg [15:0]           nx;

   // The entry is written at blk_done rather than at blk_start, so the
   // signature it carries is the one for the transfer that just happened.  A
   // trace whose address and data came from different transfers would be worse
   // than no trace: it would look consistent.
   reg [31:0] cur_key;

   always @(posedge clk) begin
      if (rst) begin
         wp   <= {DEPTH_LOG2{1'b0}};
         nx   <= 16'd0;
         busy <= 1'b0;
         sig  <= 16'd0;
      end else begin
         if (blk_start) begin
            busy      <= 1'b1;
            is_write  <= blk_we;
            sig       <= 16'd0;
            armed     <= 1'b0;
            // Seed from the address as it stands, NOT from a sentinel.  A
            // sentinel guarantees the first comparison reports a change, and
            // blk_sd already has the address parked at 0 when a transfer
            // starts -- so the sentinel folded sbuf[0] an extra time and every
            // signature was a fold of 513 bytes with the first one counted
            // twice.  Measured both ways on a board: with the fold taken in the
            // cycle of the change 255 written sectors matched s0,s0,s1..511 and
            // 83 matched the plain 512, and with it taken a cycle later 287
            // matched s0,s1..511,s0 -- the duplicate simply moved.  Seeded from
            // the address, the first real transition folds sbuf[0] and the
            // wrap past 511 folds sbuf[511]: 512 bytes, once each.
            last_addr <= blk_buf_addr;
            cur_key   <= {blk_we, blk_lba[30:0]};
         end

         if (park) begin armed <= 1'b1; last_addr <= 9'd0; end
         if (wr_seen) last_addr <= blk_buf_addr;
         if (busy && (rd_byte || wr_seen)) sig <= sig_next;

         if (busy && blk_done) begin
            busy            <= 1'b0;
            t_key[wp]       <= cur_key;
            t_sig[wp]       <= (rd_byte || wr_seen) ? sig_next : sig;
            wp              <= wp + 1'b1;
            nx              <= nx + 16'd1;
         end
      end
   end

   assign rd_data = rd_half ? {16'h0000, t_sig[rd_addr]} : t_key[rd_addr];
   assign wr_ptr  = {{(16 - DEPTH_LOG2){1'b0}}, wp};
   assign n_xfer  = nx;

endmodule
