`timescale 1ns / 1ps

//
// sun2_mb_ether driven the way the boot PROM drives it.
//
// The value of this test is that it replays the actual sequences from
// Inputs/sunos-34-src/sun/prom_monitor/msun/sys/sunstand/if_ie.c rather than a
// paraphrase of them, so a mistake shows up here instead of thirty minutes
// into a simulated boot.  In order of how badly each failure hurts:
//
//   1. The chip must find its SCP and clear the ISCP busy flag.  That single
//      bit is the byte-order test: get mp_swab backwards, or the page map
//      alias at entry 1023 wrong, and the chip reads plausible rubbish and
//      hangs -- which from the console is indistinguishable from a dead card.
//   2. ieprobe() must succeed, and it is picky in a way that is easy to miss:
//      the ID PROM has to *accept* a write, acknowledge it, and then not
//      remember it.
//   3. ieinit()'s very first act is a byte read-modify-write at +0x844, a
//      register this replica does not really have.  It still has to answer.
//   4. mies_mbmhi has to report where the memory window is, because the driver
//      reads it rather than assuming it.
//
module tb_mb_ether;

   localparam logic [19:0] REG_BASE = 20'h88000;
   localparam logic [19:0] MEM_BASE = 20'h40000;
   localparam int          MEM_KIB  = 32;      // enough for the PROM's 8 KiB

   localparam int CLK_HALF = 40;               // 12.5 MHz

   logic clk = 1'b0, rst = 1'b1;
   always #(CLK_HALF) clk = ~clk;

   logic        mb_sel = 1'b0, mb_we = 1'b0;
   logic        mb_uds_n = 1'b1, mb_lds_n = 1'b1;
   logic [19:0] mb_addr = 20'h0;
   logic [15:0] mb_din  = 16'h0;
   wire  [15:0] mb_dout;
   wire         mb_hit, mb_ack, int_o;

   wire       mii_tx_clk, mii_tx_en, mii_tx_er, mii_rx_clk, mii_rx_dv, mii_rx_er;
   wire       mii_crs, mii_col;
   wire [3:0] mii_txd, mii_rxd;

   mii_peer peer(.mii_tx_clk(mii_tx_clk), .mii_txd(mii_txd),
                 .mii_tx_en(mii_tx_en), .mii_tx_er(mii_tx_er),
                 .mii_rx_clk(mii_rx_clk), .mii_rxd(mii_rxd),
                 .mii_rx_dv(mii_rx_dv), .mii_rx_er(mii_rx_er),
                 .mii_crs(mii_crs), .mii_col(mii_col));

   sun2_mb_ether #(.REG_BASE(REG_BASE), .MEM_BASE(MEM_BASE), .MEM_KIB(MEM_KIB)) dut (
       .CLK(clk), .RESET(rst),
       .mb_sel(mb_sel), .mb_addr(mb_addr), .mb_we(mb_we),
       .mb_uds_n(mb_uds_n), .mb_lds_n(mb_lds_n),
       .mb_din(mb_din), .mb_dout(mb_dout), .mb_hit(mb_hit), .mb_ack(mb_ack),
       .int_o(int_o),
       .mii_tx_clk(mii_tx_clk), .mii_txd(mii_txd),
       .mii_tx_en(mii_tx_en), .mii_tx_er(mii_tx_er),
       .mii_rx_clk(mii_rx_clk), .mii_rxd(mii_rxd),
       .mii_rx_dv(mii_rx_dv), .mii_rx_er(mii_rx_er),
       .mii_crs(mii_crs), .mii_col(mii_col)
   );

   int fail = 0, checks = 0;

   task automatic want(input bit cond, input string what);
      checks++;
      if (!cond) begin
         $display("FAIL: %s", what);
         fail++;
      end
   endtask

   // ------------------------------------------------------------------
   // A MultiBus cycle, the way sun2_fpga will present one
   // ------------------------------------------------------------------
   // Returns 0 for a bus timeout, which is what the machine turns into the
   // bus error that peek()/poke() catch.
   localparam int ACK_LIMIT = 12;   // the machine gives up after twelve clocks

   task automatic bus_cycle(input logic [19:0] a, input bit we,
                            input bit uds, input bit lds,
                            input logic [15:0] d,
                            output logic [15:0] q, output bit ok);
      int guard;
      begin
         @(posedge clk);
         mb_addr  <= a;
         mb_we    <= we;
         mb_uds_n <= ~uds;
         mb_lds_n <= ~lds;
         mb_din   <= d;
         mb_sel   <= 1'b1;
         ok = 1'b0;
         q  = 16'hXXXX;
         for (guard = 0; guard < ACK_LIMIT; guard++) begin
            @(posedge clk);
            if (mb_hit && mb_ack) begin
               q  = mb_dout;
               ok = 1'b1;
               break;
            end
         end
         @(negedge clk);
         mb_sel   <= 1'b0;
         mb_we    <= 1'b0;
         mb_uds_n <= 1'b1;
         mb_lds_n <= 1'b1;
         @(posedge clk);
      end
   endtask

   // The monitor's own primitives.  poke() returns 0 on success and -1 on a
   // bus error; peek() returns the zero-extended word, or -1.
   task automatic poke(input logic [19:0] a, input logic [15:0] d, output bit ok);
      logic [15:0] q;
      bus_cycle(a, 1'b1, 1'b1, 1'b1, d, q, ok);
   endtask

   task automatic peek(input logic [19:0] a, output logic [15:0] q, output bit ok);
      bus_cycle(a, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
   endtask

   // A byte read-modify-write on the high byte, which is how the C compiler
   // reaches a bitfield in the first u_char of a 16-bit register.
   task automatic poke_hi(input logic [19:0] a, input logic [7:0] d, output bit ok);
      logic [15:0] q;
      bus_cycle(a, 1'b1, 1'b1, 1'b0, {d, 8'h00}, q, ok);
   endtask

   // ------------------------------------------------------------------
   // The tests
   // ------------------------------------------------------------------
   logic [15:0] q;
   bit          ok;
   int          i, guard;

   initial begin
      $timeformat(-9, 0, " ns", 12);
      $display("=== sun2_mb_ether against the boot PROM's own sequences ===");

      repeat (10) @(posedge clk);
      rst = 1'b0;
      repeat (10) @(posedge clk);

      // ---------------------------------------------------------------
      // Decode: only the two windows, and nothing else
      // ---------------------------------------------------------------
      // ecprobe() is nothing but "did 0xE0000 answer?", so a card that
      // answers outside its own windows invents a 3Com that is not there.
      peek(20'hE0000, q, ok);
      want(!ok, "the card answered at 0xE0000, where the 3Com would be");
      peek(20'h80000, q, ok);
      want(!ok, "the card answered at 0x80000, where the SCSI would be");
      peek(20'h8C000, q, ok);
      want(!ok, "the card answered at 0x8C000, the second controller's base");

      // ---------------------------------------------------------------
      // 2. ieprobe(), exactly as if_ie.c:127-136 issues it
      // ---------------------------------------------------------------
      poke(REG_BASE + 20'h000, 16'h0000, ok);
      want(ok, "ieprobe: the write to page map entry 0 took a bus error");

      poke(REG_BASE + 20'h800, 16'h6789, ok);
      want(ok, "ieprobe: the write to the ID PROM took a bus error");

      peek(REG_BASE + 20'h800, q, ok);
      want(ok, "ieprobe: the ID PROM read took a bus error");
      want(q != 16'h6789,
           $sformatf("ieprobe: the ID PROM stored the write (%04x) -- it looks like RAM", q));

      // ---------------------------------------------------------------
      // 3. The parity register that is not really here
      // ---------------------------------------------------------------
      peek(REG_BASE + 20'h844, q, ok);
      want(ok, "the read of +0x844 took a bus error -- ieinit dies here");
      poke_hi(REG_BASE + 20'h844, 8'h01, ok);
      want(ok, "mie_peack = 1 took a bus error -- ieinit dies here");

      // ---------------------------------------------------------------
      // 4. The status register
      // ---------------------------------------------------------------
      peek(REG_BASE + 20'h840, q, ok);
      want(ok, "the status register did not answer");
      want(q[3:0] == MEM_BASE[19:16],
           $sformatf("mies_mbmhi is %x, expected %x -- the driver would look for the window in the wrong place",
                     q[3:0], MEM_BASE[19:16]));
      want(q[4] == 1'b0, "mies_bigram claims 1 MiB");
      want(q[5] == 1'b0, "mies_p2mem claims a P2 expansion bus");
      want(q[9] == 1'b0, "mies_pe reports a parity error on a card with no parity");

      // Control bits read back.  if_ie.c:196-199 clears noloop, ie and pie.
      poke(REG_BASE + 20'h840, 16'hF800, ok);
      peek(REG_BASE + 20'h840, q, ok);
      want(q[15:11] == 5'b11111, "the control bits did not read back");
      poke(REG_BASE + 20'h840, 16'h0000, ok);
      peek(REG_BASE + 20'h840, q, ok);
      want(q[15:11] == 5'b00000, "the control bits did not clear");

      // ---------------------------------------------------------------
      // The page map as a register file
      // ---------------------------------------------------------------
      for (i = 0; i < 1024; i++) begin
         poke(REG_BASE + 20'(i * 2), 16'h0000, ok);
         if (!ok) begin
            want(1'b0, $sformatf("page map entry %0d did not answer", i));
            break;
         end
      end
      poke(REG_BASE + 20'h00C, 16'h8005, ok);        // entry 6: swab, page 5
      peek(REG_BASE + 20'h00C, q, ok);
      want(q == 16'h8005, $sformatf("page map entry 6 read back %04x, expected 8005", q));
      peek(REG_BASE + 20'h00E, q, ok);
      want(q == 16'h0000, "writing entry 6 disturbed entry 7");

      // ---------------------------------------------------------------
      // 5. mp_swab does something
      // ---------------------------------------------------------------
      // Two logical pages onto one physical page, one straight and one
      // exchanged.  A word written through the first must come back
      // byte-reversed through the second.
      //
      // Note what this does NOT prove.  It is symmetric: swapping which of the
      // two settings exchanges the bytes leaves both readings unchanged, so it
      // catches mp_swab being ignored but not mp_swab being backwards.  The
      // ISCP handshake below is what pins the polarity down, and it is the
      // only thing that does -- confirmed by mutation.
      poke(REG_BASE + 20'h000, 16'h8000, ok);        // entry 0: swab=1, page 0
      poke(REG_BASE + 20'h002, 16'h0000, ok);        // entry 1: swab=0, page 0
      poke(MEM_BASE + 20'h000, 16'h1234, ok);
      want(ok, "the memory window did not answer");
      peek(MEM_BASE + 20'h000, q, ok);
      want(q == 16'h1234,
           $sformatf("read back %04x through the same page, expected 1234", q));
      peek(MEM_BASE + 20'h400, q, ok);               // page 1, same physical page
      want(q == 16'h3412,
           $sformatf("read back %04x through the unswapped alias, expected 3412 -- mp_swab is not swapping",
                     q));

      // ---------------------------------------------------------------
      // 1. The chip finds its SCP
      // ---------------------------------------------------------------
      // ieinit()'s map: entries 0..7 identity with swab set, entry 1023
      // aliasing physical page 0 so the chip's hard-wired SCP address
      // 0xFFFFF6 -- 0xFFFF6 once the board drops the top nibble -- lands at
      // physical byte 0x3F6.  That is where struct ie_softc puts es_scp:
      // es_junk is padded to IEPAGSIZ - sizeof(struct iescp) = 1014 = 0x3F6.
      for (i = 0; i < 1024; i++) poke(REG_BASE + 20'(i * 2), 16'h0000, ok);
      for (i = 0; i < 8; i++)    poke(REG_BASE + 20'(i * 2), 16'h8000 | 16'(i), ok);
      poke(REG_BASE + 20'(1023 * 2), 16'h0000, ok);  // entry 1023 -> page 0

      // Zero the first two pages, as the scrub loop does.
      for (i = 0; i < 1024; i += 2) poke(MEM_BASE + 20'(i), 16'h0000, ok);

      // The SCP at 0x3F6: sysbus 0 (16-bit), then five bytes of nothing, then
      // the ISCP address as to_ieaddr() would leave it.  Put the ISCP at
      // board offset 0x400 -- page 1, which is mapped straight through.
      //
      //   to_ieaddr(0x400) -> bytes { 00, 04, 00, 00 }
      //
      // written as two 68000 words through a swab=1 page: 0x0004, 0x0000.
      poke(MEM_BASE + 20'h3F6, 16'h0000, ok);        // ie_sysbus = 0, junk
      poke(MEM_BASE + 20'h3F8, 16'h0000, ok);
      poke(MEM_BASE + 20'h3FA, 16'h0000, ok);
      poke(MEM_BASE + 20'h3FC, 16'h0004, ok);        // ie_iscp, high half
      poke(MEM_BASE + 20'h3FE, 16'h0000, ok);        // ie_iscp, low half

      // The ISCP at 0x400: busy = 1, scb offset, cbbase.  The chip must clear
      // ie_busy, which is byte 0.
      poke(MEM_BASE + 20'h400, 16'h0100, ok);        // ie_busy = 1, junk = 0
      poke(MEM_BASE + 20'h402, 16'h0002, ok);        // ie_scb  = offset 0x200
      poke(MEM_BASE + 20'h404, 16'h0000, ok);        // ie_cbbase = 0
      poke(MEM_BASE + 20'h406, 16'h0000, ok);

      // iereset(): pulse the reset bit, then channel attention.
      poke(REG_BASE + 20'h840, 16'h8000, ok);        // mies_reset = 1
      repeat (20) @(posedge clk);
      poke(REG_BASE + 20'h840, 16'h0000, ok);        // and release
      repeat (200) @(posedge clk);
      poke(REG_BASE + 20'h840, 16'h2000, ok);        // mies_ca = 1
      poke(REG_BASE + 20'h840, 16'h0000, ok);        // ... and negate it

      // ieinit() spins on this for 100000 iterations.
      guard = 0;
      q = 16'hFFFF;
      while (guard < 40000) begin
         peek(MEM_BASE + 20'h400, q, ok);
         if (q[15:8] != 8'h01) break;
         guard++;
      end
      want(q[15:8] != 8'h01,
           "the chip never cleared the ISCP busy flag -- it did not find its SCP");
      $display("ISCP busy cleared after %0d polls, word now %04x", guard, q);

      $display("%0d checks", checks);
      if (fail == 0) $display("PASS: sun2_mb_ether");
      else           $display("FAIL: %0d problems", fail);
      $finish;
   end

   initial begin
      #2_000_000_000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
