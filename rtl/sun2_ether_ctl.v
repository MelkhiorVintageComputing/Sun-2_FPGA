`timescale 1ns / 1ps

//
// The Sun-2 Ethernet control register: one byte, and the only part of the
// on-board Intel 82586 interface the CPU addresses directly.  VME machines
// only -- device page 1 (VIOPG_ETHER = 0xFE1, byte address 0x7F0800).  A
// MultiBus 2/120 has no on-board Ethernet; its page 1 is an 80287 socket.
//
// Architecture Manual section 6.13, and the driver's view of the same byte in
// the monitor source at Inputs/sunos-34-src/.../rsun/sys/sunif/if_obie.h:
//
//     D7  RESET-  0 => Ethernet reset,  1 => normal operation      R/W
//     D6  LOOPB-  0 => loopback,        1 => normal operation      R/W
//     D5  CA      channel attention to the 82586                   R/W
//     D4  INTEN   enable 82586 interrupts to the CPU               R/W
//     D3  --      reserved                                        R/O
//     D2  --      transceiver type, 0 = Level 1, 1 = Level 2      R/O
//     D1  ERR     a bus error happened during an 82586 cycle      R/O
//     D0  INT     interrupt pending from the 82586                R/O
//
// "Initialization: cleared on all resets", so reset leaves the chip held in
// reset and in loopback -- which is also the first thing iereset() writes.
// CA is a level here, not a strobe: the 82586 latches the rising edge of the
// pin, so the driver sets it and clears it again.
//
// There is no 82586 behind this yet, and the read-only bits are therefore
// honestly zero.  The register still has to exist, because ieprobe() on a VME
// machine reports Ethernet present from the ID PROM machine-type byte alone,
// without issuing a single bus cycle -- so `ie' joins the boot device list
// whether or not the chip is fitted, and auto-boot then calls iereset(), which
// does write here.  With INT and ERR stuck low the driver polls for the ISCP
// busy flag to clear, gives up after ten tries, prints "ie: cannot initialize"
// and moves on to the next boot device.  Without the register it would instead
// take a bus error that nothing had installed a handler for.
//
// Inputs/Wish82586/src/wb_csr_sun2.sv implements this same register as a
// Wishbone slave, for the day the real MAC is wired up.  Keep the two
// reconcilable: same bit assignment, same reset state.
//
module sun2_ether_ctl(input 		CLK,
		      input 		RESET,
		      input [7:0] 	din,
		      input 		WR,
		      output [7:0] 	dout,
		      /* to a future 82586 */
		      output 		core_reset_n, // 0 => hold the MAC in reset
		      output 		loopback_n,
		      output 		ca,           // channel attention, level
		      output 		int_en,
		      input 		int_in,       // interrupt pending
		      input 		bus_err_in    // DMA cycle took a bus error
		      );

   // Only the top nibble is writable; the bottom nibble is status.
   reg [3:0] 				ctl;

   always @(posedge CLK)
     if (RESET)   ctl <= 4'h0;
     else if (WR) ctl <= din[7:4];

   assign core_reset_n = ctl[3];
   assign loopback_n   = ctl[2];
   assign ca           = ctl[1];
   assign int_en       = ctl[0];

   assign dout = {ctl, 2'b00, bus_err_in, int_in};

endmodule
