`timescale 1ns / 1ps

// For FB_WB_BASE: the frame buffer check below has to look where the design
// put it, not where it guesses.
`include "sun2_config.vh"

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
//   +trace_abort=1       ring-buffer the SCC accesses and print them when
//                        the monitor commits to an abort, which says which
//                        of trap.s's two roads to `abort' was taken
//   +abort_pc=<hex>      address of _abortent, to make +trace_abort exact
//   +watch_addr=<hex>    print every bus cycle, CPU or DVMA, that touches
//                        this address -- 5b6 is the monitor's g_debounce
//   +reset_at_ms=<t>     press the reset button once, t simulated ms in, to
//                        see what a warm reset does that a cold one does not
//
//   +cycle_from=<ns>     print every clock edge, both edges, between these
//   +cycle_to=<ns>       two times: the whole state of one bus cycle
//
//   +fb_dump_ms=<real>   with a display fitted, rewrite the frame buffer
//                        capture this often so the screen can be rendered
//                        during the run rather than only at the end
//
// The console rate and log file are parameters, not plusargs -- set them with
// xelab -generic_top (sim/run_xsim.sh takes SUN2_BAUD) or iverilog -P.
//

module tb_sun2 #(
    // Console rate.  The PROM programs the SCC for 9600 from its 4.9152 MHz
    // clock (time constant 14, x16 mode).  Override with -generic_top / -P.
    parameter int    BAUD    = 9600,
    parameter string CONSOLE = "console.log",
    // Where the frame buffer is written at the end of an SUN2_FB run, for
    // "make -C sim screenshot" to render.  Relative, like CONSOLE: run_xsim.sh
    // has already cd'd into build/sim/xsim-vme-fb.
    parameter string FBIMAGE = "fb.mem",
    // Wait states before the memory acknowledges.  Zero is a memory that
    // answers next cycle, which is what every simulation of this design used
    // until the real path was measured: through MIG a Wishbone read takes 7
    // cpu_clk from STB to ACK (make -C sim migddr3 reports it).  That matters
    // now that the Ethernet competes for the same bus by DVMA, so run the VME
    // machine at 7 before trusting anything about Ethernet bandwidth.
    parameter int    MEM_LATENCY = 0,
    // The CPU clock, in Hz.  12.5 MHz is what a Sun-2 ran at and what every
    // fingerprint in the tree was measured with, so it stays the default.
    //
    // It is here because raising it looks like the obvious way to shorten a
    // long run and is not.  Measured, same machine, MEM_MIB=1 ROM=fast, boot
    // to the monitor prompt:
    //
    //     12.5 MHz   1.63 s simulated   602 s wall
    //     40   MHz   0.70 s simulated   807 s wall
    //
    // Both give 23629 bus errors and a byte-identical console, so the machine
    // does behave the same -- bus timing is counted in CPU clocks and the
    // timer and SCC still run from the 4.9152 MHz crystal.  It is simply
    // slower to simulate.
    //
    // The argument for expecting a win was that clk40, fixed at 39.3216 MHz
    // because the console's baud rate divides down from it, is the fastest
    // clock here and its event count is proportional to simulated time.  True,
    // but it clocks only the SCC.  What xsim actually spends its time on is
    // the cpu_clk domain -- the 68010, the MMU, the whole machine -- and those
    // edges went *up*, from 40.8M to 56.0M.  Wall clock followed them: +37%
    // of edges for +34% of runtime.
    //
    // They went up because simulated time did not fall by 3.2x, only by 2.3x.
    // About 270 ms of the boot is the PROM's own output at 9600 baud, which
    // takes the same real time whatever the CPU runs at; a faster CPU just
    // burns 3.2x as many cycles waiting for it.  Any part of a boot that is
    // bounded by real time rather than by instructions costs more, not less,
    // at a higher clock -- and a SunOS boot has more of that, not less.
    parameter int    CPU_HZ = 12_500_000
)();

   // ------------------------------------------------------------------
   // Clocks
   // ------------------------------------------------------------------
   // 39.3216 MHz = 9600 * 4096, as on the real hardware, so the serial clock
   // divides down to an exact baud rate.
   localparam real CLK40_HALF = 12.71565755208333333;

   // The CPU clock, from the CPU_HZ parameter; 12.5 MHz by default, matching
   // --cpu-clk-freq 12.5e6 in the LiteX build.
   localparam real CPUCLK_HALF = 1.0e9 / (2.0 * real'(CPU_HZ));

   // clk4m9152 is clk40 divided by 8 -> 4.9152 MHz.  This is the rate the SCC
   // must see: the PROM's own register table (WR4 x16 mode, time constant 14)
   // then yields 4915200 / (2 * 16 * 16) = 9600 baud on the console.  It is
   // also what the LiteX build constrains for the serial domain (period
   // 203.45052083 ns).  The old testbench used bit 3, i.e. clk40/16, which is
   // half this.  Overridable with +clk4m_bit for experiments:
   //
   //     +clk4m_bit=2   4.9152 MHz    9600 baud   (the real machine)
   //     +clk4m_bit=1   9.8304 MHz   19200 baud
   //     +clk4m_bit=0  19.6608 MHz   38400 baud
   //     +clk4m_bit=-1 39.3216 MHz   76800 baud   (clk40 with no divider)
   //
   // The console decoder has to be told as well, or the log is line noise:
   // BAUD is an elaboration parameter, so it is `make -C sim xsim BAUD=38400`.
   //
   // This is not a console-only knob, and the reason is in sun2_fpga.v:637.
   // clk4m9152 is also the Am9513's X2, because on the real machine the timer
   // and the SCCs share one 4.9152 MHz crystal.  Raising it runs the machine's
   // sense of real time at the same multiple -- the monitor's NMI clock, the
   // kernel's hz, and every driver timeout counted in ticks, xywatch()'s
   // four-second lost-interrupt check among them.  Nothing here needs the full
   // four seconds, so it is safe, but it is a change to the machine and not
   // just to how fast it talks.
   localparam int CLK4M_BIT_DEFAULT = 2;

   reg  clk40   = 1'b0;
   reg  cpu_clk = 1'b0;
   reg [3:0] clk4m_div = 4'h0;
   int  clk4m_bit = CLK4M_BIT_DEFAULT;
   wire clk4m9152 = (clk4m_bit < 0) ? clk40 : clk4m_div[clk4m_bit[1:0]];

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
   real reset_at_ms = 0.0;
   initial void'($value$plusargs("reset_at_ms=%f", reset_at_ms));
   initial begin
      #2000 sys_reset = 1'b0;

      // +reset_at_ms=<t>: press the reset button once, t simulated
      // milliseconds in.  A warm reset is not a cold one: the segment and page
      // maps are RAM and survive it, and so does anything the gateware fails
      // to clear.  Pressing it before the PROM has left boot state proves
      // nothing -- BOOT_n is still 0 and there is nothing to get wrong -- so
      // this has to fire well after en_boot drops, around 1.16 s on MultiBus.
      if (reset_at_ms > 0.0) begin
         #(reset_at_ms * 1000000.0 - 2000.0);
         $display("[%t] === reset asserted ===", $realtime);
         sys_reset = 1'b1;
         #10000 sys_reset = 1'b0;
         $display("[%t] === reset released ===", $realtime);
      end
   end

   // ------------------------------------------------------------------
   // DUT
   // ------------------------------------------------------------------
   wire        tx;
   wire        rx = 1'b1;         // console input idle
   wire [7:0]  diag_leds;
   wire        en_boot;
   wire [7:0]  todebug;
   wire [73:0] dbg_bus;

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

   // ------------------------------------------------------------------
   // The Xylogics 450's disk
   // ------------------------------------------------------------------
   // The block seam comes out of `top` for the same reason the MII pins do:
   // what is on the far end is an SD card on the board and a file here, and
   // the machine cannot tell.  With no +blk_image the drive reports itself
   // absent, which is a state the boot PROM has to handle anyway.
   wire        blk_start, blk_we, blk_buf_we;
   wire [31:0] blk_lba;
   wire [7:0]  blk_buf_rdata, blk_buf_wdata;
   wire [8:0]  blk_buf_addr;
   wire        blk_done, blk_err, blk_ready;
   wire [31:0] blk_count;

   // Clocked from the machine's own C100, which is what the card runs on;
   // the block seam has no clock crossing in it.
   blk_file disk(.clk(dut.C100), .rst(sys_reset),
                 .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
                 .blk_buf_rdata(blk_buf_rdata),
                 .blk_done(blk_done), .blk_err(blk_err),
                 .blk_ready(blk_ready), .blk_count(blk_count),
                 .blk_buf_we(blk_buf_we), .blk_buf_addr(blk_buf_addr),
                 .blk_buf_wdata(blk_buf_wdata));

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
           .dbg_bus(dbg_bus),

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

           .blk_start(blk_start),
           .blk_we(blk_we),
           .blk_lba(blk_lba),
           .blk_buf_rdata(blk_buf_rdata),
           .blk_done(blk_done),
           .blk_err(blk_err),
           .blk_ready(blk_ready),
           .blk_count(blk_count),
           .blk_buf_we(blk_buf_we),
           .blk_buf_addr(blk_buf_addr),
           .blk_buf_wdata(blk_buf_wdata),

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

`ifdef SUN2_FB
   // ------------------------------------------------------------------
   // Did anything reach the screen?
   // ------------------------------------------------------------------
   // With a frame buffer the boot PROM moves the console to the display and
   // the serial port goes quiet, so the usual "did it print the banner"
   // assertions have nothing to look at.  What it draws instead is the Sun
   // logo, and that is a 128-word constant in
   // Inputs/sunos-34-src/.../rsun/mon/dpy/sunlogo.c -- so look for it.
   //
   // Finding it proves rather a lot at once: that s2fbthere() passed, that the
   // aperture decodes, that the address remap into DDR3 is right, that the
   // byte lanes are right, and that the PROM's own drawing code ran.
   //
   // The byte order is the thing to be careful about, and it is worth writing
   // down because fb_scanout will need exactly the same unscrambling.  The
   // Wishbone bridge puts the CPU word at A1=0 in the *low* half of the 32-bit
   // word, so for the 32-bit word at aperture offset 4W:
   //
   //     byte 4W+0 = wb[15:8]     byte 4W+2 = wb[31:24]
   //     byte 4W+1 = wb[7:0]      byte 4W+3 = wb[23:16]
   //
   // i.e. the two 16-bit halves are swapped relative to a plain big-endian
   // bitmap.  That falls out of a convention chosen for main memory, where it
   // is invisible because it is self-consistent; here it is visible.
   localparam int unsigned FB_WORDS = 32768;   // 128 KiB / 4

   function automatic logic [7:0] fb_byte(input int unsigned off);
      logic [31:0] w;
      begin
         w = ram.fetch(`FB_WB_BASE + (off >> 2));
         case (off[1:0])
           2'd0: fb_byte = w[15:8];
           2'd1: fb_byte = w[7:0];
           2'd2: fb_byte = w[31:24];
           default: fb_byte = w[23:16];
         endcase
      end
   endfunction

   // One distinctive row from the middle of the logo, where it is widest:
   // logo_data[56..57] = 0x7FBFBFE7, 0x9FEFEFFE.
   localparam logic [7:0] LOGO [0:7] = '{8'h7F, 8'hBF, 8'hBF, 8'hE7,
                                         8'h9F, 8'hEF, 8'hEF, 8'hFE};

   function automatic int find_logo();
      int unsigned off;
      int          k;
      bit          hit;
      begin
         for (off = 0; off < FB_WORDS*4 - 8; off++) begin
            hit = 1'b1;
            for (k = 0; k < 8; k++)
              if (fb_byte(off + k) !== LOGO[k]) begin
                 hit = 1'b0;
                 break;
              end
            if (hit) return int'(off);
         end
         return -1;
      end
   endfunction

   task automatic fb_report();
      int where;
      begin
         where = find_logo();
         if (where >= 0)
           $display("PASS: the Sun logo is in the frame buffer, at offset 0x%05x (row %0d)",
                    where, where / 144);
         else
           $display("FAIL: no Sun logo in the frame buffer -- nothing reached the screen");
      end
   endtask

   // ------------------------------------------------------------------
   // The frame buffer, on its way to becoming a picture
   // ------------------------------------------------------------------
   // Finding the logo says the CPU wrote the right bits.  It says nothing
   // about the scan-out -- the line addressing, the bit order inside a beat,
   // the polarity, the windowbox -- because none of that exists at this level
   // of the design.  So write what is in the frame buffer out where
   // tb_fb_scanout can replay it through the real fb_scanout and render a PPM.
   // See "make -C sim screenshot".
   //
   // **Raw 32-bit Wishbone words, deliberately not unscrambled bytes.**
   // wb_to_mig_ui puts the word at adr[3:2] == L into bits [32L+31:32L] of the
   // 128-bit beat, so a beat is four consecutive words concatenated
   // low-lane-first and the replay reassembles them in one line.  Undoing the
   // byte order here instead would duplicate the reasoning above and give the
   // replay a second, independent chance to be wrong about it -- and the whole
   // point of rendering through fb_scanout is that it is the RTL's opinion of
   // the byte order that gets tested, not the testbench's.
   task automatic fb_dump(input string path);
      int fd;
      begin
         fd = $fopen(path, "w");
         if (fd == 0) begin
            $display("note: could not write %s", path);
            return;
         end
         for (int unsigned w = 0; w < FB_WORDS; w++)
           $fdisplay(fd, "%08x", ram.fetch(`FB_WB_BASE + w));
         $fclose(fd);
         $display("frame buffer written to %s (%0d words)", path, FB_WORDS);
      end
   endtask

   // Mirror the screen to disk *while* the run is going, not only at the end.
   //
   // With a display fitted the PROM sends the console to the frame buffer and
   // the serial port falls silent -- sunmon.c:396-401 sets g_outsink=OUTSCREEN
   // whenever s2fbthere() succeeds, and there is no way to ask for both.  So
   // console.log stays empty and the only readable artefact is fb.mem, which
   // $finish writes at the end of the run.  For a SunOS boot that is a day of
   // wall clock away, and killing the run loses it entirely -- the screen only
   // ever existed inside the simulator.
   //
   // +fb_dump_ms=<real> rewrites it on a timer instead, so
   //
   //   make -C sim screenshot MACHINE=multibus MB_ETHER=1 FB=1 XY450=1
   //
   // renders whatever the last dump caught, at any point in the run.  Off by
   // default; the cost when on is the whole aperture rewritten each time.
   //
   // The live dumps rotate over a fixed, small set of names rather than
   // accumulating: a run of any length costs FB_DUMP_KEEP files and no more.
   // They are separate from FBIMAGE, which $finish still writes and which
   // `make screenshot' renders, so a completed run is unaffected.
   //
   // Rotating also solves a problem overwriting one file does not.  There is
   // no rename in SystemVerilog, so a dump is an in-place rewrite and a render
   // that lands in the middle of one gets a torn image.  With rotation the
   // file written *before* the newest is always complete, so render that:
   //
   //   make -C sim screenshot MACHINE=multibus MB_ETHER=1 FB=1 XY450=1 \
   //        FBIMAGE=$PWD/build/sim/<rundir>/fb-live1.mem
   //
   // and the log says which index was written last.
   localparam int FB_DUMP_KEEP = 3;
   real fb_dump_ms = 0.0;
   int  fb_dump_idx = 0;
   initial begin
      void'($value$plusargs("fb_dump_ms=%f", fb_dump_ms));
      if (fb_dump_ms > 0.0)
        forever begin
           #(fb_dump_ms * 1000000.0);
           fb_dump($sformatf("fb-live%0d.mem", fb_dump_idx));
           fb_dump_idx = (fb_dump_idx + 1) % FB_DUMP_KEEP;
        end
   end
`endif

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

   // ---- X on a CPU read ---------------------------------------------------
   //
   // Any read that completes with an X anywhere in P_DOUT, reported once per
   // cycle with the address and the decode that answered it.
   //
   // This exists because two of this project's bugs were an X reaching a
   // status register and both were found by accident: the console SCC's
   // ctsa_n/dcda_n/synca_n left unconnected, which put X into RR0 bits 5..3
   // and produced the spurious `Abort', and the page map read as X at
   // power-up, which hid a fatal protection violation for the life of the
   // project.  An X in a status bit can reach any conditional derived from
   // it, whatever the mask says -- see the trap in CLAUDE.md.  This finds
   // them on purpose.
   //
   // Gated on sys_reset: before the machine is released, plenty is legitimately
   // unknown.  The decode field is
   // {MATCH_SERIAL, MATCH_KBM, MATCH_TIMER, MATCH_MEM, MATCH_PROM_BOOT}.
   //
   int   n_xread = 0;
   logic xread_seen = 1'b0;
   always @(posedge dut.C100) begin
      if (dut.P_AS_n || sys_reset) xread_seen <= 1'b0;
      else if (!xread_seen && !dut.P_DTACK_n && dut.P_RW_n && !dut.dvma_active
               && (^dut.P_DOUT === 1'bx)) begin
         xread_seen <= 1'b1;
         n_xread = n_xread + 1;
         if (n_xread <= 20)
           $display("[%t] X-READ %06x FC=%0d data=%16b decode=%5b%s",
                    $realtime, {dut.P_A, 1'b0}, dut.P_FC, dut.P_DOUT,
                    {dut.sun2.MATCH_SERIAL, dut.sun2.MATCH_KBM,
                     dut.sun2.MATCH_TIMER, dut.sun2.MATCH_MEM,
                     dut.sun2.MATCH_PROM_BOOT},
                    n_xread == 20 ? "   (no further X reads reported)" : "");
      end
   end

   // todebug, which the board wires to its second LED header.  Every bit is a
   // level or a latch, so a transition here is an event worth a line: bit 7 is
   // the CPU-clock heartbeat, then reset, seen_as, seen_prom, seen_dtack,
   // seen_timeout, seen_diag_wr and boot mode.  See sun2_fpga.v.
   always @(todebug)
     $display("[%t] todebug = %08b", $realtime, todebug);

   //
   // dbg_bus: the wide bus the board's ILA samples.  It is compiled into every
   // build -- only the ILA instantiation in wukong_top.sv is conditional -- so
   // the packing can and should be proved here, where a mismatch is a line of
   // output rather than a bench session with a field one bit out.
   //
   // Compared against the signals it is supposed to carry, by hierarchical
   // name, on every edge of the whole boot.  `!==' so that X matches X: before
   // the maps are written their outputs are X, which is a correct reading of
   // the machine and not a packing error.
   int dbg_bad = 0;
   always @(posedge dut.C100 or negedge dut.C100) begin
      if (dbg_bus !== {dut.sun2.P_A, dut.sun2.P_FC,
                       dut.sun2.P_AS_n, dut.sun2.P_RW_n,
                       dut.sun2.P_UDS_n, dut.sun2.P_LDS_n,
                       dut.sun2.P_DTACK_n, dut.sun2.P_BERR_n,
                       dut.sun2.C_S4, dut.sun2.C_S6,
                       dut.sun2.C_S8, dut.sun2.C_S24,
                       dut.sun2.ia_smap2pmap, dut.sun2.ps_pmap2devices,
                       dut.sun2.ma_pmap2devices,
                       dut.sun2.VALID, dut.sun2.PROTERR_raw, dut.sun2.PROTERR,
                       dut.sun2.TIMEOUT, dut.sun2.ERR, dut.sun2.MATCH_MEM}) begin
         dbg_bad = dbg_bad + 1;
         if (dbg_bad <= 5)
           $display("[%t] dbg_bus MISPACKED: %074b", $realtime, dbg_bus);
      end
   end
   final begin
      if (dbg_bad != 0)
        $display("dbg_bus: MISPACKED on %0d edges -- the ILA field map in sun2_fpga.v is wrong", dbg_bad);
      else
        $display("dbg_bus: packing verified on every clock edge");
   end

   // Every clock edge over a window, for pinning down the timing of one bus
   // cycle: +cycle_from=<ns> +cycle_to=<ns>.  Both edges, because the 68000
   // bus runs on both -- the odd C_S are clocked on negedge and the even on
   // posedge, matching Motorola's half-state numbering, and DTACK is sampled
   // on the falling edge that ends S4.  Sampling only posedges hides exactly
   // the half-cycle that matters; that cost a wrong reading of section 5.8
   // here once.
   //
   // This is the instrument that found the RESET-instruction stall: three
   // consecutive PROM fetches, two completing and the third not, with the
   // machine's DTACK identical in all three.
   real cyc_from = 0.0, cyc_to = 0.0;
   initial begin
      void'($value$plusargs("cycle_from=%f", cyc_from));
      void'($value$plusargs("cycle_to=%f", cyc_to));
   end
   // Both edges: the 68000 bus uses them -- the odd C_S are clocked on negedge
   // and the even on posedge, matching Motorola's half-state numbering, and
   // DTACK is sampled on the falling edge that ends S4.
   always @(posedge dut.C100 or negedge dut.C100)
     if (cyc_to > 0.0 && $realtime >= cyc_from && $realtime <= cyc_to)
       $display("[%t] %s A=%06x AS=%0d DTACK=%0d BERR=%0d | S3=%0d S4=%0d S5=%0d S6=%0d S7=%0d S8=%0d | MPB=%0d VALID=%0d PROT=%0d ERR=%0d",
                $realtime, dut.C100 ? "^" : "v", {dut.P_A, 1'b0},
                ~dut.P_AS_n, ~dut.P_DTACK_n, ~dut.P_BERR_n,
                dut.sun2.C_S3, dut.sun2.C_S4, dut.sun2.C_S5, dut.sun2.C_S6,
                dut.sun2.C_S7, dut.sun2.C_S8,
                dut.sun2.MATCH_PROM_BOOT, dut.sun2.VALID,
                dut.sun2.PROTERR, dut.sun2.ERR);

   // The same cycle as the board's ILA will show it, decoded out of dbg_bus
   // rather than out of the design -- so a capture from hardware and a line
   // from simulation can be read side by side, and so the field boundaries are
   // exercised on a cycle whose answer is already known.
   always @(posedge dut.C100 or negedge dut.C100)
     if (cyc_to > 0.0 && $realtime >= cyc_from && $realtime <= cyc_to)
       $display("[%t] %s   ila: A=%06x FC=%0d AS=%0d RW=%0d UDS=%0d LDS=%0d DTACK=%0d BERR=%0d | S4=%0d S6=%0d S8=%0d S24=%0d | smap=%02x ps=%03x ma=%03x | V=%0d Praw=%0d P=%0d T=%0d E=%0d MEM=%0d",
                $realtime, dut.C100 ? "^" : "v",
                {dbg_bus[73:51], 1'b0}, dbg_bus[50:48],
                ~dbg_bus[47], ~dbg_bus[46], ~dbg_bus[45], ~dbg_bus[44],
                ~dbg_bus[43], ~dbg_bus[42],
                dbg_bus[41], dbg_bus[40], dbg_bus[39], dbg_bus[38],
                dbg_bus[37:30], dbg_bus[29:18], dbg_bus[17:6],
                dbg_bus[5], dbg_bus[4], dbg_bus[3],
                dbg_bus[2], dbg_bus[1], dbg_bus[0]);

`ifdef SUSKA_PEEK
   // Suska's own view of the same cycle -- EXTRA_DEFINES=SUSKA_PEEK, and only
   // with CPU=suska, since it reaches into that core by hierarchical name.
   //
   // DTACK_In is the core's registered copy, taken on the falling edge;
   // WAITSTATES is consulted only while the core is in its own slice S3, and
   // RESET_OUT_I outranks DTACK_In in that expression unless
   // patches/Suska_Configware/0001 is applied.  Printing the four together is
   // what separated "the machine acknowledged late" from "the core ignored the
   // acknowledgement".
   always @(posedge dut.C100 or negedge dut.C100)
     if (cyc_to > 0.0 && $realtime >= cyc_from && $realtime <= cyc_to)
       $display("[%t] %s   suska: DTACK_In=%b WAITSTATES=%b SLICE_CNT_P=%b RESET_OUT=%b",
                $realtime, dut.C100 ? "^" : "v",
                dut.suska_68k10.I_BUS_IF.DTACK_In,
                dut.suska_68k10.I_BUS_IF.WAITSTATES,
                dut.suska_68k10.I_BUS_IF.SLICE_CNT_P,
                dut.suska_68k10.I_BUS_IF.RESET_OUT_I);
`endif

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
         // On a protection fault the six permission bits are the whole
         // story, so print them rather than making someone re-run with a
         // waveform.  ps_pmap2devices[11:6] are, in order, PMP_SUP_READ,
         // SUP_WRITE, SUP_EXECUTE, USER_READ, USER_WRITE and USER_EXECUTE --
         // the names in sun2_fpga.v call the first one VALID, which it is
         // not.  [5] is not wired to anything.  The pmeg and the two context
         // registers say which entry was consulted to get there.
         $display("[%t] BUS ERROR #%0d: A=%06x FC=%0d %s -> type %0d page %03x  (%s)",
                  $realtime, n_berr, a, dut.P_FC,
                  dut.P_RW_n ? "read" : "write",
                  dut.sun2.TYPE, dut.sun2.ma_pmap2devices,
                  t ? "timeout, nothing answered"
                    : "protection violation from the page map");
         if (!t)
           $display("                perm SR=%0d SW=%0d SX=%0d UR=%0d UW=%0d UX=%0d (spare=%0d)  pmeg=%02x  ctx sup=%0d usr=%0d",
                    dut.sun2.ps_pmap2devices[11], dut.sun2.ps_pmap2devices[10],
                    dut.sun2.ps_pmap2devices[9],  dut.sun2.ps_pmap2devices[8],
                    dut.sun2.ps_pmap2devices[7],  dut.sun2.ps_pmap2devices[6],
                    dut.sun2.ps_pmap2devices[5],
                    dut.sun2.ia_smap2pmap,
                    dut.sun2.ctx_out[10:8], dut.sun2.ctx_out[2:0]);
         // Who was driving, and was this even a live bus cycle?  A supervisor
         // 68010 has no business emitting FC=2, and the only way it can is a
         // `moves` with SFC/DFC set to FC_UP -- so record whether the CPU or
         // the DVMA engine owned the bus, what the CPU's own FC lines said,
         // and whether AS was actually asserted.
         if (!t)
           $display("                dvma=%0d cpu_fc=%0d p_fc=%0d AS_n=%0d C_S8=%0d ctrl=%0d gen=%0d",
                    dut.dvma_active, dut.cpu_fc, dut.P_FC, dut.P_AS_n,
                    dut.sun2.C_S8, dut.sun2.FC_CTRLLAYER, dut.sun2.FC_GENERAL);
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

   // ---------------------------------------------------------------------
   // Why the monitor decided to abort.  +trace_abort
   // ---------------------------------------------------------------------
   // The NMI handler has two roads to `abort' (msun/mon/kernel/trap.s), and
   // the console shows neither -- the machine simply arrives at `Abort at
   // <pc>'.  With a Sun-2 keyboard fitted it first polls the keyboard SCC for
   // RX_READY and hands any character to keypress() (trap.s:503-535); only if
   // that finds nothing does it fall through to the serial BREAK debounce,
   // which declares an abort on any 1->0 change of the BREAK bit between
   // ticks (trap.s:585-604).  Both read RR0 of an SCC whose receive line is
   // tied to mark, so neither should ever fire.
   //
   // Both are ruled out by the trace as it stands -- the keyboard SCC reads
   // 00000100 and the console SCC 00xxx100, whose X bits are 5, 4 and 3 and so
   // are masked away by ZSRR0_BREAK (0x80).  What is left is g_debounce, the
   // byte the debounce compares against, which the PROM keeps at 0x5B6
   // (ef043c: cmpb 0x5b6,%d0).  d0.b is RR0 & 0x80 and bit 7 is clean, so the
   // second branch is always taken and the abort fires exactly when that byte
   // is not zero -- which makes `+watch_addr=5b6' the interesting instrument.
   //
   // Keep a ring of the last accesses to either SCC and print it when the
   // monitor commits.  _abortent begins `movw #EVEC_ABORT,sp@(i_vor)' -- a
   // word write of 0x0081 -- which, qualified by a level-7 acknowledge in the
   // last 500 us, is a precise enough trigger to catch without knowing where
   // the PROM put the label.  Unqualified it fires in the self test.
   // Roughly where the CPU is.  The last instruction fetch is not the PC -- the
   // 68010 prefetches two words ahead -- but it is near enough to say which
   // routine a data cycle came from, which is the difference between "something
   // wrote this byte" and "this instruction wrote this byte".
   logic [23:0] last_ifetch = 24'h0;
   logic        ifetch_seen = 1'b0;

   always @(posedge dut.C100) begin
      if (dut.P_AS_n)
        ifetch_seen <= 1'b0;
      else if (!ifetch_seen && !dut.P_DTACK_n && !dut.dvma_active
               && dut.P_RW_n && dut.P_FC == 3'h6) begin
         ifetch_seen <= 1'b1;
         last_ifetch <= {dut.P_A, 1'b0};
      end
   end

   localparam int SCCLOG = 96;

   int  trace_abort = 0;
   initial void'($value$plusargs("trace_abort=%d", trace_abort));

   real         scc_t  [SCCLOG];
   logic [23:0] scc_a  [SCCLOG];
   logic [15:0] scc_d  [SCCLOG];
   logic        scc_rw [SCCLOG];
   logic        scc_kb [SCCLOG];
   real         last_iack7 = -1.0e30;
   // Where _abortent is, if you know: on the MultiBus rev R PROM it is
   // ef0452, `movew #EVEC_ABORT,sp@(i_vor)'.  A prefetch can fetch that word
   // without executing it, but it cannot perform the write, so a 0x0081 write
   // with the fetch pointer inside the routine is exact.  Without it the
   // trigger falls back to "an NMI was acknowledged recently", which on a
   // machine whose NMI ticks every 2.5 ms is barely a qualification at all --
   // it reported 36 aborts in a run that took none.
   int          abort_pc = 0;
   initial void'($value$plusargs("abort_pc=%h", abort_pc));
   int          scc_n = 0;
   logic        scc_seen = 1'b0;
   logic        abt_seen = 1'b0;

   always @(posedge dut.C100) begin
      if (dut.P_AS_n) begin
         scc_seen <= 1'b0;
         abt_seen <= 1'b0;
      end else if (trace_abort != 0 && !dut.P_DTACK_n && !dut.dvma_active) begin
         if (!scc_seen && (dut.sun2.MATCH_SERIAL || dut.sun2.MATCH_KBM)) begin
            scc_seen                 <= 1'b1;
            scc_t [scc_n % SCCLOG]   <= $realtime;
            scc_a [scc_n % SCCLOG]   <= {dut.P_A, 1'b0};
            scc_d [scc_n % SCCLOG]   <= dut.P_RW_n ? dut.P_DOUT : dut.P_DIN;
            scc_rw[scc_n % SCCLOG]   <= dut.P_RW_n;
            scc_kb[scc_n % SCCLOG]   <= dut.sun2.MATCH_KBM;
            scc_n                    <= scc_n + 1;
            // +trace_abort=2 prints every access as it happens, in binary,
            // which is what shows an X in an individual RR0 bit rather than
            // the whole byte going to X in a hex display.
            if (trace_abort > 1)
              $display("[%t]  scc %-8s A=%06x %s data=%8b",
                       $realtime, dut.sun2.MATCH_KBM ? "keyboard" : "console",
                       {dut.P_A, 1'b0}, dut.P_RW_n ? "read " : "write",
                       dut.P_RW_n ? dut.P_DOUT[15:8] : dut.P_DIN[15:8]);
         end
         // The abort commit itself.
         if (!abt_seen && !dut.P_RW_n && !dut.P_UDS_n && !dut.P_LDS_n
             && dut.P_DIN == 16'h0081
             && ((abort_pc > 0)
                 ? (last_ifetch >= abort_pc && last_ifetch < abort_pc + 24'h10)
                 : (($realtime - last_iack7) < 500000.0))) begin
            abt_seen <= 1'b1;
            scc_dump();
         end
      end
   end

   // Every bus cycle touching one word, CPU or DVMA.  g_debounce is the reason
   // it exists, but nothing about it is specific to that: a monitor variable
   // that changes when nothing should have written it is a shape of bug this
   // machine has no other way to see.
   int watch_addr = -1;
   logic watch_seen = 1'b0;
   initial void'($value$plusargs("watch_addr=%h", watch_addr));

   always @(posedge dut.C100) begin
      if (dut.P_AS_n)
        watch_seen <= 1'b0;
      else if (watch_addr >= 0 && !watch_seen && !dut.P_DTACK_n
               && {dut.P_A, 1'b0} == (watch_addr & 24'hFFFFFE)) begin
         watch_seen <= 1'b1;
         $display("[%t] WATCH %06x %s FC=%0d uds=%0d lds=%0d data=%16b from %06x%s",
                  $realtime, {dut.P_A, 1'b0}, dut.P_RW_n ? "read " : "write",
                  dut.P_FC, ~dut.P_UDS_n, ~dut.P_LDS_n,
                  dut.P_RW_n ? dut.P_DOUT : dut.P_DIN, last_ifetch,
                  dut.dvma_active ? "  <- DVMA" : "");
      end
   end

   task automatic scc_dump();
      int i, first;
      begin
         $display("[%t] ABORT COMMIT (EVEC_ABORT written) -- last %0d SCC accesses:",
                  $realtime, (scc_n < SCCLOG) ? scc_n : SCCLOG);
         first = (scc_n < SCCLOG) ? 0 : scc_n - SCCLOG;
         for (i = first; i < scc_n; i++)
           $display("    %12.0f ns  %-8s A=%06x %s  data=%8b",
                    scc_t[i % SCCLOG],
                    scc_kb[i % SCCLOG] ? "keyboard" : "console",
                    scc_a[i % SCCLOG],
                    scc_rw[i % SCCLOG] ? "read " : "write",
                    scc_d[i % SCCLOG][15:8]);
      end
   endtask

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
   // Which interrupts a run actually took
   // ------------------------------------------------------------------
   // An interrupt acknowledge is a CPU-space cycle (FC=7) with the level on
   // A3..A1, so counting those by level answers "did this boot exercise
   // anything besides the NMI clock?" without having to reason from the PROM
   // source about which devices it polls.  Always on: it is a counter per bus
   // cycle and costs nothing.
   int iack_count[8];
   reg iack_seen = 1'b0;

   always @(posedge dut.C100) begin
      if (dut.P_AS_n) begin
         iack_seen <= 1'b0;
      end else if (!iack_seen && dut.P_FC == 3'h7 &&
                   (!dut.P_DTACK_n || !dut.P_BERR_n || !dut.P_VPA_n)) begin
         iack_seen <= 1'b1;
         iack_count[dut.P_A[3:1]] <= iack_count[dut.P_A[3:1]] + 1;
         // +trace_abort needs to know when the NMI handler last started: the
         // only road to `abort' runs through it, and a bare word write of
         // 0x0081 is common enough elsewhere to trigger on noise without this.
         if (dut.P_A[3:1] == 3'h7) last_iack7 <= $realtime;
      end
   end

   task automatic iack_report();
      int total = 0;
      for (int l = 0; l < 8; l++) total += iack_count[l];
      if (total == 0) begin
         $display("[iack] no interrupts were acknowledged");
      end else begin
         $display("[iack] %0d interrupts acknowledged", total);
         for (int l = 0; l < 8; l++)
           if (iack_count[l] > 0)
             $display("         level %0d: %0d", l, iack_count[l]);
      end
   endtask

   // ------------------------------------------------------------------
   // Bus cycle trace
   // ------------------------------------------------------------------
   // +trace_bus_from=<ms> logs every 68010 bus cycle from that simulated time,
   // with the address, function code, direction, strobes, the data actually on
   // the bus, and which of DTACK / BERR / VPA ended it.  Off unless asked for:
   // a boot is millions of cycles.
   //
   // The point of logging VPA and FC together is that P_VPA_n is combinational
   // on the function code (`sun2_fpga.v:195', ~(P_FC == 7)), so anything that
   // leaves FC stale between cycles leaves VPA asserted with it.  A trace that
   // shows FC and VPA per cycle settles that in one read rather than by
   // argument.
   // Read data is reported at two sampling points, because which one is right
   // is not obvious and getting it wrong invents data that never existed.  d0
   // is the bus at the clock the termination is first seen; d1 is one clock
   // later, still inside the cycle.  On a write they are the same value the
   // CPU is driving.  When d0 and d1 differ on a read, d1 is the one the CPU
   // latched -- d0 catches the mux before the slave has driven.
   real trace_bus_from = -1.0;
   reg  trace_seen = 1'b0;
   reg         tr_pend = 1'b0;
   reg [23:0]  tr_a;
   reg [2:0]   tr_fc;
   reg         tr_rw, tr_uds, tr_lds, tr_dtack, tr_berr, tr_vpa;
   reg [15:0]  tr_d0;

   always @(posedge dut.C100) begin
      if (trace_bus_from >= 0.0 && $realtime >= trace_bus_from * 1000000.0) begin
         if (tr_pend) begin
            tr_pend <= 1'b0;
            $display("[%t] BUS A=%06x FC=%0d %s uds=%0d lds=%0d d0=%04x d1=%04x  %s%s%s",
                     $realtime, tr_a, tr_fc, tr_rw ? "rd" : "wr",
                     tr_uds, tr_lds, tr_d0,
                     tr_rw ? dut.P_DOUT : dut.P_DIN,
                     tr_dtack ? "DTACK " : "", tr_berr ? "BERR " : "",
                     tr_vpa ? "VPA" : "");
         end
         if (dut.P_AS_n) begin
            trace_seen <= 1'b0;
         end else if (!trace_seen &&
                      (!dut.P_DTACK_n || !dut.P_BERR_n || !dut.P_VPA_n)) begin
            trace_seen <= 1'b1;
            tr_pend  <= 1'b1;
            tr_a     <= {dut.P_A, 1'b0};
            tr_fc    <= dut.P_FC;
            tr_rw    <= dut.P_RW_n;
            tr_uds   <= ~dut.P_UDS_n;
            tr_lds   <= ~dut.P_LDS_n;
            tr_d0    <= dut.P_RW_n ? dut.P_DOUT : dut.P_DIN;
            tr_dtack <= ~dut.P_DTACK_n;
            tr_berr  <= ~dut.P_BERR_n;
            tr_vpa   <= ~dut.P_VPA_n;
         end
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
      if (n_xread > 0) $display("%0d CPU reads returned X", n_xread);
      console_mon.report();
      ram.report();
      iack_report();
`ifdef SUN2_FB
      fb_report();
      fb_dump(FBIMAGE);
`endif
      $finish;
   endtask

   initial begin
      $timeformat(-9, 0, " ns", 12);

      void'($value$plusargs("timeout_ms=%f", timeout_ms));
      void'($value$plusargs("clk4m_bit=%d", clk4m_bit));
      void'($value$plusargs("trace_bus_from=%f", trace_bus_from));

      $display("=== Sun-2 simulation ===");
      $display("cpu_clk %0.4f MHz, clk40 %0.4f MHz, SCC/timer clock %0.4f MHz (clk40 / %0d)",
               500.0 / CPUCLK_HALF, 500.0 / CLK40_HALF,
               (500.0 / CLK40_HALF) / real'(clk4m_bit < 0 ? 1 : 2 << clk4m_bit),
               clk4m_bit < 0 ? 1 : 2 << clk4m_bit);
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
