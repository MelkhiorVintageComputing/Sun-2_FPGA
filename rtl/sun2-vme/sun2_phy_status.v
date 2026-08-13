`timescale 1ns / 1ps

//
// What the Ethernet PHY did, in a place the monitor prompt can read it.
//
// Device page 0xFE7, VME machines only.  A real 2/50 has nothing there -- the
// I/O page map in Inputs/sunos-34-src/.../rsun/sys/mon/s2map.h stops at
// VIOPG_TIMER (0xFE5) and comments 0xFE6 and 0xFE7 as "unused" -- and the boot
// PROM never maps either, so this invents a register where the real machine has
// no device rather than misrepresenting one that exists.  On a MultiBus 2/120
// page 7 is the National 58167 real-time clock, which we do not implement, so
// this is compiled out entirely there and page 7 keeps timing out.
//
// The reason it exists at all: the board this runs on cannot be probed.  The
// three ways the Ethernet fails silently on real hardware -- the PHY never
// answered MDIO, it negotiated gigabit and is presenting 8-bit GMII to a 4-bit
// MII MAC, or it is holding carrier sense so every transmit defers -- are
// indistinguishable from the console, and all three are answered by one read
// here.  That is diagnosis without a scope.
//
// From the `>' prompt: map a page at it with P, then read with E.  The page map
// entry wants valid, all permissions, type 1 (VPM_IO), page 0xFE7:
//
//     >p<addr>                        (opens the page map entry for <addr>)
//     ...  1FE7 0FE7 ...              (valid + PMP_ALL + type 1, page 0xFE7)
//     >e<addr>
//     001C                            PHYID1 -- a Realtek part answered
//     >                               (return steps to the next word)
//     C000                            configured, identifier matched, no link
//
// Read-only, and a write is not acknowledged: it takes the 12-clock timeout and
// a bus error, which is exactly what writing the ID PROM does today.
//
//   +0  PHYID1 as read back over MDIO.  0x001C is the Realtek OUI; 0x0000 or
//       0xFFFF means the management interface never answered, which on this
//       board means the wiring, the PHY address strap or the reset timing.
//
//   +2  status
//       15  CFGDONE   the bring-up sequence ran to the end
//       14  PRESENT   ... and PHYID1 matched, so we are talking to the PHY we
//                     think we are.  Address 0 is a broadcast, so something
//                     answering is not by itself proof of the address strap.
//       13  LINK
//       12  FDX       full duplex
//    11:10  SPEED     00 = 10, 01 = 100, 10 = 1000 Mb/s.  Anything but 00 means
//                     the MAC and the PHY disagree about the width of the
//                     interface and no frame will ever cross it.
//        9  CRSNOW    carrier sense is asserted right now, and has been for
//                     long enough that it is not traffic
//        8  CRSEVER   ... or has been at any point since reset.  Sticky,
//                     because the transmit deferral timeout clears the
//                     condition faster than a human can read a register.
//      7:0  reserved, zero
//
// Everything here arrives from clock domains that are not the CPU's -- the PHY
// sequencer runs on cpu_clk but its enable comes from the board's 50 MHz reset
// counter, and crs_stuck comes from the MII transmit clock.  These are all
// quasi-static status bits sampled by a CPU read, so a resynchronising flop
// each is enough; nothing here is decoded in combination with anything else.
//
module sun2_phy_status(input             CLK,
		       input 		 RESET,
		       input 		 P_A1,        // word select within the page
		       output [15:0] 	 dout,
		       /* from the board's PHY management */
		       input [15:0] 	 phy_id,
		       input 		 phy_present,
		       input 		 phy_cfg_done,
		       input 		 phy_link,
		       input 		 phy_fd,
		       input [1:0] 	 phy_speed,
		       /* from the MAC */
		       input 		 crs_stuck
		       );

   (* ASYNC_REG = "TRUE" *) reg [15:0] id_s1, id_s2;
   (* ASYNC_REG = "TRUE" *) reg [5:0]  st_s1, st_s2;
   (* ASYNC_REG = "TRUE" *) reg 	  crs_s1, crs_s2;

   reg 					  crs_ever;

   always @(posedge CLK) begin
      id_s1  <= phy_id;
      id_s2  <= id_s1;
      st_s1  <= {phy_cfg_done, phy_present, phy_link, phy_fd, phy_speed};
      st_s2  <= st_s1;
      crs_s1 <= crs_stuck;
      crs_s2 <= crs_s1;
   end

   // Sticky: the deferral timeout in the MAC gives up and drops the condition
   // long before anyone gets to the prompt to look at it.
   always @(posedge CLK)
     if (RESET)        crs_ever <= 1'b0;
     else if (crs_s2)  crs_ever <= 1'b1;

   assign dout = P_A1 ? {st_s2, crs_s2, crs_ever, 8'h00}
                      : id_s2;

endmodule
