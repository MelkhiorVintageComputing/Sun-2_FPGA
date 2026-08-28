//
// 8N1 receiver, 16x oversampling.
//
// One half of the bridge between the Sun-2's SCC and the DECA's JTAG UART.  The
// machine's console is a *serial line* -- z8530_scc.sv drives txda a bit at a
// time out of its own baud generator -- and this turns it back into bytes.
//
// Clocked on clk_serial, which is what makes the arithmetic exact rather than
// approximate: the SCC's pclk and this receiver share one clock, and
// 4915254/9600 = 512.005, so a bit is 512 clocks and a 16x sample is 32, by
// construction.  On cpu_clk it would be 12500000/9600 = 1302.083, a rounded
// divisor that moves whenever CPU_HZ or CPU_DIV moves -- a console whose
// framing depends on the CPU clock is a console that breaks the first time
// somebody changes frequency.
//
// The input is still synchronised even though both ends are on clk_serial.
// That is not superstition: `tx' leaves the SCC through the machine's own
// output register and comes back here across a chunk of the die, and a
// receiver that samples a line it does not own should say so.
//
`timescale 1ns / 1ps

`include "sun2_attr.vh"

module deca_uart_rx #(
    parameter int CLKS_PER_BIT = 512
) (
    input  wire       clk,
    input  wire       rst,          // active high
    input  wire       rx,           // the serial line, idle high
    output reg  [7:0] data,
    output reg        valid,        // one clock, when `data' is new
    output reg        frame_err     // stop bit was not high
);

   localparam int HALF = CLKS_PER_BIT / 2;
   localparam int CW   = $clog2(CLKS_PER_BIT + 1);

   `SUN2_ASYNC_REG reg rx_s1, rx_s2;
   always @(posedge clk) begin
      rx_s1 <= rx;
      rx_s2 <= rx_s1;
   end

   localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

   reg [1:0]    state;
   reg [CW-1:0] cnt;
   reg [2:0]    bitn;
   reg [7:0]    sh;

   always @(posedge clk) begin
      valid     <= 1'b0;
      frame_err <= 1'b0;

      if (rst) begin
         state <= S_IDLE;
         cnt   <= '0;
         bitn  <= 3'd0;
      end else begin
         case (state)
           S_IDLE:
             // A falling edge is a candidate start bit.  Half a bit later it
             // has to still be low, or it was noise.
             if (!rx_s2) begin
                state <= S_START;
                cnt   <= '0;
             end

           S_START:
             if (cnt == HALF[CW-1:0] - 1) begin
                if (!rx_s2) begin
                   state <= S_DATA;
                   cnt   <= '0;
                   bitn  <= 3'd0;
                end else
                   state <= S_IDLE;      // it was noise
             end else
               cnt <= cnt + 1'b1;

           S_DATA:
             // Now sampling mid-bit, one full bit apart.
             if (cnt == CLKS_PER_BIT[CW-1:0] - 1) begin
                cnt <= '0;
                sh  <= {rx_s2, sh[7:1]};   // LSB first
                if (bitn == 3'd7) state <= S_STOP;
                else              bitn  <= bitn + 1'b1;
             end else
               cnt <= cnt + 1'b1;

           S_STOP:
             if (cnt == CLKS_PER_BIT[CW-1:0] - 1) begin
                state     <= S_IDLE;
                cnt       <= '0;
                data      <= sh;
                valid     <= 1'b1;
                // Reported, not acted on.  A framing error here means the two
                // clocks disagree, which is a fact worth surfacing on an LED
                // rather than a byte worth discarding -- a garbled console is
                // far more informative than a silent one.
                frame_err <= ~rx_s2;
             end else
               cnt <= cnt + 1'b1;
         endcase
      end
   end

endmodule
