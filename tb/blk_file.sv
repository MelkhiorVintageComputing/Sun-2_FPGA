`timescale 1ns / 1ps

//
// A disk, in a file, behind the block interface.
//
// The seam is Inputs/Wish5380/doc/block.md: one 512-byte block at a time
// through a buffer that lives in the controller, `start` to begin, `done` when
// it is over.  On the board that seam has blk_sd and a card behind it; here it
// has an ordinary file, which is what makes the whole controller testable
// without simulating an SD card.
//
// The image is a byte-for-byte copy of what the Sun sees in memory -- see the
// byte-order note in rtl/sun2-multibus/sun2_xy450.sv.  tools/mkxydisk builds
// one; `dd if=/dev/rxy0a` on a real machine would produce the same thing.
//
// Writes go to an in-core copy and, if `blk_writeback` is given, back out to
// the file when the simulation ends.  Nothing needs that yet, but a Write
// command that could not be read back would be a poor test of a Write command.
//
module blk_file #(
    parameter int MAX_BLOCKS = 65536,        // 32 MiB is plenty for a boot test
    parameter int READ_CLOCKS = 200          // roughly an SD card's latency
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        blk_start,
    input  wire        blk_we,
    input  wire [31:0] blk_lba,
    input  wire [7:0]  blk_buf_rdata,        // the controller's buffer
    output reg         blk_done,
    output reg         blk_err,
    output reg         blk_ready,
    output reg [31:0]  blk_count,
    output reg         blk_buf_we,
    output reg [8:0]   blk_buf_addr,
    output reg [7:0]   blk_buf_wdata
);

   reg [7:0]  media [0:MAX_BLOCKS*512-1];
   string     image_file, writeback_file;
   integer    nbytes;

   // ------------------------------------------------------------------
   // Load
   // ------------------------------------------------------------------
   // $fread on a byte array reads the file as bytes, which is what we want and
   // is why the image is raw rather than hex.  With no +blk_image the drive
   // reports itself absent, and the machine has to cope with that too -- the
   // PROM prints "Waiting for disk to spin up..." and offers a way out.
   integer fd, i;
   initial begin
      blk_ready = 1'b0;
      blk_count = 32'd0;
      for (i = 0; i < MAX_BLOCKS*512; i = i + 1) media[i] = 8'h00;

      if ($value$plusargs("blk_image=%s", image_file)) begin
         fd = $fopen(image_file, "rb");
         if (fd == 0) begin
            $display("[blk] cannot open %s -- no media", image_file);
         end else begin
            nbytes = $fread(media, fd);
            $fclose(fd);
            blk_count = nbytes / 512;
            blk_ready = (blk_count != 0);
            $display("[blk] %s: %0d bytes, %0d blocks", image_file, nbytes, blk_count);
         end
      end else begin
         $display("[blk] no +blk_image: the drive reports itself absent");
      end
   end

   // ------------------------------------------------------------------
   // Save
   // ------------------------------------------------------------------
   final begin
      if ($value$plusargs("blk_writeback=%s", writeback_file)) begin
         fd = $fopen(writeback_file, "wb");
         if (fd == 0)
           $display("[blk] cannot write %s", writeback_file);
         else begin
            for (i = 0; i < blk_count*512; i = i + 1) $fwrite(fd, "%c", media[i]);
            $fclose(fd);
            $display("[blk] wrote %s, %0d blocks", writeback_file, blk_count);
         end
      end
   end

   // ------------------------------------------------------------------
   // The transfer
   // ------------------------------------------------------------------
   localparam int S_IDLE = 0, S_LAT = 1, S_RD = 2, S_WR_ADDR = 3,
                  S_WR_LAT = 4, S_WR = 5, S_END = 6;

   integer      st;
   integer      ctr;
   integer      idx;
   reg [31:0]   lba_l;
   reg          we_l;

   always @(posedge clk) begin
      blk_done   <= 1'b0;
      blk_buf_we <= 1'b0;

      if (rst) begin
         st  <= S_IDLE;
         blk_err <= 1'b0;
      end else case (st)
        S_IDLE:
          if (blk_start) begin
             lba_l   <= blk_lba;
             we_l    <= blk_we;
             blk_err <= 1'b0;
             ctr     <= READ_CLOCKS;
             st      <= S_LAT;
          end

        S_LAT:
          if (ctr != 0) ctr <= ctr - 1;
          else begin
             if (lba_l >= blk_count) begin
                blk_err <= 1'b1;
                st      <= S_END;
             end else begin
                idx <= 0;
                st  <= we_l ? S_WR_ADDR : S_RD;
             end
          end

        // media -> the controller's buffer
        S_RD: begin
           blk_buf_we    <= 1'b1;
           blk_buf_addr  <= idx[8:0];
           blk_buf_wdata <= media[lba_l*512 + idx];
           if (idx == 511) st <= S_END;
           else            idx <= idx + 1;
        end

        // the controller's buffer -> media.  blk_buf_rdata answers
        // blk_buf_addr one cycle late, so the address leads the data.
        S_WR_ADDR: begin
           blk_buf_addr <= idx[8:0];
           st           <= S_WR_LAT;
        end

        S_WR_LAT: st <= S_WR;

        S_WR: begin
           media[lba_l*512 + idx] <= blk_buf_rdata;
           if (idx == 511) st <= S_END;
           else begin idx <= idx + 1; st <= S_WR_ADDR; end
        end

        S_END: begin
           blk_done <= 1'b1;
           st       <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
   end

endmodule
