`timescale 1ns / 1ps

`include "sun2_config.vh"

//
// The 32-byte ID PROM: machine type, Ethernet address, manufacturing date,
// serial number and a checksum, one byte per 2 KiB page of the control space.
//
// Layout and checksum rule from the Architecture Manual section 4.2:
//
//     0       format, 1 for now
//     1       machine type -- 1 = MultiBus, 2 = VME (the 2/50 board is
//             "Machine Type 2", see the manual's chapter 9)
//     2-7     Ethernet address
//     8-11    date, seconds since 1 January 1970
//     12-14   serial number
//     15      checksum, "defined such that the longitudinal XOR of the first
//             16 bytes of the PROM including the checksum yields 0"
//     16-31   reserved
//
// The checksum is computed here rather than written down.  It was previously a
// literal, which is a trap: changing the machine type alone leaves the PROM
// self-inconsistent, and the boot PROM answers with "ID PROM INVALID" -- the
// same complaint whether the type is wrong or the checksum is.
//
module idprom(input CLK,
	      input [4:0]	 idx,
	      output reg [7:0] dout
	      );

   localparam [7:0] FORMAT  = 8'h01;
   localparam [7:0] MACHINE = `IDPROM_MACHINE_TYPE;

   // 8:0:20:1:6:e0
   localparam [7:0] ETH0 = 8'h08, ETH1 = 8'h00, ETH2 = 8'h20;
   localparam [7:0] ETH3 = 8'h01, ETH4 = 8'h06, ETH5 = 8'he0;

   localparam [7:0] DATE0 = 8'h1a, DATE1 = 8'he4, DATE2 = 8'h23, DATE3 = 8'h3b;

   // serial #3442
   localparam [7:0] SER0 = 8'h00, SER1 = 8'h0d, SER2 = 8'h72;

   localparam [7:0] CKSUM = FORMAT ^ MACHINE ^
                            ETH0 ^ ETH1 ^ ETH2 ^ ETH3 ^ ETH4 ^ ETH5 ^
                            DATE0 ^ DATE1 ^ DATE2 ^ DATE3 ^
                            SER0 ^ SER1 ^ SER2;

   always @(posedge CLK)
     case (idx)
       5'h00: dout <= FORMAT;
       5'h01: dout <= MACHINE;
       5'h02: dout <= ETH0;
       5'h03: dout <= ETH1;
       5'h04: dout <= ETH2;
       5'h05: dout <= ETH3;
       5'h06: dout <= ETH4;
       5'h07: dout <= ETH5;
       5'h08: dout <= DATE0;
       5'h09: dout <= DATE1;
       5'h0a: dout <= DATE2;
       5'h0b: dout <= DATE3;
       5'h0c: dout <= SER0;
       5'h0d: dout <= SER1;
       5'h0e: dout <= SER2;
       5'h0f: dout <= CKSUM;
       5'h10: dout <= 8'hff; // reserved (16 bytes)
       5'h11: dout <= 8'hff;
       5'h12: dout <= 8'hff;
       5'h13: dout <= 8'hff;
       5'h14: dout <= 8'hff;
       5'h15: dout <= 8'hff;
       5'h16: dout <= 8'hff;
       5'h17: dout <= 8'hff;
       5'h18: dout <= 8'hff;
       5'h19: dout <= 8'hff;
       5'h1a: dout <= 8'hff;
       5'h1b: dout <= 8'hff;
       5'h1c: dout <= 8'hff;
       5'h1d: dout <= 8'hff;
       5'h1e: dout <= 8'hff;
       5'h1f: dout <= 8'hff;
     endcase
endmodule
