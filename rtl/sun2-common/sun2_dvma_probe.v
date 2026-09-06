`timescale 1ns / 1ps

//
// Did the master latch the data its own bus cycle asked for?
//
// This watches one pairing and nothing else.  sun2_wishbone_bridge loads
// P_DATA_OUT on `wb_ack_i & issued', and sun2_dvma captures dvma_din exactly
// **one clock later**, at the edge that ends S_LATCH -- the bridge presents its
// data the clock after it acknowledges, and the master is built to that.  Two
// registers, one clock apart, in different modules, with nothing but that
// convention holding them together.
//
// It is the last asymmetric thing left in the disk-write path.  Everything else
// that could put a wrong 16-bit word into a sector has been eliminated by
// measurement: misdirection, the SD path, blk_sd, the SCSI engine, BrianHG's
// write cache, metastability, bus arbitration, and AS/DS timing.  And the fault
// is memory-to-device only -- `dd if=/dev/rsd0a | sum' twice agrees, so the
// direction where DVMA *writes* memory is clean.  A wrong word in one 68010
// cycle of a longword read is precisely what a broken pairing produces.
//
// ---- What counts as broken -------------------------------------------------
//
//   * no_load  -- the master captured with no bridge load in the clock before.
//     Whatever P_DATA_OUT held then belonged to some earlier transaction.
//   * late_load -- the bridge loaded on the *same* edge the master captured.
//     Both are registered off that edge, so the master takes the value from
//     before the load: again an earlier transaction's data.
//
// Both are "the master latched somebody else's word", which is the fault being
// chased, and neither can be seen from outside the chip.
//
// ---- Why counters and a first-event latch, not a trace ---------------------
//
// The fault is about one word in a hundred thousand.  A circular buffer deep
// enough to be likely to contain one is not affordable here, and would anyway
// record mostly healthy cycles.  Counters run for ever, and latching the first
// violation keeps the evidence that matters: where it was, and what the master
// took instead.
//
module sun2_dvma_probe (
    input  wire        clk,
    input  wire        rst,

    // ---- the two halves of the pairing, watched and not touched ----------
    input  wire        brg_load,    // bridge: P_DATA_OUT loads at this edge
    input  wire        brg_half,    // ... and which 16-bit half it took
    input  wire        dvma_busy,   // master: its bus cycle is in progress
    input  wire        dvma_latch,  // master: capturing dvma_din at this edge
    input  wire [15:0] dvma_din,    // what it is capturing
    input  wire [23:1] dvma_a,      // and for which address

    // The last unchecked span.  dvma_din is sun2_fpga's P_DOUT: a 20-way
    // combinational priority mux whose MATCH_MEM arm carries the bridge's
    // registered P_DATA_OUT.  Nothing has ever checked that a DVMA memory read
    // actually comes out of that arm -- and a wide combinational mux sampled by
    // a register is exactly the shape that gives one wrong word, rarely,
    // placement-sensitively, and invisibly in simulation, where zero-delay
    // logic cannot glitch.
    //
    // The wrong values say the same: 2f2d is "/-" and 2e2e is "..", string
    // bytes of the kind another mux source supplies, not a damaged pattern.
    input  wire [15:0] brg_dout,    // wishbone_out, the MATCH_MEM arm
    input  wire        match_mem,   // ... and whether it should be selected

    // 32-bit, because the 16-bit ones wrap and a control that wraps bounds
    // nothing: see the VIO counters in wb_to_mig_ui.
    output reg  [31:0] n_mux,       // memory reads the master captured
    output reg  [31:0] n_mux_bad,   // ... where P_DOUT was not the bridge's word
    output reg  [31:0] n_pat32,     // ... whose word was the pattern
    output reg  [31:0] n_pat32_bad, // ... and was not

    // ---- readout ---------------------------------------------------------
    output wire [15:0] n_latch,     // captures seen, mod 65536
    output wire [15:0] n_no_load,   // ... with no load in the clock before
    output wire [15:0] n_late_load, // ... with a load on the same edge
    // Bridge loads, counted on their own.  The CPU produces these constantly,
    // so a zero here means the probe or its readout is dead, while a zero
    // n_latch beside a healthy n_load means the master's strobe is.  Without
    // it, "all counters zero" has two explanations and no way to choose.
    output wire [15:0] n_load,
    // A free-running clock counter.  It proves the whole instrument at once --
    // the clock arrives, a counter increments, the value crosses the module
    // boundary, and the readout decodes it -- so a zero anywhere else can be
    // read as a fact about the machine instead of a question about the probe.
    // This one exists because four separate guards silently disconnected the
    // signals above, and nothing in the readout could tell that from a healthy
    // bus.
    output wire [15:0] n_clk,
    // Loads that took the *wrong half* of the 32-bit word.  The bridge selects
    // by P_ADR_IN[1] at the load edge; the master asks for dvma_a[1].  These
    // must agree, and if they ever do not the master gets sixteen bits of the
    // neighbouring word -- which is the exact granule of the corruption being
    // chased, and something the one-load-per-cycle check above cannot see.
    output wire [15:0] n_half_bad,

    // ---- the pattern check, at the master's capture ----------------------
    // The same check sun2_blktrace does at the card, moved to the *other* end
    // of the span still under suspicion.  tools/patwr -u's pattern repeats
    // every sector, and a buffer-cache block is at least 512-byte aligned, so
    // the halfword index within a sector is dvma_a[8:1] and the expected word
    // is 0x8000 | that.  If a word is already wrong here, the fault is at or
    // below DDR3; if it is right here and wrong at the card, it is in
    // sun2_dvma's assembly or the controller's sector buffer.
    //
    // **It arms itself on four consecutive matches** rather than being switched
    // on by the host.  Ordinary traffic cannot arm it (2^-32), the pattern arms
    // it after four words, and it needs no clear, no extra port and no
    // interaction that would have to share the JTAG chain with the console.
    //
    // Both byte orders are counted because the bridge crosses lanes and getting
    // it wrong would cost a build to discover: whichever counter is large says
    // which order the master sees, and only that one's bad count means anything.
    output wire [15:0] n_pat_a,      // matches, {80, idx}
    output wire [15:0] n_pat_b,      // matches, {idx, 80}  (the other order)
    output wire [15:0] n_pat_bad,    // armed, and did not match
    output wire [15:0] n_pat_first,  // the first wrong word
    output wire [22:0] n_pat_faddr,
    output wire [23:1] first_a,
    output wire [15:0] first_d,
    output wire        seen
);

   reg load_d;                      // a load happened in the previous clock

   reg [15:0] latches, no_load, late_load, loads;
   reg [15:0] heartbeat, half_bad;
   reg [15:0] pat_a, pat_b, pat_bad, pat_first;
   reg [22:0] pat_faddr;
   reg [2:0]  pat_run;
   reg        pat_seen, pat_pend;
   reg [15:0] pend_d;
   reg [22:0] pend_a;

   wire [15:0] pat_exp_a = {8'h80, dvma_a[8:1]};
   wire [15:0] pat_exp_b = {dvma_a[8:1], 8'h80};
   wire        pat_hit_a = (dvma_din == pat_exp_a);
   wire        pat_hit_b = (dvma_din == pat_exp_b);
   reg        load_half;
   reg [23:1] f_a;
   reg [15:0] f_d;
   reg        f_seen;

   // Exclusive on purpose.  A load arriving on the capture edge is a late_load,
   // not a no_load: data did arrive, it arrived one edge too late to be the
   // value taken.  Counting it as both would inflate no_load and make the two
   // numbers impossible to reason about separately.
   // **Count the loads across the master's whole cycle, not in the clock before
   // the capture.**  The first version checked the clock before, on the theory
   // that the bridge presents data the clock after it acknowledges and the
   // master captures a clock after seeing DTACK.  Measured on the board, that
   // flagged *every* capture -- 11282 of 11282 -- which is not a machine that
   // boots, so the model was wrong and not the bus.  W_ACK is
   // `(wb_ack_i & issued) | done', and the DTACK the master actually waits on
   // is gated further by sun2_fpga's C_S chain, so the load lands somewhere
   // inside the cycle rather than one clock before its end.
   //
   // The property that does hold: exactly one load between the strobes going on
   // and the data being taken.  None means the master took whatever
   // P_DATA_OUT still held from an earlier transaction; more than one means a
   // second load overwrote this cycle's data before it was read.
   reg [3:0] loads_this_cycle;

   // The mux check.  Compared on the capture edge, against the value the bridge
   // is holding -- so this is the mux and the routing, nothing above them.
   wire [15:0] pat_word = {8'h80, dvma_a[8:1]};
   always @(posedge clk)
     if (rst) begin
        n_mux <= 32'd0;  n_mux_bad <= 32'd0;
        n_pat32 <= 32'd0; n_pat32_bad <= 32'd0;
     end else if (dvma_latch && match_mem) begin
        n_mux <= n_mux + 32'd1;
        if (dvma_din != brg_dout) n_mux_bad <= n_mux_bad + 32'd1;
        // The pattern arm is its own control: it counts only words that look
        // like tools/patwr -u's, so it says whether the check saw any.
        if (brg_dout == pat_word) begin
           n_pat32 <= n_pat32 + 32'd1;
           if (dvma_din != pat_word) n_pat32_bad <= n_pat32_bad + 32'd1;
        end
     end
   wire bad_no_load   = dvma_latch & (loads_this_cycle == 4'd0);
   wire bad_late_load = dvma_latch & (loads_this_cycle >  4'd1);

   always @(posedge clk) begin
      if (rst) begin
         load_d    <= 1'b0;
         latches   <= 16'd0;
         no_load   <= 16'd0;
         late_load <= 16'd0;
         loads     <= 16'd0;
         heartbeat <= 16'd0;
         half_bad  <= 16'd0;
         pat_a     <= 16'd0; pat_b <= 16'd0; pat_bad <= 16'd0;
         pat_run   <= 3'd0;  pat_seen <= 1'b0; pat_pend <= 1'b0;
         loads_this_cycle <= 4'd0;
         f_seen    <= 1'b0;
      end else begin
         heartbeat <= heartbeat + 16'd1;
         load_d <= brg_load;

         // Reset the per-cycle tally when the master is not in a cycle, and
         // saturate rather than wrap: two is already "more than one".
         if (!dvma_busy)                        loads_this_cycle <= 4'd0;
         else if (brg_load && loads_this_cycle != 4'd15) begin
            loads_this_cycle <= loads_this_cycle + 4'd1;
            load_half        <= brg_half;      // which half this load took
         end
         if (brg_load) loads <= loads + 16'd1;

         if (dvma_latch) begin
            latches <= latches + 16'd1;
            if (bad_no_load)   no_load   <= no_load   + 16'd1;
            // Only meaningful when a load actually happened in this cycle.
            if (!bad_no_load && (load_half != dvma_a[1]))
                               half_bad  <= half_bad  + 16'd1;
            if (bad_late_load) late_load <= late_load + 16'd1;

            // The pattern check, counting only an **isolated** miss -- a word
            // that does not match with matching words on both sides.
            //
            // The first version armed on a run of four and then counted every
            // miss, which on the board gave 1018: the master reads plenty that
            // is not the pattern (metadata, the zero fill, other files), and
            // once armed all of it was flagged.  A real corruption is one wrong
            // word inside a sector that otherwise matches, so requiring a match
            // *after* the miss separates the two without needing to know where
            // sectors begin.
            //
            // pend holds the candidate for one capture: if the next word
            // matches it was isolated and counts; if it does not, this is
            // ordinary traffic and the check disarms.
            if (pat_hit_a) begin
               pat_a <= pat_a + 16'd1;
               if (pat_run != 3'd4) pat_run <= pat_run + 3'd1;
               if (pat_pend) begin
                  pat_pend <= 1'b0;
                  pat_bad  <= pat_bad + 16'd1;
                  if (!pat_seen) begin
                     pat_seen  <= 1'b1;
                     pat_first <= pend_d;
                     pat_faddr <= pend_a;
                  end
               end
            end else begin
               if (pat_run == 3'd4 && !pat_pend) begin
                  pat_pend <= 1'b1;          // candidate, not yet counted
                  pend_d   <= dvma_din;
                  pend_a   <= dvma_a;
               end else begin
                  pat_pend <= 1'b0;          // two misses: not the pattern
                  pat_run  <= 3'd0;
               end
            end
            if (pat_hit_b) pat_b <= pat_b + 16'd1;

            // The first one only: a later violation cannot overwrite the
            // evidence of the first, which is the one with a clean history
            // behind it.
            if ((bad_no_load | bad_late_load) & ~f_seen) begin
               f_seen <= 1'b1;
               f_a    <= dvma_a;
               f_d    <= dvma_din;
            end
         end
      end
   end

   assign n_latch     = latches;
   assign n_no_load   = no_load;
   assign n_late_load = late_load;
   assign n_load      = loads;
   assign n_clk       = heartbeat;
   assign n_half_bad  = half_bad;
   assign n_pat_a     = pat_a;
   assign n_pat_b     = pat_b;
   assign n_pat_bad   = pat_bad;
   assign n_pat_first = pat_first;
   assign n_pat_faddr = pat_faddr;
   assign first_a     = f_a;
   assign first_d     = f_d;
   assign seen        = f_seen;

endmodule
