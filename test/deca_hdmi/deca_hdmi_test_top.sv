`timescale 1ns / 1ps

//
// The DECA's HDMI path and nothing else: the pixel PLL, the raster, the
// ADV7513 configuration and a test pattern.  No Sun-2, no DDR3, no console.
//
// The point of building this before the frame buffer is that the DECA has one
// instrument -- the JTAG console -- and fitting a display takes it away, because
// the boot PROM moves the console to the screen whenever it finds one.  So the
// first time a picture is attempted there must be nothing else in the design
// that could be blamed.  Same argument as test/deca_console and test/deca_ddr3,
// and the same rule: this reads the *same* boards/DECA sources the real build
// reads, never copies of them.
//
// What a working board looks like:
//
//   * a monitor that syncs at 1280x1024 60 Hz,
//   * eight colour bars over the top three quarters, a grey ramp below,
//   * a one-pixel white border proving the active window is exactly 1280x1024,
//   * LED[0] on once the register table has gone out,
//   * LED[7:4] counting configuration passes -- if that climbs on its own, the
//     transmitter is re-interrupting and the cable or the sink is the reason.
//
module deca_hdmi_test_top #(
    parameter bit CLK_INVERT = 1'b1     // see deca_hdmi_out.sv
) (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [1:0]  SW,
    output wire [7:0]  LED,

    output wire [23:0] HDMI_TX_D,
    output wire        HDMI_TX_CLK,
    output wire        HDMI_TX_DE,
    output wire        HDMI_TX_HS,
    output wire        HDMI_TX_VS,
    input  wire        HDMI_TX_INT,
    inout  wire        HDMI_I2C_SCL,
    inout  wire        HDMI_I2C_SDA
);

   // KEY is active low and Schmitt-triggered on this board.
   wire reset_raw = ~KEY[0];

   wire clk_pixel, pll_locked;
   deca_vidclk vidclk (.clk50(MAX10_CLK1_50), .reset(reset_raw),
                       .clk_pixel(clk_pixel), .locked(pll_locked));

   // Reset for the pixel domain: asserted while the PLL is unlocked, released
   // synchronously once it is.
   wire pix_rst;
   reset_sync rst_pix (.clk(clk_pixel), .rst_async_in(reset_raw | ~pll_locked), .rst_sync_out(pix_rst));

   // ...and one for the 50 MHz domain the I2C sequencer runs in.  It runs off
   // the raw oscillator rather than the pixel PLL on purpose: the transmitter
   // has to be configured whether or not the video clock ever came up, and a
   // configuration that depends on the PLL cannot report that the PLL failed.
   wire cfg_rst;
   reset_sync rst_cfg (.clk(MAX10_CLK1_50), .rst_async_in(reset_raw), .rst_sync_out(cfg_rst));

   // ------------------------------------------------------------------
   // Raster
   // ------------------------------------------------------------------
   wire [11:0] cx;
   wire [10:0] cy;
   wire        de, hsync, vsync;

   video_timing vt (.clk(clk_pixel), .rst(pix_rst),
                    .cx(cx), .cy(cy), .de(de), .hsync(hsync), .vsync(vsync));

   // ------------------------------------------------------------------
   // Test pattern
   // ------------------------------------------------------------------
   // Colour bars say the data bus is wired right and in the right order; a grey
   // ramp says the low bits are not stuck; the border says the active window is
   // where video_timing thinks it is.  A single flat colour would pass with
   // half the bus shorted together.
   localparam int H_ACTIVE = 1280, V_ACTIVE = 1024;

   wire in_border = (cx == 12'd0) || (cx == 12'(H_ACTIVE-1))
                 || (cy == 11'd0) || (cy == 11'(V_ACTIVE-1));

   wire [2:0] bar  = cx[9:7];               // 1280 / 8 = 160 px per bar
   wire [7:0] ramp = cx[9:2];               // 0..255 across the width

   reg [23:0] rgb;
   always @* begin
      if (!de)             rgb = 24'h000000;
      else if (in_border)  rgb = 24'hFFFFFF;
      else if (cy < 11'd768)
        rgb = {{8{bar[2]}}, {8{bar[1]}}, {8{bar[0]}}};
      else
        rgb = {ramp, ramp, ramp};
   end

   // ------------------------------------------------------------------
   // Out
   // ------------------------------------------------------------------
   deca_hdmi_out #(.CLK_INVERT(CLK_INVERT)) out (
       .clk_pixel(clk_pixel), .rst(pix_rst),
       .rgb(rgb), .de(de), .hsync(hsync), .vsync(vsync),
       .hdmi_d(HDMI_TX_D), .hdmi_de(HDMI_TX_DE),
       .hdmi_hs(HDMI_TX_HS), .hdmi_vs(HDMI_TX_VS), .hdmi_clk(HDMI_TX_CLK));

   // ------------------------------------------------------------------
   // The transmitter's own setup
   // ------------------------------------------------------------------
   wire scl_oe, sda_oe, cfg_done, cfg_nak;
   wire [7:0] cfg_passes;

   deca_adv7513_init cfg (
       .clk(MAX10_CLK1_50), .rst(cfg_rst),
       .scl_oe(scl_oe), .sda_oe(sda_oe), .sda_i(HDMI_I2C_SDA),
       .int_n(HDMI_TX_INT),
       .cfg_done(cfg_done), .cfg_nak(cfg_nak), .cfg_passes(cfg_passes));

   // Open drain: pull down or let the board's 2K pull-ups have it.  Never drive
   // high -- two masters and a 1.8 V rail make that expensive.
   assign HDMI_I2C_SCL = scl_oe ? 1'b0 : 1'bz;
   assign HDMI_I2C_SDA = sda_oe ? 1'b0 : 1'bz;

   assign LED[0]   = cfg_done;
   assign LED[1]   = pll_locked;
   assign LED[2]   = vsync;          // visibly flickering = the raster is running
   assign LED[3]   = cfg_nak;        // the transmitter never acknowledged
   assign LED[7:4] = cfg_passes[3:0];

   wire _unused = &{1'b0, KEY[1], SW, cx[11:10], cy[10], 1'b0};

endmodule
