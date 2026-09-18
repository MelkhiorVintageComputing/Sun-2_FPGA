`timescale 1ns / 1ps

`include "sun2_attr.vh"

//
// The Sun-2 bus to Wishbone, through two dual-clock FIFOs.
//
// sun2_wishbone_bridge is synchronous: a memory cycle raises wb_cyc and DTACK
// waits for the Wishbone acknowledgement, which on a board comes back through
// the adapter's own clock crossing -- seven to thirteen CPU clocks for a read
// and for a write alike.  This bridge is a drop-in alternative, chosen by
// SUN2_WB_FIFO in sun2_fpga, with the same ports plus the Wishbone side's own
// clock and reset:
//
//   request FIFO   CLK -> WB_CLK   {tag, we, adr, dat, sel}
//   response FIFO  WB_CLK -> CLK   {tag, dat}, reads only
//
// **A write is acknowledged as soon as it is queued.**  Nothing on this path
// can refuse a write once the MMU has granted it -- memory never bus-errors,
// which is why sun2_fpga exempts it from the timeout -- so there is nothing to
// wait for.  A full request FIFO delays the acknowledgement instead: it is
// backpressure, never loss.
//
// **A read waits for its own response**, and the response carries the tag its
// request went out with.  A response whose tag is not the read this bridge is
// waiting for is discarded.  That is the property sun2_wishbone_bridge gets
// from `issued' and cannot fully have -- it accepts any acknowledgement that
// arrives while its own request is out -- and it is the defence in depth the
// orphan-request fix left open: whatever puts a stray transaction into the
// memory path, its answer can no longer be taken by the next cycle.
//
// **Order is the whole correctness argument.**  Both masters' reads and writes
// go through one request FIFO, and the Wishbone side runs one transaction at a
// time from its head.  So a read queued behind a write that has been
// acknowledged but not yet performed is performed after it, and sees it.
//
// **Timing seen by the machine is the old bridge's.**  DTACK for a read rises
// on the same clock edge that loads P_DATA_OUT, so the data is valid the clock
// after DTACK -- which is what sun2_dvma's S_LATCH and both 68010 cores latch
// on, and what tb_sun2's memory checker models.  DTACK for a write rises the
// clock after the enqueue, the earliest the old bridge ever managed with a
// registered acknowledgement.
//
// **A transaction belongs to a data phase**, as in the fixed
// sun2_wishbone_bridge: `issued'/`done' clear when the strobes release, and a
// request needs a strobe, so a read-modify-write's two halves are two
// transactions and nothing is queued in the gap between them.
//
// Resets: ENABLE is armed exactly as the old bridge's (power-on reset, then
// SET_ENABLE at LED code 0x8F) and nothing is queued while it is clear.  The
// FIFOs' two sides are reset together -- each side takes its own reset OR the
// other side's, synchronised -- because a FIFO reset on one side only would
// desynchronise its pointers.
//
module sun2_fifo_bridge #(
   parameter [29:0] FB_WB_BASE = 30'h03E00000,
   parameter        TAG_BITS   = 4,
   parameter        REQ_ADDR   = 4,           // request FIFO depth 2**REQ_ADDR
   parameter        RSP_ADDR   = 2
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
   input             wb_ack_i
);

   localparam RQW = TAG_BITS + 1 + 30 + 32 + 4;
   localparam RSW = TAG_BITS + 32;

   // =========================================================================
   // Resets, crossed both ways so the two FIFO sides always overlap
   // =========================================================================
   `SUN2_ASYNC_REG reg [1:0] wbrst_s;     // WB_RESET seen in CLK
   `SUN2_ASYNC_REG reg [1:0] cpurst_s;    // ~RESET_n seen in WB_CLK
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

   wire [29:0] fb_adr = FB_WB_BASE | {15'h0, FB_PAGE, P_ADR_IN[10:2]};

   // The request's fields, formed exactly as sun2_wishbone_bridge forms its
   // Wishbone outputs.
   wire [29:0] q_adr = MATCH_FB  ? fb_adr :
                       MATCH_MEM ? {8'h0, P_ADR_IN[23:2]} : 30'h0C0FFEEE;
`ifdef WB_LITTLE_ENDIAN
   wire [31:0] q_dat = {P_DATA_IN[7:0], P_DATA_IN[15:8], P_DATA_IN[7:0], P_DATA_IN[15:8]};
   wire  [3:0] q_sel = P_RW_n ? 4'hF : { EN_LBYTE & ~P_ADR_IN[1], EN_UBYTE & ~P_ADR_IN[1],
                                         EN_LBYTE &  P_ADR_IN[1], EN_UBYTE &  P_ADR_IN[1]};
`else
   wire [31:0] q_dat = {P_DATA_IN, P_DATA_IN};
   wire  [3:0] q_sel = P_RW_n ? 4'hF : { EN_UBYTE &  P_ADR_IN[1], EN_LBYTE &  P_ADR_IN[1],
                                         EN_UBYTE & ~P_ADR_IN[1], EN_LBYTE & ~P_ADR_IN[1]};
`endif
   wire        q_we  = ~P_RW_n;

   reg                issued, done;
   reg  [TAG_BITS-1:0] tag;            // the tag of the read now waiting, or last sent

   wire               rq_full;
   wire               enq = ENABLE & PHASE & ~issued & ~rq_full;

   wire               rs_empty;
   wire [RSW-1:0]     rs_head;
   wire [TAG_BITS-1:0] rs_tag = rs_head[RSW-1:32];
   wire [31:0]        rs_dat = rs_head[31:0];

   // Waiting for a read's answer: queued in this phase, not yet answered.
   wire               rd_wait = ENABLE & PHASE & issued & ~done & P_RW_n;
   wire               rs_ours = ~rs_empty & rd_wait & (rs_tag == tag);
   // Anything else at the head is a stale answer and is dropped.
   wire               rs_stale = ~rs_empty & ~rs_ours;
   wire               rs_pop = rs_ours | rs_stale;

   assign W_ACK = ~ENABLE ? 1'b0 : (rs_ours | done);

   wire [TAG_BITS-1:0] tag_next = tag + {{(TAG_BITS-1){1'b0}}, 1'b1};

   always @(posedge CLK) begin
      if (~RESET_n)   ENABLE <= 1'b0;
      if (SET_ENABLE) ENABLE <= 1'b1;

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
         if (rs_ours)         done   <= 1'b1;   // a read: acknowledged by its answer
      end

      if (~ENABLE)
        P_DATA_OUT <= 16'h0000;
      else if (rs_ours)
`ifdef WB_LITTLE_ENDIAN
        P_DATA_OUT <= P_ADR_IN[1] ? {rs_dat[ 7: 0], rs_dat[15: 8]} : {rs_dat[23:16], rs_dat[31:24]};
`else
        P_DATA_OUT <= P_ADR_IN[1] ? {rs_dat[31:24], rs_dat[23:16]} : {rs_dat[15: 8], rs_dat[ 7: 0]};
`endif
   end

   // A read's tag is the next one; a write carries the current tag unused.
   wire [TAG_BITS-1:0] q_tag = q_we ? tag : tag_next;

   // =========================================================================
   // The FIFOs
   // =========================================================================
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

   // Take a request only with room to answer it, so a read's response is
   // never dropped for want of space.
   wire start = ~busy & ~rq_empty & ~rs_full;

   always @(*) begin
      rq_pop  = start;
      rs_push = busy & wb_ack_i & ~c_we;
      rs_in   = {c_tag, wb_dat_i};
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
