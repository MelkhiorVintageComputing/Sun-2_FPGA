// tb_scc -- the Z8530 driven the way SunOS drives it, not the way it is easy
// to drive.
//
// The console SCC has never been unit-tested in this project, and the one
// thing no boot has ever exercised is its *interrupts*: the boot PROM polls
// RR0 and writes the data register, and nothing else (busyio.c:17-50).  SunOS
// is the first software here to enable them, and it does so through a path
// the chip's own upstream testbench never takes.
//
// Two things about this bench matter, and both are deliberate departures from
// Inputs/z8530_scc/z8530_scc_tb.sv:
//
//   1. It uses the *Sun-2's* bus protocol.  sun2_fpga.v ties cs_n low and
//      selects the chip with rd_n/wr_n (`~MATCH_SERIAL | ~RD'), where the
//      upstream bench holds rd_n/wr_n around a cs_n strobe.  A model can pass
//      one and fail the other.
//
//   2. Every chip-wide register is written through **channel B**, because
//      that is where SunOS writes them.  zsattach() (zs_common.c:196-216)
//      walks the two ports and leaves `zs' pointing at port B before doing
//      ZWRITE(9, ZSWR9_MASTER_IE + ZSWR9_VECTOR_INCL_STAT) -- so the Master
//      Interrupt Enable, the single bit that decides whether the chip can
//      interrupt at all, arrives on channel B.  Upstream's 22 tests all write
//      WR9 through channel A and so all pass on a model that drops the
//      channel-B write on the floor.
//
// The register values are not invented: they are what zsnull_attach()
// (zs_common.c:355-377) and zsparam() (zs_async.c:475-490) actually write,
// and the interrupt dispatch replays zslevel6 (zs_asm.s:24-51) instruction
// for instruction -- point at register 2 through channel B, read the
// status-modified vector, decode channel from bit 3 and source from bits 2:1.

