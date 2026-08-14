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
    input  wire [APP_DATA_WIDTH-1:0] c_rdata
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

   reg        req_tgl;      // toggles to launch a transaction   (clk_wb)
   reg        ack_tgl;      // toggles when one completes        (ui_clk)
   reg        busy;

   wire [1:0] lane = req_adr[1:0];

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

   assign c_req   = req_pulse | waiting;
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
      end else begin
         if (req_pulse)   waiting <= 1'b1;

         if (c_done) begin
            rd_lane <= c_rdata[lane*32 +: 32];
            waiting <= 1'b0;
            ack_tgl <= ~ack_tgl;
         end
      end
   end

endmodule
