//
// 8N1 transmitter.
//
// The other half of the console bridge: bytes arriving from the host over the
// JTAG UART are serialised onto the machine's `rx' pin at 9600 baud, which is
// what the SCC's receiver expects to see.
//
// Same clock and the same reasoning as deca_uart_rx.sv: on clk_serial a bit is
// exactly 512 clocks, independent of CPU_HZ.
//
`timescale 1ns / 1ps

module deca_uart_tx #(
    parameter int CLKS_PER_BIT = 512
) (
    input  wire       clk,
    input  wire       rst,        // active high
    input  wire [7:0] data,
    input  wire       start,      // one clock; ignored unless ~busy
    output reg        tx,         // the serial line, idle high
    output wire       busy
);

   localparam int CW = $clog2(CLKS_PER_BIT + 1);

   localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

   reg [1:0]    state;
   reg [CW-1:0] cnt;
   reg [2:0]    bitn;
   reg [7:0]    sh;

   assign busy = (state != S_IDLE);

   always @(posedge clk) begin
      if (rst) begin
         state <= S_IDLE;
         tx    <= 1'b1;          // idle high, from reset
         cnt   <= '0;
      end else begin
         case (state)
           S_IDLE: begin
              tx <= 1'b1;
              if (start) begin
                 sh    <= data;
                 tx    <= 1'b0;   // start bit
                 cnt   <= '0;
                 bitn  <= 3'd0;
                 state <= S_START;
              end
           end

           S_START:
             if (cnt == CLKS_PER_BIT[CW-1:0] - 1) begin
                cnt   <= '0;
                tx    <= sh[0];
                sh    <= {1'b0, sh[7:1]};
                state <= S_DATA;
             end else
               cnt <= cnt + 1'b1;

           S_DATA:
             if (cnt == CLKS_PER_BIT[CW-1:0] - 1) begin
                cnt <= '0;
                if (bitn == 3'd7) begin
                   tx    <= 1'b1;      // stop bit
                   state <= S_STOP;
                end else begin
                   tx   <= sh[0];
                   sh   <= {1'b0, sh[7:1]};
                   bitn <= bitn + 1'b1;
                end
             end else
               cnt <= cnt + 1'b1;

           S_STOP:
             if (cnt == CLKS_PER_BIT[CW-1:0] - 1) begin
                cnt   <= '0;
                state <= S_IDLE;
             end else
               cnt <= cnt + 1'b1;
         endcase
      end
   end

endmodule
