`timescale 1ns / 1ps

//
// sun2_vme_scsi driven the way the boot PROM and the kernel drive it.
//
// Stage 1 covers the register file, the byte lanes, the aliasing and the RTC
// half.  The SCSI engine and the DMA master follow; their tests will replay
// scdoit()'s full select/CDB/DMA/status/message cycle.
//
// The register file matters more than it looks, because the *entire* existence
// test both drivers perform is to write 0x6789 to dma_count and read it back --
// the PROM as a 16-bit word through peek() (rsun/sys/sunstand/sd.c:63-67), the
// kernel as a byte through peekc() first and then a word (sundev/sc.c:80-86).
// Get the byte lanes or the acknowledge wrong and the machine reports no
// controller, with no other symptom.
//
module tb_vme_scsi;

   localparam logic [23:0] BASE = 24'h200000;
   localparam int CLK_HALF = 30;                  // 16.667 MHz

   logic clk = 1'b0, rst = 1'b1, por = 1'b1;
   always #(CLK_HALF) clk = ~clk;

   // The RTC's 4.9152 MHz oscillator, in its own domain as on the board.
   logic x2 = 1'b0;
   always #101.725 x2 = ~x2;

   logic        mb_sel = 1'b0, mb_we = 1'b0;
   logic        mb_uds_n = 1'b1, mb_lds_n = 1'b1;
   logic [22:0] mb_addr = '0;
   logic [15:0] mb_din  = '0;
   wire  [15:0] mb_dout;
   wire         mb_hit, mb_ack, int_o;

   sun2_vme_scsi #(.SCSI_BASE(BASE)) dut (
       .CLK(clk), .RESET(rst), .por_reset(por), .clk4m9152(x2),
       .mb_sel(mb_sel), .mb_addr(mb_addr), .mb_we(mb_we),
       .mb_uds_n(mb_uds_n), .mb_lds_n(mb_lds_n),
       .mb_din(mb_din), .mb_dout(mb_dout),
       .mb_hit(mb_hit), .mb_ack(mb_ack), .int_o(int_o));

   int fail = 0, checks = 0;
   task automatic want(input bit cond, input string what);
      checks++;
      if (!cond) begin $display("FAIL: %s", what); fail++; end
   endtask

   // A VME cycle as sun2_fpga presents one.  Returns ok = 0 for a timeout,
   // which is what the machine turns into the bus error peek() catches.
   localparam int ACK_LIMIT = 24;      // the RTC needs sixteen clocks
   int last_latency;
   task automatic cycle(input logic [22:0] a, input bit we,
                        input bit uds, input bit lds, input logic [15:0] d,
                        output logic [15:0] q, output bit ok);
      int guard;
      begin
         @(posedge clk);
         mb_addr <= a; mb_we <= we; mb_uds_n <= ~uds; mb_lds_n <= ~lds;
         mb_din <= d; mb_sel <= 1'b1;
         ok = 1'b0; q = 16'hXXXX;
         for (guard = 0; guard < ACK_LIMIT; guard++) begin
            @(posedge clk);
            if (mb_hit && mb_ack) begin
               q = mb_dout; ok = 1'b1; last_latency = guard + 1; break;
            end
         end
         @(negedge clk);
         mb_sel <= 1'b0; mb_we <= 1'b0; mb_uds_n <= 1'b1; mb_lds_n <= 1'b1;
         @(posedge clk);
      end
   endtask

   logic [15:0] q; bit ok;
   task automatic wr16(input logic [22:0] a, input logic [15:0] d);
      bit o; logic [15:0] junk;
      cycle(a, 1'b1, 1'b1, 1'b1, d, junk, o);
      if (!o) begin $display("FAIL: write to +0x%03x not acknowledged", a - BASE); fail++; end
   endtask
   task automatic rd16(input logic [22:0] a);
      cycle(a, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      if (!ok) begin $display("FAIL: read of +0x%03x not acknowledged", a - BASE); fail++; end
   endtask

   initial begin
      $display("=== tb_vme_scsi: the Sun VME SCSI/RTC board ===");
      repeat (4) @(posedge clk);
      @(negedge clk); rst = 1'b0; por = 1'b0;
      repeat (4) @(posedge clk);

      // ---- 1. The probe, exactly as both drivers do it ----------------
      // sdprobe(): peek() a word at +0x0C, write 0x6789, read it back.
      cycle(BASE + 23'h00C, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(ok, "probe: a word read of dma_count is acknowledged");
      wr16(BASE + 23'h00C, 16'h6789);
      rd16(BASE + 23'h00C);
      want(q == 16'h6789, $sformatf("probe: dma_count reads back 0x6789 (got %04x)", q));

      // scprobe() reads it as a *byte* first -- peekc() on the even byte.
      cycle(BASE + 23'h00C, 1'b0, 1'b1, 1'b0, 16'h0, q, ok);
      want(ok, "probe: a byte read of dma_count is acknowledged too");

      // An address the card does not own must not answer, or the PROM finds a
      // controller that is not there -- the failure this tree already met once
      // with a 3Com at 0xE0000.
      cycle(23'h300000 + 23'h00C, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(!ok && !mb_hit, "probe: an address outside the 4 KiB window does not answer");

      // ---- 2. Aliasing -------------------------------------------------
      // The board decodes only A01..A03, so the eight registers repeat every
      // sixteen bytes across the 2 KiB page.  In neither manual; schematic only.
      rd16(BASE + 23'h01C);
      want(q == 16'h6789, "alias: dma_count answers at +0x01C as well");
      rd16(BASE + 23'h7FC);
      want(q == 16'h6789, "alias: ...and at the top of the 2 KiB page");

      // ---- 3. Byte lanes -----------------------------------------------
      // dma_addr is written as a 68000 longword: high word at +0x08 (only its
      // low byte, at 0x09, is significant), low word at +0x0A.
      wr16(BASE + 23'h008, 16'h0012);
      wr16(BASE + 23'h00A, 16'h3456);
      rd16(BASE + 23'h008);
      want(q == 16'h0012, $sformatf("dma_addr: high byte at 0x09 (got %04x)", q));
      rd16(BASE + 23'h00A);
      want(q == 16'h3456, $sformatf("dma_addr: low word at 0x0A (got %04x)", q));
      want(dut.dma_addr == 24'h123456, "dma_addr: the three bytes assemble in order");

      // intvec is at an ODD address, so it is the low byte, D7:0.
      wr16(BASE + 23'h00E, 16'h0040);
      rd16(BASE + 23'h00E);
      want(q == 16'h0040, $sformatf("intvec: odd byte, D7:0 (got %04x)", q));
      want(dut.intvec == 8'h40, "intvec: scattach's 0x40 lands in the latch");

      // ---- 4. The ICR --------------------------------------------------
      // Every writable bit is in the low byte, and every one reads back, so
      // 68000 BSET/BCHG/BCLR work on it.
      wr16(BASE + 23'h004, 16'h0007);          // IntEn | DMAEn | WordMode
      rd16(BASE + 23'h004);
      want(q[5:0] == 6'h07, $sformatf("icr: the six control bits read back (got %04x)", q));

      // Bit 4 is RST, and it is the only thing that clears a latched Bus Error.
      force dut.st_buserr = 1'b1;
      #1 release dut.st_buserr;
      rd16(BASE + 23'h004);
      want(q[14] == 1'b1, "icr: a latched bus error is visible");
      wr16(BASE + 23'h004, 16'h0010);          // RST
      rd16(BASE + 23'h004);
      want(q[14] == 1'b0, "icr: writing RST clears the bus error latch");

      // ---- 5. The clock, on the other 2 KiB page -----------------------
      // Register n at offset 2n, upper byte lane -- the same wiring the 2/120
      // uses, which is why mm58167.v is reused unchanged.
      cycle(BASE + 23'h800, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(ok, "rtc: the second 2 KiB page answers");
      want(q[3:0] == 4'h0, "rtc: counter 0's low nibble reads zero, as todprobe() requires");

      // The board stretches the RTC's DTACK because the chip needs about a
      // microsecond; the SCSI half answers in a couple of clocks.  Both must be
      // inside the machine's twelve-clock timeout at the register end.
      // Measured rather than read out of the DUT: the real board stretches the
      // clock's DTACK with PAL U801 because the chip needs about a microsecond,
      // where a SCSI register answers in under 125 ns.  Both must still be
      // inside the machine's twelve-clock bus timeout.
      begin
         int rtc_lat, scsi_lat;
         cycle(BASE + 23'h800, 1'b0, 1'b1, 1'b1, 16'h0, q, ok); rtc_lat = last_latency;
         cycle(BASE + 23'h00C, 1'b0, 1'b1, 1'b1, 16'h0, q, ok); scsi_lat = last_latency;
         $display("    acknowledge: SCSI %0d clocks, RTC %0d", scsi_lat, rtc_lat);
         want(rtc_lat > scsi_lat, "rtc: its acknowledge is stretched, as the board's PAL does");
      end

      // ---- 6. Interrupts stay quiet ------------------------------------
      // scpoll() claims the interrupt whenever IntReq or BusError is set, so a
      // stuck bit spins the kernel in its handler for ever.
      wr16(BASE + 23'h004, 16'h0000);
      want(!int_o, "int: quiet with nothing pending and nothing enabled");

      $display("=== tb_vme_scsi: %0d checks, %0d failed ===", checks, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      #2_000_000;
      $display("FAIL: tb_vme_scsi timed out");
      $finish;
   end

endmodule
