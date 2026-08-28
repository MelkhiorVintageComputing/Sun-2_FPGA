//
// The Sun-2's console, over the DECA's on-board USB-Blaster II.
//
// The DECA brings no UART to the FPGA at all -- no RS-232 transceiver, no
// USB-serial bridge -- so the machine's serial console has to leave the chip
// some other way.  This bridges it to an altera_avalon_jtag_uart, which the
// host reads with `juart-terminal'.
//
// ------------------------------------------------- why bit-serial, not bytes
//
// The obvious shortcut is to reach inside the SCC and take its byte stream
// directly.  That is rejected deliberately.  The one thing this board has to
// prove is that a MAX 10 PLL's 4.915254 MHz drives the SCC's own baud
// generator (WR4 x16, time constant 14) to a usable 9600 baud -- and tapping
// bytes would bypass exactly that.  Keeping the bit-serial contract means a
// wrong PLL ratio shows up as a garbled console instead of hiding behind a
// working one.  It also leaves rtl/ and the `top' seam completely untouched,
// so the Wukong build is provably unaffected by anything here.
//
// ------------------------------------------------------------- the clock
//
// clk_serial, not cpu_clk.  z8530_scc.sv drives txda from registers clocked on
// sclk_a, which sun2_fpga.v wires to clk4m9152 -- so `tx' and `rx' are already
// in this domain and the bridge crosses nothing.  4915254/9600 = 512.005, so a
// bit is exactly 512 clocks with no dependence on CPU_HZ or CPU_DIV.
//
// ---------------------------------------------- the Avalon-MM handshake
//
// Read out of altera_avalon_jtag_uart.sv rather than from the handbook, since
// this is the one part of the design that cannot be simulated -- the IP ties
// its Atlantic port off under translate_off, so there is nothing to simulate
// against.  From the source:
//
//   :201  av_waitrequest resets to 1
//   :209  av_waitrequest <= ~(chipselect & (~write_n | ~read_n) & waitrequest)
//
// so a transfer is exactly two cycles: assert in cycle A where waitrequest is
// still 1, and in cycle B it is 0 and the transfer has happened.  Read data is
// valid in B and nowhere else -- read_0 is registered on the A->B edge (:233),
// fifo_rd is combinational and true only during A (:240), and the read FIFO is
// lpm_showahead="OFF" so its q appears one clock after rdreq.  All three line
// up on the same edge.
//
// Register fields, from :242-243 with FIFO_WIDTH=8, RD_WIDTHU=WR_WIDTHU=6:
//
//   DATA    (av_address=0):  [7:0] byte, [15] RVALID
//   CONTROL (av_address=1):  [22:16] WSPACE, 0..64
//
// The FSM below conforms to the *specification* -- sample readdata on the edge
// where waitrequest is low -- rather than to that derivation, so the two agree
// and a mistake in my reading of the source cannot become a mistake in the
// logic.
//
// ------------------------------------------------------------ flow control
//
// Toward the host a byte with no room is **dropped, not held**.  `tx' is a
// wire; there is nowhere to push back to.  With no terminal attached the
// 64-byte write FIFO fills and WSPACE stays 0 for ever, so blocking would wedge
// the bridge permanently and the first bytes after a host attached would be
// stale.  The SCC produces a byte every 1.04 ms and the FIFO drains in
// microseconds once someone is listening, so dropping costs nothing.  Drops are
// counted and the flag goes to an LED, because a console that silently loses
// output is worse than one that says it did.
//
// Toward the machine the DATA read is issued only when the serialiser is idle,
// so the JTAG UART's own 64-byte read FIFO *is* the flow control and nothing is
// ever lost.
//
`timescale 1ns / 1ps

module deca_jtag_console #(
    parameter int CLKS_PER_BIT = 512
) (
    input  wire clk,            // clk_serial
    input  wire rst,            // active high
    input  wire sun_tx,         // from the machine's `tx'
    output wire sun_rx,         // to the machine's `rx'
    output reg  dropped,        // sticky: at least one byte lost to a full FIFO
    output wire frame_err       // sticky-ish: the receiver saw a bad stop bit
);

   // ---------------------------------------------------------- serial ends
   wire [7:0] rx_data;
   wire       rx_valid, rx_frame_err;

   deca_uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
       .clk       (clk),
       .rst       (rst),
       .rx        (sun_tx),          // the machine transmits; we receive
       .data      (rx_data),
       .valid     (rx_valid),
       .frame_err (rx_frame_err)
   );

   reg  [7:0] tx_data;
   reg        tx_start;
   wire       tx_busy;

   deca_uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
       .clk   (clk),
       .rst   (rst),
       .data  (tx_data),
       .start (tx_start),
       .tx    (sun_rx),              // we transmit; the machine receives
       .busy  (tx_busy)
   );

   reg fe_sticky;
   always @(posedge clk) if (rst) fe_sticky <= 1'b0; else if (rx_frame_err) fe_sticky <= 1'b1;
   assign frame_err = fe_sticky;

   // ------------------------------------------------------- the JTAG UART
   wire [31:0] av_readdata;
   wire        av_waitrequest;
   reg         av_address, av_chipselect, av_read_n, av_write_n;
   reg  [31:0] av_writedata;

