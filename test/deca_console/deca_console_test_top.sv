//
// A console test with no Sun-2 in it.
//
// The same deca_clkgen, the same deca_jtag_console, the same two ALTPLLs and
// the same DECA pins as the real build -- driven by a pattern generator instead
// of by an MC68010.  No CPU, no MMU, no boot PROM, no on-chip RAM.
//
// It exists because of a circularity.  The DECA brings no serial port and no
// display to the FPGA, so the JTAG console is the *only* instrument this board
// has -- and when it does not work there is nothing left to debug it with.  A
// full build that shows no output leaves four candidates alive at once: the
// JTAG UART, the PLL ratio, the SCC, and whether the CPU ever started.  This
// design removes the last two by construction.
//
// The same argument, and the same shape, as test/hdmi -- which separated "the
// display path is broken" from "the Sun-2 build drives it wrongly" and settled
// in one run what a day of full builds had not.
//
// **It is not a time optimisation.**  Synthesising the whole machine takes
// about five minutes on this part; the saving here is minutes, not hours.  What
// it buys is isolation, and being the right first thing to run when a board
// arrives.
//
// ------------------------------------------------------------- what it does
//
// Two independent halves, so a one-way fault is visible as a one-way fault:
//
//   TRANSMIT.  A generator emits a repeating line of printable ASCII at 9600
//   baud onto the same wire the SCC would drive.  `juart-terminal' should show
//   it scrolling.  If it does, then the PLL ratio, the serialiser, the Avalon
//   handshake, the JTAG UART and the host tooling are all sound -- which is
//   most of what the real build depends on.
//
//   ECHO.  Anything typed comes back with bit 5 flipped, so lower case returns
//   upper.  That proves the receive direction end to end, and flipping a bit
//   rather than echoing verbatim means a host-side local echo cannot be
//   mistaken for a working path.  That distinction has fooled people before.
//
// SW[0] picks which: down is transmit, up is echo.  Running both at once would
// make a failure ambiguous, which is the opposite of the point.
//
`timescale 1ns / 1ps

module deca_console_test_top #(
    parameter int CPU_DIV = 80          // 12.5 MHz, as the real build
) (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [1:0]  SW,
    output wire [7:0]  LED,
    output wire [7:0]  GPIO0_D
);

   wire cpu_clk, clk_serial, pll_locked;

   deca_clkgen #(.CPU_DIV(CPU_DIV)) clkgen (
       .clk50      (MAX10_CLK1_50),
       .reset      (~KEY[0]),
       .clk_cpu    (cpu_clk),
       .clk_serial (clk_serial),
       .locked     (pll_locked)
   );

   wire reset = ~KEY[0] | ~pll_locked;

   wire ser_reset;
   reset_sync rst_ser (.clk(clk_serial),
                       .rst_async_in (reset),
                       .rst_sync_out (ser_reset));

   // ------------------------------------------------------------------
   // The bridge under test, wired exactly as deca_top wires it.
   // ------------------------------------------------------------------
   wire pat_tx;          // what we pretend the SCC is transmitting
   wire con_rx;          // what the host typed, serialised towards "the machine"
   wire con_dropped, con_frame_err;

   deca_jtag_console console (
       .clk       (clk_serial),
       .rst       (ser_reset),
       .sun_tx    (pat_tx),
       .sun_rx    (con_rx),
       .dropped   (con_dropped),
       .frame_err (con_frame_err)
   );

   // ------------------------------------------------------------------
   // Transmit: a scrolling line of printable ASCII.
   // ------------------------------------------------------------------
   localparam int CPB = 512;

   reg  [7:0] gen_byte;
   reg        gen_start;
   wire       gen_busy;
   reg  [5:0] col;
   reg [22:0] gap;

   deca_uart_tx #(.CLKS_PER_BIT(CPB)) u_gen (
       .clk (clk_serial), .rst (ser_reset),
       .data (gen_byte), .start (gen_start), .tx (pat_tx), .busy (gen_busy)
   );

   // ------------------------------------------------------------------
   // Echo: decode what the host sent, on its way back to "the machine".
   //
   // This taps con_rx -- the console's own output towards the CPU -- so the
   // whole receive path is under test: host, JTAG UART, Avalon read, RVALID,
   // and the serialiser.
   // ------------------------------------------------------------------
   wire [7:0] echo_data;
   wire       echo_valid;

   deca_uart_rx #(.CLKS_PER_BIT(CPB)) u_echo_rx (
       .clk (clk_serial), .rst (ser_reset), .rx (con_rx),
       .data (echo_data), .valid (echo_valid), .frame_err ()
   );

   reg [7:0] echo_seen;
   reg       echo_any;

   // One transmitter, two sources, chosen by the switch -- and ONE always
   // block driving it.  An earlier version had the pattern generator and the
   // echo path in separate always blocks both assigning gen_byte and
   // gen_start, which is a multiple-driver error.
   //
   // The handshake is explicit, and that is the second bug this generator had.
   // "if (!gen_busy) begin ...; gen_start <= 1; col <= col + 1; end" looks
   // right and is not: gen_busy rises a clock *after* the transmitter samples
   // start, so the condition is still true on the next edge and the block fires
   // two or three times, advancing col each time while only one byte actually
   // goes out.  On the board that came out as
   //
   //     !!%%)++//3377;;=??      instead of      !"#$%&'()*+,-./
   //
   // -- doubled characters, skipped characters, and CR CR where CR LF belongs.
   // Waiting for busy to rise and then fall is what makes one byte one byte.
   //
   // Worth recording plainly: deca_jtag_console and the two UART halves were
   // simulated (make -C sim decauart, 11 checks, two mutations), and this
   // generator was not, because it exists only in the test design.  The one
   // piece that went to hardware unsimulated is the one piece that was wrong.
   localparam [1:0] G_IDLE = 2'd0, G_TAKEN = 2'd1, G_SENDING = 2'd2;
   reg [1:0] gstate;

   always @(posedge clk_serial) begin
      gen_start <= 1'b0;

      if (ser_reset) begin
         col      <= 6'd0;
         gap      <= 23'd0;
         echo_any <= 1'b0;
         gstate   <= G_IDLE;
      end else begin
         if (gap != 23'd0) gap <= gap - 23'd1;

         case (gstate)
           G_IDLE:
             if (gap == 23'd0 && !gen_busy) begin
                if (SW[0] == 1'b0) begin
                   // Transmit: 62 printable characters then CR LF, and a pause,
                   // so a terminal shows something obviously periodic -- a stuck
                   // byte is then visible as a stuck *column*.
                   case (col)
                     6'd62:   gen_byte <= 8'h0D;
                     6'd63:   gen_byte <= 8'h0A;
                     default: gen_byte <= 8'h21 + {2'b0, col};
                   endcase
                   gen_start <= 1'b1;
                   gstate    <= G_TAKEN;
                end else if (echo_any) begin
                   // Echo: back it goes, case-flipped.  Not full duplex -- a
                   // byte arriving mid-transmit is lost, and a person cannot
                   // outrun 9600 baud.
                   gen_byte  <= echo_seen;
                   gen_start <= 1'b1;
                   echo_any  <= 1'b0;
                   gstate    <= G_TAKEN;
                end
             end

           G_TAKEN:                       // start was sampled; busy is coming
             if (gen_busy) gstate <= G_SENDING;

           G_SENDING:
             if (!gen_busy) begin
                if (SW[0] == 1'b0) begin
                   if (col == 6'd63) begin
                      col <= 6'd0;
                      gap <= 23'd1_228_813;      // a quarter second
                   end else
                     col <= col + 6'd1;
                end
                gstate <= G_IDLE;
             end

           default: gstate <= G_IDLE;
         endcase

         if (echo_valid) begin
            echo_seen <= echo_data ^ 8'h20;   // flip case, so a host-side local
            echo_any  <= 1'b1;                // echo cannot be mistaken for this
         end
      end
   end

   // ------------------------------------------------------------------
   // LEDs -- active low.  A dark terminal must still be distinguishable from
   // a dead clock, which is the same reason test/hdmi puts MMCM lock and a
   // pixel heartbeat on its LEDs.
   // ------------------------------------------------------------------
   reg [23:0] beat;
   always @(posedge clk_serial) beat <= beat + 24'd1;

   wire [7:0] status = {2'b00,
                        con_frame_err,     // [5] the PLL ratio is wrong
                        con_dropped,       // [4] a byte was lost: nobody listening
                        SW[0],             // [3] which mode
                        beat[21],          // [2] clk_serial is running
                        gen_busy,          // [1] the serialiser is working
                        pll_locked};       // [0] both PLLs locked
   assign LED     = ~status;
   assign GPIO0_D = {status[7:1], pat_tx};

endmodule
