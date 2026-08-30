`timescale 1ns / 1ps

//
// video_timing against the published VESA DMT numbers.
//
// The point of this test is that it does not recompute the RTL's arithmetic.
// The porch positions below are written out as absolute pixel and line numbers
// taken from the DMT specification for 1280x1024 @ 60 Hz, so a sign error or an
// off-by-one in the module fails here rather than on a monitor -- where the
// symptom is a picture shifted by one column, or no picture and no clue.
//
//   horizontal   1280 active, 48 front, 112 sync, 248 back, 1688 total
//   vertical     1024 active,  1 front,   3 sync,  38 back, 1066 total
//   polarity     positive on both
//
// A whole frame is 1688 x 1066 = 1,799,408 clocks, which at 1 ns a clock is
// under 2 ms of simulated time -- cheap enough to check every pixel of two
// consecutive frames rather than sample.
//
module tb_video_timing;

   localparam int H_ACTIVE = 1280, H_FRONT = 48, H_SYNC = 112, H_TOTAL = 1688;
   localparam int V_ACTIVE = 1024, V_FRONT =  1, V_SYNC =   3, V_TOTAL = 1066;

   // Absolute positions, written down rather than derived from the above by
   // the same expressions the RTL uses.
   localparam int HS_FIRST = 1328;   // first pixel of the h sync pulse
   localparam int HS_LAST  = 1439;   // last
   localparam int VS_FIRST = 1025;   // first line of the v sync pulse
   localparam int VS_LAST  = 1027;   // last

   logic clk = 1'b0, rst = 1'b1;
   always #0.5 clk = ~clk;

   wire [11:0] cx;
   wire [10:0] cy;
   wire        de, hsync, vsync;

   video_timing dut (.clk(clk), .rst(rst),
                     .cx(cx), .cy(cy), .de(de), .hsync(hsync), .vsync(vsync));

   int fail = 0, checks = 0;
   task automatic want(input bit cond, input string what);
      checks++;
      if (!cond) begin
         $display("FAIL: %s  (cx=%0d cy=%0d de=%b hs=%b vs=%b)",
                  what, cx, cy, de, hsync, vsync);
         fail++;
      end
   endtask

   // Counted independently of the DUT so a stuck or double-counting counter is
   // caught rather than agreed with.
   int      exp_x = 0, exp_y = 0;
   longint  de_pixels = 0, hs_pixels = 0;
   int      hs_pulses = 0, vs_lines = 0;
   bit      hs_d = 0, in_frame = 0;

   // What vsync should be at this exact (x, y), including the two split lines.
   function automatic bit vs_expected(input int x, input int y);
      if (y == VS_FIRST - 1) return (x >= HS_FIRST);
      if (y == VS_LAST)      return (x <  HS_FIRST);
      return (y >= VS_FIRST) && (y <= VS_LAST);
   endfunction

   initial begin
      $display("=== tb_video_timing: VESA DMT 1280x1024 @ 60 ===");
      repeat (4) @(posedge clk);
      @(negedge clk); rst = 1'b0;
      @(posedge clk);

      // Wind on to the top-left of a frame, sampling on the same edge the
      // checking loop will use.  A level-sensitive `wait' is wrong here: it
      // returns the instant cx is 0, which during reset is immediately, and the
      // loop then starts one clock behind the counters.
      forever begin
         @(negedge clk);
         if (cx == 0 && cy == 0) break;
      end

      // Two whole frames, every pixel.  Check first and advance afterwards --
      // the negedge above already delivered the sample for (0,0).
      for (int f = 0; f < 2; f++) begin
         for (int n = 0; n < H_TOTAL * V_TOTAL; n++) begin
            if (cx !== exp_x || cy !== exp_y) begin
               want(1'b0, $sformatf("counters: expected (%0d,%0d)", exp_x, exp_y));
               n = H_TOTAL * V_TOTAL;   // one report, not 1.8 million
               f = 2;
            end else begin
               if (de !== ((exp_x < H_ACTIVE) && (exp_y < V_ACTIVE)))
                 want(1'b0, "de does not match the active window");
               if (hsync !== ((exp_x >= HS_FIRST) && (exp_x <= HS_LAST)))
                 want(1'b0, "hsync pulse is in the wrong place");
               if (vsync !== vs_expected(exp_x, exp_y))
                 want(1'b0, "vsync pulse is in the wrong place");
            end

            if (de)    de_pixels++;
            if (hsync) hs_pixels++;
            if (hsync && !hs_d) hs_pulses++;
            hs_d = hsync;

            exp_x++;
            if (exp_x == H_TOTAL) begin
               exp_x = 0;
               exp_y++;
               if (exp_y == V_TOTAL) exp_y = 0;
            end

            @(negedge clk);   // sample away from the edge that moves them
         end
      end

      // Totals over the two frames, as an independent check on the per-pixel
      // comparisons above: a systematic error that happens to agree with
      // vs_expected() still cannot produce the right areas.
      want(de_pixels == 2 * H_ACTIVE * V_ACTIVE,
           $sformatf("de covers exactly 2x1280x1024 pixels (got %0d)", de_pixels));
      want(hs_pixels == 2 * H_SYNC * V_TOTAL,
           $sformatf("hsync is 112 wide on every line (got %0d)", hs_pixels));
      want(hs_pulses == 2 * V_TOTAL,
           $sformatf("one hsync pulse per line (got %0d of %0d)", hs_pulses, 2*V_TOTAL));

      // The frame rate the numbers imply, so a wrong total is visible as a
      // rate rather than as an off-by-one nobody can read.
      $display("    raster %0d x %0d = %0d clocks; at 108.0 MHz that is %.2f Hz",
               H_TOTAL, V_TOTAL, H_TOTAL * V_TOTAL,
               108.0e6 / real'(H_TOTAL * V_TOTAL));

      $display("=== tb_video_timing: %0d checks, %0d failed ===", checks, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      #20_000_000;
      $display("FAIL: tb_video_timing timed out");
      $finish;
   end

endmodule
