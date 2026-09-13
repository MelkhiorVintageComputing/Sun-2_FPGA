// sun2_clobber.v -- who writes into a buffer after the pattern did?
//
// Every instrument in this tree so far has asked a question of one transfer:
// was this write issued, did this read come back the way it went in, was this
// word the pattern when the master took it.  All of them read zero on runs
// that corrupt, while `ARRIVED BAD' counts the corruption one for one.  So
// memory really does hold program text where tools/patwr -u put its pattern,
// and what none of them can say is *how it got there*.  That is a question of
// history, not of a transfer, and it needs state that outlives one cycle.
//
// This keeps one bit per 512-byte block of physical memory: "the last write
// into this block was the pattern".  7 MiB is 14,336 blocks, so the table is
// one 18 Kb RAM.  Against it:
//
//   cand   a write that is NOT the pattern, into a block whose last write WAS.
//          Ordinary reuse of a buffer does this too, so a candidate is only a
//          candidate until the next write into the same block says which:
//   reuse  ... the next write into the block is not the pattern either.  A
//          page being refilled with something else, a run.  Not interesting.
//   iso    ... the next write into the block IS the pattern: one foreign word
//          in the middle of a copy.  `behind' if it landed below the offset
//          the copy had reached -- then nothing will overwrite it, and it is
//          exactly the corruption.  Ahead of the copy it is harmless.
//   lone   ... no further write into the block before the timeout.  A single
//          word dropped into a finished buffer, which is the other shape the
//          corruption could have.
//
//   ghost  the read side: a read that is NOT the pattern, from a block whose
//          last write WAS.  If memory holds text where no write of text was
//          ever seen, this is what counts it -- the write never landed, or
//          the read did not come from where the bridge thinks.  rdpat is its
//          control, pattern read back from such a block.
//
//   partial  a pattern write issued with only one data strobe.  The adapter
//          latches wb_sel on the same clock as the address and data, and the
//          write-coverage check tested address and data but never the lanes,
//          so a lane missing from a pattern write would leave the old text in
//          place under a check that reads it as written.  DECA's WRITE_VERIFY
//          masked its comparison by wb_sel and was blind to it the same way.
//
// So the counters partition the possibilities.  With ARRIVED BAD at N on the
// same run: iso-behind + lone near N says a foreign write did it, and names
// whether a master or the CPU wrote it; ghost near N with those at zero says
// no write put the text there at all.  Both zero says this model of the fault
// is wrong, which is also worth knowing.
//
// `trig' is for the ILA, and exists because a counter cannot show the cycles
// before an event.  `harm' (iso-behind or lone) is the trigger.  It is decided
// some writes after the foreign one, which is why the capture wants its
// trigger position near the end of the window: the event is in the pre-trigger
// samples.  `xact' is high one clock after every memory transaction, when the
// debug bus carries its data in either direction, and is the storage
// qualifier -- 4096 samples are then 4096 memory transactions rather than
// 4096 clocks.
//
// The pattern is tools/patwr -u's: halfword i of a 512-byte sector is
// 0x8000 | i, and a buffer-cache block is 512-byte aligned in physical memory,
// so the expected word is a function of the address alone.  The same
// prediction sun2_wishbone_bridge's write-coverage check makes.
//
// Timing.  The table is read on the clock the event happens and written on the
// next, so two events must be at least two clocks apart for the second to see
// the first.  A memory transaction cannot be shorter: the bridge issues on
// C_S6 and the slave registers its acknowledgement.  tb_clobber runs events at
// exactly that spacing.
//
// Verilog-2001, like the rest of rtl/sun2-common.

