`timescale 1ns / 1ps

//
// sun2_xy450 driven the way the boot PROM and SunOS drive it.
//
// Everything here is a replay of real code rather than a paraphrase of it, so
// that a mistake shows up in seconds instead of an hour into a simulated boot:
//
//   Inputs/sunos-34-src/sun/prom_monitor/msun/mon/prom2/xy.c   xyprobe, xyboot, xycmd
//   Inputs/sunos-34-src/sun/sys/sundev/xy.c                    xyprobe, xyexec
//   Inputs/sunos-34-src/sun/sys/sundev/xycreg.h                struct xydevice
//   Inputs/sunos-34-src/sun/sys/sundev/xyreg.h                 struct xyiopb
//
// Two things are checked that nothing else can see:
//
//   1. The byte numbering, twice over.  The controller numbers its registers
//      and its IOPB as MultiBus byte addresses and the 68010 sees them with
//      bit 0 of the address inverted, so `xyaddr->xy_csr` -- CPU offset 5 --
//      is register 0x44, and IOPB byte N is at offset N^1.  Sector data is
//      *not* inverted.  Get any of those wrong and the machine still runs; it
//      just never finds a label.
//   2. That the disk image and memory agree byte for byte, by reading block 0
//      and looking for the label the tool wrote -- its ASCII text, its magic,
//      and a checksum computed the way chklabel() computes it.
//
module tb_xy450;

   localparam logic [15:0] IO_BASE   = 16'hEE40;
   localparam logic [15:0] IO_OTHER  = 16'hEE48;   // the second controller
   localparam logic [23:0] DVMA_BASE = 24'hF00000;

   localparam int CLK_HALF = 40;                   // 12.5 MHz

   logic clk = 1'b0, rst = 1'b1;
   always #(CLK_HALF) clk = ~clk;

   logic        mbio_sel = 1'b0, mbio_we = 1'b0;
   logic        mbio_uds_n = 1'b1, mbio_lds_n = 1'b1;
   logic [15:0] mbio_addr = 16'h0;
   logic [15:0] mbio_din  = 16'h0;
   wire  [15:0] mbio_dout;
   wire         mbio_hit, mbio_ack, int_o;

   wire         wb_cyc, wb_stb, wb_we, wb_clr;
   wire [3:0]   wb_sel;
   wire [21:0]  wb_adr;
   wire [31:0]  wb_dat_m2s;
   logic [31:0] wb_dat_s2m;
   logic        wb_ack, wb_err;

   wire         blk_start, blk_we, blk_buf_we;
   wire [31:0]  blk_lba, blk_count;
   wire [7:0]   blk_buf_rdata, blk_buf_wdata;
   wire [8:0]   blk_buf_addr;
   wire         blk_done, blk_err, blk_ready;

   sun2_xy450 #(.IO_BASE(IO_BASE), .DVMA_BASE(DVMA_BASE)) dut (
       .CLK(clk), .RESET(rst),
       .mbio_sel(mbio_sel), .mbio_addr(mbio_addr), .mbio_we(mbio_we),
       .mbio_uds_n(mbio_uds_n), .mbio_lds_n(mbio_lds_n),
       .mbio_din(mbio_din), .mbio_dout(mbio_dout),
       .mbio_hit(mbio_hit), .mbio_ack(mbio_ack),
       .int_o(int_o),
       .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb), .wb_we_o(wb_we),
       .wb_sel_o(wb_sel), .wb_adr_o(wb_adr), .wb_dat_o(wb_dat_m2s),
       .wb_dat_i(wb_dat_s2m), .wb_ack_i(wb_ack), .wb_err_i(wb_err),
       .wb_clr_o(wb_clr),
       .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
       .blk_buf_rdata(blk_buf_rdata),
       .blk_done(blk_done), .blk_err(blk_err),
       .blk_ready(blk_ready), .blk_count(blk_count),
       .blk_buf_we(blk_buf_we), .blk_buf_addr(blk_buf_addr),
       .blk_buf_wdata(blk_buf_wdata)
   );

   // The media, from a file, exactly as the boot regression uses it.
   blk_file #(.MAX_BLOCKS(8192), .READ_CLOCKS(20)) disk (
       .clk(clk), .rst(rst),
       .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
       .blk_buf_rdata(blk_buf_rdata),
       .blk_done(blk_done), .blk_err(blk_err),
       .blk_ready(blk_ready), .blk_count(blk_count),
       .blk_buf_we(blk_buf_we), .blk_buf_addr(blk_buf_addr),
       .blk_buf_wdata(blk_buf_wdata)
   );

   // ------------------------------------------------------------------
   // Memory behind the DVMA port
   // ------------------------------------------------------------------
   // 8 KiB starting at the DVMA window's base, which is where the machine's
   // MMU would land.  Anything past it answers with an error, which is what a
   // DVMA cycle outside the window really does: the pages above it are TYPE 2,
   // nothing on the bus claims them, and the machine's timeout fires.
   localparam int MEM_WORDS = 2048;

   logic [31:0] mem [0:MEM_WORDS-1];
   wire [21:0]  mem_idx = wb_adr - DVMA_BASE[23:2];
   wire         mem_in  = (wb_adr >= DVMA_BASE[23:2]) &&
                          (mem_idx < MEM_WORDS[21:0]);

   int          dvma_reads = 0, dvma_writes = 0;

   // sun2_dvma latches a bus error and refuses every later cycle until it is
   // told to forget it -- on the Ethernet side that means resetting the 82586.
   // The model does the same, so that a controller which does not clear the
   // latch before each command works exactly once and then reports Slave ACK
   // Error for everything, which is a failure mode worth catching here rather
   // than an hour into a boot.
   logic err_latched = 1'b0;

   always @(posedge clk) begin
      wb_ack <= 1'b0;
      wb_err <= 1'b0;
      if (rst) begin
         err_latched <= 1'b0;
      end else begin
         if (wb_clr) err_latched <= 1'b0;
         if (wb_cyc && wb_stb && !wb_ack && !wb_err) begin
         if (!mem_in || err_latched) begin
            wb_err      <= 1'b1;
            err_latched <= 1'b1;
         end else begin
            if (wb_we) begin
               for (int b = 0; b < 4; b++)
                 if (wb_sel[b]) mem[mem_idx][8*b +: 8] <= wb_dat_m2s[8*b +: 8];
               dvma_writes++;
            end else
              dvma_reads++;
            wb_dat_s2m <= mem[mem_idx];
            wb_ack     <= 1'b1;
         end
         end
      end
   end

   // A 68010 byte address, as the card computes it.
   function automatic logic [7:0] mem_byte(input logic [23:0] va);
      mem_byte = mem[(va - DVMA_BASE) >> 2][8*(va[1:0]) +: 8];
   endfunction

   task automatic mem_put(input logic [23:0] va, input logic [7:0] d);
      mem[(va - DVMA_BASE) >> 2][8*(va[1:0]) +: 8] = d;
   endtask

   int fail = 0, checks = 0;

   task automatic want(input bit cond, input string what);
      checks++;
      if (!cond) begin
         $display("FAIL: %s", what);
         fail++;
      end
   endtask

   // ------------------------------------------------------------------
   // A MultiBus I/O cycle, the way sun2_fpga presents one
   // ------------------------------------------------------------------
   // ok = 0 means the card never acknowledged, which is what the machine turns
   // into the bus error pokec()/peekc() catch.
   localparam int ACK_LIMIT = 12;   // the machine gives up after twelve clocks

   task automatic bus_cycle(input logic [15:0] a, input bit we,
                            input bit uds, input bit lds,
                            input logic [15:0] d,
                            output logic [15:0] q, output bit ok);
      int guard;
      begin
         @(posedge clk);
         mbio_addr  <= {a[15:1], 1'b0};
         mbio_we    <= we;
         mbio_uds_n <= ~uds;
         mbio_lds_n <= ~lds;
         mbio_din   <= d;
         mbio_sel   <= 1'b1;
         ok = 1'b0;
         q  = 16'hXXXX;
         for (guard = 0; guard < ACK_LIMIT; guard++) begin
            @(posedge clk);
            if (mbio_hit && mbio_ack) begin
               q  = mbio_dout;
               ok = 1'b1;
               break;
            end
         end
         @(negedge clk);
         mbio_sel   <= 1'b0;
         mbio_we    <= 1'b0;
         mbio_uds_n <= 1'b1;
         mbio_lds_n <= 1'b1;
         @(posedge clk);
      end
   endtask

   // `a` is a *CPU* byte address, exactly as struct xydevice is indexed.  An
   // even one is the high lane (UDS, D15:8), an odd one the low lane.
   task automatic pokec(input logic [15:0] a, input logic [7:0] d, output bit ok);
      logic [15:0] q;
      if (a[0] == 1'b0) bus_cycle(a, 1'b1, 1'b1, 1'b0, {d, 8'h00}, q, ok);
      else              bus_cycle(a, 1'b1, 1'b0, 1'b1, {8'h00, d}, q, ok);
   endtask

   task automatic peekc(input logic [15:0] a, output logic [7:0] v, output bit ok);
      logic [15:0] q;
      if (a[0] == 1'b0) begin
         bus_cycle(a, 1'b0, 1'b1, 1'b0, 16'h0, q, ok);
         v = q[15:8];
      end else begin
         bus_cycle(a, 1'b0, 1'b0, 1'b1, 16'h0, q, ok);
         v = q[7:0];
      end
   endtask

   // struct xydevice, by name
   localparam logic [15:0] XY_IOPBREL0 = IO_BASE + 16'd0;   // register 0x41, hi
   localparam logic [15:0] XY_IOPBREL1 = IO_BASE + 16'd1;   // register 0x40, lo
   localparam logic [15:0] XY_IOPBOFF0 = IO_BASE + 16'd2;   // register 0x43, hi
   localparam logic [15:0] XY_IOPBOFF1 = IO_BASE + 16'd3;   // register 0x42, lo
   localparam logic [15:0] XY_RESUPD   = IO_BASE + 16'd4;   // register 0x45
   localparam logic [15:0] XY_CSR      = IO_BASE + 16'd5;   // register 0x44

   // xy_csr bits, from xycreg.h
   localparam logic [7:0] XY_GO     = 8'h80;
   localparam logic [7:0] XY_BUSY   = 8'h80;
   localparam logic [7:0] XY_ERROR  = 8'h40;
   localparam logic [7:0] XY_DBLERR = 8'h20;
   localparam logic [7:0] XY_INTR   = 8'h10;
   localparam logic [7:0] XY_ADDR24 = 8'h08;
   localparam logic [7:0] XY_ATTN   = 8'h04;
   localparam logic [7:0] XY_ACK    = 8'h02;
   localparam logic [7:0] XY_DREADY = 8'h01;

   task automatic wait_not_busy(input int limit, output bit got);
      logic [7:0] c;
      bit         ok;
      int         n;
      begin
         got = 1'b0;
         for (n = 0; n < limit; n++) begin
            peekc(XY_CSR, c, ok);
            if (!ok) break;
            if ((c & XY_BUSY) == 8'h00) begin got = 1'b1; break; end
         end
      end
   endtask

   // ------------------------------------------------------------------
   // The IOPB, where the PROM puts it
   // ------------------------------------------------------------------
   // MultiBus 0x000100 and 0x000200, from prom2/xy.c:33-36.  IOPB byte N is at
   // virtual address IOPB_VA + (N ^ 1); the sector buffer is not inverted.
   localparam logic [19:0] IOPBADDR = 20'h00100;
   localparam logic [19:0] DMADDR   = 20'h00200;
   localparam logic [23:0] IOPB_VA  = DVMA_BASE + IOPBADDR;
   localparam logic [23:0] BUF_VA   = DVMA_BASE + DMADDR;

   task automatic iopb_put(input int n, input logic [7:0] d);
      mem_put(IOPB_VA + (n ^ 1), d);
   endtask

   function automatic logic [7:0] iopb_get(input int n);
      iopb_get = mem_byte(IOPB_VA + (n ^ 1));
   endfunction

   // xycmd(): zero the IOPB, fill it in, point the controller at it, set Go,
   // and spin on BUSY.  The relocation and offset registers are rewritten
   // every time because the PROM reads the reset register after every command,
   // and a controller reset clears them.
   task automatic xycmd(input logic [7:0] cmd0,       // IOPB byte 0
                        input logic [7:0] drive,      // IOPB byte 5
                        input logic [7:0] head,
                        input logic [7:0] sect,
                        input logic [15:0] cyl,
                        input logic [15:0] nsect,
                        input logic [15:0] bufoff,
                        output bit done);
      bit ok;
      int i;
      begin
         for (i = 0; i < 24; i++) iopb_put(i, 8'h00);
         iopb_put(0,  cmd0);
         iopb_put(1,  8'h02);            // ECC mode 2, as both drivers set
         iopb_put(4,  8'h04);            // XY_THROTTLE, 32 words a burst
         iopb_put(5,  drive);
         iopb_put(6,  head);
         iopb_put(7,  sect);
         iopb_put(8,  cyl[7:0]);
         iopb_put(9,  {5'h0, cyl[10:8]});
         iopb_put(10, nsect[7:0]);
         iopb_put(11, nsect[15:8]);
         iopb_put(12, bufoff[7:0]);
         iopb_put(13, bufoff[15:8]);

         pokec(XY_IOPBREL0, 8'h00, ok);
         pokec(XY_IOPBREL1, 8'h00, ok);
         pokec(XY_IOPBOFF0, IOPBADDR[15:8], ok);
         pokec(XY_IOPBOFF1, IOPBADDR[7:0],  ok);
         pokec(XY_CSR, XY_GO, ok);
         wait_not_busy(200000, done);
      end
   endtask

   // ------------------------------------------------------------------
   // Chains
   // ------------------------------------------------------------------
   // Everything here is at an arbitrary MultiBus offset rather than the PROM's
   // fixed 0x100, because a chain is several IOPBs at once.  xychain() builds
   // them in the 8 KiB iopbmap at DVMA offset 0 and links them with 16-bit
   // offsets relocated by the same registers, which is what this mimics.
   task automatic iopb_put_at(input logic [19:0] mb, input int n,
                              input logic [7:0] d);
      mem_put(DVMA_BASE + mb + (n ^ 1), d);
   endtask

   function automatic logic [7:0] iopb_get_at(input logic [19:0] mb, input int n);
      iopb_get_at = mem_byte(DVMA_BASE + mb + (n ^ 1));
   endfunction

   // One IOPB, filled in the way xycmd()/initiopb() fill one.  `nxt` is written
   // whether or not `chen` is set: the driver leaves a stale pointer on the
   // tail of every chain and the controller has to not follow it.
   task automatic build_iopb(input logic [19:0] mb,
                             input logic [7:0]  cmd0,   // AUD/RELO/CHEN/IEN/cmd
                             input logic [7:0]  imode,  // IEI/ASR/EEF/ECC
                             input logic [7:0]  drive,
                             input logic [7:0]  head,
                             input logic [7:0]  sect,
                             input logic [15:0] cyl,
                             input logic [15:0] nsect,
                             input logic [15:0] bufoff,
                             input logic [15:0] nxt);
      int i;
      begin
         for (i = 0; i < 24; i++) iopb_put_at(mb, i, 8'h00);
         iopb_put_at(mb, 0,  cmd0);
         iopb_put_at(mb, 1,  imode);
         iopb_put_at(mb, 4,  8'h04);            // XY_THROTTLE
         iopb_put_at(mb, 5,  drive);
         iopb_put_at(mb, 6,  head);
         iopb_put_at(mb, 7,  sect);
         iopb_put_at(mb, 8,  cyl[7:0]);
         iopb_put_at(mb, 9,  {5'h0, cyl[10:8]});
         iopb_put_at(mb, 10, nsect[7:0]);
         iopb_put_at(mb, 11, nsect[15:8]);
         iopb_put_at(mb, 12, bufoff[7:0]);
         iopb_put_at(mb, 13, bufoff[15:8]);
         iopb_put_at(mb, 18, nxt[7:0]);         // Next IOPB Address low
         iopb_put_at(mb, 19, nxt[15:8]);        // ... and high
      end
   endtask

   task automatic go_at(input logic [15:0] off);
      bit ok;
      begin
         pokec(XY_IOPBREL0, 8'h00, ok);
         pokec(XY_IOPBREL1, 8'h00, ok);
         pokec(XY_IOPBOFF0, off[15:8], ok);
         pokec(XY_IOPBOFF1, off[7:0],  ok);
         pokec(XY_CSR, XY_GO, ok);
      end
   endtask

   // Run a chain the way a driver does: poll, acknowledge every interrupt as
   // it appears, and count them.  Counting edges of int_o from a concurrent
   // process would not work -- IPND is a level, so a second interrupt is
   // invisible until the first is acknowledged, which is the whole point of
   // it being a level.
   task automatic run_chain(input logic [15:0] off, output int irqs,
                            output bit finished);
      logic [7:0] c;
      bit         ok;
      int         n;
      begin
         irqs = 0;
         finished = 1'b0;
         go_at(off);
         for (n = 0; n < 100000; n++) begin
            peekc(XY_CSR, c, ok);
            if (!ok) break;
            if (c & XY_INTR) begin irqs++; pokec(XY_CSR, XY_INTR, ok); end
            if ((c & XY_BUSY) == 8'h00) begin finished = 1'b1; break; end
         end
         // The end-of-chain interrupt lands in the same cycle GBSY drops, so
         // the loop above can exit without having seen it.
         peekc(XY_CSR, c, ok);
         if (c & XY_INTR) begin irqs++; pokec(XY_CSR, XY_INTR, ok); end
      end
   endtask

   // chklabel(), byte for byte: magic, then the XOR of all 256 shorts.
   function automatic bit label_ok(input logic [23:0] base);
      logic [15:0] sum, w;
      int          i;
      begin
         sum = 16'h0;
         for (i = 0; i < 256; i++) begin
            w   = {mem_byte(base + 2*i), mem_byte(base + 2*i + 1)};
            sum = sum ^ w;
         end
         label_ok = (sum == 16'h0) &&
                    ({mem_byte(base + 508), mem_byte(base + 509)} == 16'hDABE);
      end
   endfunction

   logic [7:0]  v;
   logic [15:0] q;
   bit          ok, got;
   int          i, bad, irqs;
   string       s;

   initial begin
      $display("=== tb_xy450: a Xylogics 450 and its disk ===");

      for (i = 0; i < MEM_WORDS; i++) mem[i] = 32'h0;

      repeat (4) @(posedge clk);
      rst = 1'b0;
      repeat (8) @(posedge clk);

      // ==================================================================
      // 1. The PROM's xyprobe(): tell a Xylogics from an Interphase 2180
      // ==================================================================
      //    if (pokec(xyaddr, 0x67) || pokec(xyaddr+1, 0x89)) continue;
      //    if (xyaddr[0] == 0x67 && xyaddr[1] == 0x89) return (i);
      pokec(XY_IOPBREL0, 8'h67, ok);  want(ok, "pokec 0x67 to xy_iopbrel[0] took a bus error");
      pokec(XY_IOPBREL1, 8'h89, ok);  want(ok, "pokec 0x89 to xy_iopbrel[1] took a bus error");
      peekc(XY_IOPBREL0, v, ok);
      want(ok && v == 8'h67, $sformatf("xy_iopbrel[0] read back %02x, want 67", v));
      peekc(XY_IOPBREL1, v, ok);
      want(ok && v == 8'h89, $sformatf("xy_iopbrel[1] read back %02x, want 89", v));

      // The two bytes are the halves of one 16-bit register, high byte first:
      // xycmd() writes `t >> 8` to [0] and `t` to [1].  A word read must
      // therefore see 0x6789, not 0x8967.
      bus_cycle(IO_BASE, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(ok && q == 16'h6789,
           $sformatf("relocation as a word read %04x, want 6789 -- byte lanes crossed?", q));

      // ==================================================================
      // 2. Only this controller answers
      // ==================================================================
      // xyprobe() walks xystd[] = { 0xee40, 0xee48 } and the monitor reports
      // one controller only because the second address times out.  A decode
      // one bit too wide shows up on the console as two disks.
      pokec(IO_OTHER, 8'h67, ok);
      want(!ok, "the card answered at 0xEE48 as well: the base decode is too wide");
      peekc(IO_OTHER + 16'd5, v, ok);
      want(!ok, "the card answered a CSR read at 0xEE48");

      // ==================================================================
      // 3. The CSR is register 0x44 and reset/update is 0x45
      // ==================================================================
      peekc(XY_CSR, v, ok);
      want(ok, "CSR read took a bus error");
      want((v & XY_BUSY)   == 8'h00, "GBSY set with no command in flight");
      want((v & XY_ERROR)  == 8'h00, "ERR set out of reset");
      want((v & XY_DBLERR) == 8'h00, "DERR set out of reset");
      want((v & XY_INTR)   == 8'h00, "IPND set out of reset");
      want((v & XY_ADDR24) == 8'h00, "ADRM reads 1: the card must be jumpered 20-bit on MultiBus");
      want((v & XY_DREADY) != 8'h00, "DRDY clear with an image loaded");

      // The kernel's xyprobe() step 1: peekc(&xyio->xy_resupd) starts a
      // Controller Reset, which sets GBSY and clears the registers.
      peekc(XY_RESUPD, v, ok);
      want(ok, "reading the reset/update register took a bus error");
      peekc(XY_CSR, v, ok);
      want((v & XY_BUSY) != 8'h00,
           "GBSY did not set after reading 0x45 -- is the CSR on the wrong byte lane?");

      // step 2: CDELAY(!(xy_csr & XY_BUSY), 100000), else "controller reset failed"
      wait_not_busy(2000, got);
      want(got, "the controller reset never finished");

      peekc(XY_IOPBREL0, v, ok);
      want(ok && v == 8'h00, $sformatf("relocation high survived a controller reset as %02x", v));
      peekc(XY_IOPBREL1, v, ok);
      want(ok && v == 8'h00, $sformatf("relocation low survived a controller reset as %02x", v));

      // The two register pairs are independent: a write to one must not
      // disturb the other, which a decode that ignored address bit 1 would.
      pokec(XY_IOPBOFF0, 8'h01, ok);
      pokec(XY_IOPBOFF1, 8'h00, ok);
      bus_cycle(IO_BASE + 16'd2, 1'b0, 1'b1, 1'b1, 16'h0, q, ok);
      want(ok && q == 16'h0100,
           $sformatf("IOPB address as a word read %04x, want 0100 (the PROM's IOPBADDR)", q));
      peekc(XY_IOPBREL0, v, ok);
      want(v == 8'h00, "writing the IOPB address disturbed the relocation register");

      // ==================================================================
      // 4. A NOP, which is what SunOS's xyprobe() identifies the card with
      // ==================================================================
      //   "issue a NOP and require the IOPB to come back with controller
      //    type 1", else "unsupported controller type"
      xycmd(8'h80, 8'h00, 8'h00, 8'h00, 16'h0, 16'h0, 16'h0, got);  // AUD + cmd 0
      want(got, "GBSY never cleared after a NOP: this would hang the boot PROM");
      want(iopb_get(3) == 8'h00,
           $sformatf("NOP completion code %02x, want 00", iopb_get(3)));
      want((iopb_get(2) & 8'h1C) == 8'h04,
           $sformatf("STAT1 %02x: xyboot() reads bits 4:2 and wants controller type 1",
                     iopb_get(2)));
      want(iopb_get(2)[0] == 1'b1, "STAT1 came back without DONE set");
      want(iopb_get(2)[7] == 1'b0, "STAT1 came back with the error summary set");

      // Self Test, the other half of the kernel's probe.
      xycmd(8'h8C, 8'h00, 8'h00, 8'h00, 16'h0, 16'h0, 16'h0, got);
      want(got && iopb_get(3) == 8'h00,
           $sformatf("Self Test completion code %02x, want 00", iopb_get(3)));

      // ==================================================================
      // 5. Read block 0 and find the label
      // ==================================================================
      // This is the whole chain: IOPB fetched with its bytes inverted, CHS
      // turned into an LBA, a block pulled off the media, 512 bytes DMA'd out
      // *without* inversion, and status written back.  If the sector byte
      // order were inverted too, the magic would read as 0xBEDA and the
      // checksum would still be zero -- which is why both are checked.
      xycmd(8'h82, 8'h00, 8'h00, 8'h00, 16'h0, 16'h1, DMADDR[15:0], got);
      want(got, "GBSY never cleared after a Read");
      want(iopb_get(3) == 8'h00,
           $sformatf("Read of block 0 gave completion code %02x", iopb_get(3)));

      want({mem_byte(BUF_VA + 508), mem_byte(BUF_VA + 509)} == 16'hDABE,
           $sformatf("dkl_magic read as %02x%02x, want dabe -- sector bytes inverted?",
                     mem_byte(BUF_VA + 508), mem_byte(BUF_VA + 509)));
      want(label_ok(BUF_VA), "the label did not survive chklabel()'s XOR checksum");

      s = "";
      for (i = 0; i < 4; i++) s = {s, string'(mem_byte(BUF_VA + i))};
      want(s == "FPGA",
           $sformatf("dkl_asciilabel starts \"%s\", want \"FPGA\" -- byte order?", s));

      // The geometry the label carries is what xyboot() adopts.
      want({mem_byte(BUF_VA + 436), mem_byte(BUF_VA + 437)} == 16'd4,  "dkl_nhead is not 4");
      want({mem_byte(BUF_VA + 438), mem_byte(BUF_VA + 439)} == 16'd32, "dkl_nsect is not 32");
      want({mem_byte(BUF_VA + 440), mem_byte(BUF_VA + 441)} == 16'd0,  "dkl_bhead is not 0");
      want({mem_byte(BUF_VA + 442), mem_byte(BUF_VA + 443)} == 16'd0,  "dkl_ppart is not 0");

      // ==================================================================
      // 6. Read Drive Status, which is how the PROM waits for the disk
      // ==================================================================
      // isspinning() loops on `xy->xy_status & XY_READY`, and xy_status is the
      // low byte of the u_short at struct offset 10 -- controller byte A.
      // ONCL and DRDY are "true if zero", so a ready drive reads as 0x00.
      xycmd(8'h89, 8'h00, 8'h00, 8'h00, 16'h0, 16'h0, 16'h0, got);
      want(got && iopb_get(3) == 8'h00,
           $sformatf("Read Drive Status completion code %02x", iopb_get(3)));
      want(iopb_get(8'h0A) == 8'h00,
           $sformatf("drive status byte %02x: isspinning() would wait forever",
                     iopb_get(8'h0A)));
      want({iopb_get(8'h0D), iopb_get(8'h0C)} == 16'd512,
           $sformatf("bytes per sector reported as %0d, want 512",
                     {iopb_get(8'h0D), iopb_get(8'h0C)}));
      want(iopb_get(8'h06) == 8'd18 && iopb_get(8'h07) == 8'd31,
           "drive type 0 did not report the Table 2-8 default of 19 heads, 32 sectors");
      want(iopb_get(8'h0B) != 8'd0,
           "firmware revision 0: checkrev() rejects anything below revision B");

      // ==================================================================
      // 7. Set Drive Size, then a read that depends on it
      // ==================================================================
      // xyboot() issues this with the label's geometry once it has found one,
      // and every later block number is turned into CHS with it.  With
      // 4 heads and 32 sectors, block 33 is cylinder 0, head 1, sector 1.
      xycmd(8'h8B, 8'h00, 8'd3, 8'd31, 16'd33, 16'h0, 16'h0, got);  // nhead-1, nsect-1, ncyl+acyl-1
      want(got && iopb_get(3) == 8'h00,
           $sformatf("Set Drive Size completion code %02x", iopb_get(3)));

      // Block 1 is the first sector of the boot program, and mkxydisk puts a
      // `lea` there -- 0x45FA.
      xycmd(8'h82, 8'h00, 8'h00, 8'h01, 16'h0, 16'h1, DMADDR[15:0], got);
      want(got && iopb_get(3) == 8'h00,
           $sformatf("Read of block 1 gave completion code %02x", iopb_get(3)));
      want({mem_byte(BUF_VA), mem_byte(BUF_VA + 1)} == 16'h45FA,
           $sformatf("block 1 starts %02x%02x, want 45fa (the boot block's first instruction)",
                     mem_byte(BUF_VA), mem_byte(BUF_VA + 1)));

      // ==================================================================
      // 8. Write, then read it back
      // ==================================================================
      for (i = 0; i < 512; i++) mem_put(BUF_VA + i, 8'hA5 ^ i[7:0]);
      xycmd(8'h81, 8'h00, 8'd1, 8'd1, 16'd5, 16'h1, DMADDR[15:0], got);  // cyl 5, head 1, sect 1
      want(got && iopb_get(3) == 8'h00,
           $sformatf("Write gave completion code %02x", iopb_get(3)));

      for (i = 0; i < 512; i++) mem_put(BUF_VA + i, 8'h00);
      xycmd(8'h82, 8'h00, 8'd1, 8'd1, 16'd5, 16'h1, DMADDR[15:0], got);
      want(got && iopb_get(3) == 8'h00,
           $sformatf("Read back gave completion code %02x", iopb_get(3)));
      bad = 0;
      for (i = 0; i < 512; i++)
        if (mem_byte(BUF_VA + i) !== (8'hA5 ^ i[7:0])) bad++;
      want(bad == 0, $sformatf("%0d of 512 bytes did not survive write-then-read", bad));

      // Where a sector actually lands.  A round trip at one address proves
      // nothing about the CHS-to-LBA map -- a wrong formula is still its own
      // inverse -- so reach into the media and check the block number, with a
      // cylinder and a head both non-zero so that every term matters.
      // lba = (cyl * heads + head) * sectors + sector = (2*4 + 1)*32 + 8 = 296.
      for (i = 0; i < 512; i++) mem_put(BUF_VA + i, 8'h3C ^ i[7:0]);
      xycmd(8'h81, 8'h00, 8'd1, 8'd8, 16'd2, 16'h1, DMADDR[15:0], got);
      want(got && iopb_get(3) == 8'h00,
           $sformatf("Write to cylinder 2 head 1 sector 8 gave %02x", iopb_get(3)));
      bad = 0;
      for (i = 0; i < 512; i++)
        if (disk.media[296*512 + i] !== (8'h3C ^ i[7:0])) bad++;
      want(bad == 0,
           $sformatf("cylinder 2 head 1 sector 8 did not land on block 296 (%0d bytes wrong)",
                     bad));

      // Two sectors in one IOPB, which crosses a sector boundary in the
      // controller's own carry order.
      for (i = 0; i < 1024; i++) mem_put(BUF_VA + i, 8'h5A ^ i[7:0]);
      xycmd(8'h81, 8'h00, 8'd2, 8'd30, 16'd6, 16'h2, DMADDR[15:0], got);
      want(got && iopb_get(3) == 8'h00,
           $sformatf("two-sector Write gave completion code %02x", iopb_get(3)));
      for (i = 0; i < 1024; i++) mem_put(BUF_VA + i, 8'h00);
      xycmd(8'h82, 8'h00, 8'd2, 8'd30, 16'd6, 16'h2, DMADDR[15:0], got);
      bad = 0;
      for (i = 0; i < 1024; i++)
        if (mem_byte(BUF_VA + i) !== (8'h5A ^ i[7:0])) bad++;
      want(bad == 0, $sformatf("%0d of 1024 bytes wrong across a two-sector transfer", bad));
      // sector 30 of 32 plus two sectors carries into head 3.
      want(iopb_get(8'h06) == 8'd3 && iopb_get(8'h07) == 8'd0,
           $sformatf("after two sectors the IOPB says head %0d sector %0d, want 3/0",
                     iopb_get(8'h06), iopb_get(8'h07)));
      want({iopb_get(8'h0B), iopb_get(8'h0A)} == 16'h0,
           "the auto-updated sector count did not reach zero");

      // ==================================================================
      // 9. The ways it is allowed to fail
      // ==================================================================
      // Every one of these is a code a driver in the tree tests for by name.
      xycmd(8'h82, 8'h01, 8'h00, 8'h00, 16'h0, 16'h1, DMADDR[15:0], got);  // unit 1
      want(got && iopb_get(3) == 8'h16,
           $sformatf("read from unit 1 gave %02x, want 16 (drive not ready)", iopb_get(3)));
      want(iopb_get(2)[7] == 1'b1, "a hard error did not set the error summary in STAT1");
      peekc(XY_CSR, v, ok);
      want((v & XY_ERROR) != 8'h00, "a hard error did not set ERR in the CSR");
      pokec(XY_CSR, XY_ERROR, ok);      // Error Reset

      xycmd(8'h82, 8'h00, 8'h00, 8'h00, 16'h0, 16'h0, DMADDR[15:0], got);  // zero sectors
      want(got && iopb_get(3) == 8'h17,
           $sformatf("zero sector count gave %02x, want 17", iopb_get(3)));
      pokec(XY_CSR, XY_ERROR, ok);

      xycmd(8'h82, 8'h00, 8'h00, 8'd40, 16'h0, 16'h1, DMADDR[15:0], got);  // sector 40 of 32
      want(got && iopb_get(3) == 8'h0A,
           $sformatf("sector past the end of the track gave %02x, want 0a", iopb_get(3)));
      pokec(XY_CSR, XY_ERROR, ok);

      xycmd(8'h82, 8'h00, 8'd9, 8'h00, 16'h0, 16'h1, DMADDR[15:0], got);   // head 9 of 4
      want(got && iopb_get(3) == 8'h20,
           $sformatf("head past the end gave %02x, want 20", iopb_get(3)));
      pokec(XY_CSR, XY_ERROR, ok);

      xycmd(8'h82, 8'h00, 8'h00, 8'h00, 16'd200, 16'h1, DMADDR[15:0], got); // cylinder 200 of 34
      want(got && iopb_get(3) == 8'h07,
           $sformatf("cylinder past the end gave %02x, want 07", iopb_get(3)));
      pokec(XY_CSR, XY_ERROR, ok);

      // A data address the memory does not answer at.  On the machine this is
      // a DVMA cycle above the window, which finds no card and times out.
      xycmd(8'h82, 8'h00, 8'h00, 8'h00, 16'h0, 16'h1, 16'h7000, got);
      want(got && iopb_get(3) == 8'h0E,
           $sformatf("a transfer to memory that did not answer gave %02x, want 0e",
                     iopb_get(3)));
      pokec(XY_CSR, XY_ERROR, ok);

      // ... and the command straight after it must work.  sun2_dvma stops the
      // channel dead after a bus error and only a deliberate clear restarts
      // it, so a controller that never clears the latch reads one bad sector
      // and then fails forever.
      xycmd(8'h82, 8'h00, 8'h00, 8'h00, 16'h0, 16'h1, DMADDR[15:0], got);
      want(got && iopb_get(3) == 8'h00,
           $sformatf("the read after a memory fault gave %02x: the DVMA error latch was never cleared",
                     iopb_get(3)));

      // An unimplemented command.  Command 3 is Write Track Headers, which is
      // out of scope: there are no sector headers on an SD card.
      xycmd(8'h83, 8'h00, 8'h00, 8'h00, 16'h0, 16'h0, 16'h0, got);
      want(got && iopb_get(3) == 8'h15,
           $sformatf("Write Track Headers gave %02x, want 15 (unimplemented)", iopb_get(3)));
      pokec(XY_CSR, XY_ERROR, ok);

      // An IOPB the controller cannot even fetch.  Now the status bytes have
      // nowhere to go either, which is what DERR is for -- "usually means the
      // 450 cannot properly DMA the Status bytes to memory as a result of an
      // error" -- and the channel is left stopped, so the *next* command is
      // the real test.
      pokec(XY_IOPBOFF0, 8'h70, ok);      // IOPB at 0x7000, outside the memory
      pokec(XY_IOPBOFF1, 8'h00, ok);
      pokec(XY_CSR, XY_GO, ok);
      wait_not_busy(2000, got);
      want(got, "an unfetchable IOPB left the controller busy");
      peekc(XY_CSR, v, ok);
      want((v & XY_DBLERR) != 8'h00,
           "an IOPB that could not be written back did not set DERR");
      pokec(XY_CSR, XY_ERROR, ok);        // Error Reset clears ERR and DERR
      peekc(XY_CSR, v, ok);
      want((v & (XY_ERROR | XY_DBLERR)) == 8'h00,
           "Error Reset did not clear both error bits");

      xycmd(8'h80, 8'h00, 8'h00, 8'h00, 16'h0, 16'h0, 16'h0, got);
      want(got && iopb_get(3) == 8'h00,
           $sformatf("the command after an unfetchable IOPB gave %02x: the channel is still stopped",
                     iopb_get(3)));

      // "If DONE is set, the 450 reads the IOPB and considers it complete."
      // Both drivers zero the IOPB first; one that forgot would silently do
      // nothing, and it must be that rather than doing it twice.
      for (i = 0; i < 24; i++) iopb_put(i, 8'h00);
      iopb_put(0, 8'h82);
      iopb_put(2, 8'h01);              // DONE already set
      iopb_put(10, 8'h01);
      iopb_put(12, 8'h00);
      iopb_put(13, 8'h00);             // data address 0, which would fault
      pokec(XY_IOPBOFF0, IOPBADDR[15:8], ok);
      pokec(XY_IOPBOFF1, IOPBADDR[7:0],  ok);
      pokec(XY_CSR, XY_GO, ok);
      wait_not_busy(2000, got);
      want(got, "an already-DONE IOPB left the controller busy");
      peekc(XY_CSR, v, ok);
      want((v & XY_ERROR) == 8'h00, "an already-DONE IOPB was executed anyway");

      // ==================================================================
      // 10. The interrupt, which nothing in the tree enables
      // ==================================================================
      want(int_o == 1'b0, "the card is interrupting without IEN ever being set");
      xycmd(8'h90, 8'h00, 8'h00, 8'h00, 16'h0, 16'h0, 16'h0, got);  // IEN + NOP
      want(int_o == 1'b1, "IEN was set and no interrupt came");
      peekc(XY_CSR, v, ok);
      want((v & XY_INTR) != 8'h00, "IPND is clear while the card interrupts");
      pokec(XY_CSR, XY_INTR, ok);      // Interrupt Reset
      want(int_o == 1'b0, "writing 1 to IPND did not drop the interrupt");

      // ==================================================================
      // 11. Chains
      // ==================================================================
      // The geometry from section 7 is still in force -- 4 heads, 32 sectors --
      // so blocks 0 and 1 are cylinder 0, head 0, sectors 0 and 1.
      //
      // IOPBs at 0x100, 0x120, 0x140, 0x160, 0x180; buffers at 0x400 upward.
      // The command byte is AUD | CHEN | IEN | cmd, which is what xychain()
      // and xyasynch() between them produce.

      // --- two IOPBs, and a tail with a stale next pointer ---
      // The second IOPB's Next IOPB Address is deliberately garbage with CHEN
      // clear.  xychain() clears xy_chain on the tail and never clears
      // xy_nxtoff (xy.c:744-745), so this is not a contrived case: it is what
      // the driver hands the controller every time.
      build_iopb(20'h00100, 8'hB2, 8'h02, 8'h00, 8'd0, 8'd0, 16'd0, 16'd1,
                 16'h0400, 16'h0120);
      build_iopb(20'h00120, 8'h92, 8'h02, 8'h00, 8'd0, 8'd1, 16'd0, 16'd1,
                 16'h0600, 16'hDEAD);
      for (i = 0; i < 1024; i++) mem_put(DVMA_BASE + 20'h400 + i, 8'h00);

      run_chain(16'h0100, irqs, got);
      want(got, "a two-IOPB chain never cleared GBSY");
      want(iopb_get_at(20'h00100, 2)[0] == 1'b1, "the head of the chain has no DONE");
      want(iopb_get_at(20'h00120, 2)[0] == 1'b1, "the second IOPB was never executed");
      want(iopb_get_at(20'h00100, 3) == 8'h00 && iopb_get_at(20'h00120, 3) == 8'h00,
           $sformatf("chained completion codes %02x and %02x, want 00 and 00",
                     iopb_get_at(20'h00100, 3), iopb_get_at(20'h00120, 3)));
      want(irqs == 1,
           $sformatf("%0d interrupts for a chain of two: the driver clears IEI and expects exactly one",
                     irqs));
      want({mem_byte(DVMA_BASE + 20'h400 + 508),
            mem_byte(DVMA_BASE + 20'h400 + 509)} == 16'hDABE,
           "the first IOPB of the chain did not read the label");
      want({mem_byte(DVMA_BASE + 20'h600),
            mem_byte(DVMA_BASE + 20'h600 + 1)} == 16'h45FA,
           "the second IOPB of the chain did not read the boot block");

      // --- five, the longest chain xychain() can build ---
      // One IOPB per unit plus the controller's own, XYUNPERC + 1.
      for (i = 0; i < 5; i++)
        build_iopb(20'h00100 + i*20'h20, (i == 4) ? 8'h92 : 8'hB2, 8'h02,
                   8'h00, 8'd0, i[7:0], 16'd0, 16'd1,
                   16'h0400 + i[15:0]*16'h200,
                   16'h0120 + i[15:0]*16'h20);
      for (i = 0; i < 2560; i++) mem_put(DVMA_BASE + 20'h400 + i, 8'h00);

      run_chain(16'h0100, irqs, got);
      want(got, "a five-IOPB chain never cleared GBSY");
      bad = 0;
      for (i = 0; i < 5; i++)
        if (iopb_get_at(20'h00100 + i*20'h20, 2)[0] !== 1'b1 ||
            iopb_get_at(20'h00100 + i*20'h20, 3) !== 8'h00) bad++;
      want(bad == 0, $sformatf("%0d of 5 chained IOPBs did not complete cleanly", bad));
      want(irqs == 1, $sformatf("%0d interrupts for a chain of five, want 1", irqs));
      want({mem_byte(DVMA_BASE + 20'h400 + 508),
            mem_byte(DVMA_BASE + 20'h400 + 509)} == 16'hDABE,
           "block 0 is not where the five-IOPB chain put it");
      want({mem_byte(DVMA_BASE + 20'h600),
            mem_byte(DVMA_BASE + 20'h600 + 1)} == 16'h45FA,
           "block 1 is not where the five-IOPB chain put it");

      // --- a hard error in the middle stops the chain dead ---
      // "The 450 terminates the chain with an error if one IOPB has a hard
      // error."  What matters to the driver is the *third* IOPB: xyintr()
      // skips anything without DONE and xychain() re-issues it verbatim, so
      // it must come back untouched rather than half-executed.
      build_iopb(20'h00100, 8'hB2, 8'h02, 8'h00, 8'd0, 8'd0, 16'd0, 16'd1,
                 16'h0400, 16'h0120);
      build_iopb(20'h00120, 8'hB2, 8'h02, 8'h01, 8'd0, 8'd0, 16'd0, 16'd1,
                 16'h0600, 16'h0140);        // unit 1: not fitted
      build_iopb(20'h00140, 8'h92, 8'h02, 8'h00, 8'd0, 8'd2, 16'd0, 16'd1,
                 16'h0800, 16'hBEEF);
      for (i = 0; i < 1536; i++) mem_put(DVMA_BASE + 20'h400 + i, 8'hFF);

      run_chain(16'h0100, irqs, got);
      want(got, "a chain with a hard error in it never cleared GBSY");
      want(iopb_get_at(20'h00100, 3) == 8'h00, "the IOPB before the error did not succeed");
      want(iopb_get_at(20'h00120, 3) == 8'h16,
           $sformatf("the failing IOPB reported %02x, want 16", iopb_get_at(20'h00120, 3)));
      want(iopb_get_at(20'h00120, 2)[7] == 1'b1,
           "the failing IOPB did not set its own error summary -- xyintr() would fail the whole chain");
      want(iopb_get_at(20'h00140, 2) == 8'h00,
           $sformatf("the IOPB after the error came back as %02x: it must be untouched",
                     iopb_get_at(20'h00140, 2)));
      want(mem_byte(DVMA_BASE + 20'h800) == 8'hFF,
           "the IOPB after the error transferred data anyway");
      pokec(XY_CSR, XY_ERROR, ok);

      // --- IEI: an interrupt per IOPB rather than one at the end ---
      build_iopb(20'h00100, 8'hB2, 8'h42, 8'h00, 8'd0, 8'd0, 16'd0, 16'd1,
                 16'h0400, 16'h0120);
      build_iopb(20'h00120, 8'h92, 8'h42, 8'h00, 8'd0, 8'd1, 16'd0, 16'd1,
                 16'h0600, 16'h0000);
      run_chain(16'h0100, irqs, got);
      want(got && irqs == 2,
           $sformatf("%0d interrupts with IEI set on a chain of two, want 2", irqs));

      // --- a chain that points back at itself ---
      // The real card gives up on an IOPB after two seconds; this one counts
      // instead, and reports the same completion code.
      build_iopb(20'h00100, 8'hB0, 8'h02, 8'h00, 8'd0, 8'd0, 16'd0, 16'd0,
                 16'h0000, 16'h0100);        // NOP, chained to itself
      run_chain(16'h0100, irqs, got);
      want(got, "a chain that points at itself never stopped");
      want(iopb_get_at(20'h00100, 3) == 8'h04,
           $sformatf("a cyclic chain reported %02x, want 04 (operation timeout)",
                     iopb_get_at(20'h00100, 3)));
      pokec(XY_CSR, XY_ERROR, ok);

      // ==================================================================
      // 12. The Attention protocol
      // ==================================================================
      // AACK does not mean "noted", it means "the chain is standing still".
      // Granting it in the middle of a transfer would invite software to
      // rewrite a link the controller is about to follow, so the check is not
      // that AACK arrives but *when*: the head must already be complete and
      // the second IOPB must not have started.
      build_iopb(20'h00100, 8'hB2, 8'h02, 8'h00, 8'd0, 8'd0, 16'd0, 16'd1,
                 16'h0400, 16'h0120);
      build_iopb(20'h00120, 8'h92, 8'h02, 8'h00, 8'd0, 8'd1, 16'd0, 16'd1,
                 16'h0600, 16'h0000);
      // Block 0, because it is the one sector with content this test can
      // recognise: blocks 2 upward are the zero padding after the boot block.
      build_iopb(20'h00140, 8'h92, 8'h02, 8'h00, 8'd0, 8'd0, 16'd0, 16'd1,
                 16'h0800, 16'h0000);
      for (i = 0; i < 1536; i++) mem_put(DVMA_BASE + 20'h400 + i, 8'h00);

      go_at(16'h0100);
      pokec(XY_CSR, XY_ATTN, ok);          // ... while the head is transferring
      for (i = 0; i < 100000; i++) begin
         peekc(XY_CSR, v, ok);
         if (v & XY_ACK) break;
      end
      want((v & XY_ACK) != 8'h00, "the Attention request was never acknowledged");
      want((v & XY_BUSY) != 8'h00, "GBSY dropped during an Attention pause");
      want(iopb_get_at(20'h00100, 2)[0] == 1'b1,
           "AACK was granted before the IOPB in progress had finished");
      want(iopb_get_at(20'h00120, 2)[0] == 1'b0,
           "the chain kept going while AACK was set");

      // Re-point the completed head at a different IOPB, which is what the
      // pause exists for: "you may modify CHEN and the Next IOPB Address, but
      // do not touch previously chained IOPBs that are not marked complete".
      iopb_put_at(20'h00100, 18, 8'h40);   // next = 0x0140
      iopb_put_at(20'h00100, 19, 8'h01);
      pokec(XY_CSR, 8'h00, ok);            // clear AREQ; the chain resumes

      for (i = 0; i < 100000; i++) begin
         peekc(XY_CSR, v, ok);
         if ((v & XY_BUSY) == 8'h00) break;
      end
      want((v & XY_BUSY) == 8'h00, "the chain never resumed after the Attention pause");
      want(iopb_get_at(20'h00140, 2)[0] == 1'b1,
           "the IOPB appended during the Attention pause was never executed");
      want(iopb_get_at(20'h00120, 2)[0] == 1'b0,
           "the IOPB that was unlinked during the pause ran anyway");
      want({mem_byte(DVMA_BASE + 20'h800 + 508),
            mem_byte(DVMA_BASE + 20'h800 + 509)} == 16'hDABE,
           "the appended IOPB completed without transferring anything");
      pokec(XY_CSR, XY_INTR, ok);

      $display("DVMA: %0d reads, %0d writes", dvma_reads, dvma_writes);
      $display("checks: %0d, failures: %0d", checks, fail);
      if (fail == 0) $display("PASS: sun2_xy450");
      else           $display("FAIL: sun2_xy450");
      $finish;
   end

   initial begin
      #200_000_000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
