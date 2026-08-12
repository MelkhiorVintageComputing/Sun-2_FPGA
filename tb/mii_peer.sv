`timescale 1ns / 1ps

//
// A benign MII link for simulation: clocks, an idle receive side, and no
// carrier or collisions.
//
// This is not decoration.  The boot PROM's driver waits on the 82586 with no
// timeout anywhere -- `while (scb->ie_cmd != 0)` and `while (!cb->ie_done)` in
// iesimple(), and the same shape in iexmit() -- so a transmit that never
// completes hangs the machine solid, with no message and no bus error to show
// for it.  The transmit datapath is clocked by mii_tx_clk, which on real
// hardware comes from the PHY.  With no PHY and no clock, the first TRANSMIT
// command never finishes and the PROM stops dead.
//
// Holding crs and col inactive is the other half: mii_tx defers to carrier
// sense before transmitting, so a carrier stuck active would also hang it.
// An unplugged AUI is quiet, which is what we model.
//
// The line rate is ours to pick in simulation, and it is the cheapest knob for
// bus pressure: BIT_PERIOD_NS = 100 is 10 Mb/s, the rate a Sun-2 actually ran.
// Four bits per MII clock, so the clock period is four times that.
//
module mii_peer #(
    parameter int PHY_DATA_W   = 4,
    parameter int BIT_PERIOD_NS = 100   // 100 ns/bit = 10 Mb/s
) (
    output reg                   mii_tx_clk,
    input  wire [PHY_DATA_W-1:0] mii_txd,
    input  wire                  mii_tx_en,
    input  wire                  mii_tx_er,
    output reg                   mii_rx_clk,
    output reg  [PHY_DATA_W-1:0] mii_rxd,
    output reg                   mii_rx_dv,
    output reg                   mii_rx_er,
    output reg                   mii_crs,
    output reg                   mii_col
);

   localparam real HALF = (BIT_PERIOD_NS * PHY_DATA_W) / 2.0;

   initial begin
      mii_tx_clk = 1'b0;
      mii_rx_clk = 1'b0;
      mii_rxd    = '0;
      mii_rx_dv  = 1'b0;
      mii_rx_er  = 1'b0;
      mii_crs    = 1'b0;   // quiet line: nothing to defer to
      mii_col    = 1'b0;   // and nobody to collide with
   end

   // +crs_stuck jams carrier sense on, which is what a PHY out of reset, with
   // no link, or with CRS wired to a pull-up looks like -- the Wukong pulls it
   // up through R59.  Without a deferral timeout in the MAC this hangs the boot
   // PROM outright, so this is how that defence gets tested rather than assumed.
   int crs_stuck = 0;
   initial begin
      void'($value$plusargs("crs_stuck=%d", crs_stuck));
      if (crs_stuck != 0) begin
         $display("mii_peer: holding carrier sense asserted -- the medium never goes idle");
         #1 mii_crs = 1'b1;
      end
   end

   // Two clocks of the same rate but deliberately not the same edge, as a PHY's
   // would be: the MAC crosses between them with gray-coded FIFOs and a
   // four-phase handshake, and running them in lockstep would hide a fault in
   // either.
   always #(HALF)         mii_tx_clk = ~mii_tx_clk;
   always #(HALF * 1.013) mii_rx_clk = ~mii_rx_clk;

   // Count what the machine puts on the wire.  With no server out there the
   // PROM will send ND boot requests and get nothing back, so this is the
   // evidence that the transmit path ran at all.
   int frames = 0;
   always @(posedge mii_tx_clk)
     if (mii_tx_en && !$past(mii_tx_en, 1)) begin
        frames++;
        $display("[%t] mii_peer: frame %0d begins on the wire", $realtime, frames);
     end

endmodule
