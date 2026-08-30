`timescale 1ns / 1ps

//
// sun2_bus_arb: two masters, one BR/BG handshake.
//
// The property that matters is not "the right master wins" but "only one
// master ever wins".  Two masters driving the 68010's address bus at once does
// not show up as a wrong number in a log; it shows up as a machine that has
// stopped, days into a boot, with nothing to read.  So the mutual exclusion is
// checked on every clock edge of every case below rather than sampled at the
// points the cases happen to look at.
//
module tb_bus_arb;

   logic clk = 1'b0, rst = 1'b1;
   always #5 clk = ~clk;

   logic a_br_n = 1'b1, b_br_n = 1'b1, P_BG_n = 1'b1;
   wire  a_bg_n, b_bg_n, P_BR_n;

   sun2_bus_arb dut (.CLK(clk), .RESET(rst),
                     .a_br_n(a_br_n), .a_bg_n(a_bg_n),
                     .b_br_n(b_br_n), .b_bg_n(b_bg_n),
                     .P_BR_n(P_BR_n), .P_BG_n(P_BG_n));

   int fail = 0, checks = 0;
   task automatic want(input bit cond, input string what);
      checks++;
      if (!cond) begin $display("FAIL: %s", what); fail++; end
   endtask

   // The invariant, checked continuously rather than at chosen moments.
   int both = 0;
   always @(posedge clk)
     if (!rst && !a_bg_n && !b_bg_n) both++;

   // The CPU grants whenever asked, which is what a 68010 does.
   always @(posedge clk) P_BG_n <= P_BR_n;

   task automatic settle(input int n); repeat (n) @(posedge clk); endtask

   initial begin
      $display("=== tb_bus_arb: two masters, one bus ===");
      settle(4); @(negedge clk); rst = 1'b0; settle(2);

      want(P_BR_n, "idle: nobody asks the CPU for the bus");
      want(a_bg_n && b_bg_n, "idle: nobody is granted");

      // ---- 1. A alone ----
      @(negedge clk); a_br_n = 1'b0; settle(4);
      want(!P_BR_n, "A alone: the CPU is asked");
      want(!a_bg_n && b_bg_n, "A alone: A is granted and B is not");
      @(negedge clk); a_br_n = 1'b1; settle(3);
      want(a_bg_n && b_bg_n, "A alone: the grant is released");

      // ---- 2. B alone ----
      @(negedge clk); b_br_n = 1'b0; settle(4);
      want(!P_BR_n, "B alone: the CPU is asked");
      want(!b_bg_n && a_bg_n, "B alone: B is granted and A is not");
      @(negedge clk); b_br_n = 1'b1; settle(3);

      // ---- 3. Both at once: the 82586 wins ----
      @(negedge clk); a_br_n = 1'b0; b_br_n = 1'b0; settle(4);
      want(!a_bg_n && b_bg_n, "contention: A wins, because a frame cannot wait");
      @(negedge clk); a_br_n = 1'b1; settle(4);
      want(!b_bg_n && a_bg_n, "contention: B gets it once A is done");
      @(negedge clk); b_br_n = 1'b1; settle(3);

      // ---- 4. A must not take the bus from B mid-transfer ----
      // This is the case the lock exists for, and the one a priority-only
      // arbiter gets wrong.
      @(negedge clk); b_br_n = 1'b0; settle(4);
      want(!b_bg_n, "hold: B has the bus");
      @(negedge clk); a_br_n = 1'b0; settle(6);
      want(!b_bg_n && a_bg_n,
           "hold: A asking does not move the grant out from under B");
      want(!P_BR_n, "hold: the CPU is still asked, with both wanting it");
      @(negedge clk); b_br_n = 1'b1; settle(4);
      want(!a_bg_n && b_bg_n, "hold: A gets it the moment B lets go");
      @(negedge clk); a_br_n = 1'b1; settle(3);

      // ---- 5. No grant without the CPU's ----
      @(negedge clk); a_br_n = 1'b0; settle(4);
      want(!a_bg_n, "grant: A holds it");
      @(negedge clk); force P_BG_n = 1'b1; settle(2);
      want(a_bg_n && b_bg_n,
           "grant: with the CPU's grant withdrawn neither master has the bus");
      release P_BG_n;
      @(negedge clk); a_br_n = 1'b1; settle(3);

      want(both == 0,
           $sformatf("both masters were never granted at once (%0d clocks)", both));

      $display("=== tb_bus_arb: %0d checks, %0d failed ===", checks, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      #100_000;
      $display("FAIL: tb_bus_arb timed out");
      $finish;
   end

endmodule
