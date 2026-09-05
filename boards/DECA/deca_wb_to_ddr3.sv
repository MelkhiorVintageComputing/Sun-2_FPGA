`timescale 1ns / 1ps

//
// Wishbone B4 classic slave  ->  BrianHG DDR3 controller command port.
//
// The DECA twin of boards/Wukong/wb_to_mig_ui.sv, and deliberately the same
// shape: the clock crossing and the 32-bit lane extraction are identical, and
// only the back end differs.  That file's client port was written abstract on
// purpose, and this is the first time that has been worth anything.
//
// The Sun-2's memory master (rtl/sun2-common/sun2_wishbone_bridge.v) lives in
// the CPU clock domain and issues one 32-bit access at a time, stalling the
// 68010 on DTACK until it is answered, so this is single-transaction-in-flight
// by design: there is nothing to gain from pipelining and much to lose in
// reviewability.
//
// ------------------------------------------------------- the address mapping
//
// CMD_addr is a **byte** address, and one command moves a whole cache line of
// PORT_CACHE_BITS = 8 * DDR3_WIDTH_DM * 8 = 128 bits = 16 bytes.  So:
//
//     byte address = wb_adr * 4
//     CMD_addr     = that, aligned down to 16   = {wb_adr[26:2], 4'b0000}
//     lane         = wb_adr[1:0]   which 32-bit quarter of the 128 bits
//
// The 128-bit line is the same width as MIG's user-interface beat, which is why
// the lane arithmetic transfers unchanged.  That is a coincidence of two
// 16-bit-wide DDR3 parts on a burst of 8, not a designed correspondence, and it
// would not survive a different DQ width.
//
// -------------------------------------------------- what is NOT like the MIG
//
// **The write mask polarity is inverted.**  MIG's app_wdf_mask is active high
// meaning "do not write this byte"; BrianHG's CMD_wmask is documented in
// BrianHG_DDR3_CONTROLLER_v16_top.sv:394 as "When low, the associated byte will
// not be written", i.e. active high meaning *do* write.  Reusing the Wukong's
// mask_for() unchanged would have written every byte the CPU did not ask for
// and none of the ones it did -- silently, and only on sub-word writes, which
// the boot PROM does constantly.  Read the polarity, never assume it.
//
// **The handshake is a strobe, not a level.**  MIG's client port here held
// c_req until c_done.  CMD_ena is a single-clock "send a command", accepted
// only while CMD_busy is low.  Completion differs by direction: a read finishes
// on CMD_read_ready, a write has no acknowledgement at all and is finished the
// moment it is accepted.
//
// --------------------------------------------------------- clock domains
//
// The controller's CMD_CLK is half the DDR3 rate -- 125 MHz for the 250 MHz
// build -- against the machine's 12.5 MHz.  The crossing is the same two-phase
// toggle handshake the Wukong uses, with three-stage synchronisers: address,
// data, select and direction are captured in the Wishbone domain and held
// stable for the whole transaction, and read data is captured in the DDR3
// domain before its toggle flips.  Only the two toggle bits actually cross.
//
module deca_wb_to_ddr3 #(
    // Issue every read twice and compare the two answers.
    //
    // Every accounting check in this path reads zero -- one response per
    // request, none unbidden, the right 32-bit lane, the right 16-bit half, one
    // capture per cycle -- and a word still arrives wrong, carrying content
    // from elsewhere on the medium (tools/patwr).  What none of those checks
    // is that the data a response *carries* belongs to the address requested:
    // a controller answering with some other transaction's contents leaves
    // every counter above at zero, which is exactly what is observed.
    //
    // Reading the same address twice back to back and comparing needs no
    // knowledge of the controller's internals and is decisive either way.  A
    // mismatch is proof the fault is below this module.  Zero mismatches *with
    // the corruption still present* means the read data is self-consistent and
    // the search has been looking in the wrong place.
    //
    // Read it with that caveat in mind: issuing reads twice changes timing, so
    // if the corruption also disappears the result says nothing.  Check that a
    // run with this on still corrupts before believing a zero.
    parameter bit DOUBLE_READ = 1'b0,
    parameter int PORT_ADDR_SIZE  = 29,
    parameter int PORT_CACHE_BITS = 128
) (
    // ---- Wishbone slave, CPU clock domain -------------------------------
    input  wire                        clk_wb,
    input  wire                        rst_wb,        // active high

    input  wire                        wb_cyc_i,
    input  wire                        wb_stb_i,
    input  wire [29:0]                 wb_adr_i,      // 32-bit word address
    input  wire [31:0]                 wb_dat_i,
    input  wire [3:0]                  wb_sel_i,
    input  wire                        wb_we_i,
    output reg  [31:0]                 wb_dat_o,
    output reg                         wb_ack_o,

    // ---- BrianHG command port, CMD_CLK domain ---------------------------
    input  wire                        cmd_clk,
    input  wire                        cmd_rst,       // active high
    input  wire                        ddr3_ready,

    input  wire                        CMD_busy,
    output wire                        CMD_ena,
    output wire                        CMD_write_ena,
    output wire [PORT_ADDR_SIZE-1:0]   CMD_addr,
    output wire [PORT_CACHE_BITS-1:0]  CMD_wdata,
    output wire [PORT_CACHE_BITS/8-1:0] CMD_wmask,
    input  wire                        CMD_read_ready,

    // ---- instrumentation, for tools/deca_dvmaprobe.tcl --------------------
    // The adapter is single-transaction-in-flight and D_READ consumes whatever
    // CMD_read_ready presents.  So a response arriving outside that window, or
    // a second one for the same request, is data from another transaction
    // sitting where the next read can take it -- which is the shape of the
    // corruption being chased.  There is no ground truth for the *value* here,
    // but the request/response accounting can be checked without one.
    output reg  [15:0]                 dbg_rd_issued,     // reads accepted
    output reg  [15:0]                 dbg_rd_ready,      // responses seen
    output reg  [15:0]                 dbg_rd_unexpected, // ... outside D_READ
    // Reads whose 32-bit lane changed between issue and response.  BrianHG
    // returns a 128-bit line and this adapter takes one quarter of it by
    // req_adr[1:0]; req_adr is latched in the wb domain and the response is
    // consumed in the cmd_clk one, so if a new request overwrote it while a
    // read was in flight the wrong quarter is taken.  That is 32 bits wrong,
    // which reaches the machine as *sixteen* -- a DVMA longword is two bridge
    // transactions contributing half each -- and it is the one value selection
    // in this path that the request/response accounting above cannot see.
    output reg  [15:0]                 dbg_lane_bad,
    // DOUBLE_READ: reads whose two answers disagreed, and the first such.
    output reg  [15:0]                 dbg_reread_bad,
    output reg  [29:0]                 dbg_rr_adr,
    output reg  [31:0]                 dbg_rr_v1,
    output reg  [31:0]                 dbg_rr_v2,
    input  wire [PORT_CACHE_BITS-1:0]  CMD_read_data
);

   localparam int LANES = PORT_CACHE_BITS / 32;   // 4

   // Written only in the Wishbone domain and read only in the DDR3 domain
   // while a request is outstanding, and the other way round for rd_lane.  Both
   // are stable across their handshake, so neither needs a synchroniser -- only
   // the toggles do.
   reg [29:0] req_adr;
   reg [31:0] req_dat;
   reg [3:0]  req_sel;
   reg        req_we;
   reg [31:0] rd_lane;
   reg [1:0]  lane_at_issue;

   reg        req_tgl;      // toggles to launch a transaction   (clk_wb)
   reg        ack_tgl;      // toggles when one completes        (cmd_clk)
   reg        busy;

   wire [1:0] lane = req_adr[1:0];

   // Active HIGH = write this byte.  See the note above; this is the opposite
   // of the Wukong's.
   function automatic logic [PORT_CACHE_BITS/8-1:0] mask_for(input logic [1:0] l,
                                                             input logic [3:0] sel);
      logic [PORT_CACHE_BITS/8-1:0] m;
      begin
         m = '0;
         m[l*4 +: 4] = sel;
         mask_for = m;
      end
   endfunction

   // ------------------------------------------------------------------
   // Wishbone side
   // ------------------------------------------------------------------
   reg  ack_tgl_s1, ack_tgl_s2, ack_tgl_s3;
   wire ack_pulse = ack_tgl_s2 ^ ack_tgl_s3;

   always @(posedge clk_wb) begin
      if (rst_wb) begin
         ack_tgl_s1 <= 1'b0; ack_tgl_s2 <= 1'b0; ack_tgl_s3 <= 1'b0;
      end else begin
         ack_tgl_s1 <= ack_tgl;
         ack_tgl_s2 <= ack_tgl_s1;
         ack_tgl_s3 <= ack_tgl_s2;
      end
   end

   always @(posedge clk_wb) begin
      if (rst_wb) begin
         busy     <= 1'b0;
         req_tgl  <= 1'b0;
         wb_ack_o <= 1'b0;
         wb_dat_o <= 32'h0;
         req_adr  <= 30'h0;
         req_dat  <= 32'h0;
         req_sel  <= 4'h0;
         req_we   <= 1'b0;
      end else begin
         wb_ack_o <= 1'b0;

         if (!busy) begin
            if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
               req_adr <= wb_adr_i;
               req_dat <= wb_dat_i;
               req_sel <= wb_sel_i;
               req_we  <= wb_we_i;
               req_tgl <= ~req_tgl;
               busy    <= 1'b1;
            end
         end else if (ack_pulse) begin
            wb_dat_o <= rd_lane;   // written before ack_tgl flipped, stable now
            wb_ack_o <= 1'b1;
            busy     <= 1'b0;
         end
      end
   end

   // ------------------------------------------------------------------
   // DDR3 side
   // ------------------------------------------------------------------
   reg  req_tgl_s1, req_tgl_s2, req_tgl_s3;
   wire req_pulse = req_tgl_s2 ^ req_tgl_s3;

   always @(posedge cmd_clk) begin
      if (cmd_rst) begin
         req_tgl_s1 <= 1'b0; req_tgl_s2 <= 1'b0; req_tgl_s3 <= 1'b0;
      end else begin
         req_tgl_s1 <= req_tgl;
         req_tgl_s2 <= req_tgl_s1;
         req_tgl_s3 <= req_tgl_s2;
      end
   end

   localparam [2:0] D_IDLE  = 3'd0, D_SEND  = 3'd1, D_READ  = 3'd2,
                    D_SEND2 = 3'd3, D_READ2 = 3'd4;   // the re-read
   reg [2:0] dstate;

   // The request fields are combinational rather than registered, which looks
   // careless and is not: they are written in the Wishbone domain *before*
   // req_tgl flips, and req_pulse arrives three synchroniser stages later, so
   // they have been stable for several cmd_clk by the time the controller can
   // see them.  Registering them again would add a cycle to every CPU memory
   // access, and on the Wukong that measurably cost one of the seven clocks the
   // 68010 waits.
   // PORT_ADDR_SIZE-3, not -5.  A byte address of PORT_ADDR_SIZE bits needs
   // PORT_ADDR_SIZE-4 word-address bits above the four zeros, which is
   // req_adr[26:2] for the 29 bits this controller has -- exactly what the
   // comment at the head of this file already said.  The code said [24:2],
   // silently capping the reachable range at 128 MiB and dropping bit 25 of
   // anything above it.
   //
   // Nothing noticed for the life of the port because main memory is 7 MiB.
   // The frame buffer is the first thing this project has ever placed high --
   // FB_WB_BASE is 0x03E00000 words, 248 MiB -- and the effect was that the
   // CPU's pixel writes landed at 120 MiB with bit 25 lost while the scan-out
   // read 248 MiB, which is uninitialised DDR3.  On a monitor that is noise,
   // and it looks like a frame buffer fault rather than an address one.
   assign CMD_addr      = {req_adr[PORT_ADDR_SIZE-3:2], 4'b0000};
   assign CMD_wdata     = {LANES{req_dat}};   // same word in every lane; the
                                              // mask picks which copy lands
   assign CMD_wmask     = mask_for(req_adr[1:0], req_sel);
   assign CMD_write_ena = req_we && (dstate != D_SEND2);
   // A single-clock strobe, and only while the controller can take it.  Held
   // off until ddr3_ready so nothing is issued during calibration.
   assign CMD_ena       = ((dstate == D_SEND) || (dstate == D_SEND2))
                          && !CMD_busy && ddr3_ready;

   always @(posedge cmd_clk) begin
      if (cmd_rst) begin
         dstate  <= D_IDLE;
         ack_tgl <= 1'b0;
         rd_lane <= 32'h0;
         dbg_rd_issued     <= 16'd0;
         dbg_rd_ready      <= 16'd0;
         dbg_rd_unexpected <= 16'd0;
         dbg_lane_bad      <= 16'd0;
         dbg_reread_bad    <= 16'd0;
         lane_at_issue     <= 2'd0;
      end else begin
         // Counted outside the case so nothing about the state machine's own
         // branching can hide them.
         if (CMD_ena && !req_we)                 dbg_rd_issued <= dbg_rd_issued + 16'd1;
         if (CMD_read_ready)                     dbg_rd_ready  <= dbg_rd_ready  + 16'd1;
         if (CMD_read_ready && dstate != D_READ && dstate != D_READ2)
                                                 dbg_rd_unexpected <= dbg_rd_unexpected + 16'd1;
         if (CMD_ena && !req_we)                 lane_at_issue <= lane;
         if (CMD_read_ready && dstate == D_READ && lane != lane_at_issue)
                                                 dbg_lane_bad <= dbg_lane_bad + 16'd1;

         case (dstate)
           D_IDLE:
             if (req_pulse) dstate <= D_SEND;

           D_SEND:
             if (CMD_ena) begin
                // A write is finished the moment it is accepted -- there is no
                // write acknowledgement.  A read has to wait for its data.
                if (req_we) begin
                   ack_tgl <= ~ack_tgl;
                   dstate  <= D_IDLE;
                end else
                  dstate <= D_READ;
             end

           D_READ:
             if (CMD_read_ready) begin
                rd_lane <= CMD_read_data[lane*32 +: 32];
                if (DOUBLE_READ) begin
                   dstate  <= D_SEND2;      // ask again, same address
                end else begin
                   ack_tgl <= ~ack_tgl;
                   dstate  <= D_IDLE;
                end
             end

           D_SEND2:
             if (CMD_ena) dstate <= D_READ2;

           // The same address, read a second time.  rd_lane still holds the
           // first answer; the Wishbone side is handed the *first* one either
           // way, so a mismatch is recorded without changing what the machine
           // sees -- the point is to catch the controller disagreeing with
           // itself, not to paper over it.
           D_READ2:
             if (CMD_read_ready) begin
                if (CMD_read_data[lane*32 +: 32] != rd_lane) begin
                   dbg_reread_bad <= dbg_reread_bad + 16'd1;
                   if (dbg_reread_bad == 16'd0) begin
                      dbg_rr_adr <= req_adr;
                      dbg_rr_v1  <= rd_lane;
                      dbg_rr_v2  <= CMD_read_data[lane*32 +: 32];
                   end
                end
                ack_tgl <= ~ack_tgl;
                dstate  <= D_IDLE;
             end

           default: dstate <= D_IDLE;
         endcase
      end
   end

endmodule
