`timescale 1ns / 1ps

//
// The pixel clock, from the fourth PLL.
//
// Kept out of deca_clkgen.sv rather than added as a third instance there, for
// two reasons.  deca_clkgen is on the machine's critical path and is built into
// every DECA bitstream; this is needed only when there is a frame buffer, and a
// PLL that is instantiated and unused still costs one of the four.  And the
// standalone test/deca_hdmi design wants the pixel clock without wanting the
// CPU or the SCC clock at all.
//
// 108.000 MHz exactly: 50 x 54 / 25.  That is VESA DMT's pixel clock for
// 1280x1024 @ 60, which is the mode video_timing defaults to and the one the
// Wukong settled on -- see the note there for why nothing slower will do.
//
// The ratio is given to ALTPLL rather than an N/M/C triple, the way
// deca_clkgen's pll_b gives 87/885 for the SCC clock, and the megafunction
// solves for the counters.  What it solves to is worth reading back out of the
// STA report rather than assuming: test/deca_hdmi/build.tcl prints it, which is
// the cheapest place in the project to check because that design is 1% of the
// device.
//
module deca_vidclk (
    input  wire  clk50,        // MAX10_CLK1_50, a real oscillator
    input  wire  reset,
    output wire  clk_pixel,    // 108 MHz
    output wire  locked
);

`ifdef CLKGEN_BEHAVIOURAL
   // 108 MHz is 9.259259... ns; half of that, for a simulator.
   reg pix = 1'b0;
   always #4.6296296 pix = ~pix;
   assign clk_pixel = pix;
   assign locked    = 1'b1;
`else
   wire clk_pixel_i;
   assign clk_pixel = clk_pixel_i;

   altpll #(
       .bandwidth_type          ("AUTO"),
       .clk0_divide_by          (25),
       .clk0_duty_cycle         (50),
       .clk0_multiply_by        (54),
       .clk0_phase_shift        ("0"),
       .compensate_clock        ("CLK0"),
       .inclk0_input_frequency  (20000),      // 20000 ps = 50 MHz
       .intended_device_family  ("MAX 10"),
       .lpm_type                ("altpll"),
       .operation_mode          ("NORMAL"),
       .pll_type                ("AUTO"),
       .port_areset             ("PORT_USED"),
       .port_inclk0             ("PORT_USED"),
       .port_locked             ("PORT_USED"),
       .port_clk0               ("PORT_USED"),
       .port_clk1               ("PORT_UNUSED"),
       .port_clk2               ("PORT_UNUSED"),
       .port_clk3               ("PORT_UNUSED"),
       .port_clk4               ("PORT_UNUSED"),
       .width_clock             (5)
   ) pll_v (
       .areset (reset),
       .inclk  ({1'b0, clk50}),
       .clk    ({4'bxxxx, clk_pixel_i}),
       .locked (locked)
   );
`endif

endmodule
