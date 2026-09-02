`timescale 1ns / 1ps
//
// A trace recorder for the MMU debug bus, read out over JTAG.
//
// The DECA's answer to the Wukong's ILA, and it exists because the two boards'
// vendors disagree about what a logic analyser is.  Vivado's ILA is IP that
// `syn/build.tcl' can generate and `syn/ila_capture.tcl' can drive from a
// script.  Quartus's SignalTap is a *GUI* artefact: `quartus_stp' offers
// ::quartus::stp for running an acquisition and nothing at all for creating
// one, so an .stp cannot be produced by this project's flow -- which is
// scripted end to end and has to stay that way, because an instrument that
// takes a person and a mouse to rebuild is one nobody rebuilds.
//
// So the buffer is ordinary RTL and the readout is In-System Sources and
// Probes, which *is* scriptable and which `tools/deca_reset.tcl' already uses.
// Three consequences, all of them good: it simulates, so the trigger and the
// unwrapping are proved before a bitstream is spent; it is vendor-neutral, so
// the Wukong could read the same instrument if its ILA ever became
// inconvenient; and the capture is a file rather than a waveform window.
//
// ----------------------------------------------------------------- what it taps
//
// `dbg_bus' unchanged, 118 bits, whose field map lives at the assignment in
// sun2_fpga.v and is checked against the signals it claims to carry on every
// clock edge of every simulated boot by tb_sun2.  That check is why this
// module can slice the bus by bit number without adding a second place for the
// map to drift: the map has one owner and one test.
//
// Two fields are extracted here, and only two, because they are the trigger:
//
//   dbg_bus[47]     P_AS_n     -- a bus cycle is happening
//   dbg_bus[73:61]  P_A[23:11] -- which 2 KiB page it is on
//
// A page rather than an address on purpose.  The question this was built for
// is why a probe of the SCSI registers at 0xEE2800 stops raising a bus error
// above 12.5 MHz, and `sdprobe' (rsun/sys/sunstand/sd.c) touches `dma_count'
// at 0xEE2804 and the base at 0xEE2800 -- so a page-granular trigger catches
// the whole probe rather than one word of it, and one parameter retargets it
// at any other device.
//
// --------------------------------------------------------------- the buffer
//
// A circular buffer that is always writing, frozen POST samples after the
// first trigger, which is what makes the samples *before* the event available.
// That is not a luxury here: the leading hypothesis is that something counted
// in clocks meets something fixed in time, and the cycle that matters may be
// the one before the probe rather than the probe itself.
//
// After `done', `wr_ptr' points at the next slot that would have been written,
// which is the oldest sample; the host reads from there and wraps.
//
module sun2_trace
  #(parameter          WIDTH      = 118,
    parameter          DEPTH_LOG2 = 8,
    // Samples kept after the trigger.  DEPTH-POST-1 are kept before it.
    parameter          POST       = 192)
   (input  wire                  clk,
    input  wire                  rst,        // active high
    input  wire [WIDTH-1:0]      dbg_bus,

    // A[23:11] of the page to trigger on, and a run/hold level.  Both are
    // ports rather than parameters because the first version made them
    // build-time constants and that was a mistake worth naming: it costs a
    // 25-minute Quartus run to ask a different question, and -- worse -- when
    // the trigger never fires there is no way to tell a wrong address from a
    // broken recorder without spending another one.  With `arm' low the
    // capture is held cleared, so the host sets a page, releases arm, and can
    // retry as often as it likes on one bitstream.
    input  wire [12:0]           trig_page,
    // Function code to qualify on, and whether to.  Without it the trigger is
    // useless on a device page: the boot PROM writes the *page map entry* for
    // a page at a control-space (FC 3) address carrying that page's own
    // address bits, so the first cycle to touch 0xEE2800 is the map setup and
    // not the probe, and a capture of the map setup looks like a perfectly
    // healthy two-clock DTACK. A device probe is FC 5.
    input  wire [2:0]            trig_fc,
    input  wire                  trig_fc_en,
    // ...and whether to require the cycle to be an alternate master's.  A
    // device page is touched by the CPU as well as by a card that masters, and
    // the CPU almost always gets there first -- so a page-and-function-code
    // trigger cannot catch a DVMA cycle at all when software has set the
    // transfer up through the same page.  This is the only qualifier that
    // separates them: top_fpga muxes both masters onto the same wires on
    // purpose, so no combination of address and function code can.
    input  wire                  trig_dvma_en,
    // ...and whether trig_page names a *physical* page rather than a virtual
    // one.  Software maps a device wherever it likes -- the PROM puts this
    // board at 0xEE2800 and SunOS somewhere else entirely -- so a virtual
    // trigger can only watch one of them, and which one is not knowable from
    // outside.  The page map's output is the same either way.
    input  wire                  trig_phys_en,
    // ...and, for the case a page cannot separate, the rest of the address.
    // Every 68010 exception vector lives in the same 2 KiB page -- an address
    // error is at VBR+0xC and the level-5 clock autovector at VBR+0x74 -- so a
    // page-granular trigger fires on the next timer tick and never on the
    // fault.  A[10:1] tells them apart.  Off by default, because it is the
    // unusual case: most triggers want a page.
    input  wire [9:0]            trig_addr,
    input  wire                  trig_addr_en,
    // ...and whether the cycle has to be a *failing* one.  A page a process
    // uses normally is touched by every other process using the same library,
    // so triggering on the address alone catches the healthy access and the
    // fault is long gone by the time the buffer fills.  ERR is the machine's
    // own verdict on the cycle, so this selects the fault and nothing else.
    input  wire                  trig_err_en,
    // A capture filter, separate from the trigger.  Without one the buffer
    // records every cycle, so its span in real time is set by how fast the
    // machine executes -- 4096 samples is 246 us here, and the thing being
    // watched for (a stray write to one word of an exception frame) can be
    // further away than that while the kernel handles a page fault.  With it,
    // only cycles whose address is inside [filt_lo, filt_hi] are stored, so
    // the same buffer covers the whole of the handling and holds nothing but
    // the traffic that could be the culprit.  The trigger still decides *when*
    // capture stops; this decides *what* goes in.
    input  wire [12:0]           filt_page,    // A[23:11] to keep
    input  wire                  filt_en,
    // One sample per bus *cycle* rather than per clock.  The recorder samples
    // every clock, and a 68010 cycle here is about twelve of them, so eight or
    // so identical samples are stored for every cycle and the buffer's span in
    // real time is an eighth of what the depth suggests.  With this set only
    // the first clock of a cycle is stored -- the address, function code,
    // strobes and error terms are all valid from the start, and the data is
    // not (it arrives late and lags a transaction anyway, which every reader
    // of these captures already has to account for).
    input  wire                  one_per_cycle,
    input  wire                  arm,

    input  wire [DEPTH_LOG2-1:0] rd_addr,
    output reg  [WIDTH-1:0]      rd_data,
    output wire [DEPTH_LOG2-1:0] wr_ptr,
    output wire                  triggered,
    output wire                  done);

   localparam DEPTH = (1 << DEPTH_LOG2);

   // Uninitialised, which is what lets Quartus infer an M9K rather than
   // building it out of logic -- the trap this project already records is
   // about *initialised* memory, and sram_sync.v is the precedent for this
   // shape inferring cleanly on both vendors.
   reg [WIDTH-1:0]      mem [0:DEPTH-1];

   reg [DEPTH_LOG2-1:0] wp;
   reg                  trig_q, done_q;
   reg [DEPTH_LOG2:0]   post_cnt;

   wire        as_low = ~dbg_bus[47];
   wire [12:0] page   =  dbg_bus[73:61];
   wire [9:0]  alow   =  dbg_bus[60:51];   // A[10:1], below the page
   wire        err    =  dbg_bus[1];        // ERR: this cycle is being failed
   reg         as_low_q;
   always @(posedge clk) as_low_q <= (rst ? 1'b0 : as_low);
   wire        cyc_start = as_low && !as_low_q;   // AS just fell

   wire        on_page   = as_low && (page == filt_page);
   wire        keep      = (one_per_cycle ? cyc_start : 1'b1)
                           && (!filt_en || on_page);
   wire [2:0]  fc     =  dbg_bus[50:48];
   wire        dvma   =  dbg_bus[101];
   wire [11:0] ppage  =  dbg_bus[17:6];    // ma_pmap2devices, the translation
   wire        hit    = as_low
                        && (trig_phys_en ? (ppage == trig_page[11:0])
                                         : (page  == trig_page))
                        && (!trig_fc_en || (fc == trig_fc))
                        && (!trig_addr_en || (alow == trig_addr))
                        && (!trig_err_en  || err)
                        && (!trig_dvma_en || dvma);

   assign wr_ptr    = wp;
   assign triggered = trig_q;
   assign done      = done_q;

   always @(posedge clk) begin
      if (rst || !arm) begin
	 wp       <= {DEPTH_LOG2{1'b0}};
	 trig_q   <= 1'b0;
	 done_q   <= 1'b0;
	 post_cnt <= POST[DEPTH_LOG2:0];
      end else if (!done_q) begin
	 // The filter gates the *store*, not the trigger: a sample that is not
	 // kept must still be able to fire the trigger, or a filter narrower
	 // than the trigger would make the instrument deaf to its own event.
	 if (keep) begin
	    mem[wp] <= dbg_bus;
	    wp      <= wp + 1'b1;
	 end
	 if (!trig_q) begin
	    if (hit) trig_q <= 1'b1;
	 end else begin
	    // Exactly POST samples are written after the trigger sample, so the
	    // trigger sits at DEPTH-POST-1 counting from the oldest.  Setting
	    // done_q on the same edge as the last write rather than one later
	    // is what makes that arithmetic exact, and the arithmetic is what
	    // the host uses to find the event.
	    // Counted in *stored* samples, so POST keeps its meaning when a
	    // filter is in force -- otherwise the buffer would stop after POST
	    // clocks having written almost nothing.
	    if (keep) begin
	       if (post_cnt == 1) done_q <= 1'b1;
	       post_cnt <= post_cnt - 1'b1;
	    end
	 end
      end
      // A second port on the same array, read-only and never used until the
      // capture has stopped, so read-during-write cannot arise.
      rd_data <= mem[rd_addr];
   end

endmodule
