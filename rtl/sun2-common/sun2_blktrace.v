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
   reg        is_write;
   wire       rd_byte  = blk_buf_we;                       // card -> buffer
   wire       wr_seen  = busy && is_write && !blk_buf_we &&
                         (blk_buf_addr != last_addr);      // buffer -> card

   // **buf_rdata answers buf_addr one cycle late** (Inputs/Wish5380/doc/block.md:58),
   // so the byte belonging to an address change has not arrived in the cycle the
   // change is seen.  Fold it one cycle later.
   //
   // Getting this wrong is not a trace that looks broken -- it is a trace full of
   // plausible signatures that are simply not the block's, and this cost a whole
   // experiment.  The first run of this instrument folded rdata in the cycle of
   // the change, which made 127 of 171 sectors of a copied file look wrong; `cmp'
   // on the machine then put the file's first difference at byte 4385, proving
   // the sectors before it were byte-identical and the signatures, not the data,
   // were at fault.  The LBA half was unaffected and its verdict stood.
   reg        wr_byte;
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
            wr_byte   <= 1'b0;
            last_addr <= 9'h1FF;         // so the first address is a change
            cur_key   <= {blk_we, blk_lba[30:0]};
         end

         // last_addr tracks the address as it changes; the fold trails it by one.
         if (wr_seen) last_addr <= blk_buf_addr;
         wr_byte <= wr_seen;

         if (busy && (rd_byte || wr_byte)) sig <= sig_next;

         // Safe against the trailing byte: blk_done comes after the card's CRC and
         // response phase, many cycles after the last buffer access, so the
         // delayed fold above has always retired by the time this fires.
         if (busy && blk_done) begin
            busy            <= 1'b0;
            t_key[wp]       <= cur_key;
            t_sig[wp]       <= (rd_byte || wr_byte) ? sig_next : sig;
            wp              <= wp + 1'b1;
            nx              <= nx + 16'd1;
         end
      end
   end

   assign rd_data = rd_half ? {16'h0000, t_sig[rd_addr]} : t_key[rd_addr];
   assign wr_ptr  = {{(16 - DEPTH_LOG2){1'b0}}, wp};
   assign n_xfer  = nx;

endmodule
