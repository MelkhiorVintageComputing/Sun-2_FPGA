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
   localparam realtime X5_HALF = 0.673684;    // 742.1875 MHz

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
       .DIVCLK_DIVIDE     (4),          // PFD 12.5 MHz
       .CLKFBOUT_MULT_F   (59.375),     // VCO 742.1875 MHz
       .CLKOUT0_DIVIDE_F  (5.000),      // 148.4375 MHz  pixel
       .CLKOUT1_DIVIDE    (1),          // 742.1875 MHz  5x, for the serialisers
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