module sun2_clobber #(
   parameter integer TIMEOUT_WR  = 16,     // writes elsewhere before `lone'
   parameter integer TIMEOUT_CLK = 65535   // ... or clocks, whichever first
) (
   input              CLK,
   input              RESET_n,

   input              wr_fire,   // a memory write request goes out this clock
   input      [22:1]  adr,       // physical: [22:9] block, [8:1] halfword index
   input      [15:0]  wdat,
   input      [1:0]   wlanes,    // {UDS, LDS} asserted
   input              dvma,      // the cycle is a master's

   input              rd_load,   // a memory read is answered this clock
   input      [15:0]  rdat,      // ... with this halfword

   // {xact, ghost, harm, lone, iso, cand}, one-clock pulses
   output reg [5:0]   trig,

   // Twelve 32-bit counters, [31:0] first:
   //   0 patwr  1 partial  2 cand  3 cand_dvma  4 reuse  5 iso
   //   6 iso_behind  7 lone  8 collide  9 rdpat  10 ghost  11 ghost_dvma
   output     [383:0] n_flat,
   // [63:0]   last harmful hit: {14'h0, kind[1:0] (1 iso, 2 lone), behind,
   //                             dvma, block[13:0], off[7:0], next[7:0],
   //                             data[15:0]}
   // [127:64] last ghost:       {25'h0, dvma, block[13:0], off[7:0],
   //                             data[15:0]}
   output     [127:0] rec_flat
);

   localparam integer NBLK = 16384;
   localparam [7:0]  TWR   = TIMEOUT_WR - 1;
   localparam [15:0] TCLK  = TIMEOUT_CLK;

   // ---- the table ---------------------------------------------------------
   reg tbl [0:NBLK-1];
   integer i;
   initial for (i = 0; i < NBLK; i = i + 1) tbl[i] = 1'b0;

   // ---- stage 1: the event, and the table's answer about its block --------
   reg        v1, w1, pat1, full1, dvma1, st1;
   reg [13:0] blk1;
   reg [7:0]  off1;
   reg [15:0] dat1;

   wire [15:0] ev_dat = wr_fire ? wdat : rdat;
   wire        ev_pat = (ev_dat == {8'h80, adr[8:1]});

   // Arming.  A block is marked only by a *run*: a pattern write whose
   // previous write was the pattern at the word before it -- in the same
   // block, or word 255 of the block below for word 0.  One pattern write
   // alone marks nothing.
   //
   // The first bitstream marked a block on any single pattern-shaped word, and
   // on the board, before patwr had written a byte, SunOS's own boot had
   // counted 33,776 ghosts, 63 lones and 381 partials: {0x80, index} is not a
   // rare word, and one coincidence marked a block of kernel data whose every
   // later read and write then counted against it.  Every instrument in this
   // tree has needed a rule like this; see CLAUDE.md.  The previous *write*
   // is what is remembered, not the previous event, because a copy out of a
   // user page alternates reads of the source with writes of the destination.
   reg        prev_pat;
   reg [13:0] prev_blk;
   reg [7:0]  prev_off;
   wire seq = pat1 & prev_pat &
              (((blk1 == prev_blk) & (off1 == prev_off + 8'd1)) |
               ((blk1 == prev_blk + 14'd1) & (prev_off == 8'hFF) & (off1 == 8'h00)));
   wire arm = st1 | seq;

   always @(posedge CLK) begin
      st1 <= tbl[adr[22:9]];
      if (v1 & w1) tbl[blk1] <= pat1 & arm;
   end

   always @(posedge CLK) begin
      v1    <= RESET_n & (wr_fire | rd_load);
      w1    <= wr_fire;
      blk1  <= adr[22:9];
      off1  <= adr[8:1];
      dat1  <= ev_dat;
      pat1  <= ev_pat;
      full1 <= (wlanes == 2'b11);
      dvma1 <= dvma;
   end

   // ---- stage 2: decide ---------------------------------------------------
   reg [31:0] n [0:11];
   reg        pend, pend_dvma;
   reg [13:0] pend_blk;
   reg [7:0]  pend_off;
   reg [15:0] pend_dat;
   reg [7:0]  pend_wr;
   reg [15:0] pend_clk;
   reg [63:0] rec_hit, rec_ghost;

   // Working copies, blocking, so a resolution and a new candidate on the same
   // clock see each other in order.  Assigned only in the block below.
   reg        p;
   reg        is_cand;

   task resolve_lone;
      begin
         n[7]    <= n[7] + 32'd1;
         trig[3] <= 1'b1;
         trig[2] <= 1'b1;
         rec_hit <= {14'h0, 2'd2, 1'b0, pend_dvma, pend_blk, pend_off, 8'h00,
                     pend_dat};
         p = 1'b0;
      end
   endtask

   always @(posedge CLK) begin
      trig    <= 6'b0;
      trig[5] <= wr_fire | rd_load;

      if (~RESET_n) begin
         for (i = 0; i < 12; i = i + 1) n[i] <= 32'd0;
         pend      <= 1'b0;
         pend_dvma <= 1'b0;
         pend_blk  <= 14'h0;
         pend_off  <= 8'h0;
         pend_dat  <= 16'h0;
         pend_wr   <= 8'h0;
         pend_clk  <= 16'h0;
         rec_hit   <= 64'h0;
         rec_ghost <= 64'h0;
         trig      <= 6'b0;
         prev_pat  <= 1'b0;
         prev_blk  <= 14'h0;
         prev_off  <= 8'h0;
      end else begin
         p = pend;

         // Nothing more came for that block in time.
         if (p) begin
            if (pend_clk == TCLK) resolve_lone;
            else                               pend_clk <= pend_clk + 16'd1;
         end

         if (v1 & w1) begin
            if (pat1)                n[0] <= n[0] + 32'd1;
            if (pat1 & ~full1 & arm) n[1] <= n[1] + 32'd1;
            prev_pat <= pat1;
            prev_blk <= blk1;
            prev_off <= off1;

            // First, what this write says about the pending candidate.
            if (p & (blk1 == pend_blk)) begin
               if (pat1) begin
                  n[5]    <= n[5] + 32'd1;
                  trig[1] <= 1'b1;
                  if (pend_off < off1) begin
                     n[6]    <= n[6] + 32'd1;
                     trig[3] <= 1'b1;
                     rec_hit <= {14'h0, 2'd1, 1'b1, pend_dvma, pend_blk,
                                 pend_off, off1, pend_dat};
                  end
               end else
                 n[4] <= n[4] + 32'd1;
               p = 1'b0;
            end else if (p) begin
               if (pend_wr == TWR) resolve_lone;
               else                                   pend_wr <= pend_wr + 8'd1;
            end

            // Then whether the write is a candidate of its own.  A write that
            // just resolved the candidate in its own block cannot be one: the
            // candidate's write already cleared that block's bit.
            is_cand = ~pat1 & st1;
            if (is_cand) begin
               n[2] <= n[2] + 32'd1;
               if (dvma1) n[3] <= n[3] + 32'd1;
               trig[0] <= 1'b1;
               if (p)
                 n[8] <= n[8] + 32'd1;    // keep the older one
               else begin
                  p = 1'b1;
                  pend_blk  <= blk1;
                  pend_off  <= off1;
                  pend_dat  <= dat1;
                  pend_dvma <= dvma1;
                  pend_wr   <= 8'h0;
                  pend_clk  <= 16'h0;
               end
            end
         end

         if (v1 & ~w1 & st1) begin
            if (pat1)
              n[9] <= n[9] + 32'd1;
            else begin
               n[10] <= n[10] + 32'd1;
               if (dvma1) n[11] <= n[11] + 32'd1;
               trig[4]   <= 1'b1;
               rec_ghost <= {25'h0, dvma1, blk1, off1, dat1};
            end
         end

         pend <= p;
      end
   end

   genvar g;
   generate
      for (g = 0; g < 12; g = g + 1) begin : flat
         assign n_flat[32*g +: 32] = n[g];
      end
   endgenerate
   assign rec_flat = {rec_ghost, rec_hit};

endmodule
