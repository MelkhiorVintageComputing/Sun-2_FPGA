`timescale 1ns / 1ps

//
// The HDMI pixel clock, and the 5x clock the TMDS serialisers run on.
//
// A third MMCM, because neither of the existing two can get to 148.5 MHz.
// mmcm_a runs a 1000 MHz VCO with integer output dividers, so it can offer
// 1000/6 = 166.67 or 1000/7 = 142.86 and nothing in between; its one
// fractional output is already the MIG system clock.  mmcm_b's VCO is 615.625
// and its fractional output is the SCC's 4.9152 MHz, which must not be
// perturbed.  There are three MMCMs and five PLLs spare, so a third costs
// nothing that matters.
//
// 148.5 MHz cannot be made exactly from 50 MHz through one MMCM at all:
// 148.5/50 = 2.97, and the feedback multiplier would have to be 2.97 times an
// integer output divider, which is never a multiple of 1/8 in the usable
// range.  So this uses **QMTech's own recipe for this board**, from their
// Test06_HDMI_OUT reference design:
//
//     DIVCLK_DIVIDE   4          PFD 12.5 MHz
//     CLKFBOUT_MULT_F 59.375     VCO 742.1875 MHz
//     CLKOUT0_DIVIDE_F 5         pixel  148.4375 MHz
//     CLKOUT1_DIVIDE   1         serial 742.1875 MHz
//
// **742 MHz is more than this design can carry, and that is measured.**  The
// whole machine -- CPU, MMU, DDR3, Ethernet -- drives 720p60's 371 MHz
// perfectly and 1080p60's 742 MHz not at all, on the same board, the same
// monitor and the same colour bars.  test/hdmi drives 742 MHz happily with
// nothing else in the die, so the rate is not impossible on this part; it is
// impossible *here*.  Adding one flip-flop as a load on the 5x net moved the
// output from nothing to almost-syncing, which is what a marginal signal looks
// like and not what a broken one does.
//
// So `SUN2_HDMI_MODE' picks between three recipes:
//
//   (default)  1080p60, 148.4375 / 742.1875 MHz.  Kept because it is what the
//              board is wired for and what QMTech's reference design does, and
//              because it works with little else in the part.  Needs ALLOW_PW.
//   HALFRATE   74.21875 / 371.09375 MHz, for 1080p30 and 720p60 alike.
//   SXGA       108.125 / 540.625 MHz, 1280x1024 at 60 Hz.
//
// SXGA is the one to reach for.  1152x900 is the Sun-2's screen and no CEA
// mode with room for 900 lines runs slower than 148.5 MHz -- 1080p30 does, but
// this bench's monitor rejects 30 Hz outright, and 720p60 has too few lines.
// 1280x1024 fits the screen with a 64x62 border and its 540 MHz serial clock
// is inside both ratings that 742 MHz breaks: the BUFG's 628 MHz and the
// OSERDESE2's 680.  It also runs the MMCM's phase detector at 50 MHz instead
// of 12.5, which is four times the loop bandwidth to filter input jitter with
// -- and this board's oscillator reaches the MMCM through general routing,
// because M22 is not a clock-capable pin.
//
// `SUN2_HDMI_30HZ' existed for a while and was read by nothing: build.tcl
// appended it and this file had no `ifdef for it, so HDMI30=1 built a 60 Hz
// bitstream and a "1080p30 shows no signal" result was really a 1080p60 one.
// Grep a new define for its consumer.
//
// 148.4375 MHz is 148.5 less 0.042 %, comfortably inside the tolerance CEA-861
// allows, and the VCO sits well within range on either speed grade.
//
// **The 5x clock is on a BUFG, and that is knowingly out of specification.**
// 742 MHz is past what an Artix-7 global buffer is rated for -- more so on the
// V3's -1 part than the V1's -2.  It is done this way because it is what
// QMTech ship working on this exact board: their video_pll drives both clocks
// through plain BUFGs into Digilent's rgb2dvi, with no BUFIO or BUFR anywhere.
// The textbook alternative is BUFIO for the fast clock and BUFR divided by
// five for the slow one, which is in specification but pins every TMDS output
// and all the pixel-clock logic into a single clock region.  Expect the timing
// report to complain about this; see BRINGUP.md.
//
module hdmi_clkgen (
    input  wire clk50,          // board oscillator
    input  wire reset,          // active high, asynchronous

    output wire clk_pixel,      // 148.4375 MHz
    output wire clk_pixel_x5,   // 742.1875 MHz
    output wire locked
);

