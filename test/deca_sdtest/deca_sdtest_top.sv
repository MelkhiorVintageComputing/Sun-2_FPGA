`timescale 1ns / 1ps

//
// The micro-SD path on its own: write blocks, read them back, count the
// mismatches.  No Sun-2 in it at all.
//
// Three different disk controllers on this board -- the MultiBus SCSI adapter,
// the VME SCSI/RTC board and the Xylogics 450 -- corrupt *large* file writes to
// the card in the same way, while small writes survive and reads are perfect.
// The three share no controller logic, so the fault is below them; and
// `make -C sim blksd' shows blk_sd putting the right bytes on the wire against
// a modelled card, including back-to-back blocks and realistic busy times.
//
// That leaves two candidates that a simulation cannot separate: the data the
// controller *puts* in the sector buffer, which comes through DVMA and DDR3, and
// the physical path -- the SN74AVCA406L translator, the SD clock rate, and the
// card itself at speed.  **This design removes the first one entirely.**  The
// pattern is generated in a few LUTs beside the buffer, so if a write comes back
// wrong here, nothing above blk_sd can be blamed for it.
//
// Where it writes.  The card is about 60,000,000 blocks; every filesystem this
// project keeps lives below 4096 MiB, which is block 8,388,608.  TEST_LBA is
// 20,000,000 -- roughly 9.5 GiB in -- so the walk cannot touch a filesystem
// even if the addressing is wrong by a long way.
//
// The pattern is derived from the block number as well as the offset, so a
// block written or read at the *wrong LBA* fails the compare rather than
// passing by looking like its neighbour.
//
module deca_sdtest_top #(
    parameter int  CLK_PERIOD_PS = 20000,        // 50 MHz
    parameter int  NBLOCKS       = 256,          // 128 KiB, ~ a 104-block file
    parameter longint TEST_LBA   = 20_000_000
) (
    input  wire        MAX10_CLK1_50,

    output wire        SD_CLK,
    output wire        SD_CMD,
    input  wire        SD_MISO,
    output wire        SD_CS_N,
    output wire        SD_DAT1,
    output wire        SD_DAT2,
    output wire        SD_SEL,
    output wire        SD_CMD_DIR,
    output wire        SD_D0_DIR,
    output wire        SD_D123_DIR,

    output wire [7:0]  LED
);

   // The level translator, exactly as boards/DECA/deca_top.sv sets it: four of
   // the pins carry no data, they steer the SN74AVCA406L, and in SPI mode all
   // four are constants.  SD_SEL = 0 puts 3.3 V on the card.
   assign SD_SEL      = 1'b0;
   assign SD_CMD_DIR  = 1'b1;   // MOSI, FPGA drives out
   assign SD_D0_DIR   = 1'b0;   // MISO, FPGA receives
   assign SD_D123_DIR = 1'b1;   // DAT3 as chip select, FPGA drives out
   assign SD_DAT1     = 1'b1;   // driven, not reserved: a reserved MAX 10 pin
   assign SD_DAT2     = 1'b1;   //   defaults to ground, which would hold the
                                //   card's DAT1/DAT2 low through the translator

   wire clk = MAX10_CLK1_50;

   logic rst = 1'b1;
   logic [7:0] rstc = '0;
   always_ff @(posedge clk) begin
      if (rstc != 8'hFF) begin rstc <= rstc + 8'd1; rst <= 1'b1; end
      else rst <= 1'b0;
   end

   // ------------------------------------------------------------------
   // The card
   // ------------------------------------------------------------------
   blk_req_t blk_req;
   blk_rsp_t blk_rsp;

   blk_sd #(.CLK_PERIOD_PS(CLK_PERIOD_PS)) sdcard (
       .clk_i(clk), .rst_i(rst),
       .blk_i(blk_req), .blk_o(blk_rsp),
       .sd_clk_o(SD_CLK), .sd_cs_n_o(SD_CS_N),
       .sd_mosi_o(SD_CMD), .sd_miso_i(SD_MISO));

   // ------------------------------------------------------------------
   // The sector buffer
   // ------------------------------------------------------------------
   // It belongs to the controller on a real machine, so it belongs here.  Two
   // users, never at the same time: blk_sd owns it during a transfer and the
   // walker owns it between transfers, so one address mux serves both and the
   // read stays registered -- which is the contract doc/block.md states and the
   // thing a same-cycle model would hide.
   logic [7:0] sbuf [0:511];
   logic [8:0] wa;
   logic [7:0] wd;
   logic       wwe;
   logic       walker_owns;

   wire [8:0] sb_addr = walker_owns ? wa : blk_rsp.buf_addr;
   wire       sb_we   = walker_owns ? wwe : blk_rsp.buf_we;
   wire [7:0] sb_wd   = walker_owns ? wd  : blk_rsp.buf_wdata;

   logic [7:0] sb_q;
   always_ff @(posedge clk) begin
      if (sb_we) sbuf[sb_addr] <= sb_wd;
      sb_q <= sbuf[sb_addr];
   end
   assign blk_req.buf_rdata = sb_q;

   // The byte this block and offset should hold.  Derived from both, so a
   // transfer that lands one block out is caught rather than excused.
   function automatic logic [7:0] pat(input logic [31:0] lba, input logic [8:0] off);
      return 8'(lba[7:0] * 8'd7) ^ 8'(off[7:0] * 8'd11) ^ 8'({7'd0, off[8]} + lba[15:8]);
   endfunction

   // ------------------------------------------------------------------
   // The walk
   // ------------------------------------------------------------------
   typedef enum logic [3:0] {
      W_WAIT, W_FILL, W_WRITE, W_WDONE,
      W_RSTART, W_RDONE, W_CHECK, W_NEXT, W_DONE
   } wst_t;
   wst_t st = W_WAIT;

   logic [31:0] blk = '0;
   logic [9:0]  off = '0;
   logic        pass2 = 1'b0;          // 0 = writing, 1 = reading back
   logic [15:0] n_err = '0;
   logic [15:0] n_blkerr = '0;         // blocks blk_sd reported an error on
   logic [31:0] first_bad = 32'hFFFF_FFFF;
   logic [7:0]  first_got = '0, first_want = '0;
   logic        done = 1'b0;

   wire [31:0] cur_lba = 32'(TEST_LBA) + blk;
   wire [8:0]  chk_off = off[8:0] - 9'd2;

   always_ff @(posedge clk) begin
      blk_req.start <= 1'b0;
      wwe           <= 1'b0;

      if (rst) begin
         st <= W_WAIT; blk <= '0; off <= '0; pass2 <= 1'b0;
         n_err <= '0; n_blkerr <= '0; done <= 1'b0;
         first_bad <= 32'hFFFF_FFFF;
         walker_owns <= 1'b1;
      end else case (st)

        W_WAIT: if (blk_rsp.ready) begin off <= '0; st <= W_FILL; end

        // ---- fill the buffer with this block's pattern ----
        W_FILL: begin
           walker_owns <= 1'b1;
           wa  <= off[8:0];
           wd  <= pat(cur_lba, off[8:0]);
           wwe <= 1'b1;
           if (off == 10'd511) begin off <= '0; st <= W_WRITE; end
           else off <= off + 10'd1;
        end

        W_WRITE: begin
           walker_owns   <= 1'b0;
           blk_req.we    <= 1'b1;
           blk_req.lba   <= cur_lba;
           blk_req.start <= 1'b1;
           st            <= W_WDONE;
        end

        W_WDONE: if (blk_rsp.done) begin
           if (blk_rsp.err) n_blkerr <= n_blkerr + 16'd1;
           st <= W_NEXT;
        end

        // ---- read it back ----
        W_RSTART: begin
           walker_owns   <= 1'b0;
           blk_req.we    <= 1'b0;
           blk_req.lba   <= cur_lba;
           blk_req.start <= 1'b1;
           st            <= W_RDONE;
        end

        W_RDONE: if (blk_rsp.done) begin
           if (blk_rsp.err) n_blkerr <= n_blkerr + 16'd1;
           walker_owns <= 1'b1;
           wa  <= 9'd0;
           off <= '0;
           st  <= W_CHECK;
        end

        // One byte per clock: set the address, and two clocks later compare
        // what the registered read returned for the address before it.
        W_CHECK: begin
           walker_owns <= 1'b1;
           wa <= off[8:0] + 9'd1;
           // Two behind the address, because the buffer read is registered:
           // the byte on sb_q now answers the address set two clocks ago.
           if (off >= 10'd2) begin
              if (sb_q != pat(cur_lba, chk_off)) begin
                 n_err <= n_err + 16'd1;
                 if (first_bad == 32'hFFFF_FFFF) begin
                    first_bad  <= {cur_lba[22:0], chk_off};
                    first_got  <= sb_q;
                    first_want <= pat(cur_lba, chk_off);
                 end
              end
           end
           if (off == 10'd513) begin off <= '0; st <= W_NEXT; end
           else off <= off + 10'd1;
        end

        W_NEXT: begin
           if (!pass2) begin
              // Write every block first, then read every block back.  Reading
              // each one straight after writing it would let a card that has
              // not finished programming still answer from its own buffer, and
              // that is the case a large file does *not* have.
              if (blk == 32'(NBLOCKS - 1)) begin
                 blk <= '0; pass2 <= 1'b1; st <= W_RSTART;
              end else begin
                 blk <= blk + 32'd1; off <= '0; st <= W_FILL;
              end
           end else begin
              if (blk == 32'(NBLOCKS - 1)) begin done <= 1'b1; st <= W_DONE; end
              else begin blk <= blk + 32'd1; st <= W_RSTART; end
           end
        end

        W_DONE: ;
        default: st <= W_WAIT;
      endcase
   end

   // ------------------------------------------------------------------
   // Reporting
   // ------------------------------------------------------------------
   altsource_probe #(
       .sld_auto_instance_index ("YES"),
       .instance_id             ("SDTS"),
       // 1+1+1+1 + 28 + 16 + 16 + 32 + 8 + 8 = 112.  Count it: a probe narrower
       // than its concatenation truncates silently and every field below the
       // cut reads as nonsense, which is how this project once recorded two
       // "it never triggered" results that were really a 66-bit word in a
       // 64-bit probe.
       .probe_width             (112),
       .source_width            (1),
       .enable_metastability    ("YES")
   ) u_issp (
       .probe  ({done, blk_rsp.ready, pass2, 1'b0,
                 blk_rsp.count[27:0],      // capacity, out of the card's CSD
                 n_err, n_blkerr,
                 first_bad,
                 first_got, first_want}),
       .source ()
   );

   // Active low, and readable from across the room: a card that never comes
   // ready and one that miscompares must not look alike.
   assign LED = ~{done, (n_err != 16'd0), (n_blkerr != 16'd0), blk_rsp.ready,
                  pass2, blk[2:0]};

endmodule
