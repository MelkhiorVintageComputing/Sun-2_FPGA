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
// Neither clk_serial nor cpu_clk: the board's own 50 MHz oscillator.  What
// decides this is not the baud arithmetic but **TCK**.  The JTAG Atlantic
// inside altera_avalon_jtag_uart crosses into the TCK domain, which the timing
// report puts at 10 MHz, and a user clock close to that rate reorders bytes --
// at 4.915 MHz, below TCK, the host read each byte twice and out of order; at
// 12.5 and 16.667 MHz, 1.25x and 1.67x, machine-to-host was clean and
// host-to-machine still came back with adjacent bytes swapped in pairs.  At
// 50 MHz, 5x TCK, a 48-character string echoes byte for byte.
//
// See boards/DECA/deca_top.sv for the full argument and the measurements that
// eliminated everything else -- the counters, the loopback build, and the IP's
// own source.
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
// Toward the host the bridge queues 2048 bytes and drops only when that is
// full -- 2.1 seconds of 9600-baud output, two M9K of the device's 182.  `tx'
// is a wire with nowhere to push back to, so blocking is not an option and
// something has to give eventually; the question is only how much slack there
// is first.  One byte was not enough.  The machine emits 960 bytes a second
// into a 64-byte JTAG FIFO, so a host that pauses for 67 ms leaves the bridge
// with nowhere to put the next byte, and it then overwrote the one it held --
// a silent loss mid-line, which is what truncated long output and left the
// shell looking hung until something made it print again.
//
// Toward the machine the DATA read is issued only when the serialiser is idle,
// so the JTAG UART's own 64-byte read FIFO *is* the flow control and nothing
// is ever lost.
//
`timescale 1ns / 1ps

module deca_jtag_console #(
    parameter int CLKS_PER_BIT = 512,
    // log2 of the host-bound queue, in bytes.  11 = 2048 = 2.1 seconds of
    // 9600-baud output for two M9K.  A parameter so a testbench can ask for a
    // small one and reach the full case in a reasonable number of cycles --
    // the drop behaviour is a mechanism, not a size, and testing it at the
    // shipping depth would mean simulating two seconds of serial line.
    parameter int FIFO_LOG2   = 11
) (
    input  wire clk,            // clk_serial
    input  wire rst,            // active high
    input  wire sun_tx,         // from the machine's `tx'
    output wire sun_rx,         // to the machine's `rx'
    output reg  dropped,        // sticky: at least one byte lost to a full FIFO
    output wire frame_err,      // sticky-ish: the receiver saw a bad stop bit

    // Event taps, for instrumentation.  One clock per occurrence.  They cost
    // nothing when nothing reads them, and a probe cannot be attached after the
    // fact without a rebuild -- so they are unconditional rather than behind a
    // define that would have to be remembered.
    output wire ev_rx_valid,    // the receiver decoded a byte from the machine
    output wire ev_wr_data,     // a byte was written to the host's FIFO
    output wire ev_rd_valid,    // a byte was read from the host with RVALID set
    output wire ev_tx_start     // a byte was handed to the serialiser
