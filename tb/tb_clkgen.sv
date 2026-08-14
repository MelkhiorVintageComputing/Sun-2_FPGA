`timescale 1ns / 1ps

//
// Measures what wukong_clkgen actually produces.
//
// The step-1 console came out at the wrong baud rate because a clock divider
// was reasoned about rather than measured, so this counts edges over a fixed
// window and compares against what each clock is supposed to be.  The serial
// clock is the one that matters: the boot PROM derives 9600 baud from it.
//

module tb_clkgen #(
    parameter int CPU_CLK_HZ = 12_500_000
)();

   localparam real WINDOW_US = 500.0;   // long enough for 4.9 MHz to be precise

   reg  clk50 = 1'b0;
   reg  reset = 1'b1;

   wire clk_mig_sys, clk_idelay, clk_cpu, clk_serial, locked;
   wire clk_pixel, clk_pixel_x5, hdmi_locked;

   always #10.0 clk50 = ~clk50;         // 50 MHz

   wukong_clkgen #(.CPU_CLK_HZ(CPU_CLK_HZ)) dut (
       .clk50       (clk50),
       .reset       (reset),
       .clk_mig_sys (clk_mig_sys),
       .clk_idelay  (clk_idelay),
       .clk_cpu     (clk_cpu),
       .clk_serial  (clk_serial),
       .locked      (locked)
   );

   // The HDMI pair, from the third MMCM.  1080p60 wants 148.5 MHz; 148.4375 is
   // the closest a 50 MHz input can be made to reach through one MMCM, and is
   // what QMTech's own design for this board uses.  0.042 % out, well inside
   // what CEA-861 allows.
   hdmi_clkgen hdmiclk (
       .clk50        (clk50),
       .reset        (reset),
       .clk_pixel    (clk_pixel),
       .clk_pixel_x5 (clk_pixel_x5),
       .locked       (hdmi_locked)
   );

   int n_mig, n_idelay, n_cpu, n_serial, n_pixel, n_pixel_x5;
   int errors = 0;

   always @(posedge clk_pixel)    n_pixel++;
   always @(posedge clk_pixel_x5) n_pixel_x5++;

   always @(posedge clk_mig_sys) n_mig++;
   always @(posedge clk_idelay)  n_idelay++;
   always @(posedge clk_cpu)     n_cpu++;
   always @(posedge clk_serial)  n_serial++;

   // Report a measured frequency and fail if it is further from the expectation
   // than the tolerance allows.
   task automatic check(input string name, input int edges,
                        input real expect_hz, input real tol_pct);
      real meas_hz, err_pct;
      bit  ok;
      begin
         meas_hz = edges / (WINDOW_US * 1.0e-6);
         err_pct = 100.0 * (meas_hz - expect_hz) / expect_hz;
         ok      = (err_pct < tol_pct) && (err_pct > -tol_pct);
         $display("  %-10s measured %12.4f kHz   expected %12.4f kHz   error %9.5f %%   tol %6.3f %%   %s",
                  name, meas_hz / 1000.0, expect_hz / 1000.0, err_pct, tol_pct,
                  ok ? "ok" : "FAIL");
         if (!ok) errors++;
      end
   endtask

   initial begin
      $timeformat(-9, 0, " ns", 12);
      $display("=== wukong_clkgen, CPU_CLK_HZ = %0d ===", CPU_CLK_HZ);

      #200 reset = 1'b0;

      wait (locked === 1'b1 && hdmi_locked === 1'b1);
      $display("locked at %t", $realtime);

      // let the outputs settle before counting
      #1000;
      n_mig = 0; n_idelay = 0; n_cpu = 0; n_serial = 0;
      n_pixel = 0; n_pixel_x5 = 0;
      #(WINDOW_US * 1000.0);

      $display("measured over %0.0f us:", WINDOW_US);
      // MMCM A's outputs are exact ratios of the VCO, so hold them tightly.
      check("mig_sys",  n_mig,    1000.0e6 / 6.0, 0.01);
      check("idelay",   n_idelay, 200.0e6,        0.01);
      check("cpu",      n_cpu,    real'(CPU_CLK_HZ), 0.01);
      // The serial clock is approximated; the design aims for ~0.0006%, and
      // anything within 0.5% still gives a usable console.
      check("serial",   n_serial, 4_915_200.0,    0.10);
      // Exact ratios of the HDMI MMCM's 742.1875 MHz VCO.
      check("pixel",    n_pixel,    148_437_500.0, 0.01);
      check("pixel_x5", n_pixel_x5, 742_187_500.0, 0.01);
      // And the one relationship the serialisers actually depend on: OSERDESE2
      // in 10:1 DDR needs CLK to be five times CLKDIV.  Counted over an open
      // window the two totals differ by a handful of edges at the boundaries,
      // so allow a few; a wrong divider would be out by tens of thousands.
      if ((n_pixel_x5 > 5*n_pixel + 8) || (n_pixel_x5 < 5*n_pixel - 8)) begin
         $display("  FAIL: pixel_x5 is not five times pixel (%0d vs 5 x %0d)",
                  n_pixel_x5, n_pixel);
         errors++;
      end else begin
         $display("  pixel_x5 / pixel = %0d / %0d, five to one   ok", n_pixel_x5, n_pixel);
      end

      if (errors == 0)
        $display("PASS: all clocks within tolerance");
      else
        $fatal(1, "FAIL: %0d clock(s) out of tolerance", errors);
      $finish;
   end

   initial begin
      #10_000_000;
      $fatal(1, "tb_clkgen: timed out waiting for MMCM lock");
   end

endmodule
