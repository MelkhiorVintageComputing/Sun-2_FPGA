//
// Clocks for the Arrow DECA (MAX 10 10M50DAF484C6GES).
//
// The twin of boards/Wukong/wukong_clkgen.sv, and it has the same job: turn the
// board's 50 MHz oscillator into the two clocks the Sun-2 actually needs.
// Everything else about the two files differs, because a MAX 10 PLL is not an
// MMCM -- most importantly it has **integer counters only**, where the Wukong
// gets its 4.9152 MHz from a fractional output divider of 125.25.
//
// Two ALTPLLs rather than one, for the same reason the Wukong uses two MMCMs:
// no single VCO makes both clocks, since 1000/4.9152 is not an integer.  Having
// the serial clock on its own PLL also means CPU_CLK_HZ cannot perturb the
// console baud rate, which is a property worth keeping.
//
// -------------------------------------------------------------------- PLL A
//
// N=1, M=20 -> VCO 1000 MHz, exactly the Wukong's.  That is deliberate: it
// means CPU_DIV names the same clock on both boards, so a divider quoted in
// CLAUDE.md or a commit message does not have to say which board it was for.
//
//   CPU_DIV=80  -> 12.5 MHz    the port's target
//   CPU_DIV=100 -> 10.0 MHz    the fallback, and what a real 2/120 ran at
//   CPU_DIV=50  -> 20.0 MHz    almost certainly beyond a MAX 10 here
//
// PFD is 50 MHz (MAX 10 allows roughly 5..325) and the VCO 1000 MHz (roughly
// 600..1300 on a -6), so both are inside their ranges with room.
//
// -------------------------------------------------------------------- PLL B
//
// N=5, M=87 -> VCO 870 MHz, C=177 -> 4.915254 MHz against a target of
// 4.915200: +0.0011%, which is 9600.11 baud out of the SCC's /512.  The Wukong
// manages 4.915170 MHz (-0.0006%) with its fractional divider; both are far
// inside anything a UART cares about, and far inside a real crystal's tolerance.
//
// N=7, M=139, C=202 -> 4.915134 MHz is the documented alternative if 870 MHz
// ever turns out to be an awkward VCO on this part.
//
// Neither ratio is a guess: they were searched over the legal integer space and
// the search is reproducible.  What must still be *measured* is what Quartus's
// PLL solver actually programmed -- syn/quartus_sta.tcl checks the derived
// clock periods rather than trusting these comments, because a solver that
// quietly rounds is exactly the sort of thing this project keeps being bitten
// by.
//
`timescale 1ns / 1ps

module deca_clkgen #(
    // The CPU clock.  Give CPU_DIV alone where the frequency is not a whole
    // number of hertz; it wins over CPU_CLK_HZ, and quartus.tcl recomputes the
    // reported frequency from it so the banner cannot disagree with the logic.
    parameter int CPU_CLK_HZ = 12_500_000,
    parameter int CPU_DIV    = 0
) (
    input  wire clk50,        // MAX10_CLK1_50, straight off PIN_M8
    input  wire reset,        // active high, asynchronous
    output wire clk_cpu,      // CPU_CLK_HZ
    output wire clk_serial,   // 4.915254 MHz for the SCC, Am9513 and MM58167
    output wire locked        // both PLLs locked
);

   localparam int  VCO_A_HZ      = 1_000_000_000;                  // 50 * 20 / 1
   localparam int  CPU_DIVIDE    = (CPU_DIV != 0) ? CPU_DIV
                                                 : (VCO_A_HZ / CPU_CLK_HZ);
   localparam int  CPU_ACTUAL_HZ = VCO_A_HZ / CPU_DIVIDE;

   localparam real SERIAL_TARGET = 4_915_200.0;
   localparam real VCO_B_MHZ     = 870.0;                          // 50 * 87 / 5
   localparam int  SERIAL_DIV    = 177;
   localparam real SERIAL_MHZ    = VCO_B_MHZ / SERIAL_DIV;

   // No silent rounding, the same guarantee wukong_clkgen.sv:71-86 gives.  A
   // CPU_CLK_HZ that does not divide the VCO exactly is refused rather than
   // approximated, because a machine running at a frequency nobody asked for
   // is a measurement nobody can trust.
   //
   // Quartus discards system tasks, so these do not fire during synthesis --
   // syn/quartus.tcl repeats the checks that matter as Tcl, where they do.
   // They still fire in simulation, which is where a bad parameter is cheapest
   // to catch.
   initial begin
      if (CPU_DIV == 0 && CPU_DIVIDE * CPU_CLK_HZ != VCO_A_HZ)
        $fatal(1, "deca_clkgen: CPU_CLK_HZ=%0d does not divide the %0d Hz VCO exactly; pick a divisor of it (10 MHz, 12.5 MHz, 20 MHz, ...) or name the divider with CPU_DIV",
               CPU_CLK_HZ, VCO_A_HZ);
      if (CPU_DIVIDE < 1 || CPU_DIVIDE > 512)
        $fatal(1, "deca_clkgen: CPU_CLK_HZ=%0d needs a C counter of %0d, outside the 1..512 a MAX 10 PLL allows",
               CPU_CLK_HZ, CPU_DIVIDE);
      $display("deca_clkgen: cpu %0d Hz (VCO/%0d), serial %.6f MHz (%+.4f%% of %.4f MHz)",
               CPU_ACTUAL_HZ, CPU_DIVIDE, SERIAL_MHZ,
               100.0 * (SERIAL_MHZ * 1.0e6 - SERIAL_TARGET) / SERIAL_TARGET,
               SERIAL_TARGET / 1.0e6);
   end

`ifdef CLKGEN_BEHAVIOURAL
   // ------------------------------------------------------------------
   // Simulation: generate the frequencies directly.  A testbench wants the
   // clocks, not the PLLs, and this arm needs no vendor library at all -- which
   // is what lets tb_deca.sv exercise the real board top under xsim, on a
   // machine whose only simulator is Xilinx's.
   //
   // The half periods are a measurement of *this* board and must not be shared
   // with the Wukong's: 101.72470 ns here against its 101.72609.  Two boards
   // that differ in the sixth digit are two boards.
   // ------------------------------------------------------------------
   localparam real CPU_HALF_NS    = (1.0e9 / CPU_ACTUAL_HZ) / 2.0;
   localparam real SERIAL_HALF_NS = (1.0e3 / SERIAL_MHZ) / 2.0;   // 101.72470

   reg cpu_r = 1'b0, ser_r = 1'b0;
   always #(CPU_HALF_NS)    cpu_r = ~cpu_r;
   always #(SERIAL_HALF_NS) ser_r = ~ser_r;

   assign clk_cpu    = cpu_r;
   assign clk_serial = ser_r;
   assign locked     = 1'b1;

