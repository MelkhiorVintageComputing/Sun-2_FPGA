`timescale 1ns / 1ps

`include "sun2_attr.vh"

//
// The 2/50's frame buffer, on an HDMI screen.
//
// Reads 1152x900x1 out of DDR3 and presents it as 24-bit RGB at whatever
// position the HDMI generator is currently drawing, letterboxed inside
// 1920x1080 -- 384 pixels of border either side, 90 lines above and below.
// Scaling would need 1152*2 = 2304 pixels, which does not fit, so the image is
// 1:1 with a wide surround.
//
// Two clock domains meet here:
//
//   ui_clk      83.33 MHz, MIG's user interface, where the reads happen
//   clk_pixel  148.4375 MHz, where cx/cy come from and pixels go out
//
// They are joined by a **ping-pong line buffer**, not a stream FIFO.  A FIFO
// would need its read and write pointers reset together at every frame, which
// is an awkward thing to do across two clocks and easy to get subtly wrong; a
// line buffer needs only two one-bit pulses to cross, and those can be toggles.
// There is room to be relaxed about it: fetching a line costs about 2.4 us of
// ui_clk and a 1080p60 line lasts 14.8 us, so the fetch has roughly six times
// the time it needs.
//
// **Bit order.**  A 128-bit beat is 128 consecutive pixels, and within it
// aperture halfword k is beat[16k+15:16k] with bit 15 the leftmost pixel.
// That is worth stating because it is the product of two swaps that happen to
// cancel: the Wishbone bridge puts the CPU word at A1=0 in the *low* half of
// its 32-bit word, and the 68010 is big-endian within each 16-bit word.  The
// net effect is that halfwords come out in order and only the bits inside them
// run MSB first.  So for pixel p of a beat the bit is at {p[6:4], ~p[3:0]}.
//
// **Polarity.**  On a Sun-2 a 1 bit is black and a 0 bit is white -- the
// opposite of the Sun-1, and the monitor's own finit() says so.  White is what
// an idle screen should be.
//
module fb_scanout #(
    // app_addr of the frame buffer.  app_addr counts 2-byte DDR3 words and a
    // burst is 8 of them, so this is the byte address divided by two: the
    // default is byte 0x0F800000, 248 MiB, matching FB_WB_BASE.
    parameter logic [27:0] FB_APP_BASE = 28'h7C00000,

    parameter int FB_W     = 1152,
    parameter int FB_H     = 900,
    parameter int SCREEN_W = 1920,
    parameter int SCREEN_H = 1080
) (
    // ---- ui_clk: client 1 of mig_arb ------------------------------------
    input  wire         ui_clk,
    input  wire         ui_rst,
    output wire [27:0]  c_addr,
    output wire         c_req,
    input  wire         c_done,
    input  wire [127:0] c_rdata,

    // ---- clk_pixel: where the picture is ---------------------------------
    input  wire         clk_pixel,
    input  wire         pix_rst,
    input  wire [11:0]  cx,
    input  wire [10:0]  cy,
    input  wire         video_en,     // the control register's DISPEN, cpu_clk
    output wire [23:0]  rgb
);

   localparam int BEATS_PER_LINE = FB_W / 128;             // 9
   localparam int X0             = (SCREEN_W - FB_W) / 2;  // 384
   localparam int Y0             = (SCREEN_H - FB_H) / 2;  // 90

   // Two buffers of BEATS_PER_LINE, indexed buf*16 + beat.  16 rather than 9
   // so the index is a plain concatenation instead of a multiply.
   `SUN2_RAM_BLOCK reg [127:0] linebuf [0:31];

   // ------------------------------------------------------------------
   // Pixel side
   // ------------------------------------------------------------------
   wire        in_y   = (cy >= Y0) && (cy < Y0 + FB_H);
   wire        in_x   = (cx >= X0) && (cx < X0 + FB_W);
   wire [10:0] fb_row = cy - Y0[10:0];

   // DISPEN is written in the CPU clock domain and read here.  It is one bit
   // and quasi-static, so two flops are the whole story.
   `SUN2_ASYNC_REG reg ven_s1, ven_s2;
   always @(posedge clk_pixel) begin
      ven_s1 <= video_en;
      ven_s2 <= ven_s1;
   end

   // Start-of-frame and start-of-line, as toggles for the other domain.  Both
   // are raised in the blanking to the left of the picture, so the fetch they
   // trigger has the whole of that line to complete.
   reg vs_tgl, ls_tgl;
   always @(posedge clk_pixel) begin
      if (pix_rst) begin
         vs_tgl <= 1'b0;
         ls_tgl <= 1'b0;
      end else begin
         if (cx == 0 && cy == 0)      vs_tgl <= ~vs_tgl;
         if (cx == 0 && in_y)         ls_tgl <= ~ls_tgl;
      end
   end

   // The shifter.  pixbuf holds the beat being displayed; nextbuf is fetched
   // from the line buffer well ahead of when it is needed, which is why the
   // block RAM's registered output costs nothing here.
   //
   // There is exactly **one** read address, and that is not incidental: an
   // earlier version also read beat 0 directly when entering the picture,
   // which together with the write port made three, and three ports cannot be
   // block RAM.  Vivado said so -- "Infeasible attribute ram_style" -- and
   // quietly built it out of LUTs instead, which then failed timing by 9.8 ns.
   // So beat 0 is primed through the same path as every other beat, a couple
   // of pixels earlier.
   reg [127:0] pixbuf, nextbuf;
   reg [6:0]   p;          // pixel within the beat
   reg [3:0]   bidx;       // which beat of the line to read next

   wire        rdbuf = fb_row[0];

   always @(posedge clk_pixel) begin
      if (pix_rst) begin
         p      <= 7'h0;
         bidx   <= 4'h0;
         pixbuf <= 128'h0;
      end else if (cx == X0 - 3 && in_y) begin
         // Aim the one read port at beat 0, so nextbuf has it by X0-1.
         bidx <= 4'h0;
      end else if (cx == X0 - 1 && in_y) begin
         pixbuf <= nextbuf;      // beat 0
         bidx   <= 4'h1;
         p      <= 7'h0;
      end else if (in_x && in_y) begin
         if (p == 7'd127) begin
            pixbuf <= nextbuf;
            bidx   <= bidx + 4'h1;
            p      <= 7'h0;
         end else begin
            p <= p + 7'h1;
         end
      end
   end

   always @(posedge clk_pixel)
     nextbuf <= linebuf[{rdbuf, bidx}];

   // 1 is black, 0 is white.
   wire pix     = pixbuf[{p[6:4], ~p[3:0]}];
   wire visible = in_x && in_y && ven_s2;
   assign rgb   = visible ? {24{~pix}} : 24'h000000;

   // ------------------------------------------------------------------
   // ui_clk side
   // ------------------------------------------------------------------
   // Cross the two toggles and turn them back into pulses.
   `SUN2_ASYNC_REG reg vs_s1, vs_s2;
   `SUN2_ASYNC_REG reg ls_s1, ls_s2;
   reg vs_s3, ls_s3;
   always @(posedge ui_clk) begin
      vs_s1 <= vs_tgl; vs_s2 <= vs_s1; vs_s3 <= vs_s2;
      ls_s1 <= ls_tgl; ls_s2 <= ls_s1; ls_s3 <= ls_s2;
   end
   wire vs_pulse = vs_s2 ^ vs_s3;
   wire ls_pulse = ls_s2 ^ ls_s3;

   // Which line to fetch, and how far into it.  Start of frame fetches line 0;
   // the start of line n fetches line n+1, so the buffer the pixel side is not
   // reading is always the one being filled.
   reg [10:0] fetch_row;
   reg [3:0]  fetch_beat;
   reg        fetching;

   wire [27:0] row_base = FB_APP_BASE + 28'(fetch_row) * 28'(BEATS_PER_LINE * 8);

   assign c_addr = row_base + {24'h0, fetch_beat} * 28'd8;
   // **c_req is a level, not a strobe**, and that is MIG's contract rather
   // than a universal one.  It stays up for the whole line and advances one
   // beat per c_done; boards/Wukong/mig_arb.sv consumes it that way.
   //
   // A controller whose command input is a single-clock strobe -- BrianHG's
   // CMD_ena, for one -- needs an adapter between it and this, or it takes a
   // fresh command every clock for an address that has not completed.  The
   // returns then fill every slot of the line buffer with the first beat's
   // data, and the screen shows FB_W/128 copies of the leftmost 128 pixels.
   // That is a handshake fault that looks exactly like a line-buffer fault;
   // boards/DECA/deca_top.sv carries the adapter and the story.
   assign c_req  = fetching;

   always @(posedge ui_clk) begin
      if (ui_rst) begin
         fetch_row  <= 11'h0;
         fetch_beat <= 4'h0;
         fetching   <= 1'b0;
      end else if (vs_pulse) begin
         // A new frame: forget anything in flight and start at the top.  The
         // 90 blank lines above the picture are 1.3 ms, so there is no hurry.
         fetch_row  <= 11'h0;
         fetch_beat <= 4'h0;
         fetching   <= 1'b1;
      end else if (ls_pulse) begin
         fetch_row  <= fetch_row + 11'h1;
         fetch_beat <= 4'h0;
         fetching   <= (fetch_row + 11'h1) < FB_H[10:0];
      end else if (fetching && c_done) begin
         if (fetch_beat == BEATS_PER_LINE[3:0] - 4'h1) begin
            fetching <= 1'b0;         // line done; wait for the next line start
         end else begin
            fetch_beat <= fetch_beat + 4'h1;
         end
      end
   end

   // The buffer being filled is the one the pixel side is not reading: line n
   // is displayed from buffer n[0], and while line n is on screen we are
   // fetching line n+1.
   always @(posedge ui_clk)
     if (fetching && c_done)
       linebuf[{fetch_row[0], fetch_beat}] <= c_rdata;

endmodule
