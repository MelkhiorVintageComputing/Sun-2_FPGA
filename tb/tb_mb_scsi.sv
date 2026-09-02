`timescale 1ns / 1ps

//
// sun2_mb_scsi: what the MultiBus packaging adds, and only that.
//
// The SCSI engine is rtl/sun2-common/sun2_scsi_core.sv, shared with the VME
// board, and `make -C sim vmescsi' is its test -- 59 checks covering the odd
// tail, the DVMA chunking, the bus-error latch and its RST clear, and the whole
// of scdoit()'s select/CDB/DMA/status/message replay.  **None of that is
// repeated here.**  Two testbenches that both grow toward covering the same
// engine end up as copies of each other, and then neither is maintained.
//
// What is here is what only this card can get wrong:
//
//   * a 16 KiB window of three 2 KiB pages, where the VME board has 4 KiB of
//     two, and the neighbours it must not swallow;
//   * a 20-bit DMA address where the VME board has 24, including the wrap that
//     follows from it and that the VME card cannot produce at all;
//   * no interrupt vector -- which does not mean the register faults;
//   * the interrupt as a level, watchable here and nowhere else.
//
// plus one end-to-end READ(6) as an integration smoke test, because a card can
// pass every decode check and still not be wired to its own engine.
//
module tb_mb_scsi;

   // sc0.  conf.sun2/GENERIC:59 -- and what the PROM reaches through the
   // 0xEE2800 alias page that msun/mon/kernel/sunmon.c:168-171 maps here.
   localparam logic [19:0] BASE = 20'h80000;
   localparam int CLK_HALF = 30;                  // 16.667 MHz

   logic clk = 1'b0, rst = 1'b1;
   always #(CLK_HALF) clk = ~clk;

   logic        mb_sel = 1'b0, mb_we = 1'b0;
   logic        mb_uds_n = 1'b1, mb_lds_n = 1'b1;
   logic [19:0] mb_addr = '0;
   logic [15:0] mb_din  = '0;
   wire  [15:0] mb_dout;
   wire         mb_hit, mb_ack, int_o, scc_int_o;

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
   // Two windows, not one, and the second is the point.  A 20-bit DMA address
   // wraps from 0xFFFFF to 0, so a transfer that runs off the end of MultiBus
   // memory reappears at the bottom of it -- and to see that land rather than
   // merely to see the register wrap, there has to be memory at both ends.
   // The VME card cannot produce this case at any address, so nothing in
   // tb_vme_scsi covers it.
   localparam logic [23:0] DVMA_BASE = 24'hF00000;
   localparam int MEM_WORDS = 8192;               // 32 KiB at the bottom
   localparam int TOP_WORDS = 512;                // 2 KiB at the very top

   wire        wb_cyc, wb_stb, wb_we_o, wb_clr;
   wire [3:0]  wb_sel;
   wire [21:0] wb_adr;
   wire [31:0] wb_dat_m2s;
   logic [31:0] wb_dat_s2m;
   logic        wb_ack = 1'b0, wb_err = 1'b0;

   logic [31:0] mem [0:MEM_WORDS-1];
   logic [31:0] top [0:TOP_WORDS-1];

   // The bottom window starts at DVMA_BASE; the top one ends at 0xFFFFFF.
   localparam logic [21:0] TOP_FIRST = 22'h3FFF80;   // (0x1000000 - 2048) >> 2

   wire [21:0] mem_idx = wb_adr - DVMA_BASE[23:2];
   wire        mem_in  = (wb_adr >= DVMA_BASE[23:2]) && (mem_idx < MEM_WORDS[21:0]);
   wire [21:0] top_idx = wb_adr - TOP_FIRST;
   wire        top_in  = (wb_adr >= TOP_FIRST);

   int         dvma_reads = 0, dvma_writes = 0;

   // A filler that is not zero, so "untouched" is a claim the test can make
   // rather than something a cleared array would show whatever happened.
   initial begin
      for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'hA5A5A5A5;
      for (int i = 0; i < TOP_WORDS; i++) top[i] = 32'hA5A5A5A5;
   end
   logic       err_latched = 1'b0;

   // How long memory takes to answer.  The default of one clock is not what the
   // machine has: `make -C sim migddr3' measures a Wishbone read at 7 CPU
   // clocks through DDR3, and the frame buffer's timeout race needed 13 before
   // it would show at all.  A DMA engine that is correct against a one-cycle
   // memory and wrong against a slow one is a class of bug this tree has been
   // bitten by before, so the latency is a knob and the write tests use it.
   int mem_latency = 0;
   int mem_wait = 0;

   always @(posedge clk) begin
      wb_ack <= 1'b0;
      wb_err <= 1'b0;
      if (rst) begin err_latched <= 1'b0; mem_wait <= 0; end
      else begin
         if (wb_clr) err_latched <= 1'b0;
         if (wb_cyc && wb_stb && !wb_ack && !wb_err && mem_wait < mem_latency) begin
            mem_wait <= mem_wait + 1;
         end else if (!(wb_cyc && wb_stb)) begin
            mem_wait <= 0;
         end else if (wb_cyc && wb_stb && !wb_ack && !wb_err) begin
            mem_wait <= 0;
            if (!(mem_in || top_in) || err_latched) begin
               wb_err <= 1'b1; err_latched <= 1'b1;
            end else begin
               if (wb_we_o) begin
                  for (int b = 0; b < 4; b++)
                    if (wb_sel[b]) begin
                       if (mem_in) mem[mem_idx][8*b +: 8] <= wb_dat_m2s[8*b +: 8];
                       else        top[top_idx][8*b +: 8] <= wb_dat_m2s[8*b +: 8];
                    end
                  dvma_writes++;
               end else dvma_reads++;
               wb_dat_s2m <= mem_in ? mem[mem_idx] : top[top_idx];
               wb_ack     <= 1'b1;
            end
         end
      end
   end

   function automatic logic [7:0] mem_byte(input logic [23:0] va);
      if (va >= DVMA_BASE && va < DVMA_BASE + 24'(MEM_WORDS*4))
        mem_byte = mem[(va - DVMA_BASE) >> 2][8*(va[1:0]) +: 8];
      else
        mem_byte = top[(va - {TOP_FIRST, 2'b00}) >> 2][8*(va[1:0]) +: 8];
   endfunction

   sun2_mb_scsi #(.MB_SCSI_BASE(BASE)) dut (
       .CLK(clk), .RESET(rst),
       .mb_sel(mb_sel), .mb_addr(mb_addr), .mb_we(mb_we),
       .mb_uds_n(mb_uds_n), .mb_lds_n(mb_lds_n),
       .mb_din(mb_din), .mb_dout(mb_dout),
       .mb_hit(mb_hit), .mb_ack(mb_ack),
       .int_o(int_o), .scc_int_o(scc_int_o),
       .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb), .wb_we_o(wb_we_o),
       .wb_sel_o(wb_sel), .wb_adr_o(wb_adr), .wb_dat_o(wb_dat_m2s),
       .wb_dat_i(wb_dat_s2m), .wb_ack_i(wb_ack), .wb_err_i(wb_err),
       .wb_clr_o(wb_clr),
       .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
       .blk_buf_rdata(blk_buf_rdata),
       .blk_done(blk_done), .blk_err(blk_err), .blk_ready(blk_ready),
       .blk_count(blk_count), .blk_buf_we(blk_buf_we),
       .blk_buf_addr(blk_buf_addr), .blk_buf_wdata(blk_buf_wdata));

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

   // A MultiBus cycle as sun2_fpga presents one.  ok = 0 is a timeout, which
   // the machine turns into the bus error peek() catches.
   localparam int ACK_LIMIT = 12;      // the machine's own C_S24 bound
   task automatic cycle(input logic [19:0] a, input bit we,
                        input bit uds, input bit lds, input logic [15:0] d,
                        output logic [15:0] qq, output bit ok);
      int guard;
      begin
         @(posedge clk);
         mb_addr <= a; mb_we <= we; mb_uds_n <= ~uds; mb_lds_n <= ~lds;
         mb_din <= d; mb_sel <= 1'b1;
         ok = 1'b0; qq = 16'hXXXX;
         for (guard = 0; guard < ACK_LIMIT; guard++) begin
            @(posedge clk);
            if (mb_hit && mb_ack) begin qq = mb_dout; ok = 1'b1; break; end
         end
         @(negedge clk);
         mb_sel <= 1'b0; mb_we <= 1'b0; mb_uds_n <= 1'b1; mb_lds_n <= 1'b1;
         @(posedge clk);
      end
   endtask

   logic [15:0] q; bit ok;
   task automatic wr16(input logic [19:0] a, input logic [15:0] d);
      bit o; logic [15:0] junk;
      cycle(a, 1'b1, 1'b1, 1'b1, d, junk, o);
      if (!o) begin $display("FAIL: write to 0x%05x not acknowledged", a); fail++; end
   endtask
   task automatic rd16(input logic [19:0] a);
      cycle(a, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      if (!ok) begin $display("FAIL: read of 0x%05x not acknowledged", a); fail++; end
   endtask

   task automatic send_cdb(input logic [7:0] cdb [6], output bit ok);
      int guard; bit ready_for_byte;
      ok = 1'b1;
      for (int i = 0; i < 6; i++) begin
         ready_for_byte = 1'b0;
         for (guard = 0; guard < 4000; guard++) begin
            rd16(BASE + 20'h004);
            if (q[11] && (q[10:8] == 3'b010)) begin ready_for_byte = 1'b1; break; end
         end
         if (!ready_for_byte) begin ok = 1'b0; break; end
         wr16(BASE + 20'h002, {cdb[i], 8'h00});
      end
   endtask

   // One READ(6) in scdoit()'s register order: the bitmask, a wait for the bus
   // to be free, SELECT alone, a wait for BSY, and only then the control bits
   // and the transfer set-up.  The order is not cosmetic -- DMA is armed after
   // the target is already on the bus, not before it.
   task automatic dma_read(input int lba, input logic [19:0] addr,
                           input int nbytes, output bit ok,
                           output logic [7:0] status_byte);
      logic [7:0] cdb [6];
      int guard;
      status_byte = 8'hFF;

      wr16(BASE + 20'h000, 16'h0100);            // 1 << target 0
      ok = 1'b0;
      for (guard = 0; guard < 2000; guard++) begin
         rd16(BASE + 20'h004);
         if (!q[6]) begin ok = 1'b1; break; end
      end
      if (!ok) return;

      wr16(BASE + 20'h004, 16'h0020);            // SELECT alone
      ok = 1'b0;
      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 20'h004);
         if (q[6]) begin ok = 1'b1; break; end
      end
      if (!ok) return;

      wr16(BASE + 20'h004, 16'h0006);            // word mode + DMA enable
      wr16(BASE + 20'h008, {12'h000, addr[19:16]});
      wr16(BASE + 20'h00A, addr[15:0]);
      wr16(BASE + 20'h00C, ~nbytes[15:0]);

      cdb = '{8'h08, 8'h00, lba[15:8], lba[7:0], 8'((nbytes+511)/512), 8'h00};
      send_cdb(cdb, ok);
      if (!ok) return;

      ok = 1'b0;
      for (guard = 0; guard < 40000; guard++) begin
         rd16(BASE + 20'h004);
         if (q[12]) begin ok = 1'b1; break; end
      end

      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 20'h004);
         if (q[11] && (q[10:8] == 3'b011)) begin
            rd16(BASE + 20'h002); status_byte = q[15:8]; break;
         end
      end
      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 20'h004);
         if (q[11] && (q[10:8] == 3'b111)) begin rd16(BASE + 20'h002); break; end
      end
      for (guard = 0; guard < 2000; guard++) begin
         rd16(BASE + 20'h004);
         if (!q[6]) break;
      end
   endtask

   // WRITE(6).  Identical to dma_read but for the opcode -- the board has no
   // direction bit anywhere, so the engine reads the SCSI I/O line and follows
   // it, and a driver that set a transfer up the wrong way round would simply
   // move data the other way.
   task automatic dma_write(input int lba, input logic [19:0] addr,
                            input int nbytes, output bit ok,
                            output logic [7:0] status_byte);
      logic [7:0] cdb [6];
      int guard;
      status_byte = 8'hFF;

      wr16(BASE + 20'h000, 16'h0100);
      ok = 1'b0;
      for (guard = 0; guard < 2000; guard++) begin
         rd16(BASE + 20'h004);
         if (!q[6]) begin ok = 1'b1; break; end
      end
      if (!ok) return;

      wr16(BASE + 20'h004, 16'h0020);
      ok = 1'b0;
      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 20'h004);
         if (q[6]) begin ok = 1'b1; break; end
      end
      if (!ok) return;

      wr16(BASE + 20'h004, 16'h0006);            // word mode + DMA enable
      wr16(BASE + 20'h008, {12'h000, addr[19:16]});
      wr16(BASE + 20'h00A, addr[15:0]);
      wr16(BASE + 20'h00C, ~nbytes[15:0]);

      cdb = '{8'h0A, 8'h00, lba[15:8], lba[7:0], 8'((nbytes+511)/512), 8'h00};
      send_cdb(cdb, ok);
      if (!ok) return;

      ok = 1'b0;
      for (guard = 0; guard < 40000; guard++) begin
         rd16(BASE + 20'h004);
         if (q[12]) begin ok = 1'b1; break; end
      end

      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 20'h004);
         if (q[11] && (q[10:8] == 3'b011)) begin
            rd16(BASE + 20'h002); status_byte = q[15:8]; break;
         end
      end
      for (guard = 0; guard < 4000; guard++) begin
         rd16(BASE + 20'h004);
         if (q[11] && (q[10:8] == 3'b111)) begin rd16(BASE + 20'h002); break; end
      end
      for (guard = 0; guard < 2000; guard++) begin
         rd16(BASE + 20'h004);
         if (!q[6]) break;
      end
   endtask

   bit gok;
   logic [7:0] status;

   initial begin
      $display("=== tb_mb_scsi: the Sun-2 MultiBus SCSI host adapter ===");
      repeat (4) @(posedge clk);
      rst = 1'b0;
      repeat (4) @(posedge clk);

      // ---------------------------------------------------------------
      // 1. The probe, at the address the software actually uses
      // ---------------------------------------------------------------
      // The entire existence test, in both the PROM and the kernel: write
      // 0x6789 to dma_count and read it back (sunstand/sd.c:61-70,
      // sundev/sc.c:79-86).
      wr16(BASE + 20'h00C, 16'h6789);
      rd16(BASE + 20'h00C);
      want(q == 16'h6789, "probe: dma_count reads back 0x6789 at 0x8000C");

      // ---------------------------------------------------------------
      // 2. The window, and the neighbours it must not swallow
      // ---------------------------------------------------------------
      // 16 KiB, so the last address inside is 0x83FFE.  The registers alias
      // every sixteen bytes across page 0 only.
      cycle(20'h8000C + 20'h010, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(ok && q == 16'h6789, "alias: the registers repeat every 16 bytes");

      // sc1 is a *different card*.  A window decoded one bit too wide covers
      // it, and the machine then boots from an address the kernel calls sc1
      // while thinking it is sc0 -- which still works, and is wrong.
      cycle(20'h8400C, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(!ok, "0x8400C does not answer: that is sc1, a second board");

      // ie0 lives at 0x88000 (GENERIC:95).  A card that answers there makes
      // autoconfig hallucinate an Ethernet -- the exact failure this tree
      // already hit once with the 3Com.
      cycle(20'h88000, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(!ok, "0x88000 does not answer: that is ie0");

      cycle(20'h7FFFE, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(!ok, "the word below the window does not answer");

      // ---------------------------------------------------------------
      // 3. The two SCC pages
      // ---------------------------------------------------------------
      // They must *answer*.  XACK is gated by the board select and not by the
      // page -- Theory of Operation 4.3 -- and a bus error here would make a
      // later zs2 probe read as a missing chip rather than as a silent one.
      cycle(BASE + 20'h800, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(ok, "page 1 (+0x800, zs2) acknowledges");
      want(q == 16'h0000, "page 1 reads as zero until the SCC is fitted");

      cycle(BASE + 20'h1000, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(ok, "page 2 (+0x1000, zs3) acknowledges");

      cycle(BASE + 20'h3FFE, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(ok, "the top of the 16 KiB window still acknowledges");

      // A write into an SCC page must not reach the SCSI registers.
      wr16(BASE + 20'h80C, 16'hBEEF);
      rd16(BASE + 20'h00C);
      want(q == 16'h6789, "a write to page 1 does not reach dma_count");

      // ---------------------------------------------------------------
      // 4. Byte lanes
      // ---------------------------------------------------------------
      // dma_addr assembles from three writes: the high word takes the odd
      // byte, the low word takes both.
      wr16(BASE + 20'h008, 16'h0002);
      wr16(BASE + 20'h00A, 16'h3456);
      rd16(BASE + 20'h00A);
      want(q == 16'h3456, "dma_addr: the low word assembles");
      rd16(BASE + 20'h008);
      want(q == 16'h0002, "dma_addr: the high nibble assembles");

      // peekc() reads dma_count a byte at a time first (sundev/sc.c:79), with
      // LDS alone.  A card that needs both strobes reports no controller.
      wr16(BASE + 20'h00C, 16'h1234);
      cycle(BASE + 20'h00C, 1'b0, 1'b0, 1'b1, 16'h0, q, ok);
      want(ok && q[7:0] == 8'h34, "peekc: a single-byte read on LDS alone works");

      // ...and the register file is not byte-swapped.  Byte-swapping on this
      // machine is a property of the Ethernet card's page map, not of MultiBus,
      // and a card that swapped here would put the target bitmask in the wrong
      // half of `data' and never select anything.
      wr16(BASE + 20'h00C, 16'hAA55);
      rd16(BASE + 20'h00C);
      want(q == 16'hAA55, "the register window is not byte-swapped");

      // ---------------------------------------------------------------
      // 5. Twenty bits of DMA address, not twenty-four
      // ---------------------------------------------------------------
      // "Since the Multibus addressing is only 20 bits, only the lower 4 bits
      // of this register are actually used" -- Programmers' Manual p8.  The
      // standalone driver agrees by masking: `har->dma_addr = (int)dmaddr &
      // 0xFFFFF' (sunstand/sc.c:84).
      wr16(BASE + 20'h008, 16'h00FF);
      rd16(BASE + 20'h008);
      want(q == 16'h000F, "dma_addr high word keeps four bits, not eight");

      // ---------------------------------------------------------------
      // 6. No interrupt vector -- and no bus error either
      // ---------------------------------------------------------------
      // scattach() writes it on this machine too, with AUTOBASE + 2 = 0x1A
      // (sundev/sc.c:164).  A card that faulted there would kill autoconfig.
      cycle(BASE + 20'h00E, 1'b1, 1'b1, 1'b1, 16'h001A, q, ok);
      want(ok, "a write to intvec is acknowledged on MultiBus");
      rd16(BASE + 20'h00E);
      want(q == 16'h0000, "...and reads back zero: there is no vector here");

      // ---------------------------------------------------------------
      // 7. Interrupts are quiet, and are a level
      // ---------------------------------------------------------------
      want(int_o == 1'b0, "int_o is low with nothing going on");
      want(scc_int_o == 1'b0, "scc_int_o is low: no SCCs fitted yet");

      // ---------------------------------------------------------------
      // 8. One READ(6), end to end
      // ---------------------------------------------------------------
      // The integration check: a card can pass every decode test above and
      // still not be wired to its own engine.
      wr16(BASE + 20'h004, 16'h0000);
      dma_read(3, 20'h00400, 512, gok, status);
      want(gok, "READ(6): the transfer completed");
      want(status == 8'h00, $sformatf("READ(6): status is GOOD (got %02x)", status));
      if (gok) begin
         bit good = 1'b1;
         for (int i = 0; i < 512; i++)
           if (mem_byte(DVMA_BASE + 24'h000400 + i) != 8'((3*7 + i) & 8'hFF))
             good = 1'b0;
         want(good, "READ(6): all 512 bytes match the image");
         rd16(BASE + 20'h00C);
         want(q == 16'hFFFF, "READ(6): the count ran out to -1");
      end

      // ---------------------------------------------------------------
      // 9. The 20-bit wrap
      // ---------------------------------------------------------------
      // A transfer that runs off the end of MultiBus memory reappears at the
      // bottom of it, because the address register is twenty bits and so is
      // the counter that walks it.  The VME card cannot produce this case at
      // any address, so this is the one behaviour here with no coverage
      // anywhere else in the tree.
      wr16(BASE + 20'h004, 16'h0010);   // RST: forget the DVMA error latch
      wr16(BASE + 20'h004, 16'h0000);
      for (int i = 0; i < TOP_WORDS; i++) top[i] = 32'hA5A5A5A5;
      for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'hA5A5A5A5;

      dma_read(5, 20'hFFFFC, 8, gok, status);
      want(gok, "wrap: the transfer completed across 0xFFFFF");
      if (gok) begin
         bit wrapped = 1'b1;
         // The first four bytes land at the very top...
         for (int i = 0; i < 4; i++)
           if (mem_byte(24'hFFFFFC + i) != 8'((5*7 + i) & 8'hFF)) wrapped = 1'b0;
         want(wrapped, "wrap: the first four bytes land at 0xFFFFFC");
         // ...and the next four at the bottom of the window, not past the end.
         wrapped = 1'b1;
         for (int i = 0; i < 4; i++)
           if (mem_byte(DVMA_BASE + i) != 8'((5*7 + 4 + i) & 8'hFF)) wrapped = 1'b0;
         want(wrapped, "wrap: the next four wrap to MultiBus address 0");
      end

      // ---------------------------------------------------------------
      // 10. WRITE(6) -- the memory-to-target direction
      // ---------------------------------------------------------------
      // The DMA engine's D_FETCH/D_OUT/D_OUTACK states run only on a write,
      // and until this test **nothing in the tree exercised them on either
      // card** -- tb_vme_scsi has no WRITE(6) either, so the whole direction
      // shipped untested.  A machine that reads its disk perfectly and damages
      // it whenever it writes is exactly what that gap looks like from outside.
      wr16(BASE + 20'h004, 16'h0010);   // RST: clear any latched DVMA error
      wr16(BASE + 20'h004, 16'h0000);

      // A pattern that is not the image's own, so a read-back that silently
      // returned the old contents cannot pass.
      for (int i = 0; i < 512; i++)
        mem[(20'h00800 >> 2) + (i >> 2)][8*(i[1:0]) +: 8] = 8'((i*3 + 8'h5A) & 8'hFF);

      dma_write(20, 20'h00800, 512, gok, status);
      want(gok, "WRITE(6): the transfer completed");
      want(status == 8'h00, $sformatf("WRITE(6): status is GOOD (got %02x)", status));

      if (gok) begin
         bit same = 1'b1;
         dma_read(20, 20'h00C00, 512, gok, status);
         want(gok, "WRITE(6): the block reads back");
         for (int i = 0; i < 512; i++)
           if (mem_byte(DVMA_BASE + 24'h000C00 + i) != 8'((i*3 + 8'h5A) & 8'hFF))
             same = 1'b0;
         want(same, "WRITE(6): every byte read back is the byte written");
      end

      // ---------------------------------------------------------------
      // 11. A multi-sector WRITE -- what a filesystem write really is
      // ---------------------------------------------------------------
      // Section 10 writes one 512-byte sector, which is the easy case and the
      // only one that was ever covered.  A SunOS block is 8 KiB, sixteen
      // sectors in one command, and on hardware *large* writes come back from
      // the medium wrong while small ones do not: 3- and 10-block files copy
      // perfectly, 104-block files corrupt three times in four, each
      // differently.  This is that case.
      wr16(BASE + 20'h004, 16'h0010);
      wr16(BASE + 20'h004, 16'h0000);

      for (int i = 0; i < 8192; i++)
        mem[(20'h02000 >> 2) + (i >> 2)][8*(i[1:0]) +: 8] = 8'((i*7 + 8'hC3) & 8'hFF);

      dma_write(40, 20'h02000, 8192, gok, status);
      want(gok, "WRITE 8 KiB: the transfer completed");
      want(status == 8'h00, $sformatf("WRITE 8 KiB: status GOOD (got %02x)", status));

      if (gok) begin
         bit same = 1'b1;
         int bad = 0;
         dma_read(40, 20'h04000, 8192, gok, status);
         want(gok, "WRITE 8 KiB: it reads back");
         for (int i = 0; i < 8192; i++)
           if (mem_byte(DVMA_BASE + 24'h004000 + i) != 8'((i*7 + 8'hC3) & 8'hFF)) begin
              same = 1'b0;
              if (bad < 4)
                $display("   first bad byte %0d: got %02x want %02x", i,
                         mem_byte(DVMA_BASE + 24'h004000 + i),
                         8'((i*7 + 8'hC3) & 8'hFF));
              bad++;
           end
         want(same, $sformatf("WRITE 8 KiB: all 8192 bytes survive (%0d wrong)", bad));
      end

      // ---------------------------------------------------------------
      // 12. The same 8 KiB write, against memory as slow as the board's
      // ---------------------------------------------------------------
      // First the control, and it is not optional: the latency model is new,
      // so a write that fails at 13 clocks proves nothing until a *read* at 13
      // clocks is known to pass.  Without this, a broken memory model reads as
      // a broken DMA engine.
      mem_latency = 13;
      wr16(BASE + 20'h004, 16'h0010);
      wr16(BASE + 20'h004, 16'h0000);
      dma_read(3, 20'h00400, 512, gok, status);
      want(gok, "control: a READ(6) still completes at 13-clock latency");
      if (gok) begin
         bit ctl = 1'b1;
         for (int i = 0; i < 512; i++)
           if (mem_byte(DVMA_BASE + 24'h000400 + i) != 8'((3*7 + i) & 8'hFF)) ctl = 1'b0;
         want(ctl, "control: and every byte is right, so the model is sound");
      end

      wr16(BASE + 20'h004, 16'h0010);
      wr16(BASE + 20'h004, 16'h0000);

      for (int i = 0; i < 8192; i++)
        mem[(20'h02000 >> 2) + (i >> 2)][8*(i[1:0]) +: 8] = 8'((i*11 + 8'h17) & 8'hFF);

      dma_write(24, 20'h02000, 8192, gok, status);
      want(gok, "WRITE 8 KiB slow: the transfer completed");
      rd16(BASE + 20'h004);
      $display("   slow: ICR after the write = %04x (bit14 BusError, bit13 OddLen), residue %0d",
               q, dvma_reads);
      want(q[14] == 1'b0, "WRITE 8 KiB slow: no bus error was latched");
      want(status == 8'h00,
           $sformatf("WRITE 8 KiB slow: status is GOOD (got %02x)", status));

      if (gok) begin
         bit same = 1'b1;
         int bad = 0;
         // Read it back against a *fast* memory.  Which of the two directions
         // is broken is the whole question, and a slow read-back cannot answer
         // it: the destination buffer would keep the previous test's bytes and
         // a failed read looks exactly like a failed write.
         mem_latency = 0;
         for (int i = 0; i < 8192; i++)
           mem[(20'h04000 >> 2) + (i >> 2)][8*(i[1:0]) +: 8] = 8'hA5;
         dma_read(24, 20'h04000, 8192, gok, status);
         want(gok, "WRITE 8 KiB slow: it reads back");
         for (int i = 0; i < 8192; i++)
           if (mem_byte(DVMA_BASE + 24'h004000 + i) != 8'((i*11 + 8'h17) & 8'hFF)) begin
              same = 1'b0;
              if (bad < 4)
                $display("   slow: first bad byte %0d: got %02x want %02x", i,
                         mem_byte(DVMA_BASE + 24'h004000 + i),
                         8'((i*11 + 8'h17) & 8'hFF));
              bad++;
           end
         want(same, $sformatf("WRITE 8 KiB slow: all bytes survive (%0d wrong)", bad));
      end
      mem_latency = 0;

      $display("=== tb_mb_scsi: %0d checks, %0d failed ===", checks, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      #40_000_000;
      $display("FAIL: tb_mb_scsi timed out");
      $finish;
   end

endmodule
