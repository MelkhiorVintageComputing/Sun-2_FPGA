`timescale 1ns / 1ps

//
// Behavioural stand-in for the MIG 7 Series native user interface.
//
// Enough of the protocol to check wb_to_mig_ui against: 128-bit beats, 16-bit
// active-high byte mask, app_addr counting 2-byte DDR3 words with BL8 bursts
// (so bits [2:0] are ignored, exactly as the real controller ignores them), and
// a read latency.
//
// The point is not to model DDR3 -- the real MIG plus Micron's model does that
// in the board testbench -- but to be awkward in the ways MIG is allowed to be:
// app_rdy and app_wdf_rdy drop at random, and the two can be granted in either
// order.  An adapter that only works when both readies are always high will
// fail here.
//

module mig_ui_model #(
    parameter int APP_ADDR_WIDTH = 28,
    parameter int APP_DATA_WIDTH = 128,
    parameter int APP_MASK_WIDTH = APP_DATA_WIDTH / 8,
    parameter int READ_LATENCY   = 7,     // ui_clk cycles from accept to valid
    parameter int STALL_PERCENT  = 30     // chance either ready is low
) (
    input  wire                      ui_clk,
    input  wire                      ui_rst,

    input  wire [APP_ADDR_WIDTH-1:0] app_addr,
    input  wire [2:0]                app_cmd,
    input  wire                      app_en,
    output reg                       app_rdy,

    input  wire [APP_DATA_WIDTH-1:0] app_wdf_data,
    input  wire [APP_MASK_WIDTH-1:0] app_wdf_mask,
    input  wire                      app_wdf_wren,
    input  wire                      app_wdf_end,
    output reg                       app_wdf_rdy,

    output reg  [APP_DATA_WIDTH-1:0] app_rd_data,
    output reg                       app_rd_data_valid
);

   localparam logic [2:0] CMD_WRITE = 3'b000;
   localparam logic [2:0] CMD_READ  = 3'b001;

   // One entry per 128-bit beat, keyed by app_addr >> 3.
   logic [APP_DATA_WIDTH-1:0] mem [int unsigned];

   int unsigned n_writes = 0, n_reads = 0;

   function automatic int unsigned beat_of(input logic [APP_ADDR_WIDTH-1:0] a);
      return a >> 3;                      // BL8: 8 DDR3 words per beat
   endfunction

   // Pending write data, waiting for its command (or the other way round)
   logic [APP_DATA_WIDTH-1:0] pend_data;
   logic [APP_MASK_WIDTH-1:0] pend_mask;
   bit                        have_data;
   bit                        have_cmd;
   logic [APP_ADDR_WIDTH-1:0] cmd_addr;
   logic [2:0]                cmd_kind;

   // read pipeline
   int  rd_timer;
   bit  rd_pending;
   int unsigned rd_beat;

   always @(posedge ui_clk) begin
      if (ui_rst) begin
         app_rdy           <= 1'b0;
         app_wdf_rdy       <= 1'b0;
         app_rd_data_valid <= 1'b0;
         app_rd_data       <= '0;
         have_data         <= 1'b0;
         have_cmd          <= 1'b0;
         rd_pending        <= 1'b0;
         rd_timer          <= 0;
      end else begin
         // Randomly withhold either ready, independently.
         app_rdy     <= ($urandom_range(99) >= STALL_PERCENT);
         app_wdf_rdy <= ($urandom_range(99) >= STALL_PERCENT);

         app_rd_data_valid <= 1'b0;

         // ---- command accepted -----------------------------------------
         if (app_en && app_rdy) begin
            // A BL8 burst must start on an 8-word boundary.  Both this model
            // and the real controller derive the beat as app_addr >> 3, so a
            // misaligned address would be silently ignored here while changing
            // the burst ordering on real hardware -- police it instead.
            if (app_addr[2:0] != 3'b000)
              $fatal(1, "mig_ui_model: app_addr %07x is not 8-word aligned; BL8 bursts require app_addr[2:0] == 0",
                     app_addr);
            if (app_cmd != CMD_READ && app_cmd != CMD_WRITE)
              $fatal(1, "mig_ui_model: unsupported app_cmd %b", app_cmd);

            cmd_addr <= app_addr;
            cmd_kind <= app_cmd;
            if (app_cmd == CMD_READ) begin
               if (rd_pending)
                 $fatal(1, "mig_ui_model: second read issued while one is outstanding");
               rd_beat    <= beat_of(app_addr);
               rd_timer   <= READ_LATENCY;
               rd_pending <= 1'b1;
               n_reads++;
            end else begin
               have_cmd <= 1'b1;
            end
         end

         // ---- write data accepted --------------------------------------
         if (app_wdf_wren && app_wdf_rdy) begin
            if (!app_wdf_end)
              $fatal(1, "mig_ui_model: app_wdf_end must be set on a single-beat write");
            pend_data <= app_wdf_data;
            pend_mask <= app_wdf_mask;
            have_data <= 1'b1;
         end

         // ---- both halves present: commit -------------------------------
         if ((have_cmd  || (app_en && app_rdy && app_cmd == CMD_WRITE)) &&
             (have_data || (app_wdf_wren && app_wdf_rdy))) begin
            begin : commit
               automatic logic [APP_ADDR_WIDTH-1:0] a =
                   have_cmd ? cmd_addr : app_addr;
               automatic logic [APP_DATA_WIDTH-1:0] d =
                   have_data ? pend_data : app_wdf_data;
               automatic logic [APP_MASK_WIDTH-1:0] m =
                   have_data ? pend_mask : app_wdf_mask;
               automatic int unsigned b = beat_of(a);
               automatic logic [APP_DATA_WIDTH-1:0] cur =
                   mem.exists(b) ? mem[b] : '0;
               for (int i = 0; i < APP_MASK_WIDTH; i++)
                 if (!m[i]) cur[i*8 +: 8] = d[i*8 +: 8];   // mask is active high
               mem[b] = cur;
               n_writes++;
            end
            have_cmd  <= 1'b0;
            have_data <= 1'b0;
         end

         // ---- read return ------------------------------------------------
         if (rd_pending) begin
            if (rd_timer > 0) rd_timer <= rd_timer - 1;
            else begin
               app_rd_data       <= mem.exists(rd_beat) ? mem[rd_beat] : '0;
               app_rd_data_valid <= 1'b1;
               rd_pending        <= 1'b0;
            end
         end
      end
   end

   task automatic report();
      $display("[mig_ui] %0d writes, %0d reads, %0d beats touched",
               n_writes, n_reads, mem.num());
   endtask

endmodule
