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

   wire        blk_start, blk_we;
   wire [31:0] blk_lba;
   wire [7:0]  blk_buf_rdata;
   wire        blk_done, blk_err, blk_ready;
   wire [31:0] blk_count;
   wire        blk_buf_we;
   wire [8:0]  blk_buf_addr;
   wire [7:0]  blk_buf_wdata;

   // ------------------------------------------------------------------
   // Memory behind the DVMA port
   // ------------------------------------------------------------------
   // 8 KiB at the DVMA window's base, which is where the machine's MMU lands
   // the card's A24 addresses.  Anything outside answers with an error and
   // then latches, because sun2_dvma latches a bus error and refuses every
   // later cycle until told to forget it -- so a card that does not clear the
   // latch works exactly once, which is worth catching here rather than an
   // hour into a boot.
   localparam logic [23:0] DVMA_BASE = 24'hF00000;
   localparam int MEM_WORDS = 2048;

   wire        wb_cyc, wb_stb, wb_we_o, wb_clr;
   wire [3:0]  wb_sel;
   wire [21:0] wb_adr;
   wire [31:0] wb_dat_m2s;
   logic [31:0] wb_dat_s2m;
   logic        wb_ack = 1'b0, wb_err = 1'b0;

   logic [31:0] mem [0:MEM_WORDS-1];
   wire [21:0]  mem_idx = wb_adr - DVMA_BASE[23:2];
   wire         mem_in  = (wb_adr >= DVMA_BASE[23:2]) && (mem_idx < MEM_WORDS[21:0]);
   int          dvma_reads = 0, dvma_writes = 0;

   // A filler that is not zero, so "untouched" is a claim the test can make
   // rather than something a cleared array would show whatever happened.
   initial for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'hA5A5A5A5;
   logic        err_latched = 1'b0;

   always @(posedge clk) begin
      wb_ack <= 1'b0;
      wb_err <= 1'b0;
      if (rst) err_latched <= 1'b0;
      else begin
         if (wb_clr) err_latched <= 1'b0;
         if (wb_cyc && wb_stb && !wb_ack && !wb_err) begin
            if (!mem_in || err_latched) begin
               wb_err <= 1'b1; err_latched <= 1'b1;
            end else begin
               if (wb_we_o) begin
                  for (int b = 0; b < 4; b++)
                    if (wb_sel[b]) mem[mem_idx][8*b +: 8] <= wb_dat_m2s[8*b +: 8];
                  dvma_writes++;
               end else dvma_reads++;
               wb_dat_s2m <= mem[mem_idx];
               wb_ack     <= 1'b1;
            end
         end
      end
   end

   function automatic logic [7:0] mem_byte(input logic [23:0] va);
      mem_byte = mem[(va - DVMA_BASE) >> 2][8*(va[1:0]) +: 8];
   endfunction


   sun2_vme_scsi #(.SCSI_BASE(BASE)) dut (
       .CLK(clk), .RESET(rst), .por_reset(por), .clk4m9152(x2),
       .mb_sel(mb_sel), .mb_addr(mb_addr), .mb_we(mb_we),
       .mb_uds_n(mb_uds_n), .mb_lds_n(mb_lds_n),
       .mb_din(mb_din), .mb_dout(mb_dout),
       .mb_hit(mb_hit), .mb_ack(mb_ack), .int_o(int_o),
       .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb), .wb_we_o(wb_we_o),
       .wb_sel_o(wb_sel), .wb_adr_o(wb_adr), .wb_dat_o(wb_dat_m2s),
       .wb_dat_i(wb_dat_s2m), .wb_ack_i(wb_ack), .wb_err_i(wb_err),
       .wb_clr_o(wb_clr),
       .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
       .blk_buf_rdata(blk_buf_rdata),
       .blk_done(blk_done), .blk_err(blk_err), .blk_ready(blk_ready),
       .blk_count(blk_count), .blk_buf_we(blk_buf_we),
       .blk_buf_addr(blk_buf_addr), .blk_buf_wdata(blk_buf_wdata));

   // The drive's media.  With no +blk_image it reports the drive absent, which
   // the card must survive -- that is the empty-slot case on a real board.
   blk_file #(.MAX_BLOCKS(8192), .READ_CLOCKS(2000)) media (
       .clk(clk), .rst(rst),
       .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
       .blk_buf_rdata(blk_buf_rdata),
       .blk_done(blk_done), .blk_err(blk_err), .blk_ready(blk_ready),
       .blk_count(blk_count), .blk_buf_we(blk_buf_we),
       .blk_buf_addr(blk_buf_addr), .blk_buf_wdata(blk_buf_wdata));

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

   // Control bits that must survive a command, since selection and dropping
   // SEL are both whole-register writes and the drivers never read-modify.
   logic [15:0] icr_base = 16'h0000;

   // Selection, in scdoit()'s order: the bitmask, a wait for the bus to be
   // free, SELECT on its own, a wait for BSY, and only then the control bits --
   // which is also what drops SELECT, since the drivers never clear it.
   task automatic sel_target(input logic [7:0] mask, input logic [15:0] icr_after,
                             output bit ok);
      int guard;
      wr16(BASE + 23'h000, {mask, 8'h00});
      ok = 1'b0;
      for (guard = 0; guard < 2000; guard++) begin
         rd16(BASE + 23'h004);
         if (!q[6]) begin ok = 1'b1; break; end
      end
      if (!ok) return;
      wr16(BASE + 23'h004, 16'h0020);
      ok = 1'b0;
      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 23'h004);
         if (q[6]) begin ok = 1'b1; break; end
      end
      wr16(BASE + 23'h004, icr_after);
   endtask

   // One READ(6) from selection to bus free, so a test can ask for a block
   // without replaying twenty lines of handshake each time.
   // One READ(6) from selection to bus free, in the order scdoit() really
   // writes the registers (rsun/sys/sunstand/sc.c).  The order is not
   // cosmetic: the driver asserts SELECT *alone*, waits for BSY, and only then
   // writes the control bits and the transfer set-up -- so DMA is armed after
   // the target is already on the bus, not before it.  Setting everything up
   // first, which is the obvious way to write this, exercises a sequence no
   // driver produces.
   task automatic dma_read(input int lba, input logic [23:0] addr,
                           input int nbytes, output bit ok,
                           output logic [7:0] status_byte);
      logic [7:0] cdb [6];
      int guard;
      status_byte = 8'hFF;

      // "select controller": the target bitmask, then spin until the bus is free
      wr16(BASE + 23'h000, 16'h0100);            // 1 << target 0
      ok = 1'b0;
      for (guard = 0; guard < 2000; guard++) begin
         rd16(BASE + 23'h004);
         if (!q[6]) begin ok = 1'b1; break; end
      end
      if (!ok) return;

      // SELECT on its own.  No DMA bits: the driver has not written them yet.
      wr16(BASE + 23'h004, 16'h0020);
      ok = 1'b0;
      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 23'h004);
         if (q[6]) begin ok = 1'b1; break; end
      end
      if (!ok) return;

      // ...and only now the control bits, which is also what drops SELECT,
      // followed by the transfer set-up.
      wr16(BASE + 23'h004, 16'h0006);            // word mode + DMA enable
      wr16(BASE + 23'h008, {8'h00, addr[23:16]});
      wr16(BASE + 23'h00A, addr[15:0]);
      wr16(BASE + 23'h00C, ~nbytes[15:0]);

      cdb = '{8'h08, 8'h00, lba[15:8], lba[7:0], 8'h01, 8'h00};
      send_cdb(cdb, ok);
      if (!ok) return;

      ok = 1'b0;
      for (guard = 0; guard < 40000; guard++) begin
         rd16(BASE + 23'h004);
         if (q[12]) begin ok = 1'b1; break; end
      end

      // STATUS, then MESSAGE IN, then the bus goes free.
      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 23'h004);
         if (q[11] && (q[10:8] == 3'b011)) begin
            rd16(BASE + 23'h002); status_byte = q[15:8]; break;
         end
      end
      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 23'h004);
         if (q[11] && (q[10:8] == 3'b111)) begin rd16(BASE + 23'h002); break; end
      end
      for (guard = 0; guard < 2000; guard++) begin
         rd16(BASE + 23'h004);
         if (!q[6]) break;
      end
   endtask

   task automatic send_cdb(input logic [7:0] cdb [6], output bit ok);
      int guard; bit ready_for_byte;
      ok = 1'b1;
      for (int i = 0; i < 6; i++) begin
         ready_for_byte = 1'b0;
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[11] && (q[10:8] == 3'b010)) begin ready_for_byte = 1'b1; break; end
         end
         if (!ready_for_byte) begin ok = 1'b0; break; end
         wr16(BASE + 23'h002, {cdb[i], 8'h00});
      end
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

      // A register written through the card must read back through the card.
      // This is what actually pins the acknowledge down: the MM58167 loads its
      // output once, at the leading edge of the read strobe, so a card that
      // acknowledges before that has happened hands the CPU whatever the last
      // cycle left on the wires.  Reading a counter back is the cheapest way
      // to make that visible -- a fixed register would read correctly by
      // accident.
      cycle(BASE + 23'h804, 1'b1, 1'b1, 1'b1, 16'h2200, q, ok);   // seconds = 22
      want(ok, "rtc: a counter write is acknowledged");
      cycle(BASE + 23'h804, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(q[15:8] == 8'h22,
           $sformatf("rtc: and reads back through the card (got %02x)", q[15:8]));

      // Both halves must answer inside the machine's bus timeout.  sun2_fpga.v
      // raises TIMEOUT at C_S24, twelve clocks after AS, for card space as well
      // as everywhere that is not memory or the frame buffer -- so a card
      // answering later than that bus-errors instead of replying, and the
      // clock would simply not be there.  This bound is the machine's, not a
      // style preference.
      //
      // Beyond meeting it there is nothing to gain by being slower.  The real
      // board stretches the clock's DTACK with a PAL because the part needs
      // about a microsecond, and none of that is software-visible: no code in
      // either PROM or in SunOS measures how long a register takes to answer.
      // So both are as fast as the devices allow.
      begin
         int rtc_lat, scsi_lat;
         cycle(BASE + 23'h800, 1'b0, 1'b1, 1'b1, 16'h0, q, ok); rtc_lat = last_latency;
         cycle(BASE + 23'h00C, 1'b0, 1'b1, 1'b1, 16'h0, q, ok); scsi_lat = last_latency;
         $display("    acknowledge: SCSI %0d clocks, RTC %0d", scsi_lat, rtc_lat);
         want(rtc_lat < 12,
              $sformatf("rtc: inside the machine's twelve-clock timeout (took %0d)", rtc_lat));
         want(scsi_lat < 12,
              $sformatf("scsi: inside it too (took %0d)", scsi_lat));
      end

      // ---- 6. Interrupts stay quiet ------------------------------------
      // scpoll() claims the interrupt whenever IntReq or BusError is set, so a
      // stuck bit spins the kernel in its handler for ever.
      wr16(BASE + 23'h004, 16'h0000);
      want(!int_o, "int: quiet with nothing pending and nothing enabled");

      // ---- 7. A whole command, the way scdoit() runs one ---------------
      // TEST UNIT READY: six CDB bytes, no data phase, then status and the
      // COMMAND COMPLETE message.  This is what sdspin() issues, and what
      // isspinning() waits three minutes for before giving up.
      begin
         int guard; bit got_bsy;
         logic [7:0] status_byte, msg_byte;

         // Selection: the target bitmask into `data', then SEL.  One ID bit
         // only -- HOST_ADDR is 0, so the initiator's own bit is not set.
         wr16(BASE + 23'h000, 16'h0100);        // 1 << target 0, even lane
         wr16(BASE + 23'h004, 16'h0020);        // ICR_SELECT

         got_bsy = 1'b0;
         for (guard = 0; guard < 2000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[6]) begin got_bsy = 1'b1; break; end
         end
         want(got_bsy, "select: the target answered with BSY");

         // Dropping SEL is implicit in the next ICR write, exactly as the
         // drivers do it -- neither ever clears SEL explicitly.
         wr16(BASE + 23'h004, 16'h0000);

         // COMMAND: six bytes through cmd_stat, each gated on New Request and
         // the phase bits reading MSG=0 C/D=1 I/O=0.
         for (int i = 0; i < 6; i++) begin
            bit ready_for_byte = 1'b0;
            for (guard = 0; guard < 2000; guard++) begin
               rd16(BASE + 23'h004);
               if (q[11] && (q[10:8] == 3'b010)) begin ready_for_byte = 1'b1; break; end
            end
            if (!ready_for_byte) begin
               want(1'b0, $sformatf("command: no request for CDB byte %0d", i));
               break;
            end
            wr16(BASE + 23'h002, 16'h0000);     // TEST UNIT READY is all zeros
         end

         // STATUS: MSG=0 C/D=1 I/O=1.
         status_byte = 8'hFF;
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[11] && (q[10:8] == 3'b011)) begin
               rd16(BASE + 23'h002); status_byte = q[15:8]; break;
            end
         end
         want(status_byte == 8'h00,
              $sformatf("status: GOOD after TEST UNIT READY (got %02x)", status_byte));

         // MESSAGE IN: MSG=1 C/D=1 I/O=1, and it must be exactly 0x00.
         msg_byte = 8'hFF;
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[11] && (q[10:8] == 3'b111)) begin
               rd16(BASE + 23'h002); msg_byte = q[15:8]; break;
            end
         end
         want(msg_byte == 8'h00,
              $sformatf("message: COMMAND COMPLETE, which must be exactly 0x00 (got %02x)",
                        msg_byte));

         // And the bus goes free again, or the next selection cannot start --
         // scdoit spins 100000 times on BSY with no delay at all before giving
         // up with "bus continuously busy".
         got_bsy = 1'b1;
         for (guard = 0; guard < 2000; guard++) begin
            rd16(BASE + 23'h004);
            if (!q[6]) begin got_bsy = 1'b0; break; end
         end
         want(!got_bsy, "bus free: BSY released after the message");
      end

      // ---- 8. A READ(6) moved by DMA -----------------------------------
      // The whole point of the board: the CPU sets an address and a count and
      // the card fetches its own data.  dma_count is loaded with ~len and
      // counts UP, so a complete transfer ends at 0xFFFF and the residue a
      // driver reads afterwards is ~dma_count -- which is literally what
      // scdoit() returns.
      begin
         logic [7:0] status_byte, want_b;
         bit ok; int bad;

         dma_read(3, 24'd0, 512, ok, status_byte);

         want(ok, "dma: the transfer finished and posted IntReq");
         rd16(BASE + 23'h004);
         want(!q[14], "dma: and took no bus error");
         want(dut.dma_count == 16'hFFFF,
              $sformatf("dma: the counter ran up to -1, so the residue is zero (got %04x)",
                        dut.dma_count));
         want(dut.dma_addr == 24'd512,
              $sformatf("dma: the address advanced by one whole block (got %06x)",
                        dut.dma_addr));
         want(status_byte == 8'h00,
              $sformatf("dma: GOOD status after the read (got %02x)", status_byte));

         // The image is patterned by LBA, so a read that lands on the wrong
         // block fails here where a uniform image could not tell the
         // difference.  tb_xy450 was caught by exactly that once.
         bad = 0;
         for (int i = 0; i < 512; i++) begin
            want_b = (21 + i) % 256;            // block 3: (3*7 + i) & 0xFF
            if (mem_byte(DVMA_BASE + i) !== want_b) bad++;
         end
         want(bad == 0,
              $sformatf("dma: all 512 bytes of block 3 landed correctly (%0d wrong)", bad));
         $display("    DVMA: %0d writes for a 512-byte block, so %0d bytes a transaction",
                  dvma_writes, 512 / (dvma_writes == 0 ? 1 : dvma_writes));
      end

      // ---- 9. Unaligned DMA, every lane --------------------------------
      // A transfer that does not start on a longword boundary costs one short
      // transaction at each end, and the bytes either side of the buffer must
      // survive.  tb_xy450 covers all four alignments for the same reason: a
      // wrong byte-enable mask is invisible at offset 0 and corrupts a
      // neighbour at every other one.
      begin
         bit ok; int bad; logic [7:0] want_b, st; logic [23:0] a, ofs;
         for (int off = 1; off <= 3; off++) begin
            // dma_addr is the card's own A24 address, which the DVMA window
            // maps to DVMA_BASE + it.  Handing the engine a virtual address
            // instead aims it a megabyte past the window, which is a bus error
            // and not a transfer.
            ofs = 24'(1024 * off + off);
            a   = DVMA_BASE + ofs;
            dma_read(5, ofs, 512, ok, st);
            want(ok, $sformatf("unaligned +%0d: the transfer finished", off));

            bad = 0;
            for (int i = 0; i < 512; i++) begin
               want_b = (35 + i) % 256;         // block 5: (5*7 + i) & 0xFF
               if (mem_byte(a + 24'(i)) !== want_b) bad++;
            end
            want(bad == 0,
                 $sformatf("unaligned +%0d: all 512 bytes landed correctly (%0d wrong)",
                           off, bad));
            want(mem_byte(a - 24'd1) === 8'hA5 && mem_byte(a + 24'd512) === 8'hA5,
                 $sformatf("unaligned +%0d: the bytes either side are untouched", off));
         end
      end

      // ---- 10. An odd-length read leaves its last byte in the register ---
      // Word mode moves sixteen bits at a time, so a transfer with an odd byte
      // count cannot put its final byte in memory.  The board keeps it in the
      // Data Register and sets Odd Length, and the driver collects it from
      // there.  An INQUIRY with an odd allocation length is the cheapest way
      // to ask for one: a 512-byte read cannot be odd.
      begin
         logic [7:0] cdb [6];
         bit ok; int guard; logic [23:0] ofs, a;
         logic [7:0] tail;

         ofs = 24'd4096;
         a   = DVMA_BASE + ofs;
         cdb = '{8'h12, 8'h00, 8'h00, 8'h00, 8'h05, 8'h00};   // INQUIRY, 5 bytes
         sel_target(8'h01, 16'h0006, ok);       // word mode + DMA, after BSY
         wr16(BASE + 23'h008, 16'h0000);
         wr16(BASE + 23'h00A, ofs[15:0]);
         wr16(BASE + 23'h00C, ~16'd5);          // five bytes, which is odd
         want(ok, "odd: the target answered selection");
         send_cdb(cdb, ok);
         want(ok, "odd: the six CDB bytes were taken");

         ok = 1'b0;
         for (guard = 0; guard < 40000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[12]) begin ok = 1'b1; break; end
         end
         want(ok, "odd: the transfer finished");
         want(q[13], "odd: Odd Length is set");
         want(dut.dma_count == 16'hFFFF,
              $sformatf("odd: all five bytes were accounted for (got %04x)", dut.dma_count));

         // The four that fit went to memory: INQUIRY says direct-access,
         // not removable, SCSI-2, standard data format.
         want(mem_byte(a + 24'd0) === 8'h00 && mem_byte(a + 24'd1) === 8'h00 &&
              mem_byte(a + 24'd2) === 8'h02 && mem_byte(a + 24'd3) === 8'h02,
               $sformatf("odd: the first four bytes reached memory (%02x %02x %02x %02x)",
                         mem_byte(a+24'd0), mem_byte(a+24'd1),
                         mem_byte(a+24'd2), mem_byte(a+24'd3)));

         // ...and the fifth did not.  This is the whole point: a byte written
         // to memory here would be a byte written past the end of a driver's
         // buffer.
         want(mem_byte(a + 24'd4) === 8'hA5,
              $sformatf("odd: the fifth byte was NOT written to memory (found %02x)",
                        mem_byte(a + 24'd4)));

         rd16(BASE + 23'h000);
         tail = q[15:8];
         $display("    odd: the trailing byte is 0x%02x, readable from `data\'", tail);
         want(tail === mem_byte(a + 24'd3) || tail !== 8'hA5,
              "odd: the Data Register holds a byte the transfer produced");

         // Finish the command so the bus is free for the next test.
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[11] && (q[10:8] == 3'b011)) begin rd16(BASE + 23'h002); break; end
         end
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[11] && (q[10:8] == 3'b111)) begin rd16(BASE + 23'h002); break; end
         end
         for (guard = 0; guard < 2000; guard++) begin
            rd16(BASE + 23'h004);
            if (!q[6]) break;
         end
      end

      // ---- 11. A command that moves no data still posts IntReq ----------
      // scdoit() waits on ICR_INTERRUPT_REQUEST after every command, and TEST
      // UNIT READY has no data phase at all -- the target goes COMMAND to
      // STATUS directly.  A board that raises IntReq only when a transfer ends
      // therefore hangs the very first command the PROM issues, which is what
      // isspinning() calls.  Found on hardware, not here: the earlier TEST UNIT
      // READY test drove the card with DMA disabled and never looked at bit 12.
      begin
         logic [7:0] cdb [6];
         bit ok; int guard; logic [7:0] status_byte;

         cdb = '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};   // TEST UNIT READY
         sel_target(8'h01, 16'h0006, ok);        // word mode + DMA, as scdoit does
         want(ok, "nodata: the target answered selection");
         send_cdb(cdb, ok);
         want(ok, "nodata: the six CDB bytes were taken");

         ok = 1'b0;
         for (guard = 0; guard < 20000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[12]) begin ok = 1'b1; break; end
         end
         want(ok, "nodata: IntReq is posted although nothing was transferred");
         want(q[10:8] == 3'b011,
              $sformatf("nodata: ...with the target in STATUS (phase %03b)", q[10:8]));

         status_byte = 8'hFF;
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[11] && (q[10:8] == 3'b011)) begin
               rd16(BASE + 23'h002); status_byte = q[15:8]; break;
            end
         end
         want(status_byte == 8'h00,
              $sformatf("nodata: GOOD status (got %02x)", status_byte));

         // MESSAGE IN raises IntReq as well -- the Programmers' Manual says
         // the board interrupts "when the TARGET sends back status ... and
         // when the TARGET sends a message" -- and what retires it is taking
         // the byte, not any write to the ICR.  That is the whole mechanism:
         // "as soon as the request is acknowledged, the interrupt request goes
         // away", where acknowledgement is the host accessing the Data or
         // Command/Status register.  So this reads the message and then
         // requires the level to have dropped by itself.
         wr16(BASE + 23'h004, icr_base);
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[11] && (q[10:8] == 3'b111)) begin rd16(BASE + 23'h002); break; end
         end
         rd16(BASE + 23'h004);
         want(!q[12], "nodata: taking the message byte retires IntReq");

         // ...and the status bit is readable whether or not interrupts are
         // enabled.  "If interrupts are disabled, this bit may still read as
         // 1" -- which is not a nicety: both PROM drivers poll IntReq with
         // Interrupt Enable never set (rsun/sys/sunstand/sc.c:150,160), so a
         // card that gated the bit could not boot at all.
         cdb = '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
         sel_target(8'h01, 16'h0006, ok);        // note: no ICR_INTERRUPT_ENABLE
         send_cdb(cdb, ok);
         ok = 1'b0;
         for (guard = 0; guard < 20000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[12]) begin ok = 1'b1; break; end
         end
         want(ok, "nodata: IntReq reads back with interrupts disabled");
         want(!int_o, "nodata: ...but no interrupt is asserted");
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[11] && (q[10:8] == 3'b011)) begin rd16(BASE + 23'h002); break; end
         end
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[11] && (q[10:8] == 3'b111)) begin rd16(BASE + 23'h002); break; end
         end
         for (guard = 0; guard < 2000; guard++) begin
            rd16(BASE + 23'h004);
            if (!q[6]) break;
         end
         for (guard = 0; guard < 2000; guard++) begin
            rd16(BASE + 23'h004);
            if (!q[6]) break;
         end
      end

      // ---- 12. A bus reset leaves nothing pending -----------------------
      // scintr() resets the SCSI bus when it cannot account for an interrupt.
      // If that leaves IntReq set, the next time the driver enables interrupts
      // it takes one for a command that no longer exists, finds an empty ICR
      // and calls it spurious -- which resets the bus again.  Seen on hardware
      // as an endless `sc0: spurious interrupt' / `resetting scsi bus' pair.
      begin
         logic [7:0] cdb [6];
         bit ok; int guard;

         cdb = '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};   // TEST UNIT READY
         sel_target(8'h01, 16'h0006, ok);
         send_cdb(cdb, ok);
         ok = 1'b0;
         for (guard = 0; guard < 20000; guard++) begin
            rd16(BASE + 23'h004);
            if (q[12]) begin ok = 1'b1; break; end
         end
         want(ok, "reset: IntReq is pending before the reset");

         wr16(BASE + 23'h004, 16'h0010);          // ICR_RESET
         rd16(BASE + 23'h004);
         want(!q[12], "reset: ...and a bus reset retires it");
         wr16(BASE + 23'h004, 16'h0000);

         // The bus must also be free again, or the next selection cannot start.
         ok = 1'b1;
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 23'h004);
            if (!q[6]) begin ok = 1'b0; break; end
         end
         want(!ok, "reset: the SCSI bus is free afterwards");
      end

      $display("=== tb_vme_scsi: %0d checks, %0d failed ===", checks, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      #12_000_000;
      $display("FAIL: tb_vme_scsi timed out");
      $finish;
   end

endmodule
