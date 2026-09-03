`timescale 1ns / 1ps
//
// sun2_blktrace: does each entry carry the LBA and the *signature of that
// transfer's own 512 bytes*?
//
// This test exists because the instrument shipped without one and gave a wrong
// answer on a board.  The write side folds `buf_rdata', which
// Inputs/Wish5380/doc/block.md:58 says answers `buf_addr' **one cycle late**;
// the first version folded it in the cycle the address changed, so every
// write-side signature was a fold over a byte sequence shifted by one.  It did
// not look broken.  It produced plausible 16-bit values that simply were not
// the block's, and 127 of 171 sectors of a correctly-copied file were reported
// corrupt before `cmp' on the machine showed the file's first difference lay
// past all of them.
//
// So the sharp check here is not "does a signature appear" but "is it the fold
// of exactly the bytes the buffer held, no more and no fewer".  The model
// below therefore reproduces the one-cycle read latency rather than answering
// combinationally, because a testbench that answers sooner than the hardware
// does is how tb_dvma missed a real timing bug in this same tree.
//
module tb_blktrace;

   localparam DL2 = 3, DEPTH = 1 << DL2;     // 8 entries, so wrap is cheap
   localparam SECTOR = 512;

   reg clk = 0, rst = 1;
   always #5 clk = ~clk;

   reg         blk_start = 0, blk_we = 0, blk_done = 0;
   reg  [31:0] blk_lba = 0;
   reg         buf_we = 0;
   reg  [8:0]  buf_addr = 0;
   reg  [7:0]  buf_wdata = 0;
   reg  [7:0]  buf_rdata = 0;

   reg  [DL2-1:0] rd_addr = 0;
   reg            rd_half = 0;
   wire [31:0]    rd_data;
   wire [15:0]    wr_ptr, n_xfer;

   sun2_blktrace #(.DEPTH_LOG2(DL2)) dut (
       .clk(clk), .rst(rst),
       .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
       .blk_done(blk_done),
       .blk_buf_we(buf_we), .blk_buf_addr(buf_addr),
       .blk_buf_wdata(buf_wdata), .blk_buf_rdata(buf_rdata),
       .rd_addr(rd_addr), .rd_half(rd_half), .rd_data(rd_data),
       .wr_ptr(wr_ptr), .n_xfer(n_xfer));

   integer errors = 0, checks = 0;
   task ck(input cond, input [511:0] name);
      begin
         checks = checks + 1;
         if (cond) $display("ok:   %0s", name);
         else begin $display("FAIL: %0s", name); errors = errors + 1; end
      end
   endtask

   // The same rotate-and-add the DUT computes, kept independent of it.
   function [15:0] fold(input [15:0] s, input [7:0] b);
      fold = {s[14:0], s[15]} + {8'h00, b};
   endfunction

   reg [7:0] sbuf [0:SECTOR-1];
   reg [15:0] expect_sig;

   // The sector buffer, answering one cycle late exactly as the seam specifies.
   always @(posedge clk) buf_rdata <= sbuf[buf_addr];

   task fill(input [31:0] seed);
      integer i;
      begin
         expect_sig = 16'd0;
         for (i = 0; i < SECTOR; i = i + 1) begin
            sbuf[i]    = (seed * 8'd7 + i * 8'd31 + (i >> 4)) & 8'hFF;
            expect_sig = fold(expect_sig, sbuf[i]);
         end
      end
   endtask

   task begin_xfer(input we, input [31:0] lba);
      begin
         @(posedge clk);
         blk_we <= we; blk_lba <= lba; blk_start <= 1'b1;
         @(posedge clk); blk_start <= 1'b0;
      end
   endtask

   task end_xfer;
      begin
         // Several idle clocks first: on a real card `done' arrives after the
         // CRC and response phase, and the delayed fold must have retired.
         repeat (6) @(posedge clk);
         blk_done <= 1'b1; @(posedge clk); blk_done <= 1'b0;
         @(posedge clk);
      end
   endtask

   // Buffer -> card.  `hold' is how many clocks each address is presented for;
   // blk_sd holds one for eight (a byte is eight SPI clocks), and an edge-on-
   // change detector must not fold a held address more than once.
   task write_xfer(input [31:0] lba, input [31:0] seed, input integer hold);
      integer i;
      begin
         fill(seed);
         begin_xfer(1'b1, lba);
         for (i = 0; i < SECTOR; i = i + 1) begin
            buf_addr <= i[8:0];
            repeat (hold) @(posedge clk);
         end
         end_xfer;
      end
   endtask

   // Card -> buffer.  Here `buf_wdata' is valid in the strobe cycle itself, so
   // this side has no latency to model and is the control for the other.
   task read_xfer(input [31:0] lba, input [31:0] seed, input integer hold);
      integer i;
      begin
         expect_sig = 16'd0;
         begin_xfer(1'b0, lba);
         for (i = 0; i < SECTOR; i = i + 1) begin
            buf_addr  <= i[8:0];
            buf_wdata <= (seed * 8'd11 + i * 8'd13) & 8'hFF;
            buf_we    <= 1'b1;
            expect_sig = fold(expect_sig, (seed * 8'd11 + i * 8'd13) & 8'hFF);
            @(posedge clk);
            buf_we <= 1'b0;
            repeat (hold - 1) @(posedge clk);
         end
         end_xfer;
      end
   endtask

   task readout(input [DL2-1:0] idx, output [31:0] key, output [15:0] sg);
      begin
         rd_addr <= idx; rd_half <= 1'b0; @(posedge clk); @(posedge clk);
         key = rd_data;
         rd_half <= 1'b1; @(posedge clk); @(posedge clk);
         sg = rd_data[15:0];
      end
   endtask

   reg [31:0] k; reg [15:0] s;
   reg [15:0] sig_a, sig_b;
   integer i;

   initial begin
      $display("=== sun2_blktrace ===");
      repeat (4) @(posedge clk);
      rst <= 1'b0; @(posedge clk);

      ck(n_xfer == 16'd0, "nothing captured before any transfer");
      ck(wr_ptr == 16'd0, "write pointer starts at zero");

      // ---- the regression for the one-cycle fold ----
      write_xfer(32'h0012_3456, 32'd3, 8);
      readout(0, k, s);
      ck(k[31] == 1'b1,                  "write transfer records we=1");
      ck(k[30:0] == 31'h0012_3456,       "write transfer records its LBA");
      ck(s == expect_sig,
         "WRITE signature is the fold of the 512 bytes the buffer held");
      ck(n_xfer == 16'd1,                "one transfer counted");
      ck(wr_ptr == 16'd1,                "write pointer advanced");
      sig_a = s;

      // ---- the read side, as a control ----
      read_xfer(32'h0000_00FF, 32'd5, 4);
      readout(1, k, s);
      ck(k[31] == 1'b0,                  "read transfer records we=0");
      ck(k[30:0] == 31'h0000_00FF,       "read transfer records its LBA");
      ck(s == expect_sig,
         "READ signature is the fold of the bytes written into the buffer");

      // ---- a held address must be folded once, not once per clock ----
      write_xfer(32'h0000_0007, 32'd3, 1);
      readout(2, k, s);
      ck(s == sig_a,
         "same data at a different address rate gives the same signature");

      // ---- the signature belongs to its own transfer ----
      write_xfer(32'h0000_0008, 32'd9, 8);
      readout(3, k, s);
      sig_b = s;
      ck(sig_b != sig_a,       "different data gives a different signature");
      ck(s == expect_sig,      "a second transfer is not polluted by the first");

      // ---- order matters: a plain XOR could not tell these apart ----
      fill(32'd3);
      begin_xfer(1'b1, 32'h0000_0009);
      for (i = SECTOR - 1; i >= 0; i = i - 1) begin      // same bytes, reversed
         buf_addr <= i[8:0];
         repeat (8) @(posedge clk);
      end
      end_xfer;
      readout(4, k, s);
      ck(s != sig_a, "the same bytes in a different order fold differently");

      // ---- a transfer that moves nothing records zero, not a stale value ----
      // Posed as a read, which is the case that really occurs: a read that
      // fails before its data phase must not inherit the last signature.
      begin_xfer(1'b0, 32'h0000_000A);
      end_xfer;
      readout(5, k, s);
      ck(s == 16'd0, "a transfer with no buffer activity records zero");
      ck(k[30:0] == 31'h0000_000A, "and still records its LBA");

      // ---- the key belongs to the transfer that started ----
      // The module latches {we, lba} at blk_start on purpose: a requester may
      // have set up its next request by the time this one finishes, and an
      // entry whose address came from a different transfer than its signature
      // would not look wrong -- it would look consistent, which is worse.
      fill(32'd17);
      begin_xfer(1'b1, 32'h0000_00C5);
      blk_lba <= 32'h7FFF_FFFF; blk_we <= 1'b0;      // the next request, early
      for (i = 0; i < SECTOR; i = i + 1) begin
         buf_addr <= i[8:0];
         repeat (2) @(posedge clk);
      end
      end_xfer;
      readout(6, k, s);
      ck(k[30:0] == 31'h0000_00C5, "the key is the LBA the transfer started with");
      ck(k[31] == 1'b1,            "and the direction it started with");
      ck(s == expect_sig,          "with the signature of that same transfer");

      // ---- the circular buffer wraps and unwraps ----
      write_xfer(32'h0000_00B0, 32'd21, 2);
      write_xfer(32'h0000_00B1, 32'd22, 2);
      write_xfer(32'h0000_00B2, 32'd23, 2);      // this one wraps to index 0
      ck(n_xfer == 16'd10,        "ten transfers counted");
      ck(wr_ptr == 16'd2,         "write pointer wrapped");
      readout(1, k, s);
      ck(k[30:0] == 31'h0000_00B2, "the oldest entry was overwritten by the newest");
      readout(0, k, s);
      ck(k[30:0] == 31'h0000_00B1, "the entry before it is still the previous one");

      $display("=== %0d checks, %0d failures ===", checks, errors);
      if (errors == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

endmodule
