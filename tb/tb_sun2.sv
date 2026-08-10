`timescale 1ns / 1ps

//
// Testbench for the MultiBus Sun 2/120 replica.
//
// Drives the `top` module (Sun-2 glue + Suska MC68010) with the clocks and
// reset the FPGA board would supply, hangs a behavioural Wishbone RAM off the
// memory port, and decodes the serial console.  Success looks like the LED
// trace walking L_RESET -> ... -> L_M_MAP -> L_RUNNING while the boot PROM
// banner and monitor prompt come out of the UART.
//
// Plusargs:
//   +timeout_ms=<real>   give up after this much simulated time (default 1000)
//   +heartbeat_ms=<real> how often to report where the CPU is (default 10)
//   +stop_on=<string>    finish as soon as this appears on the console
//   +vcd                 dump the serial line to sun2.vcd
//   +vcd_full            dump the whole design to sun2.vcd (very large)
//   +clk4m_bit=<int>     clk40 divider bit for the SCC clock (default 2)
//
// The console rate and log file are parameters, not plusargs -- set them with
// xelab -generic_top (sim/run_xsim.sh takes SUN2_BAUD) or iverilog -P.
//

module tb_sun2 #(
    // Console rate.  The PROM programs the SCC for 9600 from its 4.9152 MHz
    // clock (time constant 14, x16 mode).  Override with -generic_top / -P.
    parameter int    BAUD    = 9600,
    parameter string CONSOLE = "console.log"
)();

   // ------------------------------------------------------------------
   // Clocks
   // ------------------------------------------------------------------
   // 39.3216 MHz = 9600 * 4096, as on the real hardware, so the serial clock
   // divides down to an exact baud rate.
   localparam real CLK40_HALF = 12.71565755208333333;

   // 12.5 MHz CPU clock, matching --cpu-clk-freq 12.5e6 in the LiteX build.
   localparam real CPUCLK_HALF = 40.0;

   // clk4m9152 is clk40 divided by 8 -> 4.9152 MHz.  This is the rate the SCC
   // must see: the PROM's own register table (WR4 x16 mode, time constant 14)
   // then yields 4915200 / (2 * 16 * 16) = 9600 baud on the console.  It is
   // also what the LiteX build constrains for the serial domain (period
   // 203.45052083 ns).  The old testbench used bit 3, i.e. clk40/16, which is
   // half this.  Overridable with +clk4m_bit for experiments.
   localparam int CLK4M_BIT_DEFAULT = 2;

   reg  clk40   = 1'b0;
   reg  cpu_clk = 1'b0;
   reg [3:0] clk4m_div = 4'h0;
   int  clk4m_bit = CLK4M_BIT_DEFAULT;
   wire clk4m9152 = clk4m_div[clk4m_bit];

   always #(CLK40_HALF)  clk40   = ~clk40;
   always #(CPUCLK_HALF) cpu_clk = ~cpu_clk;
   always @(posedge clk40) clk4m_div <= clk4m_div + 1;

   // Measure what we actually generate, rather than trusting the arithmetic:
   // the SCC's baud rate comes straight off clk4m9152, so a wrong divider
   // shows up as a garbled console a few simulated seconds later.
   task automatic measure_clocks(input real window_us);
      int n40, ncpu, nscc;
      fork
         begin : counters
            fork
               forever @(posedge clk40)      n40++;
               forever @(posedge cpu_clk)    ncpu++;
               forever @(posedge clk4m9152)  nscc++;
            join
         end
         #(window_us * 1000.0);
      join_any
      disable counters;
      $display("measured over %0.0f us: clk40 %0.4f MHz, cpu_clk %0.4f MHz, SCC clock %0.4f MHz",
               window_us, n40 / window_us, ncpu / window_us, nscc / window_us);
      $display("  => %0.0f baud at the SCC's usual 4.9152 MHz / 512 divide",
               (nscc / window_us) * 1.0e6 / 512.0);
   endtask

   // ------------------------------------------------------------------
   // Reset
   // ------------------------------------------------------------------
   reg sys_reset = 1'b1;
   initial begin
      #2000 sys_reset = 1'b0;
   end

   // ------------------------------------------------------------------
   // DUT
   // ------------------------------------------------------------------
   wire        tx;
   wire        rx = 1'b1;         // console input idle
   wire [7:0]  diag_leds;
   wire        en_boot;
   wire [7:0]  todebug;

   wire        wb_cyc, wb_stb, wb_we, wb_ack;
   wire [29:0] wb_adr;
   wire [31:0] wb_dat_m2s, wb_dat_s2m;
   wire [3:0]  wb_sel;

   top dut(.cpu_clk(cpu_clk),
           .clk40(clk40),
           .clk4m9152(clk4m9152),
           .sys_reset(sys_reset),

           .tx(tx),
           .rx(rx),

           .diag_leds(diag_leds),
           .en_boot(en_boot),
           .todebug(todebug),

           .wb_cyc_o(wb_cyc),
           .wb_stb_o(wb_stb),
           .wb_adr_o(wb_adr),
           .wb_dat_o(wb_dat_m2s),
           .wb_sel_o(wb_sel),
           .wb_we_o(wb_we),
           .wb_dat_i(wb_dat_s2m),
           .wb_ack_i(wb_ack)
           );

   // Main memory. In the FPGA build this is LiteDRAM behind a clock-domain
   // crossing; here a plain one-cycle-ack model in the CPU clock domain.
   wb_ram_model #(.ACK_LATENCY(0)) ram(.clk(cpu_clk),
                                       .reset(sys_reset),
                                       .wb_cyc_i(wb_cyc),
                                       .wb_stb_i(wb_stb),
                                       .wb_adr_i(wb_adr),
                                       .wb_dat_i(wb_dat_m2s),
                                       .wb_sel_i(wb_sel),
                                       .wb_we_i(wb_we),
                                       .wb_dat_o(wb_dat_s2m),
                                       .wb_ack_o(wb_ack)
                                       );

   // ------------------------------------------------------------------
   // Serial console
   // ------------------------------------------------------------------
   uart_monitor #(.BAUD(BAUD), .LOGFILE(CONSOLE)) console_mon(.rx(tx));

   // ------------------------------------------------------------------
   // Progress reporting
   // ------------------------------------------------------------------
   // sun2_fpga already $displays the decoded LED state; add a timestamp so the
   // trace can be lined up against the console output.
   always @(diag_leds)
     $display("[%t] diag_leds = %02x (boot=%0d)", $realtime, diag_leds, en_boot);

   // Heartbeat: where is the CPU?  Without this a long diagnostic loop and a
   // hang look exactly the same from the outside.
   real heartbeat_ms = 10.0;
   initial begin
      void'($value$plusargs("heartbeat_ms=%f", heartbeat_ms));
      forever begin
         #(heartbeat_ms * 1000000.0);
         $display("[%t] alive: A=%06x FC=%0d AS=%0d RW=%0d DTACK=%0d BERR=%0d diag=%02x",
                  $realtime, {dut.P_A, 1'b0}, dut.P_FC, ~dut.P_AS_n, ~dut.P_RW_n,
                  ~dut.P_DTACK_n, ~dut.P_BERR_n, diag_leds);
      end
   end

   // ------------------------------------------------------------------
   // Run control
   // ------------------------------------------------------------------
   real timeout_ms = 1000.0;

   task automatic wrap_up(input string why);
      $display("");
      $display("=== %s at %t ===", why, $realtime);
      console_mon.report();
      ram.report();
      $finish;
   endtask

   initial begin
      $timeformat(-9, 0, " ns", 12);

      void'($value$plusargs("timeout_ms=%f", timeout_ms));
      void'($value$plusargs("clk4m_bit=%d", clk4m_bit));

      $display("=== Sun-2 (MultiBus) simulation ===");
      $display("cpu_clk %0.4f MHz, clk40 %0.4f MHz, SCC clock %0.4f MHz (clk40 / %0d)",
               500.0 / CPUCLK_HALF, 500.0 / CLK40_HALF,
               (500.0 / CLK40_HALF) / real'(2 << clk4m_bit), 2 << clk4m_bit);
      $display("timeout %0.1f ms of simulated time", timeout_ms);
      measure_clocks(100.0);

      if ($test$plusargs("vcd_full")) begin
         $dumpfile("sun2.vcd");
         $dumpvars(0, tb_sun2);
      end else if ($test$plusargs("vcd")) begin
         $dumpfile("sun2.vcd");
         $dumpvars(0, dut.sun2.tolog);
      end

      #(timeout_ms * 1000000.0);
      wrap_up("TIMEOUT");
   end

   // Finish early once the console shows what we were waiting for.
   always @(posedge console_mon.stop_seen) begin
      #1000000;                 // let a little more output drain
      wrap_up("STOP STRING SEEN");
   end

endmodule
