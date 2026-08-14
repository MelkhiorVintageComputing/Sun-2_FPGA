`timescale 1ns / 1ps

//
// The Sun-2 video control register.
//
// One 16-bit register, the same on both machines and mapped by both boot PROMs
// at the same *virtual* address, 0xEE3800.  Only the page-map entry behind it
// differs:
//
//   2/50   TYPE 1 page 0x40   -- on-board I/O 0x020000
//   2/120  TYPE 0 page 0xF03  -- 0x781800, on the video board in the eighth
//                               megabyte, decoded from A19/A12/A11 alone and
//                               therefore aliased up to 0x7FFFFE
//
// The pixels are not here on either machine: they live in DDR3 and get there
// through the Wishbone bridge.
//
// Sources, which agree: the Architecture Manual section 6.3, struct videoctl in
// Inputs/sunos-34-src/.../mon/h/video.h, struct bw2cr in
// .../sun/sys/sundev/bw2reg.h, and Table 2-1 of the 2/120 video board manual
// (Inputs/doc/800-1187-01_2-120_Video_Board_Engr_Sep84.pdf, page 2-3).
//
//   15  video_en      R/W  display enable
//   14  copy_en       R/W  copy mode -- see below
//   13  int_en        R/W  vertical retrace interrupt enable
//   12  int           R/O  interrupt pending
//   11  b_jumper      R/O  configuration jumper, 0 = default
//   10  a_jumper      R/O  configuration jumper, 0 = default
//    9  color_jumper  R/O  1 = use a Sun-2 colour board as the console
//    8  1024_jumper   R/O  1 = the screen is 1024x1024
//    7  -             R/O  writable, reads back zero
//  6:1  copybase      R/W  copy source, physical A17..A22
//    0  -             R/O  writable, reads back zero
//
// The Architecture Manual describes bits 11:8 differently for Machine Type 1 --
// 10:8 reserved and 11 an audio enable for a sound generator at 0x780800.  That
// is the device-layer abstraction, not this board: the 2/120 video board's own
// manual gives 11:8 as the J1600 configuration jumpers, read only, and marks
// 0x780800 NOT USED.  There is no sound generator on it.  bw2reg.h agrees with
// the board, and bw2reg.h is the driver that has to work on both machines.
//
// Four things about this are load-bearing:
//
//   * **The jumpers must read back zero.**  They are sense inputs on the real
//     card (Engineering Manual 2.7.1, J1600) and the PROM reads them to decide
//     what it is looking at.  A 1 in 1024_jumper makes it 1024x1024 instead of
//     1152x900; a 1 in color_jumper makes finit() go looking for a CG2 colour
//     board at VME 0x400000 and, not finding one, give up on the display
//     entirely.
//
//   * **The register aliases across its whole 2 KiB page.**  There is no
//     address decode below bit 11 here, on purpose.  SunOS's bwtwoprobe()
//     reads offset 0 and offset 2 and requires them equal -- "the control
//     register is replicated every 2 bytes throughout the control page" -- and
//     returns "no frame buffer" if they differ.
//
//   * **copybase must be writable and read back -- but only bits 6:1.**  The
//     same probe writes 0x2A and then 0x54 into bits 7:1 and compares the whole
//     word each time.  Nothing ever uses the value, but the field has to behave
//     like a register.  Bits 7 and 0 are not part of it: the board manual says
//     they "can be written to by the processor, but only read back as a zero",
//     and bw2reg.h warns "vc_copybase & 0x81 == aberrant bits.  Don't depend on
//     'em!".  Both probe values have those two bits clear, so the distinction
//     is invisible to every piece of software in the tree -- it is here because
//     it is what the hardware does.
//
//   * **Reset clears it.**  "Initialization: cleared on reset."  The PROM
//     re-enables video unconditionally after every reset, so the state that
//     matters is that video is *off* until it does.
//
// Copy mode is a register bit here and nothing more.  On the real card, with
// copy_en set, a write anywhere in the 128 KiB of main memory selected by
// copybase was also written to the frame buffer, so SunOS could keep a fast
// shadow copy and let the hardware mirror it.  No software in the tree uses
// it: the monitor's path is behind an #ifdef COPYMODE that no Makefile
// defines, and no bwtwo line in any conf.sun2 config carries the flags that
// would turn it on.
//
// The vertical retrace interrupt is the same story.  It is level 4 and
// autovectored, the bits are here, and nothing in the tree ever sets int_en --
// BW2_INTENABLEMASK is only ever written as zero.  int reads back zero and
// nothing is asserted; if that ever changes, note that the real card clears
// the interrupt by momentarily dropping int_en rather than by writing int.
//
module sun2_fb_ctl(input 	    CLK,
		   input 	    RESET,
		   input [15:0]     din,
		   input 	    WR,
		   input 	    UDS_n,   // D15:8, the even byte
		   input 	    LDS_n,   // D7:0,  the odd byte
		   output [15:0]    dout,
		   /* to the display */
		   output 	    video_en,
		   /* to the interrupt encoder -- never asserted, see above */
		   output 	    fb_int
		   );

   reg 				    r_video_en;
   reg 				    r_copy_en;
   reg 				    r_int_en;
   reg [7:0] 			    r_copybase;

   // Byte lanes are honoured even though nothing writes a single byte: SunOS
   // documents that byte writes to this register misbehave on the real card
   // ("replicates itself on the subsequent byte as well ... this is a hardware
   // bug") and word-accesses it to avoid them.  Doing it properly here costs
   // nothing and means a byte write does the obvious thing rather than the
   // documented wrong thing.
   always @(posedge CLK)
     if (RESET) begin
        r_video_en <= 1'b0;
        r_copy_en  <= 1'b0;
        r_int_en   <= 1'b0;
        r_copybase <= 8'h00;
     end else if (WR) begin
        if (~UDS_n) begin
           r_video_en <= din[15];
           r_copy_en  <= din[14];
           r_int_en   <= din[13];
        end
        if (~LDS_n)
          r_copybase <= din[7:0];
     end

   assign dout = {r_video_en,        // 15
                  r_copy_en,         // 14
                  r_int_en,          // 13
                  1'b0,              // 12  int, never pending
                  4'b0000,           // 11:8 jumpers: b, a, colour, 1024
                  1'b0,              // 7    aberrant, reads zero
                  r_copybase[6:1],   // 6:1  copy base A17..A22
                  1'b0};             // 0    aberrant, reads zero

   assign video_en = r_video_en;
   assign fb_int   = 1'b0;

endmodule
