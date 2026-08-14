`timescale 1ns / 1ps

//
// fb_scanout against a known pattern.
//
// The things that are easy to get wrong here all look right in a waveform:
// which bit of a 128-bit beat is the leftmost pixel, whether the picture sits
// where it should inside 1920x1080, and whether a 1 bit is black or white.  So
// this fills DDR3 with a pattern whose value at every pixel is computable,
// sweeps a whole frame, and compares every pixel of it.
//
// It also watches for the one failure that would not show as a wrong pixel at
// all: the line fetch not keeping up.  A line is 9 beats of DDR3 read against
// a 14.8 us line period, which is roughly six times the time it needs, but
// "roughly six times" is an argument and this is a measurement.
//
// Two plusargs turn the same run into a screenshot of a real machine:
//
//   +fb_image=<file>   scan out a frame buffer captured from a boot instead of
//                      the pattern.  tb_sun2 writes one at the end of every
//                      SUN2_FB run.
//   +fb_ppm=<file>     write the frame that was checked as a binary PPM.
//
// Neither is required and neither changes anything when absent, so the
// regression is the same test it always was.  See "make -C sim screenshot".
//
module tb_fb_scanout;

   localparam int FB_W = 1152, FB_H = 900;
   localparam int SCREEN_W = 1920, SCREEN_H = 1080;
   localparam int FRAME_W  = 2200, FRAME_H = 1125;   // 1080p60 including blanking
   localparam int X0 = (SCREEN_W - FB_W)/2;          // 384
   localparam int Y0 = (SCREEN_H - FB_H)/2;          // 90
   localparam int BEATS_PER_LINE = FB_W/128;         // 9

   localparam logic [27:0] FB_APP_BASE = 28'h7C00000;

   // 83.33 MHz and 148.4375 MHz, the real pair.
   logic ui_clk = 0;    always #6.0    ui_clk    = ~ui_clk;
   logic clk_pixel = 0; always #3.3684 clk_pixel = ~clk_pixel;

   logic ui_rst = 1, pix_rst = 1;

   // ------------------------------------------------------------------
   // The pattern
   // ------------------------------------------------------------------
   // Halfword h of beat b of row r is a hash of where it is, so a pixel taken
   // from the wrong place is overwhelmingly likely to differ.
   function automatic logic [15:0] pat_halfword(input int r, input int b, input int h);
      pat_halfword = 16'((r * 9 + b) * 8 + h) ^ 16'hA5C3;
   endfunction

   function automatic logic [127:0] pat_beat(input int r, input int b);
      logic [127:0] v;
      begin
         for (int h = 0; h < 8; h++) v[16*h +: 16] = pat_halfword(r, b, h);
         pat_beat = v;
      end
   endfunction

   // What the pixel at frame-buffer (x, y) must be.  Halfword k of a beat is
   // beat[16k+15:16k] and bit 15 of it is the leftmost pixel.
   function automatic logic pat_pixel(input int x, input int y);
      int b, p, h, bit_in_h;
      begin
         b        = x / 128;
         p        = x % 128;
         h        = p / 16;
         bit_in_h = 15 - (p % 16);
         pat_pixel = pat_halfword(y, b, h)[bit_in_h];
      end
   endfunction

   // ------------------------------------------------------------------
   // Or a real frame buffer, captured from a boot
   // ------------------------------------------------------------------
   // tb_sun2 writes the 128 KiB aperture as 32-bit Wishbone words, exactly as
   // they sit in DDR3.  Reassembling a beat is then the one line below,
   // because that is all wb_to_mig_ui does: the word at adr[3:2] == L goes to
   // bits [32L+31:32L].  Nothing here knows or needs to know which bit is the
   // leftmost pixel -- that is fb_scanout's opinion, and rendering through it
   // is the whole point.
   localparam int FB_IMAGE_WORDS = 32768;         // 128 KiB / 4

   logic [31:0] img [0:FB_IMAGE_WORDS-1];
   string       image_file, ppm_file;
   bit          replay = 1'b0;

   function automatic logic [127:0] img_beat(input int b);
      img_beat = {img[4*b+3], img[4*b+2], img[4*b+1], img[4*b]};
   endfunction

   // ------------------------------------------------------------------
   // A stand-in for mig_arb plus DDR3: answers a read after a realistic wait
   // ------------------------------------------------------------------
   wire [27:0]  c_addr;
   wire         c_req;
   logic        c_done = 0;
   logic [127:0] c_rdata = 0;

   localparam int READ_LATENCY = 21;    // ui_clk, as measured by tb_mig_ddr3

   int  n_reads = 0;
   int  lat = 0;
   bit  busy = 0;

   always @(posedge ui_clk) begin
      c_done <= 1'b0;
      if (ui_rst) begin
         busy <= 1'b0;
         lat  <= 0;
      end else if (!busy) begin
         // Masking c_done here is not decoration: it is what mig_arb does, and
         // for the same reason.  done is registered, so a client's request is
         // still asserted during the cycle it sees the answer; a model that
         // does not mask it starts the next read a cycle early and reports ten
         // beats a line where the design asked for nine.
         if (c_req && !c_done) begin busy <= 1'b1; lat <= 0; end
      end else begin
         if (lat == READ_LATENCY) begin
            automatic int off = int'(c_addr - FB_APP_BASE) / 8;   // beat index
            c_rdata <= replay ? img_beat(off)
                              : pat_beat(off / BEATS_PER_LINE, off % BEATS_PER_LINE);
            c_done  <= 1'b1;
            busy    <= 1'b0;
            n_reads <= n_reads + 1;
         end else begin
            lat <= lat + 1;
         end
      end
   end

   // ------------------------------------------------------------------
   // HDMI timing, as the hdmi module generates it
   // ------------------------------------------------------------------
   logic [11:0] cx = 0;
   logic [10:0] cy = 0;

   always @(posedge clk_pixel) begin
      if (pix_rst) begin
         cx <= 0;
         cy <= 0;
      end else if (cx == FRAME_W-1) begin
         cx <= 0;
         cy <= (cy == FRAME_H-1) ? 11'd0 : cy + 11'd1;
      end else begin
         cx <= cx + 12'd1;
      end
   end

   logic        video_en = 1'b1;
   wire [23:0]  rgb;

   fb_scanout #(.FB_APP_BASE(FB_APP_BASE)) dut (
       .ui_clk (ui_clk), .ui_rst (ui_rst),
       .c_addr (c_addr), .c_req (c_req), .c_done (c_done), .c_rdata (c_rdata),
       .clk_pixel (clk_pixel), .pix_rst (pix_rst),
       .cx (cx), .cy (cy), .video_en (video_en), .rgb (rgb)
   );

   // ------------------------------------------------------------------
   // Checks
   // ------------------------------------------------------------------
   int  bad_pixel = 0, bad_border = 0, checked = 0, border = 0, white = 0;
   int  first_bad_x = -1, first_bad_y = -1;

   // The frame as it goes out, for +fb_ppm.  Captured in the same block and on
   // the same edge as the comparison, so the picture written is byte-for-byte
   // the one the checks were made against.  rgb is only ever all-ones or
   // all-zeros (fb_scanout is 1 bpp), so one byte a pixel loses nothing.
   logic [7:0] frame [0:SCREEN_H-1][0:SCREEN_W-1];
   bit         capture = 1'b0;      // only during the frame being checked
   bit         want_ppm = 1'b0;

   always @(posedge clk_pixel) begin
      if (!pix_rst && cy < SCREEN_H && cx < SCREEN_W) begin
         if (capture) frame[cy][cx] <= rgb[7:0];
         if (cx >= X0 && cx < X0+FB_W && cy >= Y0 && cy < Y0+FB_H) begin
            checked++;
            if (rgb[0]) white++;
            // Against the pattern every pixel is predictable.  Replaying a
            // captured frame buffer there is nothing to predict -- what is
            // still checked is the border, the beat count and the picture
            // itself, by eye.
            if (!replay) begin
               automatic logic want = ~pat_pixel(int'(cx) - X0, int'(cy) - Y0);
               if (rgb !== {24{want}}) begin
                  if (bad_pixel == 0) begin
                     first_bad_x = int'(cx) - X0;
                     first_bad_y = int'(cy) - Y0;
                  end
                  bad_pixel++;
               end
            end
         end else begin
            border++;
            if (rgb !== 24'h000000) bad_border++;
         end
      end
   end

   // ------------------------------------------------------------------
   // The picture, as a binary PPM
   // ------------------------------------------------------------------
   task automatic write_ppm(input string path);
      int fd;
      begin
         fd = $fopen(path, "wb");
         if (fd == 0) begin
            $display("FAIL: could not write %s", path);
            return;
         end
         $fwrite(fd, "P6\n%0d %0d\n255\n", SCREEN_W, SCREEN_H);
         for (int y = 0; y < SCREEN_H; y++)
           for (int x = 0; x < SCREEN_W; x++)
             $fwrite(fd, "%c%c%c", frame[y][x], frame[y][x], frame[y][x]);
         $fclose(fd);
         $display("wrote %s, %0dx%0d", path, SCREEN_W, SCREEN_H);
      end
   endtask

   // Instrumentation: how many line starts and frame starts the fetch side
   // actually saw, and the range of rows it asked for.
   int n_ls = 0, n_vs = 0, row_max = 0;
   always @(posedge ui_clk) if (!ui_rst) begin
      if (dut.ls_pulse) n_ls++;
      if (dut.vs_pulse) n_vs++;
      if (dut.fetching && int'(dut.fetch_row) > row_max) row_max = int'(dut.fetch_row);
   end

   initial begin
      $timeformat(-9, 0, " ns", 12);

      if ($value$plusargs("fb_image=%s", image_file)) begin
         $readmemh(image_file, img);
         replay = 1'b1;
         $display("=== fb_scanout: scanning out %s ===", image_file);
      end else begin
         $display("=== fb_scanout: one whole 1920x1080 frame, every pixel ===");
      end

      repeat (20) @(posedge ui_clk);
      ui_rst = 0;
      repeat (20) @(posedge clk_pixel);
      pix_rst = 0;

      // Let the first frame prime the line buffers, then check the second.
      @(negedge clk_pixel);
      wait (cy == FRAME_H-1);
      wait (cy == 0);
      bad_pixel = 0; bad_border = 0; checked = 0; border = 0; n_reads = 0;
      n_ls = 0; n_vs = 0; row_max = 0; white = 0;
      want_ppm = $value$plusargs("fb_ppm=%s", ppm_file);
      capture  = want_ppm;

      wait (cy == FRAME_H-1);
      wait (cy == 0);
      capture = 1'b0;

      $display("%0d picture pixels checked, %0d border pixels checked", checked, border);
      // A frame the boot PROM has drawn on is mostly white with black ink.
      // All-white or all-black passes every structural check below and is
      // still wrong, so say what the coverage was.
      $display("%0d of %0d picture pixels white (%0.1f%%)",
               white, FB_W*FB_H, 100.0 * white / (FB_W*FB_H));
      $display("%0d DDR3 beats read in the frame (expected %0d)",
               n_reads, FB_H * BEATS_PER_LINE);
      $display("line starts %0d, frame starts %0d, highest row fetched %0d",
               n_ls, n_vs, row_max);

      if (checked != FB_W*FB_H)
        $display("FAIL: checked %0d picture pixels, expected %0d", checked, FB_W*FB_H);
      else if (bad_pixel != 0)
        $display("FAIL: %0d wrong pixels, first at frame buffer (%0d,%0d)",
                 bad_pixel, first_bad_x, first_bad_y);
      else if (bad_border != 0)
        $display("FAIL: %0d border pixels were not black", bad_border);
      else if (n_reads != FB_H * BEATS_PER_LINE)
        $display("FAIL: read %0d beats, expected exactly %0d -- the fetch is not keeping up",
                 n_reads, FB_H * BEATS_PER_LINE);
      // A uniform picture passes every check above.  It is what a frame buffer
      // that was never loaded looks like: $readmemh on a file that is not
      // there is not an error, it just leaves the array X, and X scans out as
      // a black screen through {24{~pix}}.  A real one is mostly white with
      // some ink.
      else if (replay && (white == 0 || white == FB_W*FB_H))
        $display("FAIL: the picture is uniform -- was %s read at all?", image_file);
      else
        $display("PASS: fb_scanout");

      // +fb_logo: an end-to-end assertion that does not need eyes, for an image
      // captured from a boot.  tb_sun2 finds the logo at aperture offset
      // 0x04808 -- 18440, which is row 128 byte 8, so frame buffer x = 64..71
      // -- and the byte there is 0x7F.  MSB first: x=64 is a 0 bit and x=65 a
      // 1 bit, and on a Sun-2 a 1 is black.  So the two pixels must come out
      // white then black, which pins down the offset, the beat reassembly, the
      // bit order and the polarity in one line.
      if ($test$plusargs("fb_logo")) begin
         if (frame[Y0+128][X0+64] !== 8'hFF || frame[Y0+128][X0+65] !== 8'h00)
           $display("FAIL: the Sun logo did not scan out at screen (%0d,%0d) -- got %02x %02x, want ff 00",
                    X0+64, Y0+128, frame[Y0+128][X0+64], frame[Y0+128][X0+65]);
         else
           $display("PASS: the Sun logo scans out at screen (%0d,%0d)", X0+64, Y0+128);
      end

      if (want_ppm) write_ppm(ppm_file);

      // DISPEN low must blank the picture entirely.
      video_en = 1'b0;
      wait (cy == Y0 + 100);
      repeat (100) @(posedge clk_pixel);
      if (rgb !== 24'h000000) $display("FAIL: DISPEN low did not blank the display");
      else                    $display("PASS: DISPEN low blanks the display");

      $finish;
   end

   initial begin
      #200_000_000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
