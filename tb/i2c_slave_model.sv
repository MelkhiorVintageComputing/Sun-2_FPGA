`timescale 1ns / 1ps

//
// An I2C target, decoded from the wire rather than from the master's intent.
//
// The point of a separate model is that it shares no code and no assumptions
// with the thing under test.  It watches SCL and SDA as a logic analyser would
// -- START is SDA falling while SCL is high, a bit is whatever SDA holds at the
// rising edge of SCL, STOP is SDA rising while SCL is high -- so a master that
// changes SDA while SCL is high, or samples the acknowledgement in the wrong
// place, produces garbage here instead of quietly working.
//
// Same shape as tb/mdio_phy_model.sv, which does this job for the PHY
// sequencers.
//
module i2c_slave_model #(
    parameter logic [7:0] SLAVE_ADDR = 8'h72,   // 8-bit write address
    parameter int         MAX_LOG    = 512
) (
    input  wire  scl,
    input  wire  sda,           // the wired-AND bus
    output reg   sda_oe         // 1 = this model pulls SDA low
);

   // What was written, in order, as {sub-address, data}.
   logic [15:0] log_q [0:MAX_LOG-1];
   int          n_writes = 0;

   // Last value seen at each sub-address, for spot checks.
   logic [7:0]  regs [0:255];
   logic        seen [0:255];

   int          n_starts = 0, n_stops = 0;
   int          bad_addr = 0;          // a START whose address byte was not ours

   typedef enum int { IDLE, ADDR, SUB, DATA, ACK } phase_t;
   phase_t      ph = IDLE;
   phase_t      after_ack = IDLE;

   logic [7:0]  shift   = 8'h0;
   int          bitno   = 0;
   logic [7:0]  cur_sub = 8'h0;
   bit          selected = 1'b0;

   initial begin
      sda_oe = 1'b0;
      for (int i = 0; i < 256; i++) begin regs[i] = 8'h0; seen[i] = 1'b0; end
   end

   // ---- START and STOP: an SDA edge while SCL is high ----
   always @(negedge sda) if (scl === 1'b1) begin
      n_starts++;
      ph       = ADDR;
      bitno    = 0;
      shift    = 8'h0;
      selected = 1'b0;
      sda_oe   = 1'b0;
   end

   always @(posedge sda) if (scl === 1'b1) begin
      n_stops++;
      ph     = IDLE;
      sda_oe = 1'b0;
   end

   // ---- bits are sampled on the rising edge of SCL ----
   always @(posedge scl) begin
      case (ph)
        ADDR, SUB, DATA: begin
           shift = {shift[6:0], (sda === 1'b1) ? 1'b1 : 1'b0};
           bitno++;
        end
        default: ;
      endcase
   end

   // ---- the acknowledgement is driven from the falling edge, so it is
   //      stable across the whole of the following SCL high ----
   always @(negedge scl) begin
      case (ph)
        ADDR, SUB, DATA:
          if (bitno == 8) begin
             case (ph)
               ADDR: begin
                  selected = (shift == SLAVE_ADDR);
                  if (!selected) bad_addr++;
                  after_ack = SUB;
               end
               SUB: begin
                  cur_sub   = shift;
                  after_ack = DATA;
               end
               DATA: begin
                  if (selected) begin
                     regs[cur_sub] = shift;
                     seen[cur_sub] = 1'b1;
                     if (n_writes < MAX_LOG) log_q[n_writes] = {cur_sub, shift};
                     n_writes++;
                  end
                  after_ack = SUB;     // a repeated write without a STOP
               end
               default: ;
             endcase
             // ACK only for our own address; a NAK is the honest answer
             // otherwise, and lets the test drive that case if it wants to.
             sda_oe = selected;
             ph     = ACK;
             bitno  = 0;
          end

        ACK: begin
           sda_oe = 1'b0;
           shift  = 8'h0;
           ph     = after_ack;
        end

        default: ;
      endcase
   end

endmodule
