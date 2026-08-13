`timescale 1ns / 1ps

//
// Testbench for the Sun-2 replica -- whichever machine sun2_config.vh selects.
// It is machine-agnostic: the design announces what it was built as at time 0.
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
    parameter string CONSOLE = "console.log",
    // Wait states before the memory acknowledges.  Zero is a memory that
    // answers next cycle, which is what every simulation of this design used
    // until the real path was measured: through MIG a Wishbone read takes 7
    // cpu_clk from STB to ACK (make -C sim migddr3 reports it).  That matters
    // now that the Ethernet competes for the same bus by DVMA, so run the VME
    // machine at 7 before trusting anything about Ethernet bandwidth.
    parameter int    MEM_LATENCY = 0
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

   // The MII side.  Needed even though nothing is plugged in: without a
   // transmit clock the 82586 never finishes a TRANSMIT command, and the boot
   // PROM waits on that with no timeout.
   wire       mii_tx_clk, mii_tx_en, mii_tx_er, mii_rx_clk, mii_rx_dv, mii_rx_er;
   wire       mii_crs, mii_col;
   wire [3:0] mii_txd, mii_rxd;
   wire       eth_crs_stuck;

   // A PHY that never releases carrier hangs the boot PROM with nothing
   // printed; say so rather than letting the run just time out.
   always @(posedge eth_crs_stuck)
     $display("[%t] WARNING: carrier sense stuck asserted -- transmission cannot proceed",
              $realtime);

   mii_peer peer(.mii_tx_clk(mii_tx_clk), .mii_txd(mii_txd),
                 .mii_tx_en(mii_tx_en), .mii_tx_er(mii_tx_er),
                 .mii_rx_clk(mii_rx_clk), .mii_rxd(mii_rxd),
                 .mii_rx_dv(mii_rx_dv), .mii_rx_er(mii_rx_er),
                 .mii_crs(mii_crs), .mii_col(mii_col));

   top dut(.cpu_clk(cpu_clk),
           .clk40(clk40),
           .clk4m9152(clk4m9152),
           .sys_reset(sys_reset),

           .tx(tx),
           .rx(rx),

           .diag_leds(diag_leds),
           .en_boot(en_boot),
           .todebug(todebug),

           .eth_crs_stuck(eth_crs_stuck),

           // There is no board layer here and so no PHY at all -- mii_peer is
           // the wire, not a transceiver.  The status register in device page
           // 0xFE7 correctly reports a bring-up that never happened.
           .phy_id(16'h0000),
           .phy_present(1'b0),
           .phy_cfg_done(1'b0),
           .phy_link(1'b0),
           .phy_fd(1'b0),
           .phy_speed(2'b00),

           .mii_tx_clk(mii_tx_clk),
           .mii_txd(mii_txd),
           .mii_tx_en(mii_tx_en),
           .mii_tx_er(mii_tx_er),
           .mii_rx_clk(mii_rx_clk),
           .mii_rxd(mii_rxd),
           .mii_rx_dv(mii_rx_dv),
           .mii_rx_er(mii_rx_er),
           .mii_crs(mii_crs),
           .mii_col(mii_col),

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
   wb_ram_model #(.ACK_LATENCY(MEM_LATENCY)) ram(.clk(cpu_clk),
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

   // Bus errors.  A PROM written for different hardware tends to fail by
   // touching something that does not answer, so say where and why rather than
   // leaving a silent stall to be reverse-engineered from a waveform.
   // The Sun-2 raises BERR either on a protection violation from the page map
   // or on a bus timeout (see the ERR term in sun2_fpga.v).
   // Diagnostics that deliberately provoke protection faults hit the same
   // address thousands of times, so collapse repeats: report each distinct
   // (address, cause) once and say how many followed.  Otherwise the
   // interesting error after a burst is never seen.
   int    n_berr = 0, n_repeat = 0;
   logic [23:0] last_berr_a = 24'hffffff;
   logic        last_berr_t;

   task automatic flush_repeats();
      if (n_repeat > 0)
        $display("                ... and %0d more at that address", n_repeat);
      n_repeat = 0;
   endtask

   always @(negedge dut.P_BERR_n) begin
      automatic logic [23:0] a = {dut.P_A, 1'b0};
      automatic logic        t = dut.sun2.TIMEOUT;
      n_berr++;
      if (a === last_berr_a && t === last_berr_t) begin
         n_repeat++;
      end else begin
         flush_repeats();
         // Report the physical side too: the virtual address says little on a
         // machine with an MMU, and what actually decodes is the page map's
         // type field and physical page.  type 0 = memory, 1 = on-board I/O,
         // 2 = the system bus.
         $display("[%t] BUS ERROR #%0d: A=%06x FC=%0d %s -> type %0d page %03x  (%s)",
                  $realtime, n_berr, a, dut.P_FC,
                  dut.P_RW_n ? "read" : "write",
                  dut.sun2.TYPE, dut.sun2.ma_pmap2devices,
                  t ? "timeout, nothing answered"
                    : "protection violation from the page map");
         last_berr_a = a;
         last_berr_t = t;
      end
   end

   // A 68010 that takes a bus error while already handling one double-faults
   // and halts.  From outside that looks identical to a tight loop, so say it.
   // Timer/interrupt tracing.  Off by default -- +trace_irq=N prints the first
   // N timer-output and IPL changes, which is how you tell whether the NMI
   // clock the boot monitor measures wall time with is running at all.
   int trace_irq = 0, n_irqtrace = 0;
   initial void'($value$plusargs("trace_irq=%d", trace_irq));

   always @(dut.sun2.timer_int[1] or dut.sun2.EN_INT)
     if (n_irqtrace < trace_irq) begin
        n_irqtrace++;
        $display("[%t] timer OUT1=%b EN_INT=%b IPL_n=%b%b%b", $realtime,
                 dut.sun2.timer_int[1], dut.sun2.EN_INT,
                 dut.IPL2_n, dut.IPL1_n, dut.IPL0_n);
     end

   // DVMA tracing.  +trace_dvma=N reports the first N bus cycles the Ethernet
   // takes as an alternate master.  Without this a translation fault, a byte
   // order mistake and a chip that never started are indistinguishable -- all
   // three just leave the boot PROM printing "ie: cannot initialize", and its
   // driver never reads the bus-error bit that would tell them apart.
   //
   // What to look for, in order: three reads around 0xFFFFF6 (the SCP the part
   // has hard-wired), two at 0x0A0400 (the ISCP), then a write of zero to
   // 0x0A0400 -- that last one is what the PROM is spinning on.
   int trace_dvma = 0, n_dvma = 0;
   initial void'($value$plusargs("trace_dvma=%d", trace_dvma));

   // Everything is latched at the instant it is actually valid: address and
   // strobes when AS falls, data on the clock edge the cycle is acknowledged.
   // Sampling it all when AS rises reports the strobes already withdrawn and
   // races the read mux, which is a good way to chase a bug that is not there.
   logic [23:0] cap_a;
   logic        cap_rw, cap_uds, cap_lds, cap_berr;
   logic [15:0] cap_d;
   logic [11:0] cap_pp;
   logic [2:0]  cap_ty;

   always @(negedge dut.dvma_as_n) begin
      cap_a    <= {dut.dvma_a, 1'b0};
      cap_rw   <= dut.dvma_rw_n;
      cap_uds  <= ~dut.dvma_uds_n;
      cap_lds  <= ~dut.dvma_lds_n;
      cap_berr <= 1'b0;
   end

   always @(posedge dut.C100)
     if (!dut.dvma_as_n && dut.dvma_active) begin
        if (!dut.P_DTACK_n) begin
           cap_d <= dut.dvma_rw_n ? dut.P_DOUT : dut.dvma_dout;
           cap_pp <= dut.sun2.ma_pmap2devices;
           cap_ty <= dut.sun2.TYPE;
        end
        if (!dut.P_BERR_n)
          cap_berr <= 1'b1;
     end

   always @(posedge dut.dvma_as_n)
     if (dut.dvma_active) begin
        n_dvma++;
        if (n_dvma <= trace_dvma)
          $display("[%t] DVMA #%0d: A=%06x %s uds=%0d lds=%0d data=%04x -> type %0d page %03x%s",
                   $realtime, n_dvma, cap_a, cap_rw ? "read " : "write",
                   cap_uds, cap_lds, cap_d, cap_ty, cap_pp,
                   cap_berr ? "  <- BUS ERROR" : "");
     end

   // What the CPU does to the same window.  The driver saves the ten bytes at
   // 0xFFFFF6, writes its SCP there, lets the chip fetch it and puts them back;
   // if the CPU's writes and the chip's reads do not land on the same physical
   // page, that is the whole bug and this is what shows it.
   always @(posedge dut.C100)
     if (trace_dvma > 0 && !dut.dvma_active && !dut.P_AS_n && !dut.P_DTACK_n
         && dut.sun2.FC_GENERAL && {dut.P_A, 1'b0} >= 24'hfffff6)
       $display("[%t]  CPU: A=%06x %s FC=%0d uds=%0d lds=%0d data=%04x -> type %0d page %03x",
                $realtime, {dut.P_A, 1'b0}, dut.P_RW_n ? "read " : "write",
                dut.P_FC, ~dut.P_UDS_n, ~dut.P_LDS_n,
                dut.P_RW_n ? dut.P_DOUT : dut.P_DIN,
                dut.sun2.TYPE, dut.sun2.ma_pmap2devices);

   always @(negedge dut.HALT_OUTn)
     $display("[%t] CPU HALTED (double bus fault) with A=%06x", $realtime, {dut.P_A, 1'b0});

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
      flush_repeats();
      if (n_berr > 0) $display("%0d bus errors in total", n_berr);
      if (n_dvma > 0) $display("%0d DVMA cycles in total", n_dvma);
      console_mon.report();
      ram.report();
      $finish;
   endtask

   initial begin
      $timeformat(-9, 0, " ns", 12);

      void'($value$plusargs("timeout_ms=%f", timeout_ms));
      void'($value$plusargs("clk4m_bit=%d", clk4m_bit));

      $display("=== Sun-2 simulation ===");
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
