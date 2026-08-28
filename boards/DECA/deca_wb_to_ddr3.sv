`timescale 1ns / 1ps

//
// Wishbone B4 classic slave  ->  BrianHG DDR3 controller command port.
//
// The DECA twin of boards/Wukong/wb_to_mig_ui.sv, and deliberately the same
// shape: the clock crossing and the 32-bit lane extraction are identical, and
// only the back end differs.  That file's client port was written abstract on
// purpose, and this is the first time that has been worth anything.
//
// The Sun-2's memory master (rtl/sun2-common/sun2_wishbone_bridge.v) lives in
// the CPU clock domain and issues one 32-bit access at a time, stalling the
// 68010 on DTACK until it is answered, so this is single-transaction-in-flight
// by design: there is nothing to gain from pipelining and much to lose in
// reviewability.
//
// ------------------------------------------------------- the address mapping
//
// CMD_addr is a **byte** address, and one command moves a whole cache line of
// PORT_CACHE_BITS = 8 * DDR3_WIDTH_DM * 8 = 128 bits = 16 bytes.  So:
//
//     byte address = wb_adr * 4
//     CMD_addr     = that, aligned down to 16   = {wb_adr[26:2], 4'b0000}
//     lane         = wb_adr[1:0]   which 32-bit quarter of the 128 bits
//
// The 128-bit line is the same width as MIG's user-interface beat, which is why
// the lane arithmetic transfers unchanged.  That is a coincidence of two
// 16-bit-wide DDR3 parts on a burst of 8, not a designed correspondence, and it
// would not survive a different DQ width.
//
// -------------------------------------------------- what is NOT like the MIG
//
// **The write mask polarity is inverted.**  MIG's app_wdf_mask is active high
// meaning "do not write this byte"; BrianHG's CMD_wmask is documented in
// BrianHG_DDR3_CONTROLLER_v16_top.sv:394 as "When low, the associated byte will
// not be written", i.e. active high meaning *do* write.  Reusing the Wukong's
// mask_for() unchanged would have written every byte the CPU did not ask for
// and none of the ones it did -- silently, and only on sub-word writes, which
// the boot PROM does constantly.  Read the polarity, never assume it.
//
// **The handshake is a strobe, not a level.**  MIG's client port here held
// c_req until c_done.  CMD_ena is a single-clock "send a command", accepted
// only while CMD_busy is low.  Completion differs by direction: a read finishes
// on CMD_read_ready, a write has no acknowledgement at all and is finished the
// moment it is accepted.
//
// --------------------------------------------------------- clock domains
//
// The controller's CMD_CLK is half the DDR3 rate -- 125 MHz for the 250 MHz
// build -- against the machine's 12.5 MHz.  The crossing is the same two-phase
// toggle handshake the Wukong uses, with three-stage synchronisers: address,
// data, select and direction are captured in the Wishbone domain and held
// stable for the whole transaction, and read data is captured in the DDR3
// domain before its toggle flips.  Only the two toggle bits actually cross.
//
module deca_wb_to_ddr3 #(
    parameter int PORT_ADDR_SIZE  = 29,
    parameter int PORT_CACHE_BITS = 128
) (
    // ---- Wishbone slave, CPU clock domain -------------------------------
    input  wire                        clk_wb,
    input  wire                        rst_wb,        // active high

    input  wire                        wb_cyc_i,
    input  wire                        wb_stb_i,
    input  wire [29:0]                 wb_adr_i,      // 32-bit word address
    input  wire [31:0]                 wb_dat_i,
    input  wire [3:0]                  wb_sel_i,
    input  wire                        wb_we_i,
    output reg  [31:0]                 wb_dat_o,
    output reg                         wb_ack_o,

    // ---- BrianHG command port, CMD_CLK domain ---------------------------
    input  wire                        cmd_clk,
    input  wire                        cmd_rst,       // active high
    input  wire                        ddr3_ready,

    input  wire                        CMD_busy,
    output wire                        CMD_ena,
    output wire                        CMD_write_ena,
    output wire [PORT_ADDR_SIZE-1:0]   CMD_addr,
    output wire [PORT_CACHE_BITS-1:0]  CMD_wdata,
    output wire [PORT_CACHE_BITS/8-1:0] CMD_wmask,
    input  wire                        CMD_read_ready,
    input  wire [PORT_CACHE_BITS-1:0]  CMD_read_data
);

   localparam int LANES = PORT_CACHE_BITS / 32;   // 4

   // Written only in the Wishbone domain and read only in the DDR3 domain
   // while a request is outstanding, and the other way round for rd_lane.  Both
   // are stable across their handshake, so neither needs a synchroniser -- only
   // the toggles do.
   reg [29:0] req_adr;
   reg [31:0] req_dat;
   reg [3:0]  req_sel;
   reg        req_we;
   reg [31:0] rd_lane;

   reg        req_tgl;      // toggles to launch a transaction   (clk_wb)
   reg        ack_tgl;      // toggles when one completes        (cmd_clk)
   reg        busy;

   wire [1:0] lane = req_adr[1:0];

   // Active HIGH = write this byte.  See the note above; this is the opposite
   // of the Wukong's.
   function automatic logic [PORT_CACHE_BITS/8-1:0] mask_for(input logic [1:0] l,
                                                             input logic [3:0] sel);
      logic [PORT_CACHE_BITS/8-1:0] m;
      begin
         m = '0;
         m[l*4 +: 4] = sel;
         mask_for = m;
      end
   endfunction

   // ------------------------------------------------------------------
   // Wishbone side
   // ------------------------------------------------------------------
   reg  ack_tgl_s1, ack_tgl_s2, ack_tgl_s3;
   wire ack_pulse = ack_tgl_s2 ^ ack_tgl_s3;

   always @(posedge clk_wb) begin
      if (rst_wb) begin
         ack_tgl_s1 <= 1'b0; ack_tgl_s2 <= 1'b0; ack_tgl_s3 <= 1'b0;
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
   // DDR3 side
   // ------------------------------------------------------------------
   reg  req_tgl_s1, req_tgl_s2, req_tgl_s3;
   wire req_pulse = req_tgl_s2 ^ req_tgl_s3;

   always @(posedge cmd_clk) begin
      if (cmd_rst) begin
         req_tgl_s1 <= 1'b0; req_tgl_s2 <= 1'b0; req_tgl_s3 <= 1'b0;
      end else begin
         req_tgl_s1 <= req_tgl;
         req_tgl_s2 <= req_tgl_s1;
         req_tgl_s3 <= req_tgl_s2;
      end
   end

   localparam [1:0] D_IDLE = 2'd0, D_SEND = 2'd1, D_READ = 2'd2;
   reg [1:0] dstate;

   // The request fields are combinational rather than registered, which looks
   // careless and is not: they are written in the Wishbone domain *before*
   // req_tgl flips, and req_pulse arrives three synchroniser stages later, so
   // they have been stable for several cmd_clk by the time the controller can
   // see them.  Registering them again would add a cycle to every CPU memory
   // access, and on the Wukong that measurably cost one of the seven clocks the
   // 68010 waits.
   assign CMD_addr      = {req_adr[PORT_ADDR_SIZE-5:2], 4'b0000};
   assign CMD_wdata     = {LANES{req_dat}};   // same word in every lane; the
                                              // mask picks which copy lands
   assign CMD_wmask     = mask_for(req_adr[1:0], req_sel);
   assign CMD_write_ena = req_we;
   // A single-clock strobe, and only while the controller can take it.  Held
   // off until ddr3_ready so nothing is issued during calibration.
   assign CMD_ena       = (dstate == D_SEND) && !CMD_busy && ddr3_ready;

   always @(posedge cmd_clk) begin
      if (cmd_rst) begin
         dstate  <= D_IDLE;
         ack_tgl <= 1'b0;
         rd_lane <= 32'h0;
      end else begin
         case (dstate)
           D_IDLE:
             if (req_pulse) dstate <= D_SEND;

           D_SEND:
             if (CMD_ena) begin
                // A write is finished the moment it is accepted -- there is no
                // write acknowledgement.  A read has to wait for its data.
                if (req_we) begin
                   ack_tgl <= ~ack_tgl;
                   dstate  <= D_IDLE;
                end else
                  dstate <= D_READ;
             end

           D_READ:
             if (CMD_read_ready) begin
                rd_lane <= CMD_read_data[lane*32 +: 32];
                ack_tgl <= ~ack_tgl;
                dstate  <= D_IDLE;
             end

           default: dstate <= D_IDLE;
         endcase
      end
   end

endmodule
