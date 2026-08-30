`timescale 1ns / 1ps

//
// deca_adv7513_init against an independent I2C target.
//
// The failure this test exists to prevent is the quiet one.  A transmitter that
// is missing one of the eight registers the programming guide calls mandatory
// does not complain, does not half-work and does not tell anybody: it simply
// emits nothing, and on a bench that looks exactly like a dead pixel clock, a
// wrong pin assignment or a monitor that does not like the mode.  Two of those
// eight -- 0xE0 and 0xF9 -- are absent from the register table in BrianHG's
// DECA project, which is otherwise the closest working reference there is, so
// this is a mistake that is genuinely easy to inherit.
//
// The expected table below is written out independently of the RTL's, in the
// order the part should see it, so a reordering or a dropped entry fails here.
//
module tb_adv7513_init;

   localparam int CLK_HZ = 50_000_000;
   localparam int SCL_HZ =  2_000_000;   // fast, so the test is short
   localparam logic [7:0] SLAVE = 8'h72;

   logic clk = 1'b0, rst = 1'b1;
   always #10 clk = ~clk;                // 50 MHz

   // Open-drain bus with the board's pull-ups.
   wire m_scl_oe, m_sda_oe, s_sda_oe;
   wire scl = m_scl_oe ? 1'b0 : 1'b1;
   wire sda = (m_sda_oe || s_sda_oe) ? 1'b0 : 1'b1;

   logic int_n = 1'b1;
   wire  cfg_done, cfg_nak;
   wire [7:0] cfg_passes;

   deca_adv7513_init #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ),
                       .STARTUP_CLKS(64), .SLAVE_ADDR(SLAVE)) dut (
       .clk(clk), .rst(rst),
       .scl_oe(m_scl_oe), .sda_oe(m_sda_oe), .sda_i(sda),
       .int_n(int_n), .cfg_done(cfg_done), .cfg_nak(cfg_nak),
       .cfg_passes(cfg_passes));

   i2c_slave_model #(.SLAVE_ADDR(SLAVE)) target (
       .scl(scl), .sda(sda), .sda_oe(s_sda_oe));

   int fail = 0, checks = 0;
   task automatic want(input bit cond, input string what);
      checks++;
      if (!cond) begin $display("FAIL: %s", what); fail++; end
   endtask

   // The table the part should receive, transcribed from Terasic's
   // I2C_HDMI_Config.v with the audio entries removed -- independently of the
   // function inside the DUT.
   localparam int N = 27;
   logic [15:0] expect_q [0:N-1];
   initial begin
      expect_q[0]  = 16'h9803; expect_q[1]  = 16'h1520; expect_q[2]  = 16'h1630;
      expect_q[3]  = 16'h1846; expect_q[4]  = 16'h4080; expect_q[5]  = 16'h4110;
      expect_q[6]  = 16'h49A8; expect_q[7]  = 16'h5510; expect_q[8]  = 16'h5608;
      expect_q[9]  = 16'h96F6; expect_q[10] = 16'h9803; expect_q[11] = 16'h9902;
      expect_q[12] = 16'h9AE0; expect_q[13] = 16'h9C30; expect_q[14] = 16'h9D61;
      expect_q[15] = 16'hA2A4; expect_q[16] = 16'hA3A4; expect_q[17] = 16'hA504;
      expect_q[18] = 16'hAB40; expect_q[19] = 16'hAF14; expect_q[20] = 16'hBA60;
      expect_q[21] = 16'hD1FF; expect_q[22] = 16'hDE10; expect_q[23] = 16'hE460;
      expect_q[24] = 16'hFA7C; expect_q[25] = 16'hE0D0; expect_q[26] = 16'hF900;
   end

   // The eight the programming guide calls mandatory (section 3).
   localparam int N_FIXED = 8;
   logic [7:0] fixed_q [0:N_FIXED-1];
   initial begin
      fixed_q[0] = 8'h98; fixed_q[1] = 8'h9A; fixed_q[2] = 8'h9C; fixed_q[3] = 8'h9D;
      fixed_q[4] = 8'hA2; fixed_q[5] = 8'hA3; fixed_q[6] = 8'hE0; fixed_q[7] = 8'hF9;
   end

   initial begin
      $display("=== tb_adv7513_init: the ADV7513 configuration sequence ===");
      repeat (5) @(posedge clk);
      @(negedge clk); rst = 1'b0;

      fork
         begin : timeout
            #4_000_000;
            $display("FAIL: the sequence did not finish");
            fail++;
         end
         wait (cfg_done);
      join_any
      disable timeout;
      repeat (20) @(posedge clk);

      // ---- 1. It finished, and sent exactly the table ----
      want(cfg_done, "the sequencer reports done");
      want(cfg_passes == 8'd1, $sformatf("one pass (got %0d)", cfg_passes));
      want(target.n_writes == N,
           $sformatf("%0d register writes reached the part (got %0d)",
                     N, target.n_writes));
      want(target.bad_addr == 0,
           $sformatf("every transfer addressed 0x72 (got %0d that did not)",
                     target.bad_addr));
      want(!cfg_nak, "every byte was acknowledged, so cfg_nak stays clear");
      want(target.n_starts == N && target.n_stops == N,
           $sformatf("one START and one STOP per register (got %0d / %0d)",
                     target.n_starts, target.n_stops));

      begin
         bit ok = 1;
         for (int i = 0; i < N && i < target.n_writes; i++)
           if (target.log_q[i] !== expect_q[i]) begin
              if (ok) $display("       first mismatch at entry %0d: sent %04x, expected %04x",
                               i, target.log_q[i], expect_q[i]);
              ok = 0;
           end
         want(ok, "the table arrives byte for byte, in order");
      end

      // ---- 2. The eight mandatory registers ----
      begin
         bit ok = 1;
         for (int i = 0; i < N_FIXED; i++)
           if (!target.seen[fixed_q[i]]) begin
              $display("       ADI fixed register 0x%02x was never written", fixed_q[i]);
              ok = 0;
           end
         want(ok, "all eight ADI mandatory registers are present");
      end

      // ---- 3. The values that decide whether anything appears ----
      want(target.regs[8'h41][6] == 1'b0, "0x41 bit 6 clear: the part is powered up");
      want(target.regs[8'h15][3:0] == 4'h0, "0x15: input ID 0, 24-bit RGB with separate syncs");
      want(target.regs[8'h16][5:4] == 2'b11, "0x16: 8-bit colour depth");
      want(target.regs[8'h16][7] == 1'b0, "0x16: 4:4:4 output");
      want(target.regs[8'h18][7] == 1'b0, "0x18: colour-space converter disabled");
      want(target.regs[8'hAF][1] == 1'b0, "0xAF bit 1 clear: DVI mode, as the Wukong also drives");
      want(target.regs[8'h9A][7:5] == 3'b111, "0x9A[7:5] = 0b111, as the guide requires");
      want(target.regs[8'h9D][1:0] == 2'b01, "0x9D[1:0] = 0b01, clock not divided");

      // ---- 4. Hot plug replays the whole table ----
      // HPD is not routed to the FPGA on this board, so a falling INT is the
      // only notice we get that the cable moved -- and the part has powered
      // itself down and forgotten most of its registers by then.
      begin
         int n_before = target.n_writes;
         @(negedge clk); int_n = 1'b0;
         repeat (10) @(posedge clk);
         @(negedge clk); int_n = 1'b1;

         fork
            begin : t2
               #4_000_000;
               $display("FAIL: the replay did not finish");
               fail++;
            end
            // Wait on the counter, not on an edge of cfg_done.  The
            // sequencer leaves S_DONE two or three clocks after int_n falls,
            // which is inside the pulse above -- so an @(negedge cfg_done) set
            // up afterwards waits for an edge that has already gone by.
            wait (cfg_passes == 8'd2);
         join_any
         disable t2;
         repeat (20) @(posedge clk);

         want(cfg_passes == 8'd2, $sformatf("a second pass was counted (got %0d)", cfg_passes));
         want(target.n_writes == n_before + N,
              $sformatf("the whole table was sent again (got %0d more)",
                        target.n_writes - n_before));
         want(target.log_q[n_before] == expect_q[0],
              "the replay starts from the first entry, not where it left off");
      end

      $display("=== tb_adv7513_init: %0d checks, %0d failed ===", checks, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

endmodule
