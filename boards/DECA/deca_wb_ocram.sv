//
// The Sun-2's main memory, in the FPGA's own block RAM.
//
// This is what replaces the Wukong's entire wb_to_mig_ui + mig_arb + MIG stack.
// A MAX 10 has no hard memory controller and the DECA's 512 MB of DDR3 needs
// Altera's soft UniPHY, which nothing in the DECA ecosystem actually uses --
// so stage one of this port has no external memory at all and the machine's
// RAM is M9K.
//
// That is only viable because the boot PROM turns out to need far less memory
// than anyone had written down.  sun2_config.vh said "the PROM is happy with as
// little as 256 KiB"; measured, a VME machine reaches the monitor prompt with
// **32 KiB**, and every size from 16 to 128 pages does.  What it cannot do on
// chip is netboot: the bootloader's buffer is at 0x0a0462, 640 KiB up, and a
// small machine takes a protection violation there and drops to the prompt.
// So this file is the monitor's memory, not SunOS's, and that ceiling is a
// property of the machine rather than of the board.
//
// ------------------------------------------------------- the contract
//
// Read out of rtl/sun2-common/sun2_wishbone_bridge.v, because a slave that
// merely looks right is how the DVMA corruption bug survived for months:
//
//  * 30-bit **word** address; main memory is {8'h0, P_ADR_IN[23:2]}, i.e. the
//    byte address over four, based at zero (bridge :113).
//  * **The ack must be registered.**  Bridge :91-96 states it as an assumption
//    the `issued' guard depends on -- "Slaves here register their ack, it can
//    never arrive in the same clock the request goes out".  A combinational
//    ack would defeat the guard that fixed a real data-corruption bug.
//  * Exactly **one** ack per request.  `done' then holds DTACK for the rest of
//    the bus cycle, so a second ack would be attributed to the next cycle.
//  * cyc/stb stay up until that ack (bridge :106-110), so no request is ever
//    withdrawn under us.
//  * **Every request must be acknowledged, including out-of-range ones.**
//    Memory is exempt from the bus timeout (sun2_fpga.v: ~MATCH_MEM & ~MATCH_FB),
//    which is the bargain DDR3 needed -- and it cuts both ways: a cycle up here
//    that is never answered hangs the machine for ever instead of raising a bus
//    error.  Out of range returns zero and acks.
//
// ------------------------------------------------------- the implementation
//
// Four independent WORDS x 8 arrays, one per byte lane, each with its own write
// enable.  One 32-bit array with byte enables would ask Quartus to infer a
// byte-enabled M9K and the packing is identical either way (8192 usable bits per
// block at a power-of-two width), so the four-lane form buys determinism for
// nothing.
//
// The read port is deliberately **unconditional** -- no enable, no gating.  That
// is the M9K's natural single-port shape, and the bridge never latches read data
// during a write anyway (it gates the capture on ~wb_we_o).  Gating it would ask
// for a read-during-write mode the block does not have and get bypass logic in
// exchange for nothing.
//
`timescale 1ns / 1ps

`include "sun2_config.vh"
`include "sun2_attr.vh"

module deca_wb_ocram (
    input  wire        clk,
    input  wire        rst,          // active high
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire [29:0] wb_adr_i,     // word address
    input  wire [31:0] wb_dat_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_we_i,
    output wire [31:0] wb_dat_o,
    output reg         wb_ack_o
);

   // Derived from `MEM_PAGES through sun2_config.vh, never from a parameter.
   // If the RAM's depth and what the machine reports as installed could drift
   // apart, the PROM's sizing loop would read back plausible values from
   // aliased addresses and the machine would be silently wrong about itself --
   // which is far worse than being too small.
   localparam integer WORDS = `MEM_PAGES * 512;   // 2 KiB page = 512 32-bit words
   localparam integer AW    = $clog2(WORDS);

   `SUN2_RAM_BLOCK reg [7:0] mem0 [0:WORDS-1];
   `SUN2_RAM_BLOCK reg [7:0] mem1 [0:WORDS-1];
   `SUN2_RAM_BLOCK reg [7:0] mem2 [0:WORDS-1];
   `SUN2_RAM_BLOCK reg [7:0] mem3 [0:WORDS-1];

   wire [AW-1:0] a        = wb_adr_i[AW-1:0];
   wire          in_range = (wb_adr_i < WORDS);
   // ~wb_ack_o makes the request a single event: cyc/stb are still asserted in
   // the clock the ack goes out, and without this the slave would see a second
   // request and ack twice for one cycle.
   wire          req      = wb_cyc_i & wb_stb_i & ~wb_ack_o;
   wire          wr       = req & wb_we_i & in_range;

   reg [7:0] q0, q1, q2, q3;

   always @(posedge clk) begin
      if (wr & wb_sel_i[0]) mem0[a] <= wb_dat_i[ 7: 0];
      if (wr & wb_sel_i[1]) mem1[a] <= wb_dat_i[15: 8];
      if (wr & wb_sel_i[2]) mem2[a] <= wb_dat_i[23:16];
      if (wr & wb_sel_i[3]) mem3[a] <= wb_dat_i[31:24];
      q0 <= mem0[a];
      q1 <= mem1[a];
      q2 <= mem2[a];
      q3 <= mem3[a];
   end

   // Registered, one clock after the request, and asserted for every request
   // whether in range or not -- see the contract above.
   always @(posedge clk)
     wb_ack_o <= rst ? 1'b0 : req;

   assign wb_dat_o = in_range ? {q3, q2, q1, q0} : 32'h00000000;

endmodule