`else
   // ------------------------------------------------------------------
   // Synthesis: two ALTPLLs.
   //
   // Instantiated directly with defparam rather than through the MegaWizard,
   // for the reason wukong_clkgen.sv gives for its MMCMs: one readable file
   // that diffs and reviews like any other source, instead of a generated
   // wrapper plus a .qip plus a .ppf that nothing in the tree can check.
   //
   // ALTPLL, not "Altera PLL" -- the newer IP does not list MAX 10 among its
   // supported families at all, and asking for it gets a component that will
   // not generate.
   // ------------------------------------------------------------------
   wire locked_a, locked_b;
   wire [4:0] clk_a, clk_b;

   altpll #(
       .intended_device_family ("MAX 10"),
       .operation_mode         ("NORMAL"),
       .compensate_clock       ("CLK0"),
       .inclk0_input_frequency (20000),      // ps: 50 MHz
       .clk0_multiply_by       (20),         // VCO 1000 MHz
       .clk0_divide_by         (CPU_DIVIDE),
       .clk0_duty_cycle        (50),
       .clk0_phase_shift       ("0"),
       .lpm_type               ("altpll"),
       .port_clk0              ("PORT_USED"),
       .port_clk1              ("PORT_UNUSED"),
       .port_clk2              ("PORT_UNUSED"),
       .port_clk3              ("PORT_UNUSED"),
       .port_clk4              ("PORT_UNUSED"),
       .port_locked            ("PORT_USED"),
       .port_areset            ("PORT_USED"),
       .width_clock            (5)
   ) pll_a (
       .inclk  ({1'b0, clk50}),
       .areset (reset),
       .clk    (clk_a),
       .locked (locked_a)
   );

   altpll #(
       .intended_device_family ("MAX 10"),
       .operation_mode         ("NORMAL"),
       .compensate_clock       ("CLK0"),
       .inclk0_input_frequency (20000),      // ps: 50 MHz
       .clk0_multiply_by       (87),         // VCO = 50 * 87 / 5 = 870 MHz
       .clk0_divide_by         (5 * SERIAL_DIV),
       .clk0_duty_cycle        (50),
       .clk0_phase_shift       ("0"),
       .lpm_type               ("altpll"),
       .port_clk0              ("PORT_USED"),
       .port_clk1              ("PORT_UNUSED"),
       .port_clk2              ("PORT_UNUSED"),
       .port_clk3              ("PORT_UNUSED"),
       .port_clk4              ("PORT_UNUSED"),
       .port_locked            ("PORT_USED"),
       .port_areset            ("PORT_USED"),
       .width_clock            (5)
   ) pll_b (
       .inclk  ({1'b0, clk50}),
       .areset (reset),
       .clk    (clk_b),
       .locked (locked_b)
   );

   assign clk_cpu    = clk_a[0];
   assign clk_serial = clk_b[0];
   assign locked     = locked_a & locked_b;
`endif

endmodule
