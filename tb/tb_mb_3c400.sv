`timescale 1ns / 1ps

//
// sun2_mb_3c400 driven the way its three drivers drive it.
//
// The sequences are lifted from the software that actually exists, not
// paraphrased: the boot PROM's ecprobe()/ecxmit()/ecpoll() in
// Inputs/sunos-34-src/sun/prom_monitor/msun/sys/sunstand/ec.c, the SunOS 3.4
// kernel driver in sundev/if_ec.c, and NetBSD 2.0's if_ec.c.  Where the three
// disagree the manual and SunOS win.
//
// What this test is really for is the receive path, because **nothing in this
// project had ever driven rx_dv high**.  Neither Ethernet card's receiver had
// been simulated once, on either machine, in the life of the tree; every
// recorded result is a transmit result.  So the buffer ownership, RBBA, the
// status word, doff and the address filter are all new ground, and all of them
// are things a boot would fail on in a way that reads as "the network is
// broken" rather than as anything specific.
//
module tb_mb_3c400;

   localparam logic [19:0] EC_BASE = 20'hE0000;
   localparam logic [47:0] MYADDR  = 48'h08_00_20_01_06_E0;

   localparam int CLK_HALF = 40;               // 12.5 MHz

   // Register and buffer offsets, from if_ecreg.h.
   localparam logic [19:0] O_CSR  = 20'h0000;
   localparam logic [19:0] O_BACK = 20'h0002;
   localparam logic [19:0] O_AROM = 20'h0400;
   localparam logic [19:0] O_ARAM = 20'h0600;
   localparam logic [19:0] O_TBUF = 20'h0800;
   localparam logic [19:0] O_ABUF = 20'h1000;
   localparam logic [19:0] O_BBUF = 20'h1800;

   localparam logic [15:0] C_BBSW = 16'h8000, C_ABSW = 16'h4000;
   localparam logic [15:0] C_TBSW = 16'h2000, C_JAM  = 16'h1000;
   localparam logic [15:0] C_AMSW = 16'h0800, C_RBBA = 16'h0400;
   localparam logic [15:0] C_RST  = 16'h0100;
   localparam logic [15:0] C_BINT = 16'h0080, C_AINT = 16'h0040;
   localparam logic [15:0] C_TINT = 16'h0020, C_JINT = 16'h0010;

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

   sun2_mb_3c400 #(.EC_BASE(EC_BASE), .STATION_ADDR(MYADDR)) dut (
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
   // A MultiBus cycle, as sun2_fpga presents one
   // ------------------------------------------------------------------
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
            if (mb_hit && mb_ack) begin q = mb_dout; ok = 1'b1; break; end
         end
         @(negedge clk);
         mb_sel   <= 1'b0;
         mb_we    <= 1'b0;
         mb_uds_n <= 1'b1;
         mb_lds_n <= 1'b1;
         @(posedge clk);
      end
   endtask

   task automatic poke(input logic [19:0] a, input logic [15:0] d, output bit ok);
      logic [15:0] q;
      bus_cycle(EC_BASE + a, 1'b1, 1'b1, 1'b1, d, q, ok);
   endtask

   task automatic peek(input logic [19:0] a, output logic [15:0] q, output bit ok);
      bus_cycle(EC_BASE + a, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
   endtask

   // A byte write to an odd address is the low half of the word below it, and
   // that is how the receive buffers get filled a byte at a time.
   task automatic poke_lo(input logic [19:0] a, input logic [7:0] d, output bit ok);
      logic [15:0] q;
      bus_cycle(EC_BASE + a, 1'b1, 1'b0, 1'b1, {8'h00, d}, q, ok);
   endtask

   // Convenience wrappers that discard the ack -- everything inside the 8 KiB
   // must answer, and there is a dedicated check for that.
   logic [15:0] q;  bit ok;
   task automatic wr(input logic [19:0] a, input logic [15:0] d);
      bit o; poke(a, d, o);
      if (!o) begin $display("FAIL: write to +0x%04x was not acknowledged", a); fail++; end
   endtask
   function automatic logic [15:0] rd_last(); return q; endfunction
   task automatic rd(input logic [19:0] a);
      peek(a, q, ok);
      if (!ok) begin $display("FAIL: read of +0x%04x was not acknowledged", a); fail++; end
   endtask

   // The drivers' own macro: OR a bit in, relying on write-1-to-set.
   task automatic csrset(input logic [15:0] bits);
      rd(O_CSR);
      wr(O_CSR, q | bits);
   endtask

   // ecinit()/ec_init(): copy the address ROM into the address RAM and then
   // hand the RAM to the controller with AMSW.  The card filters on the RAM,
   // not the ROM -- the ROM is only what the driver reads to find out who it
   // is -- so a card that has been reset and not reinitialised matches nothing
   // but broadcast.  That is correct, and it is what caught this test out.
   task automatic load_aram();
      wr(O_ARAM + 0, MYADDR[47:32]);
      wr(O_ARAM + 2, MYADDR[31:16]);
      wr(O_ARAM + 4, MYADDR[15:0]);
      csrset(C_AMSW);
      // And once given away it is the card's: further writes are ignored
      // until reset, which is the manual's wording and worth checking.
      wr(O_ARAM + 0, 16'hDEAD);
   endtask

   // ------------------------------------------------------------------
   // Frames
   // ------------------------------------------------------------------
   byte unsigned f[$];

   task automatic build(input logic [47:0] dst, input logic [47:0] src,
                        input int payload);
      f = {};
      for (int i = 0; i < 6; i++) f.push_back(dst[47 - 8*i -: 8]);
      for (int i = 0; i < 6; i++) f.push_back(src[47 - 8*i -: 8]);
      f.push_back(8'h08); f.push_back(8'h00);          // type: IP
      for (int i = 0; i < payload; i++) f.push_back(8'h40 + i[7:0]);
   endtask

   // Wait for the receiver to finish, or give up.  A frame is 4 bits per
   // mii_rx_clk and the card writes a byte per CLK, so the card is always the
   // faster of the two; this is a guard against a wedged FSM, not a race.
   task automatic settle();
      repeat (400) @(posedge clk);
   endtask

   // ------------------------------------------------------------------
   // The tests
   // ------------------------------------------------------------------
   logic [15:0] st;
   int          n;

   initial begin
      $display("=== tb_mb_3c400: a 3Com 3C400 in the MultiBus card cage ===");
      repeat (10) @(posedge clk);
      rst = 1'b0;
      repeat (10) @(posedge clk);

      // ---- 1. Probing ------------------------------------------------
      // NetBSD's ec_match() is literally `peek_2(csr) == 0'.  A card that
      // powers up with anything at all in the register does not attach, and
      // the failure is silent -- no message, just no ec0.
      peek(O_CSR, q, ok);
      want(ok,           "probe: a 16-bit read at the base is acknowledged");
      want(q == 16'h0000, "probe: MECSR reads 0x0000 out of reset");

      // SunOS's ecprobe() peeks ec_bbuf[2046] -- the far end of the aperture,
      // with the card owning nothing.  It must answer.
      peek(O_BBUF + 20'd2046, q, ok);
      want(ok, "probe: the last word of the B buffer is acknowledged");

      // And the whole 8 KiB is one window: nothing above it is ours.
      bus_cycle(EC_BASE + 20'h2000, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(!ok && !mb_hit, "probe: 0xE2000 does not answer -- controller 1 is not fitted");

      // ---- 2. Aliasing -----------------------------------------------
      // MECSR/MEBACK repeat every four bytes across 0x000..0x3FF, and the
      // address blocks every eight across theirs.  A decode that used more
      // address bits than the card does would break a driver that reached a
      // register through any of its images.
      rd(O_CSR + 20'h0004);
      want(q == 16'h0000, "alias: MECSR is readable at +0x004");
      rd(O_CSR + 20'h03FC);
      want(q == 16'h0000, "alias: MECSR is readable at +0x3FC");

      // MEBACK is write-only.  A read of +2 returns MECSR instead, and a write
      // to it must change nothing readable.
      wr(O_BACK, 16'hFFFF);
      rd(O_CSR);
      want(q == 16'h0000, "meback: writing +0x002 changes no visible state");
      rd(O_BACK);
      want(q == 16'h0000, "meback: a read of +0x002 returns MECSR");

      // ---- 3. The address ROM ----------------------------------------
      rd(O_AROM + 0); want(q == MYADDR[47:32], "arom: word 0");
      rd(O_AROM + 2); want(q == MYADDR[31:16], "arom: word 1");
      rd(O_AROM + 4); want(q == MYADDR[15:0],  "arom: word 2");
      rd(O_AROM + 8); want(q == MYADDR[47:32], "arom: repeats every 8 bytes");
      rd(O_AROM + 20'h01F8);
      want(q == MYADDR[47:32], "arom: still repeating at the top of its region");

      // ---- 4. Write-1-to-set, write-0-is-a-no-op ---------------------
      // This is risk #1 in the plan and it is not in the manual body: both
      // drivers write zeros into the ownership bits constantly while expecting
      // the card to keep the buffers.  NetBSD's ec_init() writes a literal
      // 0x0000 immediately after setting AMSW.
      csrset(C_AMSW);
      rd(O_CSR); want((q & C_AMSW) != 0, "csr: AMSW sets");
      wr(O_CSR, 16'h0000);
      rd(O_CSR); want((q & C_AMSW) != 0, "csr: a written zero does not clear AMSW");

      csrset(C_ABSW | C_BBSW);
      rd(O_CSR);
      want((q & (C_ABSW | C_BBSW)) == (C_ABSW | C_BBSW), "csr: both receive buffers hand over");
      wr(O_CSR, 16'h0000);
      rd(O_CSR);
      want((q & (C_ABSW | C_BBSW)) == (C_ABSW | C_BBSW), "csr: a written zero does not take them back");

      // The low byte is ordinary read/write, and a driver reads-modifies-writes
      // the whole word to reach it.
      rd(O_CSR); wr(O_CSR, (q & ~16'h00FF) | 16'h0007);
      rd(O_CSR); want((q & 16'h000F) == 16'h0007, "csr: PA is plain read/write");

      // ---- 5. Reset ---------------------------------------------------
      // ecreset(): a bare RESET write.  It self-clears, returns every buffer
      // and clears the enables, which is what both drivers' ECSET macros
      // assume when they OR against the read-back afterwards.
      wr(O_CSR, C_RST);
      rd(O_CSR);
      want(q == 16'h0000, "reset: self-clears and returns everything");

      // ...but "merely gives the memory buffers back": ECSET(EC_RESET) carries
      // the low byte along, and the enables and PA in it survive.  Nothing
      // live depends on this -- the kernel's only such call is inside
      // `#ifdef notdef' -- which is exactly why it would never be noticed.
      csrset(C_ABSW | C_BBSW);
      rd(O_CSR); wr(O_CSR, (q & 16'h00FF) | C_RST | 16'h0047);
      rd(O_CSR);
      want((q & (C_ABSW | C_BBSW)) == 0, "reset: the RESET bit takes the buffers back");
      want((q & 16'h00FF) == 16'h0047, "reset: ... and leaves the enables and PA the write carried");
      wr(O_CSR, C_RST);

      // ---- 6. Transmit ------------------------------------------------
      // The frame is RIGHT-aligned: MEXHDR holds its start offset and the
      // length is implicit, 2048 - MEXHDR bytes ending at the last byte of the
      // buffer.  Nothing else in this project transmits that way.
      build(48'hFF_FF_FF_FF_FF_FF, MYADDR, 46);   // 60 bytes, minimum size
      begin
         int off = 2048 - f.size();
         wr(O_TBUF, off[15:0]);                    // MEXHDR
         for (int i = 0; i < f.size(); i++) begin
            bit o;
            bus_cycle(EC_BASE + O_TBUF + off + i, 1'b1,
                      ((off + i) % 2) == 0, ((off + i) % 2) == 1,
                      {f[i], f[i]}, q, o);
         end
      end
      n = peer.tx_frames;
      csrset(C_TBSW);
      fork begin
         repeat (40000) @(posedge clk);
      end join_none
      wait (peer.tx_frames == n + 1);
      repeat (20) @(posedge clk);

      want(peer.tx_last.size() == 8 + 60 + 4,
           "tx: 8 bytes of preamble, 60 of frame and a 4-byte FCS on the wire");
      begin
         bit good = 1;
         for (int i = 0; i < f.size(); i++)
           if (peer.tx_last[8 + i] != f[i]) good = 0;
         want(good, "tx: the buffer goes out byte for byte, source address untouched");
      end
      rd(O_CSR);
      want((q & C_TBSW) == 0, "tx: TBSW is returned when the frame has gone");

      // The card is specified never to insert the source address -- the kernel
      // patches ether_shost itself, with a comment saying so.
      want(peer.tx_last[8 + 6] == 8'h08 && peer.tx_last[8 + 11] == 8'hE0,
           "tx: the source address is the buffer's, not the card's");

      // ---- 7. Padding, the one deliberate deviation -------------------
      // The manual leaves padding to the driver and the boot PROM does not do
      // it: its ND request is 58 bytes, a runt on the wire.  A 1982 coax
      // segment carried it; a modern switch drops it, so mii_tx pads to 64.
      build(48'hFF_FF_FF_FF_FF_FF, MYADDR, 44);   // 58 bytes
      begin
         int off = 2048 - f.size();
         wr(O_TBUF, off[15:0]);
         for (int i = 0; i < f.size(); i++) begin
            bit o;
            bus_cycle(EC_BASE + O_TBUF + off + i, 1'b1,
                      ((off + i) % 2) == 0, ((off + i) % 2) == 1,
                      {f[i], f[i]}, q, o);
         end
      end
      n = peer.tx_frames;
      csrset(C_TBSW);
      wait (peer.tx_frames == n + 1);
      repeat (20) @(posedge clk);
      want(peer.tx_last.size() == 8 + 64,
           "tx: a 58-byte frame is padded to the 64-byte minimum");

      // ---- 8. Receive -------------------------------------------------
      wr(O_CSR, C_RST);
      load_aram();
      rd(O_ARAM);
      want(q == MYADDR[47:32], "aram: a write after AMSW is ignored, as the manual says");
      rd(O_CSR); wr(O_CSR, q | 16'h0007);         // PA 7: mine + broadcast
      csrset(C_ABSW | C_BBSW);

      build(MYADDR, 48'h02_00_00_00_00_01, 46);
      peer.send_frame(f);
      settle();

      rd(O_CSR);
      want((q & C_ABSW) == 0, "rx: a frame for us fills a buffer");
      want((q & C_BBSW) != 0, "rx: and only one of them");

      // The status word.  doff is the offset of the first free byte, and it
      // counts the FCS -- SunOS computes length = doff - 2 - 14 - 4 with the
      // comment `/* 4 == FCS */'.  Strip the CRC and every packet arrives four
      // bytes short, which presents as protocols that almost work.
      rd(O_ABUF); st = q;
      want(st[10:0] == 11'(2 + 60 + 4),
           "rx: doff is 2 + frame + FCS");
      want(st[10:0] > 11'd2 && st[10:0] <= 11'd2046,
           "rx: doff is inside the bounds SunOS calls garbled");
      // Bits 14 and 12 are INVERTED -- nought means "is broadcast" and "does
      // match".  That inversion is the whole content of the July 1982
      // addendum, and since neither driver reads either bit, getting it wrong
      // would never show up anywhere but a packet capture.
      want(st[12] == 1'b0, "rx: the address-match bit is inverted -- 0 means it matched");
      want(st[14] == 1'b1, "rx: not broadcast, so the broadcast bit reads 1");
      want(st[15] == 1'b0 && st[13] == 1'b0 && st[11] == 1'b0,
           "rx: no FCS, range or framing error on a good frame");

      // The payload itself, at offset 2.
      rd(O_ABUF + 2);
      want(q[15:8] == MYADDR[47:40], "rx: the frame starts at offset 2");

      // ---- 9. The second buffer, and RBBA ----------------------------
      build(MYADDR, 48'h02_00_00_00_00_02, 46);
      peer.send_frame(f);
      settle();
      rd(O_CSR);
      want((q & C_BBSW) == 0, "rx: the next frame goes to the other buffer");
      // RBBA is ABSW at the instant B was filled.  A is still ours, so it was
      // clear: B did *not* arrive before A.
      want((q & C_RBBA) == 0, "rx: RBBA records that A was already full");

      // ---- 10. Both buffers full -------------------------------------
      // Nowhere to put it.  The card must drop the frame and stay sane, not
      // overwrite a buffer the host owns.
      rd(O_ABUF); st = q;
      build(MYADDR, 48'h02_00_00_00_00_03, 46);
      peer.send_frame(f);
      settle();
      rd(O_ABUF);
      want(q == st, "rx: with both buffers full the frame is dropped, not written over one");

      // ---- 11. Address filtering -------------------------------------
      wr(O_CSR, C_RST);
      load_aram();
      rd(O_CSR); wr(O_CSR, q | 16'h0007);
      csrset(C_ABSW | C_BBSW);
      build(48'h02_00_00_00_00_99, 48'h02_00_00_00_00_01, 46);   // not us
      peer.send_frame(f);
      settle();
      rd(O_CSR);
      want((q & (C_ABSW | C_BBSW)) == (C_ABSW | C_BBSW),
           "filter: PA 7 rejects a frame addressed to somebody else");

      // Broadcast under the same mode is accepted.
      build(48'hFF_FF_FF_FF_FF_FF, 48'h02_00_00_00_00_01, 46);
      peer.send_frame(f);
      settle();
      rd(O_CSR);
      want((q & C_ABSW) == 0 || (q & C_BBSW) == 0,
           "filter: PA 7 accepts broadcast");
      begin
         logic [19:0] b = ((q & C_ABSW) == 0) ? O_ABUF : O_BBUF;
         rd(b);
         want(q[14] == 1'b0, "filter: the broadcast bit is inverted too -- 0 means it was");
      end

      // PA 1 is promiscuous, which is what the boot PROM sets.
      wr(O_CSR, C_RST);
      load_aram();
      rd(O_CSR); wr(O_CSR, q | 16'h0001);
      csrset(C_ABSW | C_BBSW);
      build(48'h02_00_00_00_00_99, 48'h02_00_00_00_00_01, 46);
      peer.send_frame(f);
      settle();
      rd(O_CSR);
      want((q & C_ABSW) == 0, "filter: PA 1 takes everything, addressed to us or not");
      rd(O_ABUF);
      want(q[12] == 1'b1, "filter: ... and reports that the address did not match");

      // ---- 12. A bad FCS ---------------------------------------------
      // PA 0 is "all frames including errors", so the card must keep it and
      // say so rather than quietly discarding it.
      wr(O_CSR, C_RST);
      load_aram();
      rd(O_CSR); wr(O_CSR, q | 16'h0000);
      csrset(C_ABSW | C_BBSW);
      build(MYADDR, 48'h02_00_00_00_00_01, 46);
      peer.send_frame(f, 1'b1);
      settle();
      rd(O_CSR);
      want((q & C_ABSW) == 0, "fcs: PA 0 keeps a frame with a bad checksum");
      rd(O_ABUF);
      want(q[15] == 1'b1, "fcs: and sets FCSERR");

      // Under PA 7 the same frame is thrown away.
      wr(O_CSR, C_RST);
      load_aram();
      rd(O_CSR); wr(O_CSR, q | 16'h0007);
      csrset(C_ABSW | C_BBSW);
      peer.send_frame(f, 1'b1);
      settle();
      rd(O_CSR);
      want((q & (C_ABSW | C_BBSW)) == (C_ABSW | C_BBSW),
           "fcs: PA 7 discards it");

      // ---- 12b. An over-length frame ---------------------------------
      // 2114 bytes is longer than the buffer can hold.  doff must land outside
      // (2, 2046] rather than wrapping round into a plausible small value,
      // which is what an 11-bit counter does if left to itself -- and under
      // PA 0, which accepts errors, a wrapped doff would be handed straight to
      // the driver as a short valid frame.
      wr(O_CSR, C_RST);
      load_aram();
      rd(O_CSR); wr(O_CSR, q | 16'h0000);         // PA 0: everything
      csrset(C_ABSW | C_BBSW);
      build(MYADDR, 48'h02_00_00_00_00_01, 2100);
      peer.send_frame(f);
      repeat (6000) @(posedge clk);
      rd(O_CSR);
      want((q & C_ABSW) == 0, "long: PA 0 keeps an over-length frame");
      rd(O_ABUF);
      want(q[10:0] > 11'd2046, "long: doff saturates outside the valid range instead of wrapping");
      want(q[13] == 1'b1, "long: and the range-error bit is set");

      // Under PA 7 it is discarded, because a range error is an error.
      wr(O_CSR, C_RST);
      load_aram();
      rd(O_CSR); wr(O_CSR, q | 16'h0007);
      csrset(C_ABSW | C_BBSW);
      peer.send_frame(f);
      repeat (6000) @(posedge clk);
      rd(O_CSR);
      want((q & (C_ABSW | C_BBSW)) == (C_ABSW | C_BBSW),
           "long: PA 7 discards it");

      // ---- 13. Interrupts ---------------------------------------------
      // Level triggered with no acknowledge, purely combinational from the
      // register.  Manual 4.2: an interrupt routine must not leave an
      // interrupt enabled unless it turns around the buffer that caused it.
      wr(O_CSR, C_RST);
      want(int_o == 1'b0, "int: quiet with nothing enabled");

      rd(O_CSR); wr(O_CSR, q | C_AINT);
      @(posedge clk);
      want(int_o == 1'b1, "int: enabling AINT with A in our hands interrupts at once");

      // Both drivers set an ownership bit and its enable in the SAME 16-bit
      // write, so the line has to be evaluated from the post-write state.
      wr(O_CSR, C_ABSW | C_AINT);
      @(posedge clk);
      want(int_o == 1'b0, "int: handing the buffer back in the same write drops the line");

      // Receiving into it raises it again with nothing else written -- which
      // is the whole reason a driver may not leave the enable set.
      build(48'hFF_FF_FF_FF_FF_FF, 48'h02_00_00_00_00_01, 46);
      peer.send_frame(f);
      settle();
      want(int_o == 1'b1, "int: and a received frame raises it again by itself");

      rd(O_CSR); wr(O_CSR, q & ~C_AINT);
      @(posedge clk);
      want(int_o == 1'b0, "int: clearing the enable is enough to drop it");

      // TINT is the same shape from the other side: TBSW clear means the
      // transmitter is idle and the buffer is the host's.
      wr(O_CSR, C_RST);
      rd(O_CSR); wr(O_CSR, q | C_TINT);
      @(posedge clk);
      want(int_o == 1'b1, "int: TINT with an idle transmitter interrupts");

      // ---- 14. JAM is write-one-to-CLEAR ------------------------------
      // The inverse of the ownership bits, in the same register, and the
      // manual states neither.  This card never raises it -- the link is full
      // duplex and mii_col cannot assert -- so the check is that a driver's
      // clear does not accidentally set it.
      wr(O_CSR, C_RST);
      wr(O_CSR, C_JAM);
      rd(O_CSR);
      want((q & C_JAM) == 0, "jam: writing 1 to JAM clears rather than sets it");

      // ---- 15. Every address in the window answers --------------------
      // ecprobe() peeks into a buffer the card owns, so a card-owned buffer
      // that bus-errored would fail the kernel's probe.  Sweep the lot.
      csrset(C_ABSW | C_BBSW | C_TBSW);
      begin
         bit good = 1;
         for (int a = 0; a < 8192; a += 2) begin
            bit o; logic [15:0] qq;
            bus_cycle(EC_BASE + a[19:0], 1'b0, 1'b1, 1'b1, 16'h0, qq, o);
            if (!o) begin
               good = 0;
               $display("       ... +0x%04x did not answer", a);
               break;
            end
         end
         want(good, "window: all 8 KiB acknowledges, buffers the card owns included");
      end

      $display("=== tb_mb_3c400: %0d checks, %0d failed ===", checks, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      #40_000_000;
      $display("FAIL: tb_mb_3c400 timed out");
      $finish;
   end

endmodule
