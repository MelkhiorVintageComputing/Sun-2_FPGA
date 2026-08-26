`timescale 1ns / 1ps

//
// Clock generation for the QMTech Wukong V1 board (XC7A100T-2FGG676).
//
// Replaces the LiteX _CRG.  Two MMCMs, instantiated directly rather than
// through the clocking wizard, so this is one readable file that simulates and
// diffs like any other source.
//
//   MMCM A   50 MHz / 1 * 20 = 1000 MHz VCO
//              / 6    -> 166.6667 MHz  MIG system clock
//              / 80   ->  12.5     MHz  CPU        (or / 25 -> 40 MHz)
//              / 5    -> 200      MHz  IDELAYCTRL reference
//
//   MMCM B   50 MHz / 2 * 24.625 = 615.625 MHz VCO
//              / 125.25 -> 4.915170 MHz  SCC serial clock
//
// Every clock MMCM A produces is exact.  The serial clock is the awkward one --
// 4.9152 MHz is not a rational multiple of 50 MHz with small terms -- so it
// gets an MMCM to itself, where the fractional CLKOUT0 divider brings it to
// within 0.0006% and, more importantly, where changing CPU_CLK_HZ cannot
// perturb it.  The boot PROM programs the SCC for 9600 baud from this clock
// (WR4 x16 mode, time constant 14), so an error here is an error in the
// console baud rate.
//
// Artix-7 -2 limits observed: VCO 600-1440 MHz, PFD 10-450 MHz,
// CLKFBOUT_MULT_F 2-64 in 1/8 steps, CLKOUT0_DIVIDE_F 1-128 in 1/8 steps,
// CLKOUT1..6 integer 1-128.
//

module wukong_clkgen #(
    parameter int CPU_CLK_HZ = 12_500_000,
    // The MMCM's CLKOUT1 divider, when the frequency you want is not a whole
    // number of hertz.  Zero means "derive it from CPU_CLK_HZ", which is the
    // old behaviour and stays the default.
    //
    // The exactness check below exists so nobody silently gets a rounded
    // clock, but it conflates two different things: an exact *divider* and an
    // integer number of *hertz*.  VCO/51 is a perfectly good clock the MMCM
    // can make -- 19.607843 MHz -- and there is no integer CPU_CLK_HZ that
    // expresses it.  Naming the divider keeps the guarantee by construction:
    // you get exactly VCO/CPU_DIV, and nothing is rounded.
    //
    // Useful because this design sits close to its ceiling at 20 MHz (VCO/50)
    // and the next exactly-representable step down is 15.625 MHz (VCO/64) --
    // a 22% cut where a few percent may do.
    parameter int CPU_DIV    = 0
) (
    input  wire clk50,        // board oscillator, straight off the pin
    input  wire reset,        // active high, asynchronous

    output wire clk_mig_sys,  // 166.6667 MHz, MIG sys_clk_i
    output wire clk_idelay,   // 200 MHz, IDELAYCTRL reference
    output wire clk_cpu,      // CPU_CLK_HZ
    output wire clk_serial,   // 4.9152 MHz (nominal) for the SCC
    output wire locked        // both MMCMs locked
);

   // ------------------------------------------------------------------
   // Divider arithmetic, checked at elaboration
   // ------------------------------------------------------------------
   localparam int    VCO_A_HZ      = 1_000_000_000;         // 50 MHz * 20 / 1
   localparam int    CPU_DIVIDE    = (CPU_DIV != 0) ? CPU_DIV : (VCO_A_HZ / CPU_CLK_HZ);
   localparam int    CPU_ACTUAL_HZ = VCO_A_HZ / CPU_DIVIDE;   // truncated, for the message only

   localparam real   SERIAL_TARGET = 4_915_200.0;
   localparam real   VCO_B_MHZ     = 615.625;               // 50 * 24.625 / 2
   localparam real   SERIAL_DIV    = 125.25;
   localparam real   SERIAL_MHZ    = VCO_B_MHZ / SERIAL_DIV;

   initial begin
      // Only when the divider was derived from a frequency.  If CPU_DIV names
      // it outright the result is exact by definition and there is nothing to
      // check -- that is the whole point of the knob.
      if (CPU_DIV == 0 && CPU_DIVIDE * CPU_CLK_HZ != VCO_A_HZ)
        $fatal(1, "wukong_clkgen: CPU_CLK_HZ=%0d does not divide the %0d Hz VCO exactly; pick a divisor of it (12.5 MHz, 20 MHz, 25 MHz, 40 MHz, 50 MHz, ...) or name the divider with CPU_DIV",
               CPU_CLK_HZ, VCO_A_HZ);
      if (CPU_DIVIDE < 1 || CPU_DIVIDE > 128)
        $fatal(1, "wukong_clkgen: CPU_CLK_HZ=%0d needs CLKOUT1_DIVIDE=%0d, outside the 1..128 the MMCM allows",
               CPU_CLK_HZ, CPU_DIVIDE);
      $display("wukong_clkgen: cpu %0d Hz (VCO/%0d, exact), serial %.6f MHz (%.4f%% from %.4f MHz)",
               CPU_ACTUAL_HZ, CPU_DIVIDE, SERIAL_MHZ,
               100.0 * (SERIAL_MHZ * 1.0e6 - SERIAL_TARGET) / SERIAL_TARGET,
               SERIAL_TARGET / 1.0e6);
   end

`ifdef CLKGEN_BEHAVIOURAL
   // ------------------------------------------------------------------
   // Simulation shortcut
   // ------------------------------------------------------------------
   // The MMCME2 model simulates its VCO at 1 GHz, which costs more events than
   // the rest of the machine put together: measured, the board testbench runs
   // about 6x slower with the real clock generator (0.12 vs 0.7 simulated ms
   // per wall second), turning a boot to the monitor prompt from ~40 minutes
   // into ~4 hours.  This generates the same four frequencies directly so a
   // testbench can exercise the real board top -- reset sequencing, memory
   // path, console -- without paying for that.
   //
   // These must match what the MMCMs in the other branch produce; tb_clkgen
   // measures the real ones, and these are the numbers it reports.  Never
   // define this for synthesis -- this branch contains no MMCMs at all.
   localparam realtime MIG_HALF    = 3.0;         // 166.6667 MHz
   localparam realtime IDELAY_HALF = 2.5;         // 200 MHz
   localparam realtime CPU_HALF    = (1.0e9 / (2.0 * CPU_CLK_HZ));
   localparam realtime SERIAL_HALF = 101.72609;   // 4.915170 MHz

   reg mig_r = 1'b0, idelay_r = 1'b0, cpu_r = 1'b0, serial_r = 1'b0;
   reg locked_r = 1'b0;

   always #(MIG_HALF)    mig_r    = ~mig_r;
   always #(IDELAY_HALF) idelay_r = ~idelay_r;
   always #(CPU_HALF)    cpu_r    = ~cpu_r;
   always #(SERIAL_HALF) serial_r = ~serial_r;

   // Mimic the lock delay so the reset sequencing is still exercised.
   always @(posedge reset) locked_r <= 1'b0;
   initial begin
      forever begin
         wait (reset === 1'b0);
         #6500 locked_r = 1'b1;      // tb_clkgen measures the real MMCMs at ~6.5 us
         wait (reset === 1'b1);
         locked_r = 1'b0;
      end
   end

   assign clk_mig_sys = mig_r;
   assign clk_idelay  = idelay_r;
   assign clk_cpu     = cpu_r;
   assign clk_serial  = serial_r;
   assign locked      = locked_r;

`else
   // ------------------------------------------------------------------
   // Board clock onto a global buffer first, as the LiteX build did, so the
   // generated-clock constraints have a net to attach to.
   // ------------------------------------------------------------------
   wire clk50_bufg;
   BUFG bufg_clk50 (.I(clk50), .O(clk50_bufg));

   // ------------------------------------------------------------------
   // MMCM A -- memory, CPU and IDELAYCTRL
   // ------------------------------------------------------------------
   wire mmcm_a_fb, mmcm_a_fb_bufg;
   wire mmcm_a_mig, mmcm_a_cpu, mmcm_a_idelay;
   wire locked_a;

   MMCME2_BASE #(
       .BANDWIDTH         ("OPTIMIZED"),
       .CLKIN1_PERIOD     (20.000),   // 50 MHz
       .DIVCLK_DIVIDE     (1),
       .CLKFBOUT_MULT_F   (20.000),   // VCO = 1000 MHz
       .CLKOUT0_DIVIDE_F  (6.000),    // 166.6667 MHz  MIG
       .CLKOUT1_DIVIDE    (CPU_DIVIDE),
       .CLKOUT2_DIVIDE    (5),        // 200 MHz  IDELAYCTRL
       .STARTUP_WAIT      ("FALSE")
   ) mmcm_a (
       .CLKIN1   (clk50_bufg),
       .CLKFBIN  (mmcm_a_fb_bufg),
       .CLKFBOUT (mmcm_a_fb),
       .CLKOUT0  (mmcm_a_mig),
       .CLKOUT1  (mmcm_a_cpu),
       .CLKOUT2  (mmcm_a_idelay),
       .CLKOUT3  (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
       .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(),
       .LOCKED   (locked_a),
       .PWRDWN   (1'b0),
       .RST      (reset)
   );

   BUFG bufg_a_fb     (.I(mmcm_a_fb),     .O(mmcm_a_fb_bufg));
   BUFG bufg_mig      (.I(mmcm_a_mig),    .O(clk_mig_sys));
   BUFG bufg_cpu      (.I(mmcm_a_cpu),    .O(clk_cpu));
   BUFG bufg_idelay   (.I(mmcm_a_idelay), .O(clk_idelay));

   // ------------------------------------------------------------------
   // MMCM B -- the serial clock, on its own so nothing else disturbs it
   // ------------------------------------------------------------------
   wire mmcm_b_fb, mmcm_b_fb_bufg;
   wire mmcm_b_serial;
   wire locked_b;

   MMCME2_BASE #(
       .BANDWIDTH         ("OPTIMIZED"),
       .CLKIN1_PERIOD     (20.000),        // 50 MHz
       .DIVCLK_DIVIDE     (2),             // PFD 25 MHz
       .CLKFBOUT_MULT_F   (24.625),        // VCO = 615.625 MHz
       .CLKOUT0_DIVIDE_F  (SERIAL_DIV),    // 125.25 -> 4.915170 MHz
       .STARTUP_WAIT      ("FALSE")
   ) mmcm_b (
       .CLKIN1   (clk50_bufg),
       .CLKFBIN  (mmcm_b_fb_bufg),
       .CLKFBOUT (mmcm_b_fb),
       .CLKOUT0  (mmcm_b_serial),
       .CLKOUT1  (), .CLKOUT2 (), .CLKOUT3 (),
       .CLKOUT4  (), .CLKOUT5 (), .CLKOUT6 (),
       .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(),
       .LOCKED   (locked_b),
       .PWRDWN   (1'b0),
       .RST      (reset)
   );

   BUFG bufg_b_fb   (.I(mmcm_b_fb),     .O(mmcm_b_fb_bufg));
   BUFG bufg_serial (.I(mmcm_b_serial), .O(clk_serial));

   assign locked = locked_a & locked_b;
`endif // CLKGEN_BEHAVIOURAL

endmodule
