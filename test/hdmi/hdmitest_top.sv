// A standalone 720p60 HDMI test for the QMTech Wukong V1.
//
// Adapted from hdl-util/hdmi-demo's Seeed Spartan Edge Accelerator top: the
// same hdmi block, the same OBUFDS per lane, a colour-bar pattern instead of
// the demo's audio.  What differs is the board -- 50 MHz rather than 100, and
// the Wukong's TMDS pins.
//
// The point is to take everything else out of the picture.  The Sun-2 build
// puts its console on a frame buffer in DDR3, scanned out by fb_scanout, at
// 1080p60 -- and 1080p60 is past what this part's OSERDESE2 can do (Min Period
// 1.471 ns required against 1.347 needed, measured).  This asks the narrower
// question: does the HDMI block reach this monitor at all, at a rate that is
// comfortably inside every rating?
//
// Two modes, one define.  Both take the same VCO, 742.1875 MHz from 50 MHz
// with DIVCLK 4 and MULT 59.375, and differ only in the output dividers:
//
//   default        /10 and /2   74.21875 and 371.09375   720p60
//   HDMI_1080P60   /5  and /1   148.4375 and 742.1875    1080p60
//
// Both are 0.04 % low against the nominal clock, well inside CEA-861.

module hdmitest_top (
    input  wire        clk50,
    output wire [2:0]  tmds_p,
    output wire [2:0]  tmds_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [1:0]  user_led
);

   wire mmcm_fb, mmcm_fb_bufg, mmcm_pixel, mmcm_x5, locked;
   wire clk_pixel, clk_pixel_x5;

   MMCME2_BASE #(
       .BANDWIDTH         ("OPTIMIZED"),
       .CLKIN1_PERIOD     (20.000),
       .DIVCLK_DIVIDE     (4),
       .CLKFBOUT_MULT_F   (59.375),
`ifdef HDMI_1080P60
       .CLKOUT0_DIVIDE_F  (5.000),
       .CLKOUT1_DIVIDE    (1),
`else
       .CLKOUT0_DIVIDE_F  (10.000),
       .CLKOUT1_DIVIDE    (2),
`endif
       .STARTUP_WAIT      ("FALSE")
   ) mmcm (
       .CLKIN1(clk50), .CLKFBIN(mmcm_fb_bufg), .CLKFBOUT(mmcm_fb),
       .CLKOUT0(mmcm_pixel), .CLKOUT1(mmcm_x5),
       .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
       .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(),
       .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0)
   );
   BUFG b0 (.I(mmcm_fb),    .O(mmcm_fb_bufg));
   BUFG b1 (.I(mmcm_pixel), .O(clk_pixel));
   BUFG b2 (.I(mmcm_x5),    .O(clk_pixel_x5));

   // Reset the video block until the MMCM is locked, released on the pixel
   // clock so nothing sees a partial cycle.
   reg [3:0] rstq = 4'hF;
   always @(posedge clk_pixel) rstq <= {rstq[2:0], ~locked};
   wire pix_rst = rstq[3];

`ifdef HDMI_1080P60
   wire [11:0] cx;   // code 16 counts to 2200 x 1125
   wire [10:0] cy;
   localparam LAST_X = 12'd1919, LAST_Y = 11'd1079;
   localparam VIC = 16;
`else
   wire [9:0] cx, cy;    // code 4 counts to 1650 x 750
   localparam LAST_X = 10'd1279, LAST_Y = 10'd719;
   localparam VIC = 4;
`endif
   wire [23:0] rgb;
   wire [2:0]  tmds;
   wire        tmds_clock;

   // Eight colour bars, and a white frame one pixel wide so the edges of the
   // raster are visible: a picture that is obviously right or obviously wrong.
   wire [2:0] bar = cx[$bits(cx)-2 -: 3];
   assign rgb = (cy == 0 || cy == LAST_Y || cx == 0 || cx == LAST_X)
                ? 24'hFFFFFF
                : {{8{bar[2]}}, {8{bar[1]}}, {8{bar[0]}}};

   hdmi #(.VIDEO_ID_CODE(VIC),
          .DVI_OUTPUT(1'b1),
          .VIDEO_REFRESH_RATE(60.0),
          .IT_CONTENT(1'b1),
          .VENDOR_NAME({"Sun     "}),
          .PRODUCT_DESCRIPTION({"HDMI test       "})
   ) hdmi_tx (
       .clk_pixel_x5(clk_pixel_x5), .clk_pixel(clk_pixel),
       .clk_audio(clk_pixel), .reset(pix_rst), .rgb(rgb),
       .audio_sample_word('{16'd0, 16'd0}),
       .tmds(tmds), .tmds_clock(tmds_clock), .cx(cx), .cy(cy),
       .frame_width(), .frame_height(), .screen_width(), .screen_height()
   );

   OBUFDS o0 (.I(tmds[0]),    .O(tmds_p[0]), .OB(tmds_n[0]));
   OBUFDS o1 (.I(tmds[1]),    .O(tmds_p[1]), .OB(tmds_n[1]));
   OBUFDS o2 (.I(tmds[2]),    .O(tmds_p[2]), .OB(tmds_n[2]));
   OBUFDS oc (.I(tmds_clock), .O(tmds_clk_p), .OB(tmds_clk_n));

   // Something to look at without a monitor: locked, and a pixel-clock
   // heartbeat slow enough for an eye.
   reg [24:0] hb = 25'd0;
   always @(posedge clk_pixel) hb <= hb + 1'b1;
   assign user_led = {hb[24], locked};

endmodule
