`timescale 1ns / 1ps

//
// Wishbone B4 classic slave  ->  MIG 7 Series native user interface.
//
// Replaces LiteX's WishboneDomainCrossingMaster plus LiteDRAM's Wishbone port.
// The Sun-2's memory master (rtl/sun2-common/sun2_wishbone_bridge.v) lives in the CPU clock
// domain and issues one 32-bit access at a time, stalling the 68010 on DTACK
// until it is answered, so this is deliberately a single-transaction-in-flight
// design: there is nothing to gain from pipelining and a great deal to lose in
// reviewability.
//
// Address mapping, read out of the generated MIG core rather than assumed
// (build/ip/sun2_mig/.../ui/mig_7series_v4_2_ui_cmd.v, MEM_ADDR_ORDER =
// "BANK_ROW_COLUMN"):
//
//     col  = app_addr[9:0]
//     row  = app_addr[23:10]
//     bank = app_addr[26:24]
//
// so app_addr counts in DDR3 words of DQ_WIDTH = 16 bits = 2 bytes, and with
// BURST_MODE = 8 and nCK_PER_CLK = 4 one user-interface beat moves a fixed
// burst of 8 of them = 16 bytes = 128 bits.  A burst must therefore start on an
// 8-word boundary, i.e. app_addr[2:0] == 0.
//
//     byte address = wb_adr * 4
//     app_addr     = byte address / 2, aligned down to 8
//                  = {wb_adr[25:2], 3'b000}
//     lane         = wb_adr[1:0]        which 32-bit quarter of the 128 bits
//
// wb_adr[25:2] covers the whole 256 MiB device; the Sun-2 only ever asks for
// the low 7 MiB of it.
//
// Sub-word writes need no read-modify-write: app_wdf_mask masks per byte.
//
// Clock domain crossing: a two-phase (toggle) request/acknowledge handshake
// with two-flop synchronisers.  Address, data, select and direction are
// captured in the Wishbone domain and held stable for the whole transaction,
// and the read data is captured in the MIG domain before its toggle flips, so
// only the two toggle bits actually cross.  Those paths want
// set_max_delay -datapath_only in the XDC; see syn/wukong_v1.xdc.
//

module wb_to_mig_ui #(
    parameter bit DOUBLE_READ = 1'b0,
    parameter int APP_ADDR_WIDTH = 28,
    parameter int APP_DATA_WIDTH = 128,
    parameter int APP_MASK_WIDTH = APP_DATA_WIDTH / 8
) (
    // ---- Wishbone slave, CPU clock domain -------------------------------
    input  wire                      clk_wb,
    input  wire                      rst_wb,          // active high

    input  wire                      wb_cyc_i,
    input  wire                      wb_stb_i,
    input  wire [29:0]               wb_adr_i,        // 32-bit word address
    input  wire [31:0]               wb_dat_i,
    input  wire [3:0]                wb_sel_i,
    input  wire                      wb_we_i,
    output reg  [31:0]               wb_dat_o,
    output reg                       wb_ack_o,

    // ---- client port on mig_arb, ui_clk domain ---------------------------
    input  wire                      ui_clk,
    input  wire                      ui_rst,          // ui_clk_sync_rst, active high

    output wire [APP_ADDR_WIDTH-1:0] c_addr,
    output wire                      c_we,
    output wire [APP_DATA_WIDTH-1:0] c_wdata,
    output wire [APP_MASK_WIDTH-1:0] c_wmask,
    output wire                      c_req,           // held until c_done
    input  wire                      c_done,          // one cycle; rdata valid with it
    input  wire [APP_DATA_WIDTH-1:0] c_rdata,

    // ---- the crossing check -----------------------------------------------
    // rd_lane is written in ui_clk and read in clk_wb, an unsynchronised 32-bit
    // payload carried by a toggle handshake.  It is the one hop in this whole
    // path that nothing has ever tested: every adapter check compares values
    // *within* ui_clk (WRITE_VERIFY against req_dat, DOUBLE_READ against
    // another read), and every bridge check is in clk_wb and assumes wb_dat_i
    // arrived intact.
    //
    // tools/patwr -u writes a pattern that repeats every sector, so both sides
    // can predict it from the address they already hold -- 32 bits at word
    // address A covers halfword indices 2A and 2A+1, modulo 256.  The check is
    // computed separately in each domain and only the verdict crosses:
    //
    //   xchk_bad   the word matched the pattern before the crossing and did
    //              not after.  Self-gating: traffic that is not the pattern
    //              never sets pre_ok, so it cannot trigger.
    //
    // Both byte orders are accepted, because getting the lane order wrong here
    // would cost a build to discover and the order is not what is being tested.
    output wire                      xchk_bad,
    output wire [31:0]               xchk_got,
    output wire [31:0]               xchk_exp,
    // Counters, read once at the end over a VIO.  An ILA capture is 205 us
    // against a workload of minutes, so the capture could never answer this;
    // a count can.  n_pat is the control -- it is what makes n_bad meaningful,
    // because zero bad crossings means nothing unless pattern words were
    // crossing to begin with.
    output wire [31:0]               xchk_n_read,   // read acks
    output wire [31:0]               xchk_n_pat,    // ... that were the pattern
    output wire [31:0]               xchk_n_bad,
    // The write side, the mirror of the above.  req_dat is latched in the
    // Wishbone domain and read combinationally in ui_clk, which is the other
    // untested hop -- and the one that fits every observation, because a word
    // corrupted here is stored faithfully and read back faithfully forever
    // after: WRITE_VERIFY compares CMD_read_data against req_dat and would be
    // comparing the corrupted value with itself.
    output wire [31:0]               xchk_n_wpat,   // full writes that were the
                                                    // pattern in the wb domain
    output wire [31:0]               xchk_n_wbad,

    // DOUBLE_READ, ported from boards/DECA/deca_wb_to_ddr3.sv.  Every read is
    // issued twice and the two answers compared: is the controller
    // self-consistent for this address at this moment?
    //
    // That is what the open contradiction needs.  ARRIVED BAD says the master
    // was handed program text for an address whose physical page is correct at
    // C_S6, while patwr's later read-back of the same file is clean.  If the
    // two reads agree, memory really did hold that word then and the right
    // value arrived afterwards -- a visibility or ordering fault.  If they
    // disagree, a read returned something memory did not hold.
    output reg  [31:0]               dbg_rr,      // reads compared
    output reg  [31:0]               dbg_rr_bad,  // ... whose answers differed
    output reg  [31:0]               dbg_rr_v1,
    output reg  [31:0]               dbg_rr_v2
);

   // ------------------------------------------------------------------
   // Shared state.  req_* are written only in the Wishbone domain and read
   // only in the MIG domain while a request is outstanding; rd_lane the other
   // way round.  Both are stable across their handshake, so neither needs a
   // synchroniser -- only the toggles below do.
   // ------------------------------------------------------------------
   reg [29:0] req_adr;
   reg [31:0] req_dat;
   reg [3:0]  req_sel;
   reg        req_we;
   reg [31:0] rd_lane;
   reg        pre_ok;
   reg [31:0] c_wpat, c_wbad;

   reg        req_tgl;      // toggles to launch a transaction   (clk_wb)
   reg        ack_tgl;      // toggles when one completes        (ui_clk)
   reg        busy;

   wire [1:0] lane = req_adr[1:0];

   // The pattern word this address should hold, in both lane orders.
   function automatic logic [31:0] pat_for(input logic [29:0] a, input bit swap);
      logic [7:0] i0, i1;
      begin
         i0 = 8'((a << 1)      & 30'hFF);   // halfword index 2A
         i1 = 8'(((a << 1) + 1) & 30'hFF);  // and 2A+1
         pat_for = swap ? {8'h80, i0, 8'h80, i1}
                        : {8'h80, i1, 8'h80, i0};
      end
   endfunction

   // Does the half this access actually writes carry the pattern for its
   // address?  Anything that is not a clean halfword write is not checkable
   // and must not be counted either way.
   function automatic bit half_ok(input logic [29:0] a, input logic [3:0] sel,
                                  input logic [31:0] d);
      logic [15:0] lo, hi;
      begin
         lo = {8'h80, 8'((a << 1)       & 30'hFF)};
         hi = {8'h80, 8'(((a << 1) + 1) & 30'hFF)};
         if      (sel == 4'b0011) half_ok = (d[15:0]  == lo);
         else if (sel == 4'b1100) half_ok = (d[31:16] == hi);
         else if (sel == 4'b1111) half_ok = (d == {hi, lo});
         else                     half_ok = 1'b0;
      end
   endfunction

   // app_wdf_mask is active high: a 1 means "do not write this byte".  Mask
   // everything except the bytes wb_sel asks for, in the addressed lane.
   function automatic logic [APP_MASK_WIDTH-1:0] mask_for(input logic [1:0] l,
                                                          input logic [3:0] sel);
      logic [APP_MASK_WIDTH-1:0] m;
      begin
         m = '1;
         m[l*4 +: 4] = ~sel;
         mask_for = m;
      end
   endfunction

   // ------------------------------------------------------------------
   // Wishbone side: capture the request, hand it over, wait for the answer
   // ------------------------------------------------------------------
   reg        xb_q;
   reg [31:0] xg_q, xe_q;
   reg [31:0] c_read, c_pat, c_bad;
   reg        req_pre_ok;   // set in clk_wb, consumed in ui_clk

   // The verdict on this side of the crossing, of the value clk_wb sampled.
   wire post_ok = (rd_lane == pat_for(req_adr, 1'b0)) ||
                  (rd_lane == pat_for(req_adr, 1'b1));

   reg  ack_tgl_s1, ack_tgl_s2, ack_tgl_s3;
   wire ack_pulse = ack_tgl_s2 ^ ack_tgl_s3;

   always @(posedge clk_wb) begin
      if (rst_wb) begin
         ack_tgl_s1 <= 1'b0;
         ack_tgl_s2 <= 1'b0;
         ack_tgl_s3 <= 1'b0;
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
         xb_q     <= 1'b0;
         c_read   <= 32'd0; c_pat <= 32'd0; c_bad <= 32'd0;
         req_adr  <= 30'h0;
         req_dat  <= 32'h0;
         req_sel  <= 4'h0;
         req_we   <= 1'b0;
      end else begin
         wb_ack_o <= 1'b0;

         if (!busy) begin
            if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
               req_adr <= wb_adr_i;
               // Halfword, not word.  The 68010 is a 16-bit bus, so the
               // bridge never issues a full 32-bit write and gating on
               // wb_sel_i == 4'hF made this check dead: the board read the
               // control as zero, which is exactly what it is there for.
               //
               // The read side confirms the lane mapping -- its expected word
               // is {80,idx+1,80,idx}, so bits [15:0] carry the lower byte
               // address and [31:16] the upper.
               req_pre_ok <= wb_we_i && half_ok(wb_adr_i, wb_sel_i, wb_dat_i);
               req_dat <= wb_dat_i;
               req_sel <= wb_sel_i;
               req_we  <= wb_we_i;
               req_tgl <= ~req_tgl;
               busy    <= 1'b1;
            end
         end else if (ack_pulse) begin
            wb_dat_o <= rd_lane;   // written before ack_tgl flipped, stable now
            // The same question asked again on this side of the crossing, of
            // the value clk_wb actually sampled.
            xb_q     <= pre_ok && !post_ok;
            if (!req_we) begin
               c_read <= c_read + 32'd1;
               if (pre_ok)             c_pat <= c_pat + 32'd1;
               if (pre_ok && !post_ok) c_bad <= c_bad + 32'd1;
            end
            xg_q     <= rd_lane;
            xe_q     <= pat_for(req_adr, 1'b0);
            wb_ack_o <= 1'b1;
            busy     <= 1'b0;
         end
      end
   end

   // ------------------------------------------------------------------
   // MIG side
   // ------------------------------------------------------------------
   reg  req_tgl_s1, req_tgl_s2, req_tgl_s3;
   wire req_pulse = req_tgl_s2 ^ req_tgl_s3;

   always @(posedge ui_clk) begin
      if (ui_rst) begin
         req_tgl_s1 <= 1'b0;
         req_tgl_s2 <= 1'b0;
         req_tgl_s3 <= 1'b0;
      end else begin
         req_tgl_s1 <= req_tgl;
         req_tgl_s2 <= req_tgl_s1;
         req_tgl_s3 <= req_tgl_s2;
      end
   end

   // Ask the arbiter, then wait.  Everything about actually driving MIG -- the
   // two write handshakes, the read turnaround, one transaction in flight --
   // now lives in mig_arb, because there are two masters and only one user
   // port.  What stays here is the clock crossing and the 32-bit lane
   // extraction, which is all this ever really was.
   //
   // The request fields are combinational rather than registered, which looks
   // careless and is not: req_adr and friends are written in the Wishbone
   // domain *before* req_tgl flips, and req_pulse arrives three synchroniser
   // stages later, so they have been stable for several ui_clk by the time the
   // arbiter can see them.  Registering them again would add a cycle to every
   // CPU memory access, and measurably does -- it cost a whole cpu_clk of the
   // seven the 68010 waits, which is not a reasonable price for tidiness.
   reg waiting;
   reg        rr_second;   // this c_done is the repeat of a read
   reg [31:0] rr_first;

   assign c_req   = req_pulse | waiting | rr_second;
   assign c_addr  = {{(APP_ADDR_WIDTH-27){1'b0}}, req_adr[25:2], 3'b000};
   assign c_we    = req_we;
   // The same word in all four lanes; the mask decides which copy is actually
   // written, so no read-modify-write.
   assign c_wdata = {4{req_dat}};
   assign c_wmask = mask_for(req_adr[1:0], req_sel);

   always @(posedge ui_clk) begin
      if (ui_rst) begin
         waiting <= 1'b0;
         ack_tgl <= 1'b0;
         rd_lane <= 32'h0;
         c_wpat  <= 32'd0; c_wbad <= 32'd0;
         rr_second <= 1'b0; rr_first <= 32'h0;
         dbg_rr <= 32'd0; dbg_rr_bad <= 32'd0;
         dbg_rr_v1 <= 32'h0; dbg_rr_v2 <= 32'h0;
      end else begin
         if (req_pulse) begin
            waiting <= 1'b1;
            if (req_pre_ok) begin
               c_wpat <= c_wpat + 32'd1;
               if (!half_ok(req_adr, req_sel, req_dat))
                 c_wbad <= c_wbad + 32'd1;
            end
         end

         if (c_done && DOUBLE_READ && !req_we && !rr_second) begin
            // First answer: keep it, go round once more at the same address.
            // waiting stays low; rr_second holds c_req up for the repeat.
            rr_first  <= c_rdata[lane*32 +: 32];
            rr_second <= 1'b1;
         end else if (c_done) begin
            if (rr_second) begin
               rr_second <= 1'b0;
               dbg_rr <= dbg_rr + 32'd1;
               if (c_rdata[lane*32 +: 32] != rr_first) begin
                  dbg_rr_bad <= dbg_rr_bad + 32'd1;
                  dbg_rr_v1  <= rr_first;
                  dbg_rr_v2  <= c_rdata[lane*32 +: 32];
               end
            end
            rd_lane <= c_rdata[lane*32 +: 32];
            // The verdict for this word, decided here in ui_clk where the data
            // is native, and carried across with it.
            pre_ok  <= (c_rdata[lane*32 +: 32] == pat_for(req_adr, 1'b0)) ||
                       (c_rdata[lane*32 +: 32] == pat_for(req_adr, 1'b1));
            waiting <= 1'b0;
            ack_tgl <= ~ack_tgl;
         end
      end
   end

   assign xchk_bad = xb_q;
   assign xchk_got = xg_q;
   assign xchk_exp = xe_q;
   assign xchk_n_read = c_read;
   assign xchk_n_pat  = c_pat;
   assign xchk_n_bad  = c_bad;
   assign xchk_n_wpat = c_wpat;
   assign xchk_n_wbad = c_wbad;

endmodule
