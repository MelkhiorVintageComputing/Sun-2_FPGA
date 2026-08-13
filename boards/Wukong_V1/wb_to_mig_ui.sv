`timescale 1ns / 1ps

//
// Wishbone B4 classic slave  ->  MIG 7 Series native user interface.
//
// Replaces LiteX's WishboneDomainCrossingMaster plus LiteDRAM's Wishbone port.
// The Sun-2's memory master (rtl/sun2-common/sun2_wishbone_bridge.v) lives in the CPU clock
// domain and issues one 32-bit access at a time, stalling the 68010 on DTACK
// until it is answered, so this is deliberately a single-transaction-in-flight
// design: there is nothing to gain from pipelining and a great deal to lose in
// reviewability.
//
// Address mapping, read out of the generated MIG core rather than assumed
// (build/ip/sun2_mig/.../ui/mig_7series_v4_2_ui_cmd.v, MEM_ADDR_ORDER =
// "BANK_ROW_COLUMN"):
//
//     col  = app_addr[9:0]
//     row  = app_addr[23:10]
//     bank = app_addr[26:24]
//
// so app_addr counts in DDR3 words of DQ_WIDTH = 16 bits = 2 bytes, and with
// BURST_MODE = 8 and nCK_PER_CLK = 4 one user-interface beat moves a fixed
// burst of 8 of them = 16 bytes = 128 bits.  A burst must therefore start on an
// 8-word boundary, i.e. app_addr[2:0] == 0.
//
//     byte address = wb_adr * 4
//     app_addr     = byte address / 2, aligned down to 8
//                  = {wb_adr[25:2], 3'b000}
//     lane         = wb_adr[1:0]        which 32-bit quarter of the 128 bits
//
// wb_adr[25:2] covers the whole 256 MiB device; the Sun-2 only ever asks for
// the low 7 MiB of it.
//
// Sub-word writes need no read-modify-write: app_wdf_mask masks per byte.
//
// Clock domain crossing: a two-phase (toggle) request/acknowledge handshake
// with two-flop synchronisers.  Address, data, select and direction are
// captured in the Wishbone domain and held stable for the whole transaction,
// and the read data is captured in the MIG domain before its toggle flips, so
// only the two toggle bits actually cross.  Those paths want
// set_max_delay -datapath_only in the XDC; see syn/wukong_v1.xdc.
//

module wb_to_mig_ui #(
    parameter int APP_ADDR_WIDTH = 28,
    parameter int APP_DATA_WIDTH = 128,
    parameter int APP_MASK_WIDTH = APP_DATA_WIDTH / 8
) (
    // ---- Wishbone slave, CPU clock domain -------------------------------
    input  wire                      clk_wb,
    input  wire                      rst_wb,          // active high

    input  wire                      wb_cyc_i,
    input  wire                      wb_stb_i,
    input  wire [29:0]               wb_adr_i,        // 32-bit word address
    input  wire [31:0]               wb_dat_i,
    input  wire [3:0]                wb_sel_i,
    input  wire                      wb_we_i,
    output reg  [31:0]               wb_dat_o,
    output reg                       wb_ack_o,

    // ---- MIG user interface, ui_clk domain ------------------------------
    input  wire                      ui_clk,
    input  wire                      ui_rst,          // ui_clk_sync_rst, active high
    input  wire                      init_calib_complete,

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

   // ------------------------------------------------------------------
   // Shared state.  req_* are written only in the Wishbone domain and read
   // only in the MIG domain while a request is outstanding; rd_lane the other
   // way round.  Both are stable across their handshake, so neither needs a
   // synchroniser -- only the toggles below do.
   // ------------------------------------------------------------------
   reg [29:0] req_adr;
   reg [31:0] req_dat;
   reg [3:0]  req_sel;
   reg        req_we;
   reg [31:0] rd_lane;

   reg        req_tgl;      // toggles to launch a transaction   (clk_wb)
   reg        ack_tgl;      // toggles when one completes        (ui_clk)
   reg        busy;

   wire [1:0] lane = req_adr[1:0];

   // app_wdf_mask is active high: a 1 means "do not write this byte".  Mask
   // everything except the bytes wb_sel asks for, in the addressed lane.
   function automatic logic [APP_MASK_WIDTH-1:0] mask_for(input logic [1:0] l,
                                                          input logic [3:0] sel);
      logic [APP_MASK_WIDTH-1:0] m;
      begin
         m = '1;
         m[l*4 +: 4] = ~sel;
         mask_for = m;
      end
   endfunction

   // ------------------------------------------------------------------
   // Wishbone side: capture the request, hand it over, wait for the answer
   // ------------------------------------------------------------------
   reg  ack_tgl_s1, ack_tgl_s2, ack_tgl_s3;
   wire ack_pulse = ack_tgl_s2 ^ ack_tgl_s3;

   always @(posedge clk_wb) begin
      if (rst_wb) begin
         ack_tgl_s1 <= 1'b0;
         ack_tgl_s2 <= 1'b0;
         ack_tgl_s3 <= 1'b0;
      end else begin
         ack_tgl_s1 <= ack_tgl;
         ack_tgl_s2 <= ack_tgl_s1;
         ack_tgl_s3 <= ack_tgl_s2;
      end
   end

   always @(posedge clk_wb) begin
      if (rst_wb) begin
         busy     <= 1'b0;
         req_tgl  <= 1'b0;
         wb_ack_o <= 1'b0;
         wb_dat_o <= 32'h0;
         req_adr  <= 30'h0;
         req_dat  <= 32'h0;
         req_sel  <= 4'h0;
         req_we   <= 1'b0;
      end else begin
         wb_ack_o <= 1'b0;

         if (!busy) begin
            if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
               req_adr <= wb_adr_i;
               req_dat <= wb_dat_i;
               req_sel <= wb_sel_i;
               req_we  <= wb_we_i;
               req_tgl <= ~req_tgl;
               busy    <= 1'b1;
            end
         end else if (ack_pulse) begin
            wb_dat_o <= rd_lane;   // written before ack_tgl flipped, stable now
            wb_ack_o <= 1'b1;
            busy     <= 1'b0;
         end
      end
   end

   // ------------------------------------------------------------------
   // MIG side
   // ------------------------------------------------------------------
   reg  req_tgl_s1, req_tgl_s2, req_tgl_s3;
   wire req_pulse = req_tgl_s2 ^ req_tgl_s3;

   always @(posedge ui_clk) begin
      if (ui_rst) begin
         req_tgl_s1 <= 1'b0;
         req_tgl_s2 <= 1'b0;
         req_tgl_s3 <= 1'b0;
      end else begin
         req_tgl_s1 <= req_tgl;
         req_tgl_s2 <= req_tgl_s1;
         req_tgl_s3 <= req_tgl_s2;
      end
   end

   typedef enum logic [1:0] { S_IDLE, S_WRITE, S_READ, S_READ_WAIT } state_t;
   state_t state;

   // A write is two independent handshakes: MIG takes the command when app_rdy
   // is high and the data when app_wdf_rdy is, in either order, and either
   // ready may drop mid-transaction.  Track them separately and leave only when
   // both are done.
   reg  cmd_done, dat_done;
   wire cmd_ok = cmd_done | (app_en       & app_rdy);
   wire dat_ok = dat_done | (app_wdf_wren & app_wdf_rdy);

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
         ack_tgl      <= 1'b0;
         rd_lane      <= 32'h0;
      end else begin
         case (state)
           S_IDLE: begin
              app_en       <= 1'b0;
              app_wdf_wren <= 1'b0;
              app_wdf_end  <= 1'b0;
              cmd_done     <= 1'b0;
              dat_done     <= 1'b0;

              if (req_pulse && init_calib_complete) begin
                 app_addr <= {{(APP_ADDR_WIDTH-27){1'b0}}, req_adr[25:2], 3'b000};
                 app_en   <= 1'b1;
                 if (req_we) begin
                    app_cmd      <= CMD_WRITE;
                    // The same word in all four lanes; the mask decides which
                    // copy is actually written, so no read-modify-write.
                    app_wdf_data <= {4{req_dat}};
                    app_wdf_mask <= mask_for(req_adr[1:0], req_sel);
                    app_wdf_wren <= 1'b1;
                    app_wdf_end  <= 1'b1;    // single beat, so also the last
                    state        <= S_WRITE;
                 end else begin
                    app_cmd <= CMD_READ;
                    state   <= S_READ;
                 end
              end
           end

           S_WRITE: begin
              if (app_en       && app_rdy)     begin app_en       <= 1'b0; cmd_done <= 1'b1; end
              if (app_wdf_wren && app_wdf_rdy) begin app_wdf_wren <= 1'b0;
                                                     app_wdf_end  <= 1'b0; dat_done <= 1'b1; end
              if (cmd_ok && dat_ok) begin
                 ack_tgl <= ~ack_tgl;
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
                 rd_lane <= app_rd_data[lane*32 +: 32];
                 ack_tgl <= ~ack_tgl;
                 state   <= S_IDLE;
              end
           end

           default: state <= S_IDLE;
         endcase
      end
   end

endmodule
