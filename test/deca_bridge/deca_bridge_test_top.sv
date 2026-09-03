`timescale 1ns / 1ps

//
// The Sun-2's memory path on its own: 68010 bus cycles in, DDR3 out.
//
//   sun2_wishbone_bridge -> deca_wb_to_ddr3 -> BrianHG's controller -> DDR3
//
// Every disk controller on this board corrupts *large* file writes and none of
// them corrupts small ones, with reads perfect.  Four layers have been cleared
// by test and none of them was it: the micro-SD media (a new card fails the
// same way), the SD transport on real hardware (test/deca_sdtest walks 256
// blocks at 25 MHz with zero errors), blk_sd in simulation (`make -C sim
// blksd'), the SCSI engine and sun2_dvma (`make -C sim mbscsi', `dvma', both
// with sustained traffic against slow memory).
//
// What is left is this path, and it is the one thing all three controllers
// share.  It is also the one every simulation replaces with a byte array:
// tb_dvma answers 68010 cycles from a `logic [7:0] mem []', and
// test/deca_ddr3 drives BrianHG's controller *directly* without the adapter or
// the bridge in front of it.  So on hardware neither has ever been exercised
// alone.
//
// There is no CPU here and no MMU.  A walker drives the bridge's CPU side the
// way sun2_fpga does -- assert MATCH_MEM with an address, wait for W_ACK, drop
// it -- writes a pattern over 128 KiB, reads it all back and counts the words
// that differ.  If a word comes back wrong here, nothing above the bridge can
// be blamed for it.
//
// The pattern is derived from the address, so a cycle that lands at the wrong
// word fails rather than passing by resembling its neighbour.
//
// **clk_wb is 50/3 = 16.67 MHz on purpose.**  That is what the machine runs
// cpu_clk at (CPU_DIV=60), and the adapter crosses from it into the DDR3
// controller's own domain.  A clock-domain fault is not something to test at a
// convenient frequency.
//
module deca_bridge_test_top #(
    parameter int CLK_IN_MULT = 20,     // 50 * 20 / 4 = 250 MHz, as test/deca_ddr3
    parameter int CLK_IN_DIV  = 4,
    // 16-bit words.  65536 of them is 128 KiB, comparable to the 104-block
    // files that corrupt, and enough to cross rows and banks.
    parameter int NWORDS      = 65536,
    // Where in DDR3.  Clear of anything the machine would use for its own
    // memory image, though nothing else is running here anyway.
    parameter int WORD_BASE   = 32'h0002_0000
) (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    output wire [7:0]  LED,

    output wire        DDR3_RESET_n,
    output wire        DDR3_CK_p,
    output wire        DDR3_CK_n,
    output wire        DDR3_CKE,
    output wire        DDR3_CS_n,
    output wire        DDR3_RAS_n,
    output wire        DDR3_CAS_n,
    output wire        DDR3_WE_n,
    output wire        DDR3_ODT,
    output wire [14:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    inout  wire [1:0]  DDR3_DM,
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS_p,
    inout  wire [1:0]  DDR3_DQS_n
);

   localparam int PORT_CACHE_BITS = 128;
   localparam int PORT_ADDR_SIZE  = 29;

   // ------------------------------------------------------------------
   // Clocks
   // ------------------------------------------------------------------
   // 50 / 3, so the bridge and the adapter's Wishbone side see the frequency
   // the machine gives them rather than a round number.
   logic [1:0] div3 = '0;
   logic       clk_wb = 1'b0;
   always_ff @(posedge MAX10_CLK1_50) begin
      if (div3 == 2'd2) begin div3 <= '0; clk_wb <= ~clk_wb; end
      else div3 <= div3 + 2'd1;
   end

   wire        CMD_CLK, RST_OUT, DDR3_READY, SEQ_CAL_PASS, PLL_LOCKED;
   wire [7:0]  RDCAL_data;

   logic [7:0] rstc = '0;
   logic       rst_wb = 1'b1;
   always_ff @(posedge clk_wb) begin
      if (!DDR3_READY) begin rstc <= '0; rst_wb <= 1'b1; end
      else if (rstc != 8'hFF) begin rstc <= rstc + 8'd1; rst_wb <= 1'b1; end
      else rst_wb <= 1'b0;
   end

   // ------------------------------------------------------------------
   // The bridge
   // ------------------------------------------------------------------
   logic [22:0] p_adr;
   logic [15:0] p_din;
   wire  [15:0] p_dout;
   logic        p_rw_n, en_ub, en_lb, match_mem;
   wire         w_ack;

   wire        wb_cyc, wb_stb, wb_we, wb_ack;
   wire [29:0] wb_adr;
   wire [31:0] wb_dat_w, wb_dat_r;
   wire [3:0]  wb_sel;

   sun2_wishbone_bridge bridge (
       .SET_ENABLE (~rst_wb),        // a level here; the machine pulses it at 0x8F
       .RESET_n    (~rst_wb),
       .CLK        (clk_wb),
       .P_ADR_IN   (p_adr),
       .P_DATA_IN  (p_din),
       .P_DATA_OUT (p_dout),
       .P_RW_n     (p_rw_n),
       .EN_LBYTE   (en_lb),
       .EN_UBYTE   (en_ub),
       .FB_PAGE    (6'd0),
       .MATCH_MEM  (match_mem),
       .MATCH_FB   (1'b0),
       .W_ACK      (w_ack),
       .wb_cyc_o   (wb_cyc), .wb_stb_o (wb_stb),
       .wb_adr_o   (wb_adr), .wb_dat_o (wb_dat_w),
       .wb_sel_o   (wb_sel), .wb_we_o  (wb_we),
       .wb_dat_i   (wb_dat_r), .wb_ack_i (wb_ack));

   // ------------------------------------------------------------------
   // The adapter and the controller
   // ------------------------------------------------------------------
   wire                          cmd_busy       [0:0];
   wire                          cmd_read_ready [0:0];
   wire  [PORT_CACHE_BITS-1:0]   cmd_read_data  [0:0];
   wire  [7:0]                   cmd_rvec_out   [0:0];

   wire                          w_cmd_ena, w_cmd_we;
   wire [PORT_ADDR_SIZE-1:0]     w_cmd_addr;
   wire [PORT_CACHE_BITS-1:0]    w_cmd_wdata;
   wire [PORT_CACHE_BITS/8-1:0]  w_cmd_wmask;

   logic                         cmd_ena        [0:0];
   logic                         cmd_write_ena  [0:0];
   logic [PORT_ADDR_SIZE-1:0]    cmd_addr       [0:0];
   logic [PORT_CACHE_BITS-1:0]   cmd_wdata      [0:0];
   logic [PORT_CACHE_BITS/8-1:0] cmd_wmask      [0:0];
   logic [7:0]                   cmd_rvec_in    [0:0];
   logic                         cmd_boost      [0:0];

   always_comb begin
      cmd_ena[0]       = w_cmd_ena;
      cmd_write_ena[0] = w_cmd_we;
      cmd_addr[0]      = w_cmd_addr;
      cmd_wdata[0]     = w_cmd_wdata;
      cmd_wmask[0]     = w_cmd_wmask;
      cmd_rvec_in[0]   = 8'h00;
      cmd_boost[0]     = 1'b0;
   end

   deca_wb_to_ddr3 #(.PORT_ADDR_SIZE(PORT_ADDR_SIZE),
                     .PORT_CACHE_BITS(PORT_CACHE_BITS)) memif (
       .clk_wb   (clk_wb),
       .rst_wb   (rst_wb),
       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb),
       .wb_adr_i (wb_adr), .wb_dat_i (wb_dat_w),
       .wb_sel_i (wb_sel), .wb_we_i  (wb_we),
       .wb_dat_o (wb_dat_r), .wb_ack_o (wb_ack),

       .cmd_clk        (CMD_CLK),
       .cmd_rst        (RST_OUT),
       .ddr3_ready     (DDR3_READY),
       .CMD_busy       (cmd_busy[0]),
       .CMD_ena        (w_cmd_ena),
       .CMD_write_ena  (w_cmd_we),
       .CMD_addr       (w_cmd_addr),
       .CMD_wdata      (w_cmd_wdata),
       .CMD_wmask      (w_cmd_wmask),
       .CMD_read_ready (cmd_read_ready[0]),
       .CMD_read_data  (cmd_read_data[0]));

   BrianHG_DDR3_CONTROLLER_v16_top #(
       .FPGA_VENDOR     ("Altera"),
       .FPGA_FAMILY     ("MAX 10"),
       .CLK_KHZ_IN      (50000),
       .CLK_IN_MULT     (CLK_IN_MULT),
       .CLK_IN_DIV      (CLK_IN_DIV),
       .INTERFACE_SPEED ("Half"),
       .DDR3_SIZE_GB    (4),
       .DDR3_WIDTH_DQ   (16),
       .DDR3_NUM_CHIPS  (1),
       .PORT_TOTAL      (1),
       // The same three the machine sets to zero.  A read cache with a timeout
       // counted in clocks, against a CPU whose access spacing is also fixed in
       // clocks, gives a fault that is frequency-dependent and deterministic --
       // which is what once made `sd(2,0,0)' out of a bus that was working.
       .PORT_W_CACHE_TOUT ('{16{9'd0}}),
       .PORT_R_CACHE_TOUT ('{16{9'd0}}),
       .PORT_CACHE_SMART  ('{16{1'b0}})
   ) ddr3 (
       .RST_IN   (~KEY[0]),
       .CLK_IN   (MAX10_CLK1_50),
       .DDR3_CLK (), .DDR3_CLK_50 (), .DDR3_CLK_25 (),
       .CMD_CLK      (CMD_CLK),
       .RST_OUT      (RST_OUT),
       .DDR3_READY   (DDR3_READY),
       .SEQ_CAL_PASS (SEQ_CAL_PASS),
       .PLL_LOCKED   (PLL_LOCKED),
       .RDCAL_data   (RDCAL_data),

       .CMD_busy            (cmd_busy),
       .CMD_ena             (cmd_ena),
       .CMD_write_ena       (cmd_write_ena),
       .CMD_addr            (cmd_addr),
       .CMD_wdata           (cmd_wdata),
       .CMD_wmask           (cmd_wmask),
       .CMD_read_vector_in  (cmd_rvec_in),
       .CMD_read_ready      (cmd_read_ready),
       .CMD_read_data       (cmd_read_data),
       .CMD_read_vector_out (cmd_rvec_out),
       .CMD_priority_boost  (cmd_boost),
       .SEQ_refresh_hold    (1'b0),

       .DDR3_RESET_n (DDR3_RESET_n), .DDR3_CK_p (DDR3_CK_p), .DDR3_CK_n (DDR3_CK_n),
       .DDR3_CKE (DDR3_CKE), .DDR3_CS_n (DDR3_CS_n), .DDR3_RAS_n (DDR3_RAS_n),
       .DDR3_CAS_n (DDR3_CAS_n), .DDR3_WE_n (DDR3_WE_n), .DDR3_ODT (DDR3_ODT),
       .DDR3_A (DDR3_A), .DDR3_BA (DDR3_BA), .DDR3_DM (DDR3_DM),
       .DDR3_DQ (DDR3_DQ), .DDR3_DQS_p (DDR3_DQS_p), .DDR3_DQS_n (DDR3_DQS_n));

   // ------------------------------------------------------------------
   // The walk
   // ------------------------------------------------------------------
   function automatic logic [15:0] pat(input logic [31:0] w);
      return {w[7:0] ^ 8'hA5, w[15:8] ^ 8'h3C} ^ {w[23:16], w[23:16]};
   endfunction

   typedef enum logic [2:0] { B_IDLE, B_DRIVE, B_ACK, B_GAP, B_DONE } bst_t;
   bst_t st = B_IDLE;

   logic [31:0] widx = '0;
   // Four passes, because the machine's traffic is not one shape.  The first
   // two are a bulk write then a bulk read.  The third interleaves them word by
   // word, which is what the bridge's issued/done state and its P_DATA_OUT
   // register actually see during a transfer.  The fourth uses one byte enable
   // at a time: wb_sel_o is built differently for a read than for a write, and
   // nothing above has ever exercised the write side of that on hardware.
   logic [1:0]  phase = 2'd0;
   logic [15:0] n_err = '0;
   logic [31:0] first_bad = 32'hFFFF_FFFF;
   logic [15:0] first_got = '0, first_want = '0;
   logic        done = 1'b0;
   logic [2:0]  gap = '0;

   wire [31:0] cur_w = 32'(WORD_BASE) + widx;
   logic        rd_now = 1'b0;
   // In the byte pass only one lane was written, so the other still holds what
   // the interleaved pass left there.
   // A function call cannot be bit-selected directly, so name it first.
   wire [15:0] pat_now  = pat(cur_w);
   wire [15:0] pat_prev = pat_now ^ 16'hFFFF;   // what pass 2 left in the lane
   // Pass 2 writes the inverted pattern, so it must expect the inverted
   // pattern.  Expecting pat_now there made every word of that pass mismatch
   // by construction -- a fault in the test that reads exactly like a fault in
   // the bridge, which is why "everything is wrong" is worth distrusting.
   wire [15:0] want = (phase == 2'd2) ? pat_prev
                    : (phase != 2'd3) ? pat_now
                    : (widx[0] ? {pat_now[15:8], pat_prev[7:0]}
                               : {pat_prev[15:8], pat_now[7:0]});

   always_ff @(posedge clk_wb) begin
      if (rst_wb) begin
         st <= B_IDLE; widx <= '0; phase <= 1'b0; n_err <= '0;
         done <= 1'b0; match_mem <= 1'b0;
         first_bad <= 32'hFFFF_FFFF;
      end else case (st)

        B_IDLE: if (DDR3_READY) st <= B_DRIVE;

        // sun2_fpga asserts MATCH_MEM for the data-strobe part of a cycle and
        // drops it when AS releases; the bridge keys everything off that.
        B_DRIVE: begin
           p_adr     <= cur_w[22:0];
           p_din     <= (phase == 2'd2) ? pat_prev : pat_now;
           p_rw_n    <= rd_now;
           // The last pass drives one lane at a time.  A read always selects
           // the whole longword; only a write uses the enables, so this is the
           // only pass that exercises wb_sel_o's write arm.
           en_ub     <= (phase != 2'd3) || rd_now ||  widx[0];
           en_lb     <= (phase != 2'd3) || rd_now || !widx[0];
           match_mem <= 1'b1;
           st        <= B_ACK;
        end

        B_ACK: if (w_ack) begin
           if (rd_now) begin
              if (p_dout !== want) begin
                 n_err <= n_err + 16'd1;
                 if (first_bad == 32'hFFFF_FFFF) begin
                    first_bad  <= cur_w;
                    first_got  <= p_dout;
                    first_want <= want;
                 end
              end
           end
           match_mem <= 1'b0;
           gap       <= 3'd0;
           st        <= B_GAP;
        end

        // A couple of idle clocks, which is what the CPU's own cycle gives
        // between one access and the next.  Zero would be a burst no 68010
        // produces.
        B_GAP: begin
           gap <= gap + 3'd1;
           if (gap == 3'd2) begin
              if (phase == 2'd2 && !rd_now) begin
                 // interleaved: the read of this same word comes next
                 rd_now <= 1'b1;
                 st     <= B_DRIVE;
              end else if (widx == 32'(NWORDS - 1)) begin
                 widx   <= '0;
                 rd_now <= (phase == 2'd0);
                 if (phase == 2'd3) begin done <= 1'b1; st <= B_DONE; end
                 else begin phase <= phase + 2'd1; st <= B_DRIVE; end
              end else begin
                 widx   <= widx + 32'd1;
                 rd_now <= (phase == 2'd1);
                 st     <= B_DRIVE;
              end
           end
        end

        B_DONE: ;
        default: st <= B_IDLE;
      endcase
   end

   // ------------------------------------------------------------------
   // Reporting
   // ------------------------------------------------------------------
   // done(1) + phase(2) + ready(1) + cal(1) + lock(1) + n_err(16) +
   // first_bad(32) + got(16) + want(16) = 86.
   //
   // Recount this whenever a field changes width.  `phase' went from one bit to
   // two when the interleaved and byte passes were added, the width stayed at
   // 85, and the result was 65535 of 65536 words "wrong" with the first read
   // returning 0000 -- a truncated probe, not a broken bridge.  A probe
   // narrower than its concatenation shifts every field below the cut and says
   // nothing about it.
   altsource_probe #(
       .sld_auto_instance_index ("YES"),
       .instance_id             ("BRDG"),
       .probe_width             (86),
       .source_width            (1),
       .enable_metastability    ("YES")
   ) u_issp (
       .probe  ({done, phase, DDR3_READY, SEQ_CAL_PASS, PLL_LOCKED,
                 n_err, first_bad, first_got, first_want}),
       .source ());

   assign LED = ~{done, (n_err != 16'd0), DDR3_READY, SEQ_CAL_PASS,
                  PLL_LOCKED, phase, widx[17:16]};

endmodule
