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
    output wire [23:1] first_a,
    output wire [15:0] first_d,
    output wire        seen
);

   reg load_d;                      // a load happened in the previous clock

   reg [15:0] latches, no_load, late_load, loads;
   reg [15:0] heartbeat, half_bad;
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
   assign first_a     = f_a;
   assign first_d     = f_d;
   assign seen        = f_seen;

endmodule
