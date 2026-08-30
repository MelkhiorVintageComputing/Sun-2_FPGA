`timescale 1ns / 1ps

//
// Two bus masters, one 68010 bus request line.
//
// A 2/50 with a SCSI board has two things that master the bus: the on-board
// 82586, whose DVMA path is on the motherboard, and the card, which is a VME
// master with its own.  They do not share a data path -- each has its own
// address latches and its own error latch, which is why this project gives
// them two sun2_dvma instances rather than one behind a Wishbone arbiter.
// What they do share is the single BR/BG handshake to the CPU, and that is
// all this arbitrates.
//
// Priority is the 82586's.  Its receive unit cannot ask the wire to wait --
// a frame arriving with nowhere to put it is a lost frame -- while the disk
// is reading from media that will still be there a microsecond later.  On the
// real machine the same ordering falls out of the VME daisy chain, the
// motherboard sitting closer to the arbiter than the card cage.
//
// The grant is locked to whoever wins until that master drops its request.
// Without the lock a higher-priority request appearing mid-transfer would move
// BG under a master that is already driving the bus, and two masters driving
// P_A at once is not a race that shows up as a wrong number -- it shows up as
// a machine that has stopped.
//
module sun2_bus_arb (
    input  wire CLK,
    input  wire RESET,

    // Client A: higher priority.
    input  wire a_br_n,
    output wire a_bg_n,

    // Client B.
    input  wire b_br_n,
    output wire b_bg_n,

    // The CPU's own handshake.
    output wire P_BR_n,
    input  wire P_BG_n
);

   reg  lock;                       // a grant is in progress
   reg  owner;                      // 0 = A, 1 = B

   wire a_req   = ~a_br_n;
   wire b_req   = ~b_br_n;
   wire cur_req = owner ? b_req : a_req;

   always @(posedge CLK) begin
      if (RESET) begin
         lock  <= 1'b0;
         owner <= 1'b0;
      end else if (!lock) begin
         if (a_req)      begin lock <= 1'b1; owner <= 1'b0; end
         else if (b_req) begin lock <= 1'b1; owner <= 1'b1; end
      end else if (!cur_req) begin
         lock <= 1'b0;
      end
   end

   // Either master asking asks the CPU.  Open drain on the real bus, an AND
   // of the active-low lines here.
   assign P_BR_n = a_br_n & b_br_n;

   // ...and the grant reaches exactly one of them, and only once the arbiter
   // has decided whose it is.  A master that is not granted sees BG high and
   // keeps waiting, which is what sun2_dvma does with it.
   assign a_bg_n = P_BG_n | ~(lock & ~owner);
   assign b_bg_n = P_BG_n | ~(lock &  owner);

endmodule
