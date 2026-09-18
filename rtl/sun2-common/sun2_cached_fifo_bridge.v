`timescale 1ns / 1ps

`include "sun2_attr.vh"

//
// sun2_fifo_bridge with a read cache in front of it.
//
// Everything sun2_fifo_bridge.v says about the two FIFOs, the tags, ordering
// and the machine-visible timing holds here, and is not repeated.  What is
// added is a direct-mapped cache of 128-bit lines -- the width of a MIG beat
// and of a BrianHG line, so a read miss brings a whole line back for the cost
// of one -- sitting on the machine's side of the request queue, in CLK.
//
// **Why it cannot go stale.**  Every master's every memory cycle comes through
// this one bridge, and nothing else writes DDR3 (fb_scanout only reads).
//   * Writes are write-through, no-allocate: queued exactly as before, and a
//     write that hits updates the cached line in the same clock it is queued.
//     A read that hits afterwards sees it before DDR3 does, which is correct.
//   * A read miss holds the bus until its line comes back, so nothing can write
//     that line while it is being fetched; and the fill request is queued
//     behind any writes still waiting, so the line it brings back contains
//     them.
//   * A line is installed only from the answer this bridge is waiting for --
//     the tag check that already drops stale answers.  An abandoned read's late
//     answer would arrive after the bus had moved on, possibly after a write to
//     that very line, and installing it would put stale data in the cache.
//   * The frame buffer aperture is not cached: MATCH_FB reads always go to
//     memory and its writes never touch the cache.  That also keeps the VME
//     machine's frame buffer, decoded on TYPE 1 pages that alias low memory
//     pages, from ever being mistaken for memory lines.
//
// **A hit costs no memory wait, and a miss costs nothing extra.**  The cache
// RAMs are read every clock with the address on the bus, so by the first clock
// of a data phase the tag and data for that address are already registered.
// A hit raises W_ACK in that clock and loads P_DATA_OUT on the edge that ends
// it -- data valid the clock after DTACK, as the other two bridges -- and a
// miss is queued on that same edge, exactly when sun2_fifo_bridge would have
// queued it.  That needs the physical address to be on the bus a clock before
// the phase begins (tb_sun2 measures it on every boot), and it is guarded: a
// lookup counts only if the address it was made with is the address now, and
// no cache write landed on the edge that registered it; anything else is
// treated as a miss (reads) or invalidates the line (writes), which is always
// safe.
//
// **Storage.**  Eight RAMs of 16 bits, one per halfword of a line, each with a
// byte write enable, so a fill writes all eight in one clock and a write hit
// writes one halfword under UDS/LDS; and a tag RAM of {valid, tag}.  Valid
// bits are cleared by a sweep at power-on reset, one line per clock, long
// before the bridge is ENABLEd -- not by relying on either vendor's RAM
// powering up as zeros.  Lines are 2**IDX; main memory is under 8 MiB, so the
// tag is the physical line address above the index.
//
// Only the big-endian lane arrangement is supported.
//
module sun2_cached_fifo_bridge #(
   parameter [29:0] FB_WB_BASE = 30'h03E00000,
   parameter        TAG_BITS   = 4,
   parameter        REQ_ADDR   = 4,           // request FIFO depth 2**REQ_ADDR
   parameter        RSP_ADDR   = 2,
   parameter        IDX        = 9            // 2**IDX lines of 16 bytes
) (
   input             SET_ENABLE,
   input             RESET_n,
   input             CLK,

   input      [23:1] P_ADR_IN,
   input      [15:0] P_DATA_IN,
   output reg [15:0] P_DATA_OUT,
   input             P_RW_n,
   input             EN_LBYTE,
   input             EN_UBYTE,
   input       [5:0] FB_PAGE,
   input             MATCH_MEM,
   input             MATCH_FB,
   output            W_ACK,

   input             WB_CLK,
   input             WB_RESET,
   output            wb_cyc_o,
   output            wb_stb_o,
   output     [29:0] wb_adr_o,
   output     [31:0] wb_dat_o,
   output      [3:0] wb_sel_o,
   output            wb_we_o,
   input      [31:0] wb_dat_i,
   input             wb_ack_i,
   input     [127:0] wb_line_i          // the whole line, valid with wb_ack_i
);

   localparam RQW   = TAG_BITS + 1 + 30 + 32 + 4;
   localparam RSW   = TAG_BITS + 128;
   localparam LINES = 1 << IDX;
   localparam TAGW  = 23 - (IDX + 4) + 1;   // P_ADR_IN[23:IDX+4]

