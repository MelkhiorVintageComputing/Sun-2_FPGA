`timescale 1ns / 1ps

//
// A raster: pixel counters, syncs and data enable.  No encoder, no vendor.
//
// The Wukong does not need this -- Inputs/hdmi's hdmi.sv generates the same
// counters on its way to TMDS.  The DECA does, because its HDMI is an ADV7513:
// a transmitter chip that wants parallel RGB with HSYNC, VSYNC and DE on pins
// and does the encoding itself.  hdmi.sv generates hsync and vsync internally
// (hdmi.sv:191-201) and exposes neither, so using it here would mean patching a
// third-party core to bring out three wires and then carrying the TMDS encoder,
// the serialiser and the packet/infoframe files that a board with a real
// transmitter has no use for.  Sixty lines of VESA arithmetic is the cheaper
// side of that trade.
//
// **cx/cy, de, hsync and vsync are all valid in the same clock.** cx and cy are
// registered; the other three are combinational functions of them.  That is
// deliberate and it is what keeps the picture aligned: fb_scanout's rgb is also
// combinational from cx/cy (fb_scanout.sv:145-148), so a consumer that
// registers {rgb, de, hsync, vsync} together on one edge cannot get them out of
// step with each other.  Register de here and the picture shifts a pixel; the
// symptom is a one-column stripe at the edge of the screen and it looks like a
// buffer bug.
//
// Vertical sync changes at the leading edge of horizontal sync rather than at
// the start of the line.  That is what the timing specifications actually say
// and what hdmi.sv:193-200 implements; the shortcut of toggling at cx == 0 also
// produces a picture on most monitors, which is exactly why it is worth not
// doing.
//
// Defaults are VESA DMT 1280x1024 @ 60 Hz -- 1688 x 1066 total, 108.0 MHz,
// positive on both syncs.  Two reasons for that mode rather than another.  It
// is the one the Wukong settled on, so fb_scanout's windowing arithmetic is
// unchanged and the Sun's 1152x900 sits centred with a 64 x 62 border.  And
// there is no cheaper option: every standard mode with room for 900 lines wants
// a pixel clock near 108 MHz, which the ADV7513 takes comfortably against its
// 165 MHz rating.
//
module video_timing #(
    // Horizontal, in pixels: active, front porch, sync width, whole line.
    parameter int H_ACTIVE = 1280,
    parameter int H_FRONT  = 48,
    parameter int H_SYNC   = 112,
    parameter int H_TOTAL  = 1688,   // back porch is the remainder, 248

    // Vertical, in lines.
    parameter int V_ACTIVE = 1024,
    parameter int V_FRONT  = 1,
    parameter int V_SYNC   = 3,
    parameter int V_TOTAL  = 1066,   // back porch is the remainder, 38

    // 1 = sync pulse is high.  DMT 1280x1024 is positive on both; most CEA
    // modes are negative, so this is not a constant.
    parameter bit H_POSITIVE = 1'b1,
    parameter bit V_POSITIVE = 1'b1,

    // Wide enough for H_TOTAL-1 and V_TOTAL-1.  Given rather than computed
    // with $clog2 so that a wire of the wrong width in the instantiating file
    // is a width mismatch here instead of a counter that silently truncates --
    // the failure hdmi.sv's BIT_HEIGHT had under VIDEO_ID_CODE 34.
    parameter int CXW = 12,
    parameter int CYW = 11
) (
    input  wire            clk,       // pixel clock
    input  wire            rst,

    output reg  [CXW-1:0]  cx,        // 0 .. H_TOTAL-1
    output reg  [CYW-1:0]  cy,        // 0 .. V_TOTAL-1
    output wire            de,        // active area
    output wire            hsync,
    output wire            vsync
);

   // The sync pulse, as absolute positions rather than porch widths.
   localparam int HS_BEGIN = H_ACTIVE + H_FRONT;              // 1328
   localparam int HS_END   = H_ACTIVE + H_FRONT + H_SYNC;     // 1440
   localparam int VS_BEGIN = V_ACTIVE + V_FRONT;              // 1025
   localparam int VS_END   = V_ACTIVE + V_FRONT + V_SYNC;     // 1028

   initial begin
      if (H_TOTAL <= HS_END)
        $fatal(1, "video_timing: H_TOTAL %0d leaves no back porch after sync ends at %0d",
               H_TOTAL, HS_END);
      if (V_TOTAL <= VS_END)
        $fatal(1, "video_timing: V_TOTAL %0d leaves no back porch after sync ends at %0d",
               V_TOTAL, VS_END);
      if ((1 << CXW) < H_TOTAL)
        $fatal(1, "video_timing: CXW %0d cannot count to H_TOTAL %0d", CXW, H_TOTAL);
      if ((1 << CYW) < V_TOTAL)
        $fatal(1, "video_timing: CYW %0d cannot count to V_TOTAL %0d", CYW, V_TOTAL);
   end

   always @(posedge clk) begin
      if (rst) begin
         cx <= '0;
         cy <= '0;
      end else if (cx == CXW'(H_TOTAL - 1)) begin
         cx <= '0;
         cy <= (cy == CYW'(V_TOTAL - 1)) ? '0 : cy + 1'b1;
      end else begin
         cx <= cx + 1'b1;
      end
   end

   assign de = (cx < CXW'(H_ACTIVE)) && (cy < CYW'(V_ACTIVE));

   wire hs_active = (cx >= CXW'(HS_BEGIN)) && (cx < CXW'(HS_END));
   assign hsync = H_POSITIVE ? hs_active : ~hs_active;

   // Vertical sync begins and ends at the leading edge of horizontal sync, so
   // the first and last lines of the pulse are split at that point rather than
   // at cx == 0.
   reg vs_active;
   always @* begin
      if (cy == CYW'(VS_BEGIN - 1))
        vs_active = (cx >= CXW'(HS_BEGIN));
      else if (cy == CYW'(VS_END - 1))
        vs_active = (cx <  CXW'(HS_BEGIN));
      else
        vs_active = (cy >= CYW'(VS_BEGIN)) && (cy < CYW'(VS_END));
   end
   assign vsync = V_POSITIVE ? vs_active : ~vs_active;

endmodule
