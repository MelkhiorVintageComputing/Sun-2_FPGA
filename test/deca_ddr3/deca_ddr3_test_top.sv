//
// A DDR3 test with no Sun-2 in it.
//
// BrianHG's DDR3 controller, its PLL, the DECA's own DDR3 chip, and a
// write/read/verify walk over memory.  No CPU, no MMU, no console.
//
// Same shape and the same argument as test/deca_console: prove the block on its
// own before anything depends on it, so that a failure means one thing.  The
// console test earned that keep -- it is what separated "the bridge is wrong"
// from "the machine is wrong", and the answer turned out to be neither.
//
// This one matters more, because the Sun-2 cannot netboot without it.  The
// on-chip build reaches the monitor prompt in 64 KiB and stops there: the boot
// loader's buffer is at 0x0a0462, 640 KiB up, and a small machine takes a
// protection violation there.  Ethernet needs memory, and memory needs this.
//
// ------------------------------------------------------------ what it reports
//
// Everything comes back over JTAG through In-System Sources and Probes, read
// with tools/deca_ddr3_probe.tcl.  That is deliberate: the DECA has no serial
// port, the JTAG console is a different subsystem with its own history, and a
// memory test that depends on the console to report is two experiments at once.
//
//   [11:0]  errors      compare mismatches
//   [31:12] reads       cache lines read back      (20 bits)
//   [51:32] writes      cache lines written        (20 bits)
//   [59:52] RDCAL_data  the controller's read-calibration tuning record
//   [60]    DDR3_READY
//   [61]    SEQ_CAL_PASS
//   [62]    PLL_LOCKED
//   [63]    done        the walk finished
//
// The counters are twenty bits and not sixteen, which is not fussiness.  With
// LINES = 65536 and 16-bit counters the first run reported "writes=0 reads=0
// errors=0 done=1" -- a full clean walk of a mebibyte, wrapped exactly to zero,
// and completely indistinguishable from a walk that never started.  The probe
// script now checks the counts equal LINES rather than just trusting the error
// flag, because "no errors" is worthless if nothing was tested.
//
// RDCAL_data is included because it is the controller's own account of read
// calibration, and a board that fails calibration and a board with a bad
// address line look identical from an error count alone.
//
`timescale 1ns / 1ps

module deca_ddr3_test_top #(
    // 50 MHz * 20 / 4 = 250 MHz DDR3, i.e. 500 Mbps on the clock pin.
    //
    // NOT the 400 MHz BrianHG's own DECA project uses, and the reason is worth
    // recording: at 400 MHz the fitter refuses outright --
    //
    //   Error (176060): The transmitter driving I/O pin DDR3_CK_p at data rate
    //   800 Mbps exceeds the maximum allowed data rate of 600 Mbps for
    //   Differential 1.5-V SSTL Class I output
    //
    // -- on the same device, the same speed grade, the same I/O standard and
    // with no waiver in their project either.  Their project was built with
    // Quartus 17.1 and this is 25.1, so a newer fitter is enforcing a rating
    // the older one did not.  "It is hardware-verified" and "it builds with
    // today's tools" are different claims.
    //
    // No loss here: a 12.5 MHz Sun-2 asks for a few MB/s and 250 MHz DDR3 is
    // about 1000 MB/s raw, so the margin is four orders of magnitude.  250 is
    // also one of the frequencies BrianHG lists as working on every build,
    // unlike odd values such as 310 or 320.
    parameter int CLK_IN_MULT = 20,
    parameter int CLK_IN_DIV  = 4,
    // How much of memory to walk.  Each line is 128 bits = 16 bytes, so 65536
    // lines is 1 MiB -- enough to prove addressing across rows and banks
    // without a test that takes minutes.
    parameter int LINES       = 65536
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

   localparam int PORT_CACHE_BITS = 128;   // 8 * DDR3_WIDTH_DM(2) * 8
   localparam int PORT_ADDR_SIZE  = 29;    // ADDR(15) + BANK(3) + CAS(10) + DM-1(1)

   wire        CMD_CLK, RST_OUT, DDR3_READY, SEQ_CAL_PASS, PLL_LOCKED;
   wire [7:0]  RDCAL_data;

   wire                        cmd_busy       [0:0];
   logic                       cmd_ena        [0:0];
   logic                       cmd_write_ena  [0:0];
   logic [PORT_ADDR_SIZE-1:0]  cmd_addr       [0:0];
   logic [PORT_CACHE_BITS-1:0] cmd_wdata      [0:0];
   logic [PORT_CACHE_BITS/8-1:0] cmd_wmask    [0:0];
   logic [7:0]                 cmd_rvec_in    [0:0];
   wire                        cmd_read_ready [0:0];
   wire  [PORT_CACHE_BITS-1:0] cmd_read_data  [0:0];
   wire  [7:0]                 cmd_rvec_out   [0:0];
   logic                       cmd_boost      [0:0];

   BrianHG_DDR3_CONTROLLER_v16_top #(
       .FPGA_VENDOR     ("Altera"),
       .FPGA_FAMILY     ("MAX 10"),
       .CLK_KHZ_IN      (50000),
       .CLK_IN_MULT     (CLK_IN_MULT),
       .CLK_IN_DIV      (CLK_IN_DIV),
       .INTERFACE_SPEED ("Half"),
       .DDR3_SIZE_GB    (4),          // MT41K256M16, 4 Gbit -- the DECA's part
       .DDR3_WIDTH_DQ   (16),
       .DDR3_NUM_CHIPS  (1),
       .PORT_TOTAL      (1)
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

       .DDR3_RESET_n (DDR3_RESET_n),
       .DDR3_CK_p    (DDR3_CK_p),
       .DDR3_CK_n    (DDR3_CK_n),
       .DDR3_CKE     (DDR3_CKE),
       .DDR3_CS_n    (DDR3_CS_n),
       .DDR3_RAS_n   (DDR3_RAS_n),
       .DDR3_CAS_n   (DDR3_CAS_n),
       .DDR3_WE_n    (DDR3_WE_n),
       .DDR3_ODT     (DDR3_ODT),
       .DDR3_A       (DDR3_A),
       .DDR3_BA      (DDR3_BA),
       .DDR3_DM      (DDR3_DM),
       .DDR3_DQ      (DDR3_DQ),
       .DDR3_DQS_p   (DDR3_DQS_p),
       .DDR3_DQS_n   (DDR3_DQS_n)
   );

   // ------------------------------------------------------------------
   // The walk: write every line, then read every line back and compare.
   //
   // The pattern is derived from the address rather than being a constant, so
   // a stuck or swapped address line shows up as a mismatch instead of passing.
   // A constant pattern is the classic memory test that proves nothing about
   // addressing -- the same trap tb_xy450 hit, where every transfer was a round
   // trip to the same place and a wrong sector map was its own inverse.
   // ------------------------------------------------------------------
   function automatic [PORT_CACHE_BITS-1:0] pat (input [31:0] i);
      pat = {~i, i ^ 32'hA5A5_5A5A, i + 32'h1234_5678, i};
   endfunction

   localparam [2:0] S_WAIT = 3'd0, S_WR = 3'd1, S_WRW = 3'd2,
                    S_RD   = 3'd3, S_RDW = 3'd4, S_DONE = 3'd5;

   reg [2:0]  state;
   reg [31:0] idx;
   reg [11:0] n_err;
   reg [19:0] n_rd, n_wr;
   reg        walk_done;

   // Line N lives at byte address N*16; the low four bits of a cache-line
   // address are inside the line.
   wire [PORT_ADDR_SIZE-1:0] line_addr = idx[PORT_ADDR_SIZE-5:0] << 4;

   always @(posedge CMD_CLK) begin
      cmd_ena[0] <= 1'b0;

      if (RST_OUT) begin
         state     <= S_WAIT;
         idx       <= 32'd0;
         n_err     <= 12'd0;
         n_rd      <= 20'd0;
         n_wr      <= 20'd0;
         walk_done <= 1'b0;
         cmd_wmask[0]   <= {(PORT_CACHE_BITS/8){1'b1}};
         cmd_rvec_in[0] <= 8'h00;
         cmd_boost[0]   <= 1'b0;
      end else begin
         case (state)
           S_WAIT:
             if (DDR3_READY) state <= S_WR;

           S_WR:
             if (!cmd_busy[0]) begin
                cmd_addr[0]      <= line_addr;
                cmd_wdata[0]     <= pat(idx);
                cmd_write_ena[0] <= 1'b1;
                cmd_ena[0]       <= 1'b1;
                state            <= S_WRW;
             end

           S_WRW: begin
              n_wr <= n_wr + 20'd1;
              if (idx == LINES - 1) begin idx <= 32'd0; state <= S_RD; end
              else begin idx <= idx + 32'd1; state <= S_WR; end
           end

           S_RD:
             if (!cmd_busy[0]) begin
                cmd_addr[0]      <= line_addr;
                cmd_write_ena[0] <= 1'b0;
                cmd_ena[0]       <= 1'b1;
                state            <= S_RDW;
             end

           S_RDW:
             if (cmd_read_ready[0]) begin
                n_rd <= n_rd + 20'd1;
                if (cmd_read_data[0] !== pat(idx)) n_err <= n_err + 12'd1;
                if (idx == LINES - 1) state <= S_DONE;
                else begin idx <= idx + 32'd1; state <= S_RD; end
             end

           S_DONE: walk_done <= 1'b1;

           default: state <= S_WAIT;
         endcase
      end
   end

   // ------------------------------------------------------------------
   // Report over JTAG, and on the LEDs for someone standing at the board.
   // ------------------------------------------------------------------
   altsource_probe #(
       .sld_auto_instance_index ("YES"),
       .instance_id             ("DDR3"),
       .probe_width             (64),
       .source_width            (1),
       .enable_metastability    ("YES")
   ) u_issp (
       .probe  ({walk_done, PLL_LOCKED, SEQ_CAL_PASS, DDR3_READY,
                 RDCAL_data, n_wr, n_rd, n_err}),
       .source ()
   );

   // Active low.  A board that never calibrates and a board that miscompares
   // must look different from across the room.
   assign LED = ~{walk_done, (n_err != 0), PLL_LOCKED, SEQ_CAL_PASS,
                  DDR3_READY, state};

endmodule
