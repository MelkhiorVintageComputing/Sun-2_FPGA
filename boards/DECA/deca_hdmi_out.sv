`timescale 1ns / 1ps

//
// The pixel bus to the ADV7513.
//
// Nothing here but a register and a clock, and both matter more than they look.
//
// **Everything leaves on one edge.**  rgb, de, hsync and vsync all arrive
// combinational from cx/cy -- video_timing's three and fb_scanout's colour --
// so registering them together is what guarantees they stay aligned.  Register
// any one of them somewhere else and the picture shifts by a pixel relative to
// its own blanking, which on a monitor reads as a thin stripe down one edge and
// gets blamed on the frame buffer.
//
// **The output clock is inverted, deliberately.**  The ADV7513 samples D, DE,
// HS and VS on the *rising* edge of its CLK input, with 1.0 ns of setup and
// 0.7 ns of hold (Hardware User's Guide, AC specifications).  This module
// launches those signals on the rising edge of clk_pixel.  Handing the part
// clk_pixel unchanged would ask it to sample at the same instant the data
// moves; handing it the inverse puts its sampling edge half a period -- 4.6 ns
// at 108 MHz -- after the launch, which is the whole margin available.
//
// Terasic's DECA reference does exactly this (`assign HDMI_TX_CLK =
// ~hdmi_pclk`); BrianHG's does not, and compensates by placing his output
// register differently.  Either can be made to work and getting it wrong gives
// a shimmering or absent picture that looks like a dozen other faults, so it is
// a parameter with a reason attached rather than a constant with a shrug.
//
module deca_hdmi_out #(
    // 1 = send the inverse of the pixel clock, which is what a rising-edge
    // launch wants.  See above before changing it.
    parameter bit CLK_INVERT = 1'b1
) (
    input  wire        clk_pixel,
    input  wire        rst,

    input  wire [23:0] rgb,        // {R[7:0], G[7:0], B[7:0]}
    input  wire        de,
    input  wire        hsync,
    input  wire        vsync,

    output reg  [23:0] hdmi_d,
    output reg         hdmi_de,
    output reg         hdmi_hs,
    output reg         hdmi_vs,
    output wire        hdmi_clk
);

   // D[23:16] = R, D[15:8] = G, D[7:0] = B.  Fixed by the part for input ID 0
   // (Programming Guide table 16); it is not a convention we get to choose.
   always @(posedge clk_pixel) begin
      if (rst) begin
         hdmi_d  <= 24'h0;
         hdmi_de <= 1'b0;
         hdmi_hs <= 1'b0;
         hdmi_vs <= 1'b0;
      end else begin
         hdmi_d  <= rgb;
         hdmi_de <= de;
         hdmi_hs <= hsync;
         hdmi_vs <= vsync;
      end
   end

   assign hdmi_clk = CLK_INVERT ? ~clk_pixel : clk_pixel;

endmodule
