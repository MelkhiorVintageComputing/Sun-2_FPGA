`timescale 1ns / 1ps

//
// Wishbone master on ui_clk  ->  mig_arb client 0.  No clock crossing.
//
// The partner of sun2_fifo_bridge.  That bridge puts its Wishbone side on the
// memory controller's own clock, so the crossing wb_to_mig_ui exists for --
// two toggles, two three-flop synchronisers, request fields held stable across
// the domains -- has already happened inside the bridge's FIFOs, and what is
// left is a straight mapping with no state at all:
//
//   c_req    = wb_cyc & wb_stb          held until c_done, as mig_arb wants
//   c_addr   = {wb_adr[25:2], 3'b000}   8-word aligned MIG units, lane below
//   c_wdata  = the word in all four lanes; c_wmask picks the bytes
//   wb_ack   = c_done
//   wb_dat   = c_rdata's lane           valid with c_done
//
// The address map, the lane and the active-high "do not write this byte" mask
// are wb_to_mig_ui's, unchanged; its header has the derivation from the
// generated MIG core.
//
// Why a combinational request cannot run twice: mig_arb masks c_req with its
// own registered c_done, so the cycle c_done is high cannot start another
// transaction, and the bridge drops wb_cyc on the edge it sees the ack, so the
// cycle after it cannot either.
//

module wb_mig_sync #(
    parameter int APP_ADDR_WIDTH = 28,
    parameter int APP_DATA_WIDTH = 128,
    parameter int APP_MASK_WIDTH = APP_DATA_WIDTH / 8
) (
    // ---- Wishbone slave, ui_clk domain ------------------------------------
    input  wire                      wb_cyc_i,
    input  wire                      wb_stb_i,
    input  wire [29:0]               wb_adr_i,        // 32-bit word address
    input  wire [31:0]               wb_dat_i,
    input  wire [3:0]                wb_sel_i,
    input  wire                      wb_we_i,
    output wire [31:0]               wb_dat_o,
    output wire                      wb_ack_o,

    // ---- client port on mig_arb, same domain -------------------------------
    output wire [APP_ADDR_WIDTH-1:0] c_addr,
    output wire                      c_we,
    output wire [APP_DATA_WIDTH-1:0] c_wdata,
    output wire [APP_MASK_WIDTH-1:0] c_wmask,
    output wire                      c_req,
    input  wire                      c_done,
    input  wire [APP_DATA_WIDTH-1:0] c_rdata
);

   // app_wdf_mask is active high: a 1 means "do not write this byte".
   function automatic logic [APP_MASK_WIDTH-1:0] mask_for(input logic [1:0] l,
                                                          input logic [3:0] sel);
      logic [APP_MASK_WIDTH-1:0] m;
      begin
         m = '1;
         m[l*4 +: 4] = ~sel;
         mask_for = m;
      end
   endfunction

   assign c_req    = wb_cyc_i & wb_stb_i;
   assign c_addr   = {{(APP_ADDR_WIDTH-27){1'b0}}, wb_adr_i[25:2], 3'b000};
   assign c_we     = wb_we_i;
   assign c_wdata  = {4{wb_dat_i}};
   assign c_wmask  = mask_for(wb_adr_i[1:0], wb_sel_i);

   assign wb_ack_o = c_done;
   assign wb_dat_o = c_rdata[wb_adr_i[1:0]*32 +: 32];

endmodule