`ifdef SUN2_SIM
    ,
    // In simulation the JTAG UART is not instantiated -- the real IP ties its
    // Atlantic port off under translate_off, so it can neither transmit nor
    // receive there.  The Avalon master is brought out instead and a testbench
    // supplies tb/jtag_uart_model.sv, which transcribes the IP's own handshake.
    //
    // That gap is not academic: this FSM went to a board with only a hand-trace
    // of the protocol behind it, and produced doubled and skipped characters
    // that three readings of the source did not explain.
    output wire        av_address_o,
    output wire        av_chipselect_o,
    output wire        av_read_n_o,
    output wire        av_write_n_o,
    output wire [31:0] av_writedata_o,
    input  wire [31:0] av_readdata_i,
    input  wire        av_waitrequest_i
`endif
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
   assign av_address_o    = av_address;
   assign av_chipselect_o = av_chipselect;
   assign av_read_n_o     = av_read_n;
   assign av_write_n_o    = av_write_n;
   assign av_writedata_o  = av_writedata;
   assign av_readdata     = av_readdata_i;
   assign av_waitrequest  = av_waitrequest_i;
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
                    S_GAP     = 3'd4,   // chipselect low between transfers
                    S_TXW1    = 3'd5,   // wait for the serialiser to take it
                    S_TXW2    = 3'd6;   // ... and to finish

   reg [2:0] state;
   reg       wspace_ok;

   // ------------------------------------------------- the host-bound FIFO
   //
   // This used to be a single byte and a timeout, and that is not enough
   // elasticity for a console.  The machine emits 960 bytes a second and the
   // JTAG UART's own write FIFO is 64 deep, so a host that drains in bursts
   // only has to fall 67 ms behind for the bridge to have nowhere to put the
   // next byte.  It then overwrote the byte it was holding, which is a silent
   // loss in the middle of a line -- long output truncated and did not resume
   // until something else made the shell print again.
   //
   // The timeout made it worse rather than bounding it.  It was reset on every
   // arrival, so during continuous output it could never expire: the intended
   // "wait up to 84 ms, then give up on this byte" became "wait for as long as
   // the machine keeps talking", and every byte in the burst was dropped
   // rather than one.
   //
   // 2048 bytes is 2.1 seconds of 9600-baud output and costs two M9K of the
   // 182 on the device.  Dropping only when *that* is full keeps the property
   // the single byte was there to provide -- a machine with nobody listening
   // is never held up -- while making the case that actually happens, a host
   // that pauses, cost nothing.  It also means the boot banner survives until
   // a terminal attaches, instead of the first 65 bytes being all that is left
   // of it.
   localparam int FIFO_SIZE = (1 << FIFO_LOG2);

   reg [7:0]            fifo [0:FIFO_SIZE-1];
   reg [FIFO_LOG2:0]    wptr, rptr;
   reg [7:0]            fifo_q;

   wire [FIFO_LOG2:0]   fifo_used  = wptr - rptr;
   wire                 fifo_empty = (wptr == rptr);
   wire                 fifo_full  = (fifo_used == FIFO_SIZE[FIFO_LOG2:0]);

   // Registered read, so it infers an M9K rather than 2048 bytes of logic.
   // rptr only advances when a byte has been written to the host, and the FSM
   // takes several clocks to get from there to the next S_GAP, so fifo_q is
   // always settled by the time av_writedata is loaded from it.
   always @(posedge clk) fifo_q <= fifo[rptr[FIFO_LOG2-1:0]];

   // How long to wait before asking the JTAG UART about space again.  Polling
   // it back to back at 50 MHz is thousands of Avalon transfers per byte of
   // real output, for no gain: the machine produces one byte every millisecond,
   // so a retry every few microseconds is already far faster than it needs to
   // be, and it keeps the slave quiet while the host drains.
   reg [7:0] backoff;

   assign ev_rx_valid = rx_valid;
   assign ev_tx_start = tx_start;
   // The Avalon transfer completes on the cycle where waitrequest is low; these
   // count the ones that carried a DATA byte in each direction.
   assign ev_wr_data  = (state == S_WDAT) & ~av_waitrequest;
   assign ev_rd_valid = (state == S_RDAT) & ~av_waitrequest & av_readdata[15];


   always @(posedge clk) begin
      tx_start <= 1'b0;

      if (rst) begin
         state         <= S_IDLE;
         av_chipselect <= 1'b0;
         av_read_n     <= 1'b1;
         av_write_n    <= 1'b1;
         av_address    <= 1'b0;
         wspace_ok     <= 1'b0;
         wptr          <= '0;
         rptr          <= '0;
         backoff       <= 8'd0;
         dropped       <= 1'b0;
      end else begin
         if (backoff != 8'd0) backoff <= backoff - 8'd1;

         // The machine's output is queued the moment it appears, whatever the
         // FSM is doing.  A byte is only lost if 2048 of them are already
         // waiting, which means nobody has drained for two seconds.
         if (rx_valid) begin
            if (fifo_full) dropped <= 1'b1;
            else begin
               fifo[wptr[FIFO_LOG2-1:0]] <= rx_data;
               wptr <= wptr + 1'b1;
            end
         end

         case (state)
           S_IDLE: begin
              av_chipselect <= 1'b0;
              av_read_n     <= 1'b1;
              av_write_n    <= 1'b1;
              if (!fifo_empty && backoff == 8'd0) begin
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
           //
           // Chipselect drops for at least one idle cycle between every
           // transfer -- S_GAP below -- rather than being held across the
           // CONTROL read and the DATA write.  Holding it is legal Avalon and
           // it is what the first version did; on hardware it produced every
           // byte twice with every other byte lost, and a model of the slave
           // transcribed from the IP's own source did not reproduce it.  Rather
           // than keep guessing at which cycle the real slave latches, each
           // transfer now stands alone, which is unambiguous.  It costs two
           // clocks per byte at 9600 baud, i.e. nothing.
           S_WCTL:
             if (!av_waitrequest) begin
                av_chipselect <= 1'b0;
                av_read_n     <= 1'b1;
                if (av_readdata[22:16] != 7'd0) begin
                   wspace_ok <= 1'b1;
                   state     <= S_GAP;
                end else begin
                   // No room in the JTAG UART's own 64-byte FIFO yet.  Keep
                   // the byte -- it is safe in ours -- and come back shortly.
                   //
                   // Nothing is given up on here any more.  The byte is only
                   // lost if our 2048-deep FIFO fills behind it, which takes
                   // two seconds of a host that is not draining, and that
                   // decision belongs where the queue is rather than in a
                   // timer that a busy machine keeps resetting.
                   backoff <= 8'hFF;
                   state   <= S_IDLE;
                end
             end

           // One dead cycle with chipselect low, then the write.
           S_GAP: begin
              av_chipselect <= 1'b1;
              av_address    <= 1'b0;         // DATA
              av_writedata  <= {24'h0, fifo_q};
              av_write_n    <= 1'b0;
              wspace_ok     <= 1'b0;
              state         <= S_WDAT;
           end

           S_WDAT:
             if (!av_waitrequest) begin
                av_chipselect <= 1'b0;
                av_write_n    <= 1'b1;
                rptr          <= rptr + 1'b1;   // the byte is away; pop it
                state         <= S_IDLE;
             end

           S_RDAT:
             if (!av_waitrequest) begin
                av_chipselect <= 1'b0;
                av_read_n     <= 1'b1;
                if (av_readdata[15]) begin   // RVALID
                   tx_data  <= av_readdata[7:0];
                   tx_start <= 1'b1;
                   state    <= S_TXW1;
                end else
                  state <= S_IDLE;
             end

           // Wait for the serialiser to take the byte and finish with it.
           //
           // Without this the FSM returns to S_IDLE, sees tx_busy still low --
           // it does not rise until the clock *after* start is sampled -- and
           // issues another DATA read, which POPS the JTAG UART's receive FIFO.
           // That byte is then thrown away, because by the time the read
           // completes the serialiser is busy and ignores start.  Every other
           // character typed at the machine disappeared.
           //
           // This is the identical mistake that was already found and fixed in
           // the standalone test's pattern generator an hour earlier, and not
           // looked for here.  A stale `busy' is worth grepping for across a
           // whole design once it has been found once.
           S_TXW1:
             if (tx_busy) state <= S_TXW2;

           S_TXW2:
             if (!tx_busy) state <= S_IDLE;

           default: state <= S_IDLE;
         endcase
      end
   end

endmodule
