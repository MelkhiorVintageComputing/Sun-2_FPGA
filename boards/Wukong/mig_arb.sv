`timescale 1ns / 1ps

//
// Two masters, one MIG user interface.
//
// Until now the CPU was the only thing that touched DDR3 and wb_to_mig_ui
// drove the app_* pins itself.  The frame buffer scan-out is a second master,
// and MIG has exactly one user port, so the transaction state machine moves
// here and both clients get a request port instead.
//
// Deliberately **one transaction in flight on the whole interface**.  MIG is
// configured with ORDERING = "NORM" and nothing in this project establishes
// what that guarantees about the order read data comes back in; the read path
// carries no tag, so a second outstanding read could be handed to the wrong
// client.  One at a time is slower and obviously correct.  If that ever needs
// to change, settle the ordering question from UG586 first, or regenerate the
// core with ORDERING = "STRICT".
//
// Round-robin rather than a fixed priority.  Strict CPU priority reads better
// -- the CPU is what the machine is waiting on -- but round-robin bounds the
// delay in *both* directions: the CPU waits at most one scan-out transaction,
// and the scan-out waits at most one CPU transaction.  Given how little of the
// interface the scan-out actually wants, the two behave almost identically in
// practice, and this one cannot starve either client no matter what the
// traffic looks like.
//
// What the scan-out costs, for the record.  A 1152x900 line is 144 bytes = 9
// beats of 16, and with one transaction in flight each beat costs the full MIG
// read latency of about 21 ui_clk, so a line is roughly 200 ui_clk = 2.4 us
// against a 14.8 us HDMI line period at 1080p60.  About a sixth of the
// interface, and only on the 900 lines of 1080 that show frame buffer.  The
// CPU's own worst case grows by one scan-out transaction, which is what
// tb_mig_ddr3 is there to measure rather than assume.
//
// Client 1 is read-only: the scan-out never writes, and saying so here is
// cheaper than carrying write ports it would tie off.
//
module mig_arb #(
    parameter int APP_ADDR_WIDTH = 28,
    parameter int APP_DATA_WIDTH = 128,
    parameter int APP_MASK_WIDTH = APP_DATA_WIDTH / 8
) (
    input  wire                      ui_clk,
    input  wire                      ui_rst,
    input  wire                      init_calib_complete,

    // ---- client 0: the CPU, read and write ------------------------------
    input  wire [APP_ADDR_WIDTH-1:0] c0_addr,
    input  wire                      c0_we,
    input  wire [APP_DATA_WIDTH-1:0] c0_wdata,
    input  wire [APP_MASK_WIDTH-1:0] c0_wmask,
    input  wire                      c0_req,     // held until c0_done
    output reg                       c0_done,    // one cycle; rdata valid with it
    output reg  [APP_DATA_WIDTH-1:0] c0_rdata,

    // ---- client 1: the scan-out, read only ------------------------------
    input  wire [APP_ADDR_WIDTH-1:0] c1_addr,
    input  wire                      c1_req,
    output reg                       c1_done,
    output reg  [APP_DATA_WIDTH-1:0] c1_rdata,

    // ---- MIG user interface ---------------------------------------------
    output reg  [APP_ADDR_WIDTH-1:0] app_addr,
    output reg  [2:0]                app_cmd,
    output reg                       app_en,
    input  wire                      app_rdy,

    output reg  [APP_DATA_WIDTH-1:0] app_wdf_data,
    output reg  [APP_MASK_WIDTH-1:0] app_wdf_mask,
    output reg                       app_wdf_wren,
    output reg                       app_wdf_end,
    input  wire                      app_wdf_rdy,

    input  wire [APP_DATA_WIDTH-1:0] app_rd_data,
    input  wire                      app_rd_data_valid
);

   localparam logic [2:0] CMD_WRITE = 3'b000;
   localparam logic [2:0] CMD_READ  = 3'b001;

   typedef enum logic [1:0] { S_IDLE, S_WRITE, S_READ, S_READ_WAIT } state_t;
   state_t state;

   reg       owner;        // which client the transaction in flight belongs to
   reg       last_owner;   // for the round robin

   // A write is two independent handshakes: MIG takes the command when app_rdy
   // is high and the data when app_wdf_rdy is, in either order, and either
   // ready may drop mid-transaction.  Track them separately and leave only
   // when both are done.
   reg       cmd_done, dat_done;
   wire      cmd_ok = cmd_done | (app_en       & app_rdy);
   wire      dat_ok = dat_done | (app_wdf_wren & app_wdf_rdy);

   // A client's request is still asserted during the cycle its own done comes
   // back -- done is a registered output, so the client cannot possibly have
   // dropped the request yet.  Masking it here is not politeness, it is
   // correctness: without it the arbiter returns to S_IDLE, sees the stale
   // request and immediately issues the whole transaction a second time.  That
   // is silent for a read, which merely fetches the same bytes again and costs
   // a full MIG latency, and it showed up as the CPU's memory access getting a
   // clock slower for no visible reason.
   wire      c0_ask = c0_req & ~c0_done;
   wire      c1_ask = c1_req & ~c1_done;

   // Round robin: when both ask, the one that did not go last wins.
   wire      pick = (c0_ask & c1_ask) ? ~last_owner
                  :  c0_ask           ? 1'b0
                  :                     1'b1;
   wire      any_req = c0_ask | c1_ask;

   always @(posedge ui_clk) begin
      if (ui_rst) begin
         state        <= S_IDLE;
         app_en       <= 1'b0;
         app_cmd      <= CMD_WRITE;
         app_addr     <= '0;
         app_wdf_wren <= 1'b0;
         app_wdf_end  <= 1'b0;
         app_wdf_data <= '0;
         app_wdf_mask <= '1;
         cmd_done     <= 1'b0;
         dat_done     <= 1'b0;
         owner        <= 1'b0;
         last_owner   <= 1'b1;
         c0_done      <= 1'b0;
         c1_done      <= 1'b0;
         c0_rdata     <= '0;
         c1_rdata     <= '0;
      end else begin
         c0_done <= 1'b0;
         c1_done <= 1'b0;

         case (state)
           S_IDLE: begin
              app_en       <= 1'b0;
              app_wdf_wren <= 1'b0;
              app_wdf_end  <= 1'b0;
              cmd_done     <= 1'b0;
              dat_done     <= 1'b0;

              if (any_req && init_calib_complete) begin
                 owner      <= pick;
                 last_owner <= pick;
                 app_en     <= 1'b1;

                 if (pick == 1'b0) begin
                    app_addr <= c0_addr;
                    if (c0_we) begin
                       app_cmd      <= CMD_WRITE;
                       app_wdf_data <= c0_wdata;
                       app_wdf_mask <= c0_wmask;
                       app_wdf_wren <= 1'b1;
                       app_wdf_end  <= 1'b1;   // single beat, so also the last
                       state        <= S_WRITE;
                    end else begin
                       app_cmd <= CMD_READ;
                       state   <= S_READ;
                    end
                 end else begin
                    // The scan-out only ever reads.
                    app_addr <= c1_addr;
                    app_cmd  <= CMD_READ;
                    state    <= S_READ;
                 end
              end
           end

           S_WRITE: begin
              if (app_en       && app_rdy)     begin app_en       <= 1'b0; cmd_done <= 1'b1; end
              if (app_wdf_wren && app_wdf_rdy) begin app_wdf_wren <= 1'b0;
                                                    app_wdf_end  <= 1'b0; dat_done <= 1'b1; end
              if (cmd_ok && dat_ok) begin
                 c0_done <= 1'b1;               // only client 0 writes
                 state   <= S_IDLE;
              end
           end

           S_READ: begin
              if (app_rdy) begin
                 app_en <= 1'b0;
                 state  <= S_READ_WAIT;
              end
           end

           S_READ_WAIT: begin
              if (app_rd_data_valid) begin
                 if (owner == 1'b0) begin
                    c0_rdata <= app_rd_data;
                    c0_done  <= 1'b1;
                 end else begin
                    c1_rdata <= app_rd_data;
                    c1_done  <= 1'b1;
                 end
                 state <= S_IDLE;
              end
           end

           default: state <= S_IDLE;
         endcase
      end
   end

endmodule