`ifdef CLKGEN_BEHAVIOURAL

   // Same shortcut wukong_clkgen offers: the real MMCM simulates slowly and
   // for most of what the testbenches check the exact jitter is irrelevant.
   //
   // The pixel clock is *divided from* the 5x one rather than generated
   // independently, because the one relationship the serialisers depend on is
   // that CLK is exactly five times CLKDIV -- OSERDESE2 in 10:1 DDR will not
   // work otherwise.  Two free-running clocks with rounded half-periods are
   // not exactly 5:1, and a model that is only approximately right about the
   // thing under test is worse than useless.  Counting both edges of the fast
   // clock gives a pixel half-period of five fast half-periods.
`ifdef SUN2_HDMI_SXGA
   localparam realtime X5_HALF = 0.924855;    // 540.625 MHz
`elsif SUN2_HDMI_HALFRATE
   localparam realtime X5_HALF = 1.347368;    // 371.09375 MHz
`else
   localparam realtime X5_HALF = 0.673684;    // 742.1875 MHz
`endif

   reg pix_r = 1'b0, x5_r = 1'b0, locked_r = 1'b0;
   reg [2:0] div5 = 3'd0;

   always #(X5_HALF) x5_r = ~x5_r;

   always @(x5_r) begin
      if (div5 == 3'd4) begin
         div5  <= 3'd0;
         pix_r <= ~pix_r;
      end else begin
         div5 <= div5 + 3'd1;
      end
   end
   initial begin
      locked_r = 1'b0;
      #6500 locked_r = 1'b1;
   end

   assign clk_pixel    = pix_r;
   assign clk_pixel_x5 = x5_r;
   assign locked       = locked_r & ~reset;

`else

   wire mmcm_fb, mmcm_fb_bufg;
   wire mmcm_pixel, mmcm_x5;

   MMCME2_BASE #(
       .BANDWIDTH         ("OPTIMIZED"),
       .CLKIN1_PERIOD     (20.000),     // 50 MHz
`ifdef SUN2_HDMI_SXGA
       .DIVCLK_DIVIDE     (1),          // PFD 50 MHz
       .CLKFBOUT_MULT_F   (21.625),     // VCO 1081.25 MHz
       .CLKOUT0_DIVIDE_F  (10.000),     // 108.125 MHz   pixel  (108.0 + 0.116%)
       .CLKOUT1_DIVIDE    (2),          // 540.625 MHz   5x, for the serialisers
`elsif SUN2_HDMI_HALFRATE
       .DIVCLK_DIVIDE     (4),          // PFD 12.5 MHz
       .CLKFBOUT_MULT_F   (59.375),     // VCO 742.1875 MHz
       .CLKOUT0_DIVIDE_F  (10.000),     // 74.21875 MHz  pixel
       .CLKOUT1_DIVIDE    (2),          // 371.09375 MHz 5x, for the serialisers
`else
       .DIVCLK_DIVIDE     (4),          // PFD 12.5 MHz
       .CLKFBOUT_MULT_F   (59.375),     // VCO 742.1875 MHz
       .CLKOUT0_DIVIDE_F  (5.000),      // 148.4375 MHz  pixel
       .CLKOUT1_DIVIDE    (1),          // 742.1875 MHz  5x, for the serialisers
`endif
       .STARTUP_WAIT      ("FALSE")
   ) mmcm_hdmi (
       .CLKIN1   (clk50),
       .CLKFBIN  (mmcm_fb_bufg),
       .CLKFBOUT (mmcm_fb),
       .CLKOUT0  (mmcm_pixel),
       .CLKOUT1  (mmcm_x5),
       .CLKOUT2  (), .CLKOUT3 (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
       .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(),
       .LOCKED   (locked),
       .PWRDWN   (1'b0),
       .RST      (reset)
   );

   BUFG bufg_fb    (.I(mmcm_fb),    .O(mmcm_fb_bufg));
   BUFG bufg_pixel (.I(mmcm_pixel), .O(clk_pixel));
   BUFG bufg_x5    (.I(mmcm_x5),    .O(clk_pixel_x5));

`endif

endmodule
