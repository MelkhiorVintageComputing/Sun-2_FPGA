`timescale 1ns / 1ps

//
// blk_sd against a card, and above all: does a write put the right bytes on the
// wire?
//
// This exists because three different disk controllers on this board -- the
// MultiBus SCSI adapter, the VME SCSI/RTC board and the Xylogics 450 -- all
// corrupt *large* file writes to the micro-SD card in the same way, while small
// ones survive and reads are perfect.  Measured on hardware, copies read back
// from the medium after a reboot:
//
//     3 blocks    54006 -> 54006     ok
//    10 blocks    09808 -> 09808     ok
//   104 blocks    34435 -> 51819     corrupt
//   104 blocks    05453 -> 29364     corrupt
//   104 blocks    34435 -> 53822     corrupt
//
// Each corruption differs from the others, so it is a race rather than a
// transformation.  The Xylogics shares no controller logic with the SCSI cards
// at all -- different registers, different addressing, different DMA -- so the
// fault is in what is *below* them, and blk_sd is the first thing there.
//
// **Nothing has ever tested it.**  tb/blk_file.sv replaces this module in every
// existing simulation, so the SPI transport, the CMD24 write sequence and the
// sector buffer's read timing have run only on hardware.
//
// The two checks that matter are separate on purpose:
//
//   * what the *card* received, byte for byte, which is blk_sd's own output;
//   * what a read-back returns, which is the round trip.
//
// A test that only did the round trip could not tell a bad write from a bad
// read, which is the mistake that cost time when this was chased at the SCSI
// level.
//
module tb_blk_sd;

   localparam int CLK_PS = 20000;          // 50 MHz
   localparam int NBLK   = 64;

   logic clk = 1'b0, rst = 1'b1;
   always #10 clk = ~clk;                  // 20 ns

   blk_req_t blk_req;
   blk_rsp_t blk_rsp;

   wire sd_clk, sd_cs_n, sd_mosi;
   logic sd_miso;

   blk_sd #(.CLK_PERIOD_PS(CLK_PS)) dut (
       .clk_i(clk), .rst_i(rst),
       .blk_i(blk_req), .blk_o(blk_rsp),
       .sd_clk_o(sd_clk), .sd_cs_n_o(sd_cs_n),
       .sd_mosi_o(sd_mosi), .sd_miso_i(sd_miso));

   // ------------------------------------------------------------------
   // The sector buffer, which lives in the target and not in blk_sd
   // ------------------------------------------------------------------
   // doc/block.md: buf_rdata is the answer to buf_addr and arrives one cycle
   // later.  That one cycle is the whole reason this model is here rather than
   // a plain array -- a write engine that assumes the data is available in the
   // same cycle it sets the address sends every byte one position stale, and
   // only a registered model shows it.
   logic [7:0] sbuf [0:511];
   logic [7:0] sbuf_q;
   always @(posedge clk) begin
      if (blk_rsp.buf_we) sbuf[blk_rsp.buf_addr] <= blk_rsp.buf_wdata;
      sbuf_q <= sbuf[blk_rsp.buf_addr];
   end
   always @* blk_req.buf_rdata = sbuf_q;

   // ------------------------------------------------------------------
   // The card
   // ------------------------------------------------------------------
   // SPI mode 0, as sd_spi.sv drives it: the card samples MOSI on the rising
   // edge and changes MISO on the falling one.
   logic [7:0] media [0:NBLK*512-1];
   logic [7:0] wseen [0:511];       // what the card was actually sent
   int         wseen_n = 0;

   logic [7:0] rx_sh, tx_sh = 8'hFF;
   int         bitc = 0;
   logic [7:0] cmd [0:5];
   int         cmdn = 0;
   logic [7:0] rsp_q [$];
   bit         acmd41_seen = 0;
   bit         in_data = 0;         // receiving a CMD24 data packet
   int         dcnt = 0;
   int         wr_lba = 0;
   int         busy_len = 300;    // bytes the card stays busy after a write

   logic [7:0] csd [0:15];
   initial begin
      // CSD v2: C_SIZE = 15, so (15+1) * 512 KiB = 8 MiB = 16384 blocks.
      csd = '{8'h40,8'h0E,8'h00,8'h32,8'h5B,8'h59,8'h00,8'h00,
              8'h00,8'h0F,8'h7F,8'h80,8'h0A,8'h40,8'h00,8'h01};
   end

   assign sd_miso = tx_sh[7];

   // CRC16-CCITT, x^16 + x^12 + x^5 + 1, initial value zero.  blk_sd checks it
   // on read data -- "it is the only thing standing between a marginal card and
   // a silently corrupt sector" -- so a model that sends zeros makes every read
   // report an error, which is a fault in the model and not in the design.
   function automatic logic [15:0] crc16_b(input logic [15:0] c, input logic [7:0] b);
      logic [15:0] r = c;
      r = r ^ (16'(b) << 8);
      for (int i = 0; i < 8; i++)
        r = r[15] ? ((r << 1) ^ 16'h1021) : (r << 1);
      return r;
   endfunction

   function automatic void push_r1(input logic [7:0] r1);
      rsp_q.push_back(8'hFF);
      rsp_q.push_back(r1);
   endfunction

   // A command frame is complete: decide what the card answers.
   task automatic do_cmd();
      logic [5:0]  idx = cmd[0][5:0];
      logic [31:0] arg = {cmd[1], cmd[2], cmd[3], cmd[4]};
      case (idx)
        6'd0:  push_r1(8'h01);
        6'd8:  begin push_r1(8'h01);
               rsp_q.push_back(8'h00); rsp_q.push_back(8'h00);
               rsp_q.push_back(8'h01); rsp_q.push_back(8'hAA); end
        6'd55: push_r1(8'h01);
        6'd41: begin
           // Idle once, then ready -- a real card takes many polls and the
           // driver must survive both answers.
           push_r1(acmd41_seen ? 8'h00 : 8'h01);
           acmd41_seen = 1;
        end
        6'd58: begin push_r1(8'h00);
               rsp_q.push_back(8'hC0);   // CCS = 1: block addressing
               rsp_q.push_back(8'hFF); rsp_q.push_back(8'h80);
               rsp_q.push_back(8'h00); end
        6'd16: push_r1(8'h00);
        6'd9:  begin
               logic [15:0] c = '0;
               push_r1(8'h00);
               rsp_q.push_back(8'hFF);
               rsp_q.push_back(8'hFE);
               for (int i = 0; i < 16; i++) begin
                  rsp_q.push_back(csd[i]); c = crc16_b(c, csd[i]);
               end
               rsp_q.push_back(c[15:8]); rsp_q.push_back(c[7:0]); end
        6'd17: begin
               logic [15:0] c = '0;
               push_r1(8'h00);
               rsp_q.push_back(8'hFF);
               rsp_q.push_back(8'hFE);
               for (int i = 0; i < 512; i++) begin
                  rsp_q.push_back(media[arg*512 + i]);
                  c = crc16_b(c, media[arg*512 + i]);
               end
               rsp_q.push_back(c[15:8]); rsp_q.push_back(c[7:0]); end
        6'd24: begin push_r1(8'h00); wr_lba = arg; in_data = 1; dcnt = 0; end
        default: push_r1(8'h04);       // illegal command
      endcase
   endtask

   // One received byte.
   task automatic got_byte(input logic [7:0] b);
      if (in_data) begin
         if (dcnt == 0) begin
            if (b == 8'hFE) dcnt = 1;      // the start token; data follows
         end else if (dcnt <= 512) begin
            media[wr_lba*512 + (dcnt-1)] = b;
            if (wseen_n < 512) begin wseen[dcnt-1] = b; wseen_n = dcnt; end
            dcnt++;
         end else if (dcnt <= 514) begin
            dcnt++;                        // the two CRC bytes
            if (dcnt == 515) begin
               in_data = 0;
               rsp_q.push_back(8'hFF);
               rsp_q.push_back(8'h05);     // data accepted
               // Busy: the card holds the line low while it programmes, and a
               // real one does so for milliseconds, not microseconds -- the
               // whole reason blk_sd has a 500 ms guard here.  It also varies
               // block to block, which an idealised model hides: a host that
               // starts the next CMD24 while the card is still busy loses the
               // block, and that is a fault only a *large* write can show.
               for (int i = 0; i < busy_len; i++) rsp_q.push_back(8'h00);
               busy_len = 40 + ((busy_len * 7) % 900);
               rsp_q.push_back(8'hFF);
            end
         end
      end else if (cmdn > 0) begin
         cmd[cmdn] = b; cmdn++;
         if (cmdn == 6) begin cmdn = 0; do_cmd(); end
      end else if (b[7:6] == 2'b01) begin
         cmd[0] = b; cmdn = 1;
      end
   endtask

   always @(posedge sd_clk) if (!sd_cs_n) begin
      rx_sh <= {rx_sh[6:0], sd_mosi};
      if (bitc == 7) got_byte({rx_sh[6:0], sd_mosi});
   end

   always @(negedge sd_clk) if (!sd_cs_n) begin
      if (bitc == 7) begin
         bitc  <= 0;
         tx_sh <= (rsp_q.size() > 0) ? rsp_q.pop_front() : 8'hFF;
      end else begin
         bitc  <= bitc + 1;
         tx_sh <= {tx_sh[6:0], 1'b1};
      end
   end

   int fail = 0, checks = 0;
   task automatic want(input bit cond, input string what);
      checks++;
      if (!cond) begin $display("FAIL: %s", what); fail++; end
   endtask

   task automatic do_block(input bit we, input int lba);
      blk_req.we    <= we;
      blk_req.lba   <= lba;
      blk_req.start <= 1'b1;
      @(posedge clk);
      blk_req.start <= 1'b0;
      wait (blk_rsp.done);
      @(posedge clk);
   endtask

   initial begin
      $display("=== tb_blk_sd: the SD back end, and its write path ===");
      blk_req = '0;
      for (int i = 0; i < NBLK*512; i++) media[i] = 8'hA5;
      repeat (10) @(posedge clk);
      rst = 1'b0;

      // ---------------------------------------------------------------
      // 1. It initialises
      // ---------------------------------------------------------------
      fork
         begin wait (blk_rsp.ready); end
         begin #20_000_000; end
      join_any
      want(blk_rsp.ready, "init: the card came ready (CMD0/8/41/58/16/9)");
      want(blk_rsp.count > 0,
           $sformatf("init: a capacity came out of the CSD (%0d blocks)", blk_rsp.count));

      // ---------------------------------------------------------------
      // 2. A write puts the right bytes on the wire
      // ---------------------------------------------------------------
      // Checked at the card, not by reading back: this is the direction that
      // fails on hardware, and a round trip cannot say which half of it broke.
      for (int i = 0; i < 512; i++) sbuf[i] = 8'((i*7 + 8'h3D) & 8'hFF);
      wseen_n = 0;
      do_block(1'b1, 5);
      want(!blk_rsp.err, "write: no error reported");
      want(wseen_n == 512,
           $sformatf("write: the card received 512 data bytes (got %0d)", wseen_n));

      begin
         int bad = 0;
         for (int i = 0; i < 512; i++)
           if (wseen[i] != 8'((i*7 + 8'h3D) & 8'hFF)) begin
              if (bad < 6)
                $display("   write byte %0d: card got %02x, buffer held %02x",
                         i, wseen[i], 8'((i*7 + 8'h3D) & 8'hFF));
              bad++;
           end
         want(bad == 0,
              $sformatf("write: every byte on the wire is the byte in the buffer (%0d wrong)", bad));
      end

      // ---------------------------------------------------------------
      // 3. ...and it reads back
      // ---------------------------------------------------------------
      for (int i = 0; i < 512; i++) sbuf[i] = 8'h00;
      do_block(1'b0, 5);
      want(!blk_rsp.err, "read: no error reported");
      begin
         int bad = 0;
         for (int i = 0; i < 512; i++)
           if (sbuf[i] != 8'((i*7 + 8'h3D) & 8'hFF)) bad++;
         want(bad == 0,
              $sformatf("read: the block round-trips unchanged (%0d wrong)", bad));
      end

      // ---------------------------------------------------------------
      // 4. Back-to-back writes, which is what a large file is
      // ---------------------------------------------------------------
      // A 104-block file is 104 of these with nothing between them.  If the
      // engine leaves state behind -- a stale sector-buffer address, a CRC not
      // cleared, a busy wait cut short -- the first block is right and a later
      // one is not, which is exactly the hardware symptom.
      begin
         int bad = 0;
         for (int b = 0; b < 8; b++) begin
            for (int i = 0; i < 512; i++)
              sbuf[i] = 8'(((i + b*37)*11 + 8'h91) & 8'hFF);
            wseen_n = 0;
            do_block(1'b1, 10 + b);
            if (wseen_n != 512) bad++;
            for (int i = 0; i < 512; i++)
              if (wseen[i] != 8'(((i + b*37)*11 + 8'h91) & 8'hFF)) begin
                 if (bad < 6)
                   $display("   block %0d byte %0d: card got %02x want %02x",
                            b, i, wseen[i], 8'(((i + b*37)*11 + 8'h91) & 8'hFF));
                 bad++;
              end
         end
         want(bad == 0,
              $sformatf("write: eight back-to-back blocks all arrive intact (%0d wrong)", bad));
      end

      $display("=== tb_blk_sd: %0d checks, %0d failed ===", checks, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      #200_000_000;
      $display("FAIL: tb_blk_sd timed out");
      $finish;
   end

endmodule