`ifdef WB_LITTLE_ENDIAN
   initial begin
      $display("sun2_cached_fifo_bridge: WB_LITTLE_ENDIAN is not supported");
      $finish;
   end
`endif

   // =========================================================================
   // Resets, crossed both ways so the two FIFO sides always overlap
   // =========================================================================
   `SUN2_ASYNC_REG reg [1:0] wbrst_s;
   `SUN2_ASYNC_REG reg [1:0] cpurst_s;
   always @(posedge CLK)    wbrst_s  <= {wbrst_s[0],  WB_RESET};
   always @(posedge WB_CLK) cpurst_s <= {cpurst_s[0], ~RESET_n};
   wire cpu_side_rst = ~RESET_n | wbrst_s[1];
   wire wb_side_rst  = WB_RESET | cpurst_s[1];

   // =========================================================================
   // CLK side: the machine's bus
   // =========================================================================
   reg ENABLE;

   wire MATCH_ANY = MATCH_MEM | MATCH_FB;
   wire PHASE     = MATCH_ANY & (EN_LBYTE | EN_UBYTE);
   wire CACHEABLE = MATCH_MEM & ~MATCH_FB;

   wire [29:0] fb_adr = FB_WB_BASE | {15'h0, FB_PAGE, P_ADR_IN[10:2]};
   wire [29:0] q_adr  = MATCH_FB  ? fb_adr :
                        MATCH_MEM ? {8'h0, P_ADR_IN[23:2]} : 30'h0C0FFEEE;
   wire [31:0] q_dat  = {P_DATA_IN, P_DATA_IN};
   wire  [3:0] q_sel  = P_RW_n ? 4'hF : { EN_UBYTE &  P_ADR_IN[1], EN_LBYTE &  P_ADR_IN[1],
                                          EN_UBYTE & ~P_ADR_IN[1], EN_LBYTE & ~P_ADR_IN[1]};
   wire        q_we   = ~P_RW_n;

   // ---- the cache --------------------------------------------------------
   wire [19:0]     cur_line = P_ADR_IN[23:4];          // 16-byte line address
   wire [IDX-1:0]  cur_idx  = P_ADR_IN[IDX+3:4];
   wire [TAGW-1:0] cur_tag  = P_ADR_IN[23:IDX+4];
   wire [2:0]      cur_hw   = P_ADR_IN[3:1];           // halfword within the line

   // Power-on sweep of the valid bits.
   reg [IDX:0] swp;                                    // top bit = done
   wire        swp_done = swp[IDX];

   // One write port on every cache RAM, driven by exactly one of: the sweep,
   // a fill, a write hit, an invalidation.
   reg             t_we;                // tag RAM
   reg  [IDX-1:0]  t_wa;
   reg  [TAGW:0]   t_wd;                // {valid, tag}
   reg  [7:0]      d_we_hi, d_we_lo;    // per halfword, per byte
   reg  [IDX-1:0]  d_wa;
   reg  [127:0]    d_wd;
   wire            cache_we = t_we | (|d_we_hi) | (|d_we_lo);

   // The read ports, free-running on the bus address.
   `SUN2_RAM_BLOCK reg [TAGW:0] tmem [0:LINES-1];
   reg  [TAGW:0]   tq;
   always @(posedge CLK) begin
      if (t_we) tmem[t_wa] <= t_wd;
      tq <= tmem[cur_idx];
   end

   wire [15:0] dq [0:7];
   genvar g;
   generate
      for (g = 0; g < 8; g = g + 1) begin : dline
         `SUN2_RAM_BLOCK reg [15:0] dmem [0:LINES-1];
         reg [15:0] q;
         always @(posedge CLK) begin
            if (d_we_hi[g]) dmem[d_wa][15:8] <= d_wd[g*16+8 +: 8];
            if (d_we_lo[g]) dmem[d_wa][ 7:0] <= d_wd[g*16   +: 8];
            q <= dmem[cur_idx];
         end
         assign dq[g] = q;
      end
   endgenerate

   // Is what the RAMs are showing now a lookup of the line on the bus now?
   reg  [19:0]  lk_line;
   reg          lk_cwr;
   always @(posedge CLK) begin
      lk_line <= cur_line;
      lk_cwr  <= cache_we;
   end
   wire lk_ok  = swp_done & (lk_line == cur_line) & ~lk_cwr;
   wire lk_hit = lk_ok & tq[TAGW] & (tq[TAGW-1:0] == cur_tag);

   // ---- the transaction ----------------------------------------------------
   reg                 issued, done;
   reg  [TAG_BITS-1:0] tag;

   wire                rd_hit = ENABLE & PHASE & P_RW_n & ~issued & ~done & CACHEABLE & lk_hit;

   wire                rq_full;
   wire                enq = ENABLE & PHASE & ~issued & ~done & ~rq_full & ~rd_hit;

   wire                rs_empty;
   wire [RSW-1:0]      rs_head;
   wire [TAG_BITS-1:0] rs_tag  = rs_head[RSW-1:128];
   wire [127:0]        rs_line = rs_head[127:0];

   wire                rd_wait  = ENABLE & PHASE & issued & ~done & P_RW_n;
   wire                rs_ours  = ~rs_empty & rd_wait & (rs_tag == tag);
   wire                rs_stale = ~rs_empty & ~rs_ours;
   wire                rs_pop   = rs_ours | rs_stale;

   assign W_ACK = ~ENABLE ? 1'b0 : (rd_hit | rs_ours | done);

   wire [TAG_BITS-1:0] tag_next = tag + {{(TAG_BITS-1){1'b0}}, 1'b1};

   // What the cache RAMs are told to do on this edge.
   wire wr_now  = enq & q_we & CACHEABLE;   // a write being queued
   wire fill    = rs_ours & CACHEABLE;       // our line has come back
   always @(*) begin
      t_we = 1'b0; t_wa = cur_idx; t_wd = {1'b0, cur_tag};
      d_we_hi = 8'h00; d_we_lo = 8'h00; d_wa = cur_idx;
      d_wd = {8{P_DATA_IN}};
      if (~swp_done) begin
         t_we = 1'b1; t_wa = swp[IDX-1:0]; t_wd = {(TAGW+1){1'b0}};
      end else if (fill) begin
         t_we = 1'b1; t_wd = {1'b1, cur_tag};
         d_we_hi = 8'hFF; d_we_lo = 8'hFF; d_wd = rs_line;
      end else if (wr_now & lk_hit) begin
         d_we_hi[cur_hw] = EN_UBYTE;
         d_we_lo[cur_hw] = EN_LBYTE;
      end else if (wr_now & ~lk_ok) begin
         // Could not tell whether the line is here: make sure it is not.
         t_we = 1'b1; t_wd = {(TAGW+1){1'b0}};
      end
   end

   always @(posedge CLK) begin
      if (~RESET_n)   ENABLE <= 1'b0;
      if (SET_ENABLE) ENABLE <= 1'b1;

      if (~RESET_n)       swp <= {(IDX+1){1'b0}};
      else if (~swp_done) swp <= swp + {{IDX{1'b0}}, 1'b1};

      if (cpu_side_rst)
        tag <= {TAG_BITS{1'b0}};
      else if (enq & ~q_we)
        tag <= tag_next;

      if (~ENABLE | ~PHASE) begin
         issued <= 1'b0;
         done   <= 1'b0;
      end else begin
         if (enq)             issued <= 1'b1;
         if (issued & q_we)   done   <= 1'b1;   // a write: acknowledged once queued
         if (rs_ours)         done   <= 1'b1;   // a read miss: by its answer
         if (rd_hit)          done   <= 1'b1;   // a read hit: at once
      end

      if (~ENABLE)
        P_DATA_OUT <= 16'h0000;
      else if (rd_hit)
        P_DATA_OUT <= dq[cur_hw];
      else if (rs_ours)
        P_DATA_OUT <= rs_line[cur_hw*16 +: 16];
   end

`ifdef SUN2_SIM
   // What the cache did, for tb_sun2's report and the unit test.
   integer n_hit = 0, n_miss = 0, n_uncached = 0, n_whit = 0, n_wmiss = 0,
           n_winval = 0, n_fill = 0, n_rd_notok = 0;
   always @(posedge CLK) if (ENABLE) begin
      if (rd_hit)                                   n_hit      = n_hit + 1;
      if (enq & ~q_we & CACHEABLE)                  n_miss     = n_miss + 1;
      if (enq & ~q_we & ~CACHEABLE)                 n_uncached = n_uncached + 1;
      if (enq & ~q_we & CACHEABLE & ~lk_ok)         n_rd_notok = n_rd_notok + 1;
      if (wr_now & lk_hit)                          n_whit     = n_whit + 1;
      if (wr_now & lk_ok & ~lk_hit)                 n_wmiss    = n_wmiss + 1;
      if (wr_now & ~lk_ok)                          n_winval   = n_winval + 1;
      if (fill)                                     n_fill     = n_fill + 1;
   end
`endif

   // =========================================================================
   // The FIFOs
   // =========================================================================
   wire [TAG_BITS-1:0] q_tag = q_we ? tag : tag_next;
   wire               rq_empty;
   wire [RQW-1:0]     rq_head;
   reg                rq_pop;

   sun2_async_fifo #(.WIDTH(RQW), .ADDR(REQ_ADDR)) req_fifo (
      .wclk(CLK),    .wrst(cpu_side_rst), .wr_en(enq),
      .wr_data({q_tag, q_we, q_adr, q_dat, q_sel}), .wfull(rq_full),
      .rclk(WB_CLK), .rrst(wb_side_rst),  .rd_en(rq_pop),
      .rd_data(rq_head), .rempty(rq_empty));

   wire               rs_full;
   reg                rs_push;
   reg  [RSW-1:0]     rs_in;

   sun2_async_fifo #(.WIDTH(RSW), .ADDR(RSP_ADDR)) rsp_fifo (
      .wclk(WB_CLK), .wrst(wb_side_rst),  .wr_en(rs_push),
      .wr_data(rs_in), .wfull(rs_full),
      .rclk(CLK),    .rrst(cpu_side_rst), .rd_en(rs_pop),
      .rd_data(rs_head), .rempty(rs_empty));

   // =========================================================================
   // WB_CLK side: one Wishbone transaction at a time, from the queue's head
   // =========================================================================
   reg                busy;
   reg [TAG_BITS-1:0] c_tag;
   reg                c_we;
   reg [29:0]         c_adr;
   reg [31:0]         c_dat;
   reg  [3:0]         c_sel;

   assign wb_cyc_o = busy;
   assign wb_stb_o = busy;
   assign wb_we_o  = busy & c_we;
   assign wb_adr_o = c_adr;
   assign wb_dat_o = c_dat;
   assign wb_sel_o = c_sel;

   wire start = ~busy & ~rq_empty & ~rs_full;

   always @(*) begin
      rq_pop  = start;
      rs_push = busy & wb_ack_i & ~c_we;
      rs_in   = {c_tag, wb_line_i};
   end

   always @(posedge WB_CLK) begin
      if (wb_side_rst) begin
         busy <= 1'b0;
      end else if (start) begin
         busy <= 1'b1;
         {c_tag, c_we, c_adr, c_dat, c_sel} <= rq_head;
      end else if (busy & wb_ack_i) begin
         busy <= 1'b0;
      end
   end

endmodule
