//
// deca_jtag_console against a model of the Avalon slave it talks to.
//
// Written after the board said something the source reading had not predicted:
// the standalone console test produced doubled and skipped characters, and
// three readings of deca_jtag_console failed to explain it.  This is the
// instrument that stops that being a guessing game.
//
// It drives the console exactly as the board does -- a serial byte stream in on
// sun_tx, a modelled JTAG UART on the Avalon side -- and asserts the one thing
// that matters: **what the host receives is what the machine sent, once each,
// in order**.
//
`timescale 1ns / 1ps

module tb_deca_console;

   localparam int  CPB    = 512;
   localparam real CLK_NS = 101.72470;

   reg clk = 1'b0;
   always #(CLK_NS / 2.0) clk = ~clk;
   reg rst = 1'b1;

   int pass = 0, fail = 0;
   task check(input string what, input logic cond);
      if (cond) begin pass++; $display("  ok:   %s", what); end
      else      begin fail++; $display("  FAIL: %s", what); end
   endtask

   // ------------------------------------------------ the machine's serial out
   //
   // `loopback' ties the console's own serialiser output back into its own
   // receiver, which is what the board's loopback bitstream does.  It is a
   // separate mode because the two directions running at once is a different
   // design than either alone -- and the first version of this testbench only
   // ever drove one direction, which is why it passed while the board doubled.
   wire mach_rx;                 // declared here: xvlog rejects use-before-
                                 // declaration where Vivado invents an implicit
                                 // net, and the harness ran a stale snapshot
                                 // rather than reporting the error.
   reg  mach_tx_drv = 1'b1;
   reg  loopback    = 1'b0;
   wire mach_tx = loopback ? mach_rx : mach_tx_drv;

   task send_byte(input [7:0] b);
      integer i;
      begin
         mach_tx_drv = 1'b0;
         repeat (CPB) @(posedge clk);
         for (i = 0; i < 8; i++) begin
            mach_tx_drv = b[i];
            repeat (CPB) @(posedge clk);
         end
         mach_tx_drv = 1'b1;
         repeat (CPB) @(posedge clk);
      end
   endtask

   // ------------------------------------------------------------ the console
   wire con_dropped, con_frame_err;
   wire        av_address, av_chipselect, av_read_n, av_write_n;
   wire [31:0] av_writedata;
   wire [31:0] av_readdata;
   wire        av_waitrequest;

   // An 8-byte queue, not the 2048 the board gets.  The drop path is a
   // mechanism and the depth is a parameter precisely so this test can reach
   // the full case in eighty bytes instead of simulating two seconds of
   // serial line to push two thousand.
   deca_jtag_console #(.CLKS_PER_BIT(CPB), .FIFO_LOG2(3)) dut (
       .clk (clk), .rst (rst),
       .sun_tx (mach_tx), .sun_rx (mach_rx),
       .dropped (con_dropped), .frame_err (con_frame_err),
       .av_address_o     (av_address),
       .av_chipselect_o  (av_chipselect),
       .av_read_n_o      (av_read_n),
       .av_write_n_o     (av_write_n),
       .av_writedata_o   (av_writedata),
       .av_readdata_i    (av_readdata),
       .av_waitrequest_i (av_waitrequest)
   );

   // The console instantiates its own JTAG UART under `ifndef SUN2_SIM.  Here
   // SUN2_SIM is defined, so those ports are exposed for the model instead --
   // see deca_jtag_console.sv's simulation arm.
   wire [7:0] host_rx_data;
   wire       host_rx_valid;
   reg  [7:0] host_tx_data;
   reg        host_tx_push = 1'b0;
   wire       host_tx_full;
   reg        drain = 1'b1;

   jtag_uart_model uart (
       .clk (clk), .rst_n (~rst),
       .av_address     (av_address),
       .av_chipselect  (av_chipselect),
       .av_read_n      (av_read_n),
       .av_write_n     (av_write_n),
       .av_writedata   (av_writedata),
       .av_readdata    (av_readdata),
       .av_waitrequest (av_waitrequest),
       .host_rx_data   (host_rx_data),
       .host_rx_valid  (host_rx_valid),
       .host_tx_data   (host_tx_data),
       .host_tx_push   (host_tx_push),
       .host_tx_full   (host_tx_full),
       .drain          (drain)
   );

   // What the host actually received, in order.
   byte unsigned got[$];
   always @(posedge clk) if (host_rx_valid) got.push_back(host_rx_data);

   // ------------------------------------------------------------------- run
   integer n;
   byte unsigned expect_q[$];

   initial begin
      $display("=== deca_console: the bridge against a modelled JTAG UART ===");
      repeat (20) @(posedge clk);
      rst = 1'b0;
      repeat (20) @(posedge clk);

      // 1. The exact failure the board showed: a run of consecutive bytes.
      //    Doubling or skipping shows here and nowhere else.
      got.delete(); expect_q.delete();
      for (n = 0; n < 24; n++) begin
         send_byte(8'h21 + n[7:0]);
         expect_q.push_back(8'h21 + n[7:0]);
      end
      repeat (CPB * 20) @(posedge clk);      // let the FSM drain

      check($sformatf("host got %0d bytes for 24 sent", got.size()),
            got.size() == 24);
      begin
         int bad = 0;
         for (n = 0; n < got.size() && n < expect_q.size(); n++)
           if (got[n] !== expect_q[n]) bad++;
         check("... and every one is the byte that was sent, in order", bad == 0);
         if (got.size() != 24 || bad != 0) begin
            $write("      sent:");
            for (n = 0; n < expect_q.size(); n++) $write(" %02x", expect_q[n]);
            $write("\n      got: ");
            for (n = 0; n < got.size(); n++) $write(" %02x", got[n]);
            $write("\n");
         end
      end
      check("no byte was dropped", con_dropped === 1'b0);
      check("no framing error", con_frame_err === 1'b0);

      // 2. Nobody listening: the write FIFO fills and the console must drop
      //    rather than wedge.  Then draining resumes, and it must recover.
      drain = 1'b0;
      got.delete();
      for (n = 0; n < 80; n++) send_byte(8'h41);
      repeat (CPB * 4) @(posedge clk);
      check("a queue that fills sets `dropped'", con_dropped === 1'b1);

      drain = 1'b1;
      repeat (CPB * 8) @(posedge clk);
      got.delete();
      send_byte(8'h5A);
      repeat (CPB * 8) @(posedge clk);
      check("... and the bridge recovers once someone listens",
            got.size() == 1 && got[0] === 8'h5A);

      // 3. LOOPBACK -- the configuration the board actually ran, and the one
      //    this testbench did not cover.  Both directions are live at once:
      //    the FSM reads a byte from the host, serialises it, its own receiver
      //    decodes it, and it writes it back.  A byte typed once must come back
      //    exactly once.
      loopback = 1'b1;
      repeat (CPB * 4) @(posedge clk);
      got.delete();
      for (n = 0; n < 8; n++) begin
         host_tx_data = 8'h41 + n[7:0];      // 'A'..'H'
         host_tx_push = 1'b1;
         @(posedge clk);
         host_tx_push = 1'b0;
         @(posedge clk);
      end
      repeat (CPB * 140) @(posedge clk);     // 8 bytes, both ways

      check($sformatf("loopback: 8 typed, %0d came back", got.size()),
            got.size() == 8);
      begin
         int bad = 0;
         for (n = 0; n < got.size(); n++)
           if (n < 8 && got[n] !== (8'h41 + n[7:0])) bad++;
         check("loopback: ... each exactly once, in order", bad == 0 && got.size() == 8);
         if (got.size() != 8 || bad != 0) begin
            $write("      got: ");
            for (n = 0; n < got.size(); n++) $write(" %02x", got[n]);
            $write("\n");
         end
      end
      loopback = 1'b0;

      // 4. The other direction: a byte from the host reaches the machine's rx.
      got.delete();
      host_tx_data = 8'h37;
      host_tx_push = 1'b1;
      @(posedge clk);
      host_tx_push = 1'b0;
      fork
         begin : decode
            integer i;
            reg [7:0] b;
            @(negedge mach_rx);
            repeat (CPB + CPB/2) @(posedge clk);
            for (i = 0; i < 8; i++) begin
               b[i] = mach_rx;
               repeat (CPB) @(posedge clk);
            end
            check("host -> machine: the byte arrives on rx", b === 8'h37);
         end
         begin
            repeat (CPB * 30) @(posedge clk);
            check("host -> machine: the byte arrives on rx", 1'b0);
         end
      join_any
      // NOTE: `disable fork' here terminates this initial block under xsim, so
      // nothing after it runs -- which is why the loopback test above is
      // *above* it and not below.  A check that silently does not execute is
      // worse than one that fails: the summary said "7 checks, 7 passed" while
      // the case that mattered had never run.
      disable fork;

      $display("=== deca_console: %0d checks, %0d passed, %0d failed ===",
               pass + fail, pass, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      // 500 ms.  NOT 4_000_000_000 -- an unsized literal above 2^31-1 wraps,
      // and the guard then fires at time zero, which reads as a design that
      // never starts.  Cost one confusing run.
      #500_000_000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
