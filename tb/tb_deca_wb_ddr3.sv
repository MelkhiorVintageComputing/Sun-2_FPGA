//
// deca_wb_to_ddr3 against a model of BrianHG's command port.
//
// What this is really testing is a set of claims read out of someone else's
// source: that CMD_wmask is active high, that CMD_ena is a strobe gated by
// CMD_busy, that a write needs no acknowledgement and a read answers with
// CMD_read_ready, and that a 128-bit line holds four 32-bit lanes indexed by
// wb_adr[1:0].  Each of those is a place where being wrong corrupts memory
// quietly rather than failing loudly.
//
// The model deliberately makes CMD_busy and the read latency *vary*, because a
// handshake that only works when the far end is always ready is not a
// handshake.
//
// The two clocks are deliberately unrelated and far apart -- 12.5 MHz against
// 125 MHz -- since the crossing is the other half of what is under test.
//
`timescale 1ns / 1ps

module tb_deca_wb_ddr3;

   localparam int AW = 29, CB = 128;

   reg clk_wb  = 1'b0;   always #40.000 clk_wb  = ~clk_wb;   // 12.5 MHz
   reg cmd_clk = 1'b0;   always #4.000  cmd_clk = ~cmd_clk;  // 125 MHz

   reg rst = 1'b1;

   int pass = 0, fail = 0;
   task check(input string what, input logic cond);
      if (cond) begin pass++; $display("  ok:   %s", what); end
      else      begin fail++; $display("  FAIL: %s", what); end
   endtask

   // ---------------------------------------------------------- the adapter
   reg         wb_cyc = 0, wb_stb = 0, wb_we = 0;
   reg  [29:0] wb_adr = 0;
   reg  [31:0] wb_dat = 0;
   reg  [3:0]  wb_sel = 0;
   wire [31:0] wb_dat_o;
   wire        wb_ack;

   wire                CMD_busy, CMD_ena, CMD_write_ena, CMD_read_ready;
   wire [AW-1:0]       CMD_addr;
   wire [CB-1:0]       CMD_wdata, CMD_read_data;
   wire [CB/8-1:0]     CMD_wmask;

   deca_wb_to_ddr3 #(.PORT_ADDR_SIZE(AW), .PORT_CACHE_BITS(CB)) dut (
       .clk_wb (clk_wb), .rst_wb (rst),
       .wb_cyc_i (wb_cyc), .wb_stb_i (wb_stb), .wb_adr_i (wb_adr),
       .wb_dat_i (wb_dat), .wb_sel_i (wb_sel), .wb_we_i (wb_we),
       .wb_dat_o (wb_dat_o), .wb_ack_o (wb_ack),
       .cmd_clk (cmd_clk), .cmd_rst (rst), .ddr3_ready (1'b1),
       .CMD_busy (CMD_busy), .CMD_ena (CMD_ena),
       .CMD_write_ena (CMD_write_ena), .CMD_addr (CMD_addr),
       .CMD_wdata (CMD_wdata), .CMD_wmask (CMD_wmask),
       .CMD_read_ready (CMD_read_ready), .CMD_read_data (CMD_read_data)
   );

   // ------------------------------------------------- the controller model
   //
   // A sparse byte-addressed memory of 16-byte lines.  The mask is applied as
   // BrianHG documents it: a HIGH bit writes its byte.  If the adapter had
   // MIG's inverted polarity, every check below that reads back a sub-word
   // write would fail -- which is the point.
   byte unsigned mem [int];          // byte address -> value

   reg        busy_r = 1'b0;
   reg        rd_pending = 1'b0;
   reg [AW-1:0] rd_addr;
   reg [3:0]  rd_delay;
   reg        rr = 1'b0;
   reg [CB-1:0] rdata_r;

   assign CMD_busy       = busy_r;
   assign CMD_read_ready = rr;
   assign CMD_read_data  = rdata_r;

   // Deterministic variation rather than $urandom.  Two reasons: a testbench
   // that fails differently on each run is a poor instrument, and $urandom(seed)
   // *re-seeds* on every call, so it returns the same number for ever -- which
   // pinned CMD_busy high and deadlocked the first version of this file into a
   // timeout that looked exactly like a broken adapter.
   reg [5:0] jitter = 6'd0;

   always @(posedge cmd_clk) begin
      rr     <= 1'b0;
      jitter <= jitter + 6'd1;

      // Busy varies, so the adapter cannot rely on the port always accepting.
      busy_r <= (jitter[1:0] == 2'b00);

      if (CMD_ena) begin
         if (CMD_write_ena) begin
            for (int b = 0; b < CB/8; b++)
              if (CMD_wmask[b]) mem[CMD_addr + b] = CMD_wdata[b*8 +: 8];
         end else begin
            rd_pending <= 1'b1;
            rd_addr    <= CMD_addr;
            rd_delay   <= 4'd3 + {1'b0, jitter[4:2]};   // latency varies too
         end
      end

      if (rd_pending) begin
         if (rd_delay == 0) begin
            for (int b = 0; b < CB/8; b++)
              rdata_r[b*8 +: 8] <= mem.exists(rd_addr + b) ? mem[rd_addr + b] : 8'h00;
            rr         <= 1'b1;
            rd_pending <= 1'b0;
         end else
           rd_delay <= rd_delay - 4'd1;
      end
   end

   // ------------------------------------------------------------ Wishbone
   task wb_write(input [29:0] a, input [31:0] d, input [3:0] sel);
      begin
         @(posedge clk_wb);
         wb_adr <= a; wb_dat <= d; wb_sel <= sel; wb_we <= 1'b1;
         wb_cyc <= 1'b1; wb_stb <= 1'b1;
         @(posedge clk_wb);
         while (!wb_ack) @(posedge clk_wb);
         wb_cyc <= 1'b0; wb_stb <= 1'b0; wb_we <= 1'b0;
         @(posedge clk_wb);
      end
   endtask

   task wb_read(input [29:0] a, output [31:0] d);
      begin
         @(posedge clk_wb);
         wb_adr <= a; wb_sel <= 4'hF; wb_we <= 1'b0;
         wb_cyc <= 1'b1; wb_stb <= 1'b1;
         @(posedge clk_wb);
         while (!wb_ack) @(posedge clk_wb);
         d = wb_dat_o;
         wb_cyc <= 1'b0; wb_stb <= 1'b0;
         @(posedge clk_wb);
      end
   endtask

   integer    n, errs;
   reg [31:0] got;

   initial begin
      $display("=== deca_wb_ddr3: the adapter against a modelled command port ===");
      repeat (20) @(posedge clk_wb);
      rst = 1'b0;
      repeat (20) @(posedge clk_wb);

      // 1. Full-word round trip across four lanes of one line and beyond it,
      //    so lane selection and line addressing are both exercised.
      errs = 0;
      for (n = 0; n < 32; n++) wb_write(n, 32'hDEAD0000 + n, 4'hF);
      for (n = 0; n < 32; n++) begin
         wb_read(n, got);
         if (got !== (32'hDEAD0000 + n)) errs++;
      end
      check("32 word round trips across lanes and lines", errs == 0);

      // 2. The lane really is wb_adr[1:0] -- four consecutive words share one
      //    128-bit line, and writing one must not disturb its neighbours.
      wb_write(4, 32'h11111111, 4'hF);
      wb_write(5, 32'h22222222, 4'hF);
      wb_write(6, 32'h33333333, 4'hF);
      wb_write(7, 32'h44444444, 4'hF);
      wb_read(4, got); check("lane 0 of a shared line", got === 32'h11111111);
      wb_read(5, got); check("lane 1 of a shared line", got === 32'h22222222);
      wb_read(6, got); check("lane 2 of a shared line", got === 32'h33333333);
      wb_read(7, got); check("lane 3 of a shared line", got === 32'h44444444);

      // 3. THE MASK POLARITY.  A byte write must change one byte and leave the
      //    other three -- and its three lane-mates -- alone.  With MIG's
      //    inverted mask this writes everything except the byte asked for, and
      //    the boot PROM does sub-word writes constantly, so it would corrupt
      //    memory from the first instruction while looking plausible.
      wb_write(8,  32'hAABBCCDD, 4'hF);
      wb_write(9,  32'h99999999, 4'hF);
      wb_write(8,  32'h000000EE, 4'h1);       // byte 0 only
      wb_read (8,  got);
      check("byte write changes only its own byte", got === 32'hAABBCCEE);
      wb_read (9,  got);
      check("... and not the next word in the same line", got === 32'h99999999);

      wb_write(10, 32'h12345678, 4'hF);
      wb_write(10, 32'h00FF0000, 4'h4);       // byte 2 only
      wb_read (10, got);
      check("a middle byte write lands in the right byte", got === 32'h12FF5678);

      // 4. A halfword, which is what the 68010 does most.
      wb_write(12, 32'hCAFEBABE, 4'hF);
      wb_write(12, 32'h0000BEEF, 4'h3);
      wb_read (12, got);
      check("halfword write", got === 32'hCAFEBEEF);

      // 5. Back-to-back traffic, to be sure the crossing recovers each time.
      errs = 0;
      for (n = 0; n < 64; n++) begin
         wb_write(64 + n, ~n, 4'hF);
         wb_read (64 + n, got);
         if (got !== (~n & 32'hFFFFFFFF)) errs++;
      end
      check("64 interleaved write/read pairs", errs == 0);

      $display("=== deca_wb_ddr3: %0d checks, %0d passed, %0d failed ===",
               pass + fail, pass, fail);
      if (fail == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   initial begin
      #20_000_000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