`ifdef SUN2_SIM
   // The IP cannot be simulated -- its Atlantic port is tied off under
   // translate_off -- so a testbench gets a stub that never has room and never
   // has data.  tb_deca then exercises the UART halves and the FSM's timing
   // without pretending a host is attached.
   assign av_readdata    = 32'h00000000;
   assign av_waitrequest = 1'b0;
`else
   altera_avalon_jtag_uart #(
       .writeBufferDepth (64),
       .readBufferDepth  (64)
   ) u_juart (
       .clk            (clk),
       .rst_n          (~rst),
       .av_address     (av_address),
       .av_chipselect  (av_chipselect),
       .av_read_n      (av_read_n),
       .av_write_n     (av_write_n),
       .av_writedata   (av_writedata),
       .av_readdata    (av_readdata),
       .av_waitrequest (av_waitrequest),
       .av_irq         ()
   );
`endif

   // ---------------------------------------------------------------- FSM
   localparam [2:0] S_IDLE    = 3'd0,
                    S_WCTL    = 3'd1,   // read CONTROL, for WSPACE
                    S_WDAT    = 3'd2,   // write the byte
                    S_RDAT    = 3'd3,   // read DATA, for RVALID + byte
                    S_DONE    = 3'd4;

   reg [2:0] state;
   reg [7:0] pending;      // the byte waiting to go to the host
   reg       have_pending;

   always @(posedge clk) begin
      tx_start <= 1'b0;

      if (rst) begin
         state         <= S_IDLE;
         av_chipselect <= 1'b0;
         av_read_n     <= 1'b1;
         av_write_n    <= 1'b1;
         av_address    <= 1'b0;
         have_pending  <= 1'b0;
         dropped       <= 1'b0;
      end else begin
         // The machine's output is latched the moment it appears, whatever the
         // FSM is doing.  One byte of holding is enough: at 9600 baud the next
         // one is 1.04 ms away and the longest FSM path is a handful of clocks.
         if (rx_valid) begin
            if (have_pending) dropped <= 1'b1;
            pending      <= rx_data;
            have_pending <= 1'b1;
         end

         case (state)
           S_IDLE: begin
              av_chipselect <= 1'b0;
              av_read_n     <= 1'b1;
              av_write_n    <= 1'b1;
              if (have_pending) begin
                 av_address    <= 1'b1;      // CONTROL
                 av_chipselect <= 1'b1;
                 av_read_n     <= 1'b0;
                 state         <= S_WCTL;
              end else if (!tx_busy) begin
                 av_address    <= 1'b0;      // DATA
                 av_chipselect <= 1'b1;
                 av_read_n     <= 1'b0;
                 state         <= S_RDAT;
              end
           end

           // Sample on the edge where waitrequest is low: that is the cycle in
           // which the transfer completes and readdata is valid.
           S_WCTL:
             if (!av_waitrequest) begin
                av_chipselect <= 1'b0;
                av_read_n     <= 1'b1;
                if (av_readdata[22:16] != 7'd0) begin
                   av_address    <= 1'b0;    // DATA
                   av_writedata  <= {24'h0, pending};
                   av_chipselect <= 1'b1;
                   av_write_n    <= 1'b0;
                   state         <= S_WDAT;
                end else begin
                   // No room and nobody listening.  Drop it and say so.
                   dropped      <= 1'b1;
                   have_pending <= 1'b0;
                   state        <= S_IDLE;
                end
             end

           S_WDAT:
             if (!av_waitrequest) begin
                av_chipselect <= 1'b0;
                av_write_n    <= 1'b1;
                have_pending  <= 1'b0;
                state         <= S_IDLE;
             end

           S_RDAT:
             if (!av_waitrequest) begin
                av_chipselect <= 1'b0;
                av_read_n     <= 1'b1;
                if (av_readdata[15]) begin   // RVALID
                   tx_data  <= av_readdata[7:0];
                   tx_start <= 1'b1;
                end
                state <= S_IDLE;
             end

           default: state <= S_IDLE;
         endcase
      end
   end

endmodule
