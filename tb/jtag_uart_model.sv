//
// A model of altera_avalon_jtag_uart's Avalon-MM slave, good enough to test a
// master against.
//
// This exists because of a gap that turned into a bug.  The real IP ties its
// Atlantic port off under `translate_off', so it cannot be simulated -- which
// is why deca_jtag_console's FSM went to hardware with only a hand-trace of the
// protocol behind it, and why the first board run produced doubled and skipped
// characters that three readings of the source failed to explain.
//
// The protocol here is transcribed from the IP itself, not from the handbook:
//
//   :201  av_waitrequest resets to 1
//   :209  av_waitrequest <= ~(av_chipselect & (~av_write_n | ~av_read_n)
//                             & av_waitrequest)
//   :233  read_0 <= ~av_address        registered on the A->B edge
//   :240  fifo_rd = cs & ~read_n & waitrequest & ~address ? ~fifo_EF : 0
//   :242  DATA    = {..., rvalid, ..., fifo_rdata}      RVALID is bit 15
//   :243  CONTROL = {..., WSPACE, ...}                  bits 22:16
//
// So a transfer is two cycles: assert while waitrequest is 1, and it completes
// on the cycle where waitrequest is 0, with read data valid only then.
//
// The FIFOs are modelled with real depth, because "what happens when the host
// is not listening" is a behaviour the console depends on -- it drops rather
// than blocks, and that is only testable against a FIFO that can fill.
//
`timescale 1ns / 1ps

module jtag_uart_model #(
    parameter int WDEPTH = 64,        // host-bound, what WSPACE reports
    parameter int RDEPTH = 64         // machine-bound, what RVALID reports
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        av_address,
    input  wire        av_chipselect,
    input  wire        av_read_n,
    input  wire        av_write_n,
    input  wire [31:0] av_writedata,
    output reg  [31:0] av_readdata,
    output reg         av_waitrequest,

    // The far side: what the host would see and type.
    output reg  [7:0]  host_rx_data,      // a byte the design sent out
    output reg         host_rx_valid,
    input  wire [7:0]  host_tx_data,      // a byte the host is sending in
    input  wire        host_tx_push,
    output wire        host_tx_full,
    input  wire        drain               // is anyone listening?
);

   // Host-bound FIFO (the design writes, the "host" drains).
   int wcount;
   // Machine-bound FIFO (the "host" pushes, the design reads).
   reg [7:0] rfifo [0:RDEPTH-1];
   int rhead, rtail, rcount;

   assign host_tx_full = (rcount >= RDEPTH);

   wire [6:0] wspace = WDEPTH[6:0] - wcount[6:0];
   wire       rvalid = (rcount != 0);

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         av_waitrequest <= 1'b1;
         av_readdata    <= 32'h0;
         wcount         <= 0;
         rhead          <= 0;
         rtail          <= 0;
         rcount         <= 0;
         host_rx_valid  <= 1'b0;
      end else begin
         host_rx_valid <= 1'b0;

         // The host end.
         if (host_tx_push && !host_tx_full) begin
            rfifo[rhead] <= host_tx_data;
            rhead        <= (rhead + 1) % RDEPTH;
            rcount       <= rcount + 1;
         end
         if (drain && wcount > 0) wcount <= wcount - 1;

         // :209 verbatim.
         av_waitrequest <= ~(av_chipselect & (~av_write_n | ~av_read_n)
                             & av_waitrequest);

         // The transfer completes on the cycle where waitrequest is about to
         // fall -- i.e. while it is still 1 and chipselect is asserted.  That
         // is the same edge fifo_rd is evaluated on (:240).
         if (av_chipselect && av_waitrequest) begin
            if (!av_read_n) begin
               if (!av_address) begin
                  // DATA: pop, and report RVALID for the byte being returned.
                  av_readdata <= {9'h0, 7'h0, rvalid, 7'h0,
                                  (rcount != 0) ? rfifo[rtail] : 8'h00};
                  if (rcount != 0) begin
                     rtail  <= (rtail + 1) % RDEPTH;
                     rcount <= rcount - 1;
                  end
               end else begin
                  // CONTROL: WSPACE at 22:16, RVALID at 15.  Pops nothing.
                  av_readdata <= {9'h0, wspace, rvalid, 15'h0};
               end
            end
            if (!av_write_n && !av_address) begin
               if (wcount < WDEPTH) begin
                  wcount        <= wcount + 1;
                  host_rx_data  <= av_writedata[7:0];
                  host_rx_valid <= 1'b1;
               end
               // A write with no space is silently lost, as the real FIFO does.
            end
         end
      end
   end

endmodule
