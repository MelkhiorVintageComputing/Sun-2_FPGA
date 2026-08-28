//
// deca_uart_rx / deca_uart_tx: the two halves of the DECA's console bridge.
//
// The console is the *instrument* on this board -- with no serial port on the
// DECA and no display yet, a garbled console is indistinguishable from a dead
// machine.  So the bridge is tested on its own, before it is trusted to report
// anything else.
//
// What is actually being checked is a timing claim.  On clk_serial a bit is
// exactly CLKS_PER_BIT clocks, and the SCC on the far end derives its own
// timing from the same clock -- so the two agree by construction rather than by
// arithmetic.  The tests therefore drive the receiver at the nominal rate and
// at deliberate offsets, because the interesting failure is not "does 0x55
// survive" but "how far apart can the two ends drift before it stops working".
//
`timescale 1ns / 1ps

module tb_deca_uart;

   localparam int CPB      = 512;          // clocks per bit
   localparam real CLK_NS  = 101.72470;    // 4.915254 MHz, the real one

   reg clk = 1'b0;
   always #(CLK_NS / 2.0) clk = ~clk;

   reg rst = 1'b1;

   int pass = 0, fail = 0;
   task check(input string what, input logic cond);
      if (cond) begin pass++; $display("  ok:   %s", what); end
      else      begin fail++; $display("  FAIL: %s", what); end
   endtask

   // ------------------------------------------------------------ receiver
   reg        line = 1'b1;      // what the "machine" transmits
   wire [7:0] rx_data;
   wire       rx_valid, rx_frame_err;

   deca_uart_rx #(.CLKS_PER_BIT(CPB)) dut_rx (
       .clk (clk), .rst (rst), .rx (line),
       .data (rx_data), .valid (rx_valid), .frame_err (rx_frame_err)
   );

   // Send one byte at `bit_clocks' clocks per bit -- the parameter is the whole
   // point: a receiver that only works when both ends agree exactly is not a
   // receiver, it is a coincidence.
   task send_byte(input [7:0] b, input int bit_clocks, input logic stop_ok);
      integer i;
      begin
         line = 1'b0;                                   // start
         repeat (bit_clocks) @(posedge clk);
         for (i = 0; i < 8; i++) begin
            line = b[i];                                // LSB first
            repeat (bit_clocks) @(posedge clk);
         end
         line = stop_ok ? 1'b1 : 1'b0;                  // stop
         repeat (bit_clocks) @(posedge clk);
         line = 1'b1;
         repeat (bit_clocks) @(posedge clk);
      end
   endtask

   // ------------------------------------------------------------ transmitter
   reg  [7:0] tx_byte;
   reg        tx_start = 1'b0;
   wire       tx_line, tx_busy;

   deca_uart_tx #(.CLKS_PER_BIT(CPB)) dut_tx (
       .clk (clk), .rst (rst), .data (tx_byte), .start (tx_start),
       .tx (tx_line), .busy (tx_busy)
   );

   // Decode what the transmitter emits, independently of the receiver above --
   // two implementations of the same protocol, so a shared misunderstanding
   // cannot pass.  Samples mid-bit by counting, not by using the DUT's states.
   task recv_byte(output [7:0] b, output logic framing_ok);
      integer i;
      begin
         @(negedge tx_line);                            // start bit
         repeat (CPB + CPB/2) @(posedge clk);           // to the middle of D0
         for (i = 0; i < 8; i++) begin
            b[i] = tx_line;
            repeat (CPB) @(posedge clk);
         end
         framing_ok = tx_line;                          // should be the stop bit
      end
   endtask

   // ------------------------------------------------------------------ run
   integer     n, errs;
   reg [7:0]   got;
   logic       fok;
   int         drift;

   initial begin
      $display("=== deca_uart: %0d clocks per bit, %.5f ns clock ===", CPB, CLK_NS);
      repeat (10) @(posedge clk);
      rst = 1'b0;
      repeat (10) @(posedge clk);

      // 1. Every byte value, at the nominal rate.
      errs = 0;
      for (n = 0; n < 256; n++) begin
         fork
            send_byte(n[7:0], CPB, 1'b1);
            begin
               @(posedge rx_valid);
               if (rx_data !== n[7:0]) errs++;
            end
         join
      end
      check("receiver: all 256 byte values round-trip", errs == 0);

      // 2. Framing error is reported, and the byte still arrives.  A console
      //    that drops a byte because its stop bit was marginal tells you less
      //    than one that hands it over and raises a flag.
      fork
         send_byte(8'h5A, CPB, 1'b0);
         begin
            @(posedge rx_valid);
            check("receiver: bad stop bit sets frame_err", rx_frame_err === 1'b1);
            check("receiver: ... and the byte still arrives", rx_data === 8'h5A);
         end
      join

      // 3. Tolerance.  The SCC and this receiver share a clock, so in the real
      //    machine the rate error is zero -- but a receiver with no margin at
      //    all would be a latent fault the moment anything about the clocking
      //    changed.  +/-2% is roughly what 8N1 can stand.
      for (drift = -2; drift <= 2; drift++) begin
         errs = 0;
         for (n = 0; n < 16; n++) begin
            fork
               send_byte(8'hA5 ^ n[7:0], CPB + (CPB * drift) / 100, 1'b1);
               begin
                  @(posedge rx_valid);
                  if (rx_data !== (8'hA5 ^ n[7:0])) errs++;
               end
            join
         end
         check($sformatf("receiver: tolerates %0d%% rate error", drift), errs == 0);
      end

      // 4. The transmitter, decoded by an independent counter.
      //
      // The decoder is armed *before* start is asserted.  The DUT drops tx on
      // the same edge that samples start, so calling recv_byte afterwards waits
      // for a falling edge that has already gone by -- which hangs, and looks
      // exactly like a transmitter that never transmits.  Cost an incorrect
      // "FAIL: timeout" once.
      errs = 0;
      for (n = 0; n < 256; n++) begin
         fork
            recv_byte(got, fok);
            begin
               tx_byte  = n[7:0];
               tx_start = 1'b1;
               @(posedge clk);
               tx_start = 1'b0;
            end
         join
         if (got !== n[7:0] || !fok) errs++;
         while (tx_busy) @(posedge clk);
      end
      check("transmitter: all 256 byte values, independently decoded", errs == 0);

      // 5. busy is honest: start is ignored while a byte is going out, so the
      //    console FSM can use it as flow control.
      tx_byte  = 8'hFF;
      tx_start = 1'b1;
      @(posedge clk);
      tx_start = 1'b0;
      @(posedge clk);
      check("transmitter: busy asserts", tx_busy === 1'b1);
      while (tx_busy) @(posedge clk);
      check("transmitter: busy clears", tx_busy === 1'b0);

      $display("=== deca_uart: %0d checks, %0d passed, %0d failed ===",
               pass + fail, pass, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   // A byte is ten bit times: 10 * 512 * 101.72 ns = 521 us.  256 of them is
   // 133 ms, and the run does that twice plus the tolerance sweep -- so the
   // guard has to be north of 400 ms of *simulated* time.  The first version
   // of this file used 50 ms and reported "FAIL: timeout", which is exactly
   // what a broken receiver would have looked like.
   initial begin
      #2_000_000_000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