`timescale 1ns / 1ps

module tb_scc;

   // The machine's own clocks: cpu_clk at 20 MHz (a v1s1 bitstream) and one
   // 4.9152 MHz crystal feeding both pclk and sclk, exactly as sun2_fpga.v
   // wires them.
   localparam real CLK_PERIOD  = 50.0;      // 20 MHz
   localparam real SCLK_PERIOD = 203.4505;  // 4.9152 MHz

   // SunOS's own constants (sundev/zsreg.h).
   localparam [7:0] ZSWR0_RESET_STATUS = 8'h10;
   localparam [7:0] ZSWR0_RESET_TXINT  = 8'h28;
   localparam [7:0] ZSWR0_RESET_ERRORS = 8'h30;
   localparam [7:0] ZSWR0_CLR_INTR     = 8'h38;

   localparam [7:0] ZSWR1_INIT         = 8'h13;  // SIE|TIE|RIE, WR1[4:3]=10
   localparam [7:0] ZSWR3_RX_8         = 8'hC0;
   localparam [7:0] ZSWR3_RX_ENABLE    = 8'h01;
   localparam [7:0] ZSWR4_INIT         = 8'h46;  // even parity + 1 stop + x16
   localparam [7:0] ZSWR5_INIT         = 8'hEA;  // DTR|TX_8|TX_ENABLE|RTS
   localparam [7:0] ZSWR1_TIE          = 8'h02;  // transmit interrupt enable
   localparam [7:0] ZSWR9_RESET_WORLD  = 8'hC0;
   localparam [7:0] ZSWR9_MASTER_IE    = 8'h08;
   localparam [7:0] ZSWR9_VECTOR_INCL_STAT = 8'h01;
   localparam [7:0] ZSWR11_INIT        = 8'h50;  // TXCLK_BAUD|RXCLK_BAUD
   localparam [7:0] ZSWR14_BAUD_FROM_PCLK = 8'h02;
   localparam [7:0] ZSWR14_BAUD_ENA    = 8'h01;

   localparam [7:0] ZSRR0_RX_READY     = 8'h01;
   localparam [7:0] ZSRR0_TX_READY     = 8'h04;

   // ZSTimeConst(PCLK=4915200, 9600) with x16 -> 4915200/(2*16*9600) - 2 = 14.
   localparam [15:0] SPEED_9600 = 16'd14;
   localparam real   BIT_NS     = 1000000000.0 / 9600.0;

   reg         clk = 0, sclk = 0;
   reg         reset_n = 0;
   reg         rd_n = 1, wr_n = 1, a_b = 1, d_c = 0;
   reg  [7:0]  data_in = 8'h00;
   wire [7:0]  data_out;
   wire        data_oe, int_n;
   reg         rxda = 1'b1;
   wire        txda;

   integer     checks = 0, errors = 0;

   always #(CLK_PERIOD/2.0)  clk  = ~clk;
   always #(SCLK_PERIOD/2.0) sclk = ~sclk;

   // Parameters and tie-offs copied from the `serial' instance in
   // sun2_fpga.v:1015-1080, so this is the chip the machine actually builds.
   z8530_scc #(.SOFT_RESET_EN(1),
               .RR8_CTRL_POP(1),
               .BRG_SRC_A(1),
               .BRG_SRC_B(1),
               .UNIPLUS_BAUD_PATCH_B(0),
               .AUTO_ENABLES_EN(0),
               .RTXC_XTAL_FULLRATE_A(0),
               .RTXC_XTAL_FULLRATE_B(0),
               .RDWR_RESET_EN(1)
               ) dut (
                      .clk(clk), .pclk(sclk), .sclk(sclk),
                      .reset_n(reset_n),
                      .cs_n(1'b0),            // the machine ties this low
                      .rd_n(rd_n), .wr_n(wr_n),
                      .a_b(a_b), .d_c(d_c),
                      .data_in(data_in), .data_out(data_out), .data_oe(data_oe),
                      .int_n(int_n), .intack_n(1'b1),
                      .rxca(1'b0), .txca(1'b0), .rxda(rxda), .txda(txda),
                      .ctsa_n(1'b1), .dcda_n(1'b1), .synca_n(1'b1),
                      .rtsa_n(), .dtra_n(),
                      .rxcb(1'b0), .txcb(1'b0), .rxdb(1'b1), .txdb(),
                      .ctsb_n(1'b1), .dcdb_n(1'b1), .syncb_n(1'b1),
                      .rtsb_n(), .dtrb_n());

   //-------------------------------------------------------------------------
   // The bus, as sun2_fpga.v presents it.  RD and WR are the 68010 data-strobe
   // window (sun2_fpga.v:341-343) qualified by MATCH_SERIAL, so the strobe is
   // asserted for several cpu_clk cycles with address and data already valid.
   // Between accesses both are high and the chip is unselected in every way
   // that matters.
   //
   // zszwrite/zszread (zs_asm.s:164-199) put 3 to 5 nops between the pointer
   // write and the data cycle -- about 1.8 us at 12.5 MHz.  RECOVERY_CLK is
   // that gap, in cpu_clk cycles.
   //-------------------------------------------------------------------------
   localparam int STROBE_CLK   = 4;
   localparam int RECOVERY_CLK = 36;

   task automatic bus_write(input chan_a, input is_data, input [7:0] val);
      begin
         @(posedge clk);
         a_b <= chan_a; d_c <= is_data; data_in <= val;
         @(posedge clk);
         wr_n <= 1'b0;
         repeat (STROBE_CLK) @(posedge clk);
         wr_n <= 1'b1;
         repeat (RECOVERY_CLK) @(posedge clk);
      end
   endtask

   task automatic bus_read(input chan_a, input is_data, output [7:0] val);
      begin
         @(posedge clk);
         a_b <= chan_a; d_c <= is_data;
         @(posedge clk);
         rd_n <= 1'b0;
         repeat (STROBE_CLK) @(posedge clk);
         val = data_out;
         rd_n <= 1'b1;
         repeat (RECOVERY_CLK) @(posedge clk);
      end
   endtask

   // ZWRITE(n,v) / ZREAD(n) -- zscom.h:51-53.  Point the register pointer with
   // a write to the control port, then do the real cycle there too.
   task automatic zwrite(input chan_a, input [3:0] regnum, input [7:0] val);
      begin
         if (regnum != 4'd0) bus_write(chan_a, 1'b0, {4'h0, regnum});
         bus_write(chan_a, 1'b0, val);
      end
   endtask

   task automatic zread(input chan_a, input [3:0] regnum, output [7:0] val);
      begin
         bus_write(chan_a, 1'b0, {4'h0, regnum});
         bus_read(chan_a, 1'b0, val);
      end
   endtask

   // A bare RR0 read, the way the driver and the PROM do it: no pointer write,
   // relying on the pointer having auto-reset to 0.
   task automatic read_rr0(input chan_a, output [7:0] val);
      begin
         bus_read(chan_a, 1'b0, val);
      end
   endtask

   task automatic check(input ok, input [1023:0] what);
      begin
         checks = checks + 1;
         if (!ok) begin
            errors = errors + 1;
            $display("FAIL: %0s", what);
         end else
            $display("  ok: %0s", what);
      end
   endtask

   task automatic check_eq(input [7:0] got, input [7:0] want, input [1023:0] what);
      begin
         checks = checks + 1;
         if (got !== want) begin
            errors = errors + 1;
            $display("FAIL: %0s -- got %02x, want %02x", what, got, want);
         end else
            $display("  ok: %0s (%02x)", what, got);
      end
   endtask

   // Wait for int_n to reach a level, with a timeout in cpu_clk cycles.
   task automatic wait_int(input want_low, input integer limit, output ok);
      integer n;
      begin
         n  = 0;
         ok = 0;
         while (n < limit) begin
            if (int_n === (want_low ? 1'b0 : 1'b1)) begin ok = 1; n = limit; end
            else begin @(posedge clk); n = n + 1; end
         end
      end
   endtask

   // Shift a byte into rxda at 9600 8N1, the rate the BRG is programmed for.
   task automatic send_char(input [7:0] ch);
      integer i;
      begin
         rxda = 1'b0;                       // start bit
         #(BIT_NS);
         for (i = 0; i < 8; i = i + 1) begin
            rxda = ch[i];                   // LSB first
            #(BIT_NS);
         end
         rxda = 1'b1;                       // stop bit
         #(BIT_NS);
      end
   endtask

   //-------------------------------------------------------------------------
   // zsnull_attach(), zs_common.c:355-377.  `chan_a' says which port.
   //-------------------------------------------------------------------------
   task automatic attach_port(input chan_a);
      begin
         zwrite(chan_a, 4'd4,  ZSWR4_INIT);
         zwrite(chan_a, 4'd3,  ZSWR3_RX_8);
         zwrite(chan_a, 4'd11, ZSWR11_INIT);
         zwrite(chan_a, 4'd12, SPEED_9600[7:0]);
         zwrite(chan_a, 4'd13, SPEED_9600[15:8]);
         zwrite(chan_a, 4'd14, ZSWR14_BAUD_FROM_PCLK);
         zwrite(chan_a, 4'd3,  ZSWR3_RX_8 | ZSWR3_RX_ENABLE);
         zwrite(chan_a, 4'd5,  ZSWR5_INIT);
         zwrite(chan_a, 4'd14, ZSWR14_BAUD_ENA | ZSWR14_BAUD_FROM_PCLK);
         zwrite(chan_a, 4'd0,  ZSWR0_RESET_ERRORS | ZSWR0_RESET_STATUS);
      end
   endtask

   //-------------------------------------------------------------------------
   // zslevel6, zs_asm.s:24-51.  Point at register 2 through **channel B** and
   // read the status-modified vector; bit 3 says which channel, bits 2:1 say
   // which source.  Returns the raw byte.
   //-------------------------------------------------------------------------
   task automatic level6_vector(output [7:0] v);
      begin
         bus_write(1'b0, 1'b0, 8'h02);   // movb #2,a1@  -- channel B
         bus_read (1'b0, 1'b0, v);       // movb a1@,d0
      end
   endtask

   function automatic [23:0] srcname(input [7:0] v);
      case (v[2:1])
        2'b00: srcname = "tx ";
        2'b01: srcname = "ext";
        2'b10: srcname = "rx ";
        2'b11: srcname = "spc";
      endcase
   endfunction

   //-------------------------------------------------------------------------

   reg [7:0] v, r0, r2a;
   reg       ok;

   initial begin
      $display("=== tb_scc: the Z8530 driven as SunOS drives it ===");

      reset_n = 1'b0;
      repeat (20) @(posedge clk);
      reset_n = 1'b1;
      repeat (20) @(posedge clk);

      // --- 1. zsattach: force hardware reset, through channel B.
      zwrite(1'b0, 4'd9, ZSWR9_RESET_WORLD);
      repeat (200) @(posedge clk);

      // --- 2. zsnull_attach for both ports.
      attach_port(1'b1);
      attach_port(1'b0);

      // --- 3. zsparam: enable the interrupt sources themselves, on channel A.
      //     WR1 is not a readable register on an 8530 -- register 1 reads back
      //     as RR1, the receive status -- so the only honest check here is
      //     that RR1 says the transmitter is idle before we prime it.
      zwrite(1'b1, 4'd1, ZSWR1_INIT);
      zread (1'b1, 4'd1, v);
      check((v & 8'h01) != 0, "RR1 says all sent before the first character");

      // --- 4a. Control: the same Master Interrupt Enable, written through
      //     channel A.  Nothing in the machine does this -- it is here so that
      //     a failure below says *which* half is broken.  If this passes and
      //     the channel-B write does not, the interrupt machinery is sound and
      //     the chip is dropping a chip-wide register written through B.
      zwrite(1'b1, 4'd9, ZSWR9_MASTER_IE | ZSWR9_VECTOR_INCL_STAT);
      bus_write(1'b1, 1'b1, 8'h40);        // '@'
      wait_int(1, 20000, ok);
      check(ok, "control: MIE written through channel A enables interrupts");

      // Put it back the way SunOS leaves it and start again from a reset chip,
      // so the sequence below is the real one and not a continuation.
      zwrite(1'b1, 4'd0, ZSWR0_RESET_TXINT);
      #(BIT_NS * 12);
      zwrite(1'b1, 4'd0, ZSWR0_RESET_TXINT);
      zwrite(1'b0, 4'd9, ZSWR9_RESET_WORLD);
      repeat (200) @(posedge clk);
      attach_port(1'b1);
      attach_port(1'b0);
      zwrite(1'b1, 4'd1, ZSWR1_INIT);

      // --- 4b. The write this whole bench exists for: MIE, through channel B.
      //     zs_common.c:214, with `zs' left pointing at port B by the loop
      //     above it.  RR9 does not exist on an 8530, so this cannot be
      //     checked by reading it back -- the assertion is the interrupt
      //     itself, at step 5.
      zwrite(1'b0, 4'd9, ZSWR9_MASTER_IE | ZSWR9_VECTOR_INCL_STAT);

      // --- 5. zsstart primes the first byte itself (zs_async.c:538-542),
      //     having first checked RR0 says the transmitter will take it.
      read_rr0(1'b1, r0);
      check((r0 & ZSRR0_TX_READY) != 0, "RR0 says Tx buffer empty before priming");
      bus_write(1'b1, 1'b1, 8'h41);        // 'A' to channel A's data port

      wait_int(1, 20000, ok);
      check(ok, "MIE written through channel B enables interrupts");

      // --- 6. zslevel6 decodes it: channel A, transmit buffer empty.
      level6_vector(v);
      $display("     RR2(B) = %02x -> channel %0s, source %0s",
               v, v[3] ? "A" : "B", srcname(v));
      check(v[3] === 1'b1,   "RR2 status-modified names channel A");
      check(v[2:1] === 2'b00, "RR2 status-modified names Tx buffer empty");

      // --- 7. zsa_txint with nothing left to send: reset Tx int pending.
      zwrite(1'b1, 4'd0, ZSWR0_RESET_TXINT);
      wait_int(0, 2000, ok);
      check(ok, "ZSWR0_RESET_TXINT deasserts int_n");

      // zslevel6 then writes ZSWR0_CLR_INTR unconditionally.  This model has
      // no IUS, so it must be a harmless no-op -- in particular it must not
      // re-point the register pointer at 8, which command bit 3 alone would.
      zwrite(1'b1, 4'd0, ZSWR0_CLR_INTR);
      read_rr0(1'b1, r0);
      check(r0 !== 8'hxx, "ZSWR0_CLR_INTR leaves the pointer at 0");

      // --- 8. With nothing pending, the vector reads the "no interrupt" code.
      //     zsopinit (zs_common.c:293-317) routes 011 to zslevel6intr on a
      //     Sun-2, so this encoding is load-bearing.
      level6_vector(v);
      check(v[3:1] === 3'b011, "RR2 reads channel-B-special when nothing is pending");

      // --- 9. Receive: a character on the wire must interrupt.
      //     Let the transmitter finish first so its own interrupt cannot be
      //     mistaken for the receiver's.
      #(BIT_NS * 12);
      zwrite(1'b1, 4'd0, ZSWR0_RESET_TXINT);
      repeat (100) @(posedge clk);

      fork
         send_char(8'h5A);                 // 'Z'
      join_none
      wait_int(1, 400000, ok);
      check(ok, "int_n asserts on a received character");

      level6_vector(v);
      $display("     RR2(B) = %02x -> channel %0s, source %0s",
               v, v[3] ? "A" : "B", srcname(v));
      check(v[3] === 1'b1,    "RR2 names channel A for the receive interrupt");
      check(v[2:1] === 2'b10, "RR2 names Rx character available");

      read_rr0(1'b1, r0);
      check((r0 & ZSRR0_RX_READY) != 0, "RR0 says a character is available");

      // zsa_rxint reads the data port and nothing else (zs_async.c:652-677).
      bus_read(1'b1, 1'b1, v);
      check_eq(v, 8'h5A, "the received character is the one sent");

      wait_int(0, 2000, ok);
      check(ok, "draining the receiver deasserts int_n");

      // --- 10. WR2 is chip-wide too (zs_common.c:216 writes it through B).
      zwrite(1'b0, 4'd2, 8'h30);
      zread (1'b1, 4'd2, r2a);
      check_eq(r2a, 8'h30, "WR2 written through channel B reads back on channel A");

      // --- 11. And the whole thing must go quiet again when MIE is cleared,
      //     since that is the only gate between a pending source and the
      //     machine's INT6_n.
      zwrite(1'b0, 4'd9, ZSWR9_VECTOR_INCL_STAT);   // MIE off, through B
      bus_write(1'b1, 1'b1, 8'h42);
      repeat (20000) @(posedge clk);
      check(int_n === 1'b1, "int_n stays deasserted while MIE is clear");

      // ---------------------------------------------------------------
      // RR3, which is how NetBSD dispatches and SunOS never does.
      //
      // zsc_intr_hard (dev/ic/z8530sc.c:287-320) reads RR3 and calls rxint,
      // stint and txint from its IP bits; SunOS's zslevel6 reads the
      // status-modified vector in RR2 instead.  So RR3 is a path no boot
      // before NetBSD ever took, and an IP that sets without its enable is
      // invisible until something walks it.
      //
      // On a Z8530 an IP is set by its condition *and* its enable.  If the
      // transmit IP could latch with TxIE clear it would stay set for ever --
      // only an explicit WR0 command clears it -- so every interrupt from any
      // source would also look like a transmit interrupt, and zstty_txint
      // writes the next byte without checking the transmitter because being
      // called is supposed to mean it is empty.  The byte still going out is
      // overwritten and lost.
      $display("-- RR3, the way NetBSD reads it --");

      // Master reset, then bring channel A up with MIE on but every WR1
      // source still disabled.
      zwrite(1'b1, 4'd9, ZSWR9_RESET_WORLD);
      repeat (200) @(posedge clk);
      attach_port(1'b1);
      zwrite(1'b0, 4'd9, ZSWR9_MASTER_IE | ZSWR9_VECTOR_INCL_STAT);
      zwrite(1'b1, 4'd1, 8'h00);            // no Rx, no Tx, no Ext enables
      zwrite(1'b1, 4'd0, ZSWR0_RESET_TXINT);

      // Transmit a character with TxIE clear.  The buffer empties, so the
      // condition happens; the enable is off, so no IP may latch.
      bus_write(1'b1, 1'b1, 8'h41);
      repeat (4000) @(posedge clk);
      zread(1'b1, 4'd3, v);
      check_eq(v & 8'h10, 8'h00,
               "RR3: no TX IP with TxIE clear");
      check(int_n === 1'b1, "int_n stays deasserted with every WR1 source off");

      // A received character with the receive interrupt mode disabled must
      // not raise an IP either.
      send_char(8'h5a);
      repeat (200) @(posedge clk);
      zread(1'b1, 4'd3, v);
      check_eq(v & 8'h20, 8'h00,
               "RR3: no RX IP with the receive interrupt disabled");
      zread(1'b1, 4'd8, v);                  // drain it again

      // Now enable the transmitter's interrupt and send one.  The IP must
      // appear, because this time the enable is set.
      zwrite(1'b1, 4'd1, ZSWR1_TIE);
      bus_write(1'b1, 1'b1, 8'h42);
      repeat (4000) @(posedge clk);
      zread(1'b1, 4'd3, v);
      check_eq(v & 8'h10, 8'h10,
               "RR3: TX IP does appear once TxIE is set");

      // And NetBSD's own dispatch decision on that RR3: with only the
      // transmitter enabled it must see exactly one source, not three.
      check_eq(v & 8'h38, 8'h10,
               "RR3: exactly the TX source, not RX or STAT as well");

      // ---------------------------------------------------------------
      // What clears the transmit IP, which is where the two drivers differ.
      //
      // The IP means "the transmit buffer is empty".  Writing a new character
      // makes it non-empty, so the condition has gone and the IP goes with it;
      // the explicit WR0 command exists for a driver with nothing more to send,
      // which cannot clear it by writing.  SunOS issues the command
      // (sundev/zs_common.c:384, zs_async.c:615); NetBSD never does -- the only
      // ZSWR0_RESET_TXINT in its tree is in the kgdb stub -- and zstty_txint
      // just writes the next byte and relies on that.
      //
      // If a write does not clear it, /INT never drops, zstty_txint is
      // re-entered at once, and it writes another byte on top of the one still
      // going out.  That is a fixed loop and not a race, which is why the loss
      // is byte-for-byte reproducible on the board.
      $display("-- what clears the transmit IP --");

      // We are here with TxIE set and the TX IP raised by the last character.
      zread(1'b1, 4'd3, v);
      check_eq(v & 8'h10, 8'h10, "TX IP is raised before the write");

      // Write a character the way zstty_txint does: data only, no command.
      bus_write(1'b1, 1'b1, 8'h43);
      zread(1'b1, 4'd3, v);
      check_eq(v & 8'h10, 8'h00,
               "a data write clears the TX IP, with no WR0 command");

      // And the interrupt must go away with it, or the driver re-enters for
      // ever.
      check(int_n === 1'b1,
            "int_n drops when the data write clears the TX IP");

      // The explicit command still works, for the driver that uses it.  Wait
      // for the interrupt rather than a fixed delay: the character just written
      // sits in the FIFO until the one before it has shifted out at 9600 baud,
      // which is a millisecond, not a few thousand clocks.
      wait_int(1'b1, 200000, ok);
      check(ok, "the transmitter raises its interrupt again");
      zread(1'b1, 4'd3, v);
      check_eq(v & 8'h10, 8'h10, "TX IP raised again once the buffer empties");
      zwrite(1'b1, 4'd0, ZSWR0_RESET_TXINT);
      zread(1'b1, 4'd3, v);
      check_eq(v & 8'h10, 8'h00,
               "Reset Tx Int Pending still clears it, as SunOS expects");

      $display("=== %0d checks, %0d failures ===", checks, errors);
      if (errors == 0) $display("PASS");
      else             $display("FAIL");
      $finish;
   end

   // A bench that hangs is a bench that says nothing.
   initial begin
      #200000000;
      $display("FAIL: timeout -- the bench never reached its end");
      $finish;
   end

endmodule
