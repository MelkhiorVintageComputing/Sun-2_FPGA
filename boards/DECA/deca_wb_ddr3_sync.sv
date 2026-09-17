`timescale 1ns / 1ps

//
// Wishbone master on CMD_CLK  ->  BrianHG DDR3 controller command port.
// No clock crossing.
//
// The partner of sun2_fifo_bridge on the DECA, as wb_mig_sync is on the
// Wukong.  The bridge runs its Wishbone side on the controller's own CMD_CLK,
// so the toggle handshake and synchronisers of deca_wb_to_ddr3 have already
// happened inside the bridge's FIFOs.  What is left is deca_wb_to_ddr3's back
// end, unchanged in every detail that matters:
//
//   CMD_addr  = {wb_adr[26:2], 4'b0000}   byte address of the 128-bit line
//   lane      = wb_adr[1:0]
//   CMD_wmask is active HIGH meaning *write* this byte -- the opposite of MIG
//   a write is finished when it is accepted; a read on CMD_read_ready
//
// The request fields come straight from the Wishbone inputs: the bridge holds
// them for the whole transaction.
//
// One transaction per Wishbone cycle.  The acknowledgement is registered and
// lasts one clock; the bridge drops CYC on the edge it samples it, so CYC is
// still high in the clock the acknowledgement is visible -- which is why IDLE
// will not start while wb_ack_o is high.
//
module deca_wb_ddr3_sync #(
    parameter int PORT_ADDR_SIZE  = 29,
    parameter int PORT_CACHE_BITS = 128
) (
    input  wire                         cmd_clk,
    input  wire                         cmd_rst,       // active high
    input  wire                         ddr3_ready,

    // ---- Wishbone slave, CMD_CLK domain -----------------------------------
    input  wire                         wb_cyc_i,
    input  wire                         wb_stb_i,
    input  wire [29:0]                  wb_adr_i,      // 32-bit word address
    input  wire [31:0]                  wb_dat_i,
    input  wire [3:0]                   wb_sel_i,
    input  wire                         wb_we_i,
    output reg  [31:0]                  wb_dat_o,
    output reg                          wb_ack_o,

    // ---- BrianHG command port ----------------------------------------------
    input  wire                         CMD_busy,
    output wire                         CMD_ena,
    output wire                         CMD_write_ena,
    output wire [PORT_ADDR_SIZE-1:0]    CMD_addr,
    output wire [PORT_CACHE_BITS-1:0]   CMD_wdata,
    output wire [PORT_CACHE_BITS/8-1:0] CMD_wmask,
    input  wire                         CMD_read_ready,
    input  wire [PORT_CACHE_BITS-1:0]   CMD_read_data
);

   localparam int LANES = PORT_CACHE_BITS / 32;   // 4

   // Active HIGH = write this byte (BrianHG_DDR3_CONTROLLER_v16_top.sv:394).
   function automatic logic [PORT_CACHE_BITS/8-1:0] mask_for(input logic [1:0] l,
                                                             input logic [3:0] sel);
      logic [PORT_CACHE_BITS/8-1:0] m;
      begin
         m = '0;
         m[l*4 +: 4] = sel;
         mask_for = m;
      end
   endfunction

   localparam [0:0] D_IDLE = 1'b0, D_READ = 1'b1;
   reg dstate;

   assign CMD_addr      = {wb_adr_i[PORT_ADDR_SIZE-3:2], 4'b0000};
   assign CMD_wdata     = {LANES{wb_dat_i}};
   assign CMD_wmask     = mask_for(wb_adr_i[1:0], wb_sel_i);
   assign CMD_write_ena = wb_we_i;
   // A single-clock strobe, only while the controller can take it, only once
   // per Wishbone cycle, and never during calibration.
   assign CMD_ena       = (dstate == D_IDLE) && wb_cyc_i && wb_stb_i && !wb_ack_o
                          && !CMD_busy && ddr3_ready;

   always @(posedge cmd_clk) begin
      if (cmd_rst) begin
         dstate   <= D_IDLE;
         wb_ack_o <= 1'b0;
         wb_dat_o <= 32'h0;
      end else begin
         wb_ack_o <= 1'b0;
         case (dstate)
           D_IDLE:
             if (CMD_ena) begin
                if (wb_we_i) wb_ack_o <= 1'b1;     // accepted is finished
                else         dstate   <= D_READ;
             end
           D_READ:
             if (CMD_read_ready) begin
                wb_dat_o <= CMD_read_data[wb_adr_i[1:0]*32 +: 32];
                wb_ack_o <= 1'b1;
                dstate   <= D_IDLE;
             end
         endcase
      end
   end

endmodule
