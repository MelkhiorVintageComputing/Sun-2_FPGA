`timescale 1ns / 1ps

`include "sun2_attr.vh"

//
// Reset synchroniser: asserts asynchronously, releases synchronously.
//
// The board's reset condition is assembled in the clk50 domain from the
// button, the MMCM lock and MIG's calibration status, none of which are
// related to the clock the logic being reset actually runs on.  Feeding that
// straight into flip-flop clear pins leaves the *release* unsynchronised:
// registers come out of reset at slightly different times depending on routing,
// and the recovery/removal checks fail -- which is precisely what the first
// build reported, on the path into the SCC.
//
// Holding the reset asynchronously is what we want (it works before any clock
// is running); releasing it on a clock edge in the destination domain is what
// makes that safe.
//
// ASYNC_REG keeps the chain in one slice and tells the tools these registers
// are expected to go metastable.  It is spelled through sun2_attr.vh because
// this file is shared between two vendors now and each ignores the other's
// attribute silently -- see that header.
//
// This lives in rtl/ rather than under a board because async-assert /
// sync-release is not a property of any board: the Wukong assembles its reset
// from a button, an MMCM lock and MIG's calibration, the DECA from a button and
// two PLL locks, and both need the same synchroniser at the end of it.
//

module reset_sync #(
    parameter int STAGES = 3
) (
    input  wire clk,
    input  wire rst_async_in,    // active high, any domain
    output wire rst_sync_out     // active high, released synchronously to clk
);

   `SUN2_ASYNC_REG reg [STAGES-1:0] chain;

   always @(posedge clk or posedge rst_async_in) begin
      if (rst_async_in) chain <= {STAGES{1'b1}};
      else              chain <= {chain[STAGES-2:0], 1'b0};
   end

   assign rst_sync_out = chain[STAGES-1];

endmodule
