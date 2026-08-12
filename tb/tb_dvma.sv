`timescale 1ns / 1ps

//
// Unit test for sun2_dvma: a Wishbone master's accesses turned into MC68010
// bus cycles.
//
// The contract being checked is the one that matters and the one that fails
// silently if it is wrong:
//
//     the 82586's byte address N must reach the same memory byte that the
//     68010 calls byte address N.
//
// So the memory model here is deliberately *byte* addressed, and it stores
// what a 68010 would store: on a cycle at P_A with UDS asserted, the byte at
// {P_A,1'b0} takes D[15:8]; with LDS, the byte at {P_A,1'b1} takes D[7:0].
// Nothing in the model knows about Wishbone or about the 82586.  If a Wishbone
// write of 32'hDDCCBBAA lands as AA BB CC DD in ascending byte order, the lane
// crossing is right; any other arrangement and it is not.
//
// Also covers: every SEL pattern including the awkward 4'b0110 tail, halves
// that are skipped entirely, wait states, bus-error termination, and the
// channel staying stopped after a fault until Ethernet reset.
//
module tb_dvma;

   localparam int MEMBYTES = 4096;

   reg clk = 1'b0;
   reg reset = 1'b1;
   always #5 clk = ~clk;

   // ------------------------------------------------------------------
   // Wishbone side
   // ------------------------------------------------------------------
   reg         wb_cyc = 1'b0, wb_stb = 1'b0, wb_we = 1'b0;
   reg  [3:0]  wb_sel = 4'h0;
   reg  [21:0] wb_adr = 22'h0;
   reg  [31:0] wb_dat_w = 32'h0;
   wire [31:0] wb_dat_r;
   wire        wb_ack, wb_err;

   // ------------------------------------------------------------------
   // Bus side
   // ------------------------------------------------------------------
   wire        P_BR_n, dvma_active, dvma_as_n, dvma_rw_n, dvma_uds_n, dvma_lds_n;
   wire [23:1] dvma_a;
   wire [2:0]  dvma_fc;
   wire [15:0] dvma_dout;
   reg  [15:0] dvma_din = 16'hxxxx;
   reg         P_DTACK_n = 1'b1, P_BERR_n = 1'b1;
   reg         P_BG_n = 1'b1, BUS_EN = 1'b1, cpu_as_n = 1'b1;
   reg         EN_DVMA = 1'b1, ether_reset = 1'b0;
   wire        dvma_err;

   sun2_dvma dut(.CLK(clk), .RESET(reset),
                 .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_we_i(wb_we),
                 .wb_sel_i(wb_sel), .wb_adr_i(wb_adr), .wb_dat_i(wb_dat_w),
                 .wb_dat_o(wb_dat_r), .wb_ack_o(wb_ack), .wb_err_o(wb_err),
                 .EN_DVMA(EN_DVMA), .P_BR_n(P_BR_n), .P_BG_n(P_BG_n),
                 .BUS_EN(BUS_EN), .cpu_as_n(cpu_as_n),
                 .dvma_active(dvma_active), .dvma_a(dvma_a), .dvma_fc(dvma_fc),
                 .dvma_as_n(dvma_as_n), .dvma_rw_n(dvma_rw_n),
                 .dvma_uds_n(dvma_uds_n), .dvma_lds_n(dvma_lds_n),
                 .dvma_dout(dvma_dout), .dvma_din(dvma_din),
                 .P_DTACK_n(P_DTACK_n), .P_BERR_n(P_BERR_n),
                 .ether_reset(ether_reset), .dvma_err(dvma_err));

   // ------------------------------------------------------------------
   // A 68010 that grants the bus when asked
   // ------------------------------------------------------------------
   // Two-wire arbitration, as on the 2/50: BG follows BR, and BUS_EN drops to
   // say the core has genuinely let go of the address and strobes.
   int grant_dly = 0;
   always @(posedge clk) begin
      if (!P_BR_n) begin
         grant_dly <= grant_dly + 1;
         if (grant_dly >= 2) begin P_BG_n <= 1'b0; BUS_EN <= 1'b0; end
      end else begin
         grant_dly <= 0;
         P_BG_n <= 1'b1;
         BUS_EN <= 1'b1;
      end
   end

   // ------------------------------------------------------------------
   // Byte-addressed memory that answers like the Sun-2 would
   // ------------------------------------------------------------------
   logic [7:0] mem [0:MEMBYTES-1];
   int         wait_states = 0;
   int         err_lo = -1, err_hi = -1;   // byte range that bus-errors
   int         ws_count = 0;
   int         n_cycles = 0;
   int         fail = 0, checks = 0;

   reg [15:0]  rd_next;
   reg         rd_valid = 1'b0;

   wire [23:0] cyc_byte = {dvma_a, 1'b0};
   wire        cyc_err  = (err_lo >= 0) && (cyc_byte >= err_lo) && (cyc_byte <= err_hi);

   always @(posedge clk) begin
      if (dvma_as_n) begin
         P_DTACK_n <= 1'b1;
         P_BERR_n  <= 1'b1;
         ws_count  <= 0;
      end else if (P_DTACK_n && P_BERR_n) begin
         if (ws_count < wait_states) begin
            ws_count <= ws_count + 1;
         end else if (cyc_err) begin
            P_BERR_n <= 1'b0;
         end else begin
            n_cycles <= n_cycles + 1;
            if (dvma_rw_n) begin
               // read: even byte on the upper lane, odd on the lower
               rd_next  <= {dvma_uds_n ? 8'h00 : mem[cyc_byte],
                            dvma_lds_n ? 8'h00 : mem[cyc_byte + 1]};
               rd_valid <= 1'b1;
            end else begin
               if (!dvma_uds_n) mem[cyc_byte]     <= dvma_dout[15:8];
               if (!dvma_lds_n) mem[cyc_byte + 1] <= dvma_dout[7:0];
            end
            P_DTACK_n <= 1'b0;
         end
      end
   end

   // Read data appears the clock *after* the acknowledge, which is what the
   // machine actually does: sun2_wishbone_bridge drives DTACK from the Wishbone
   // ack and presents the data behind it, and a 68010 latches at the end of S6
   // rather than on the edge it first sees DTACK.  Until the data is there the
   // bus reads as X, so a master that samples on the DTACK edge is caught here
   // instead of quietly collecting the previous cycle's data -- which is
   // exactly the bug this test failed to catch the first time round.
   always @(posedge clk)
     if (dvma_as_n) begin
        rd_valid <= 1'b0;
        dvma_din <= 16'hxxxx;
     end else begin
        dvma_din <= rd_valid ? rd_next : 16'hxxxx;
     end

   // Function code must be supervisor data on every DVMA cycle.
   always @(negedge dvma_as_n)
     if (dvma_fc !== 3'b101) begin
        $display("FAIL: DVMA cycle at %06x used FC=%0d, expected 5 (supervisor data)",
                 cyc_byte, dvma_fc);
        fail++;
     end

   // Nobody may drive the bus without owning it.
   always @(posedge clk)
     if (!dvma_as_n && !dvma_active) begin
        $display("FAIL: AS asserted while dvma_active is low");
        fail++;
     end

   // ------------------------------------------------------------------
   // Wishbone driver
   // ------------------------------------------------------------------

   task automatic wb_access(input bit we, input [21:0] adr, input [3:0] sel,
                            input [31:0] wdat, output [31:0] rdat,
                            output bit errored);
      int guard;
      @(posedge clk);
      wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_we <= we;
      wb_sel <= sel;  wb_adr <= adr;  wb_dat_w <= wdat;
      guard = 0;
      forever begin
         @(posedge clk);
         if (wb_ack || wb_err) break;
         if (++guard > 2000) begin
            $display("FAIL: Wishbone access to word %06x never completed", adr);
            fail++;
            break;
         end
      end
      rdat    = wb_dat_r;
      errored = wb_err;
      wb_cyc <= 1'b0; wb_stb <= 1'b0;
      @(posedge clk);
   endtask

   task automatic expect_byte(input int addr, input [7:0] want, input string what);
      checks++;
      if (mem[addr] !== want) begin
         $display("FAIL: %s -- byte %04x is %02x, expected %02x",
                  what, addr, mem[addr], want);
         fail++;
      end
   endtask

   task automatic expect_word(input [31:0] got, input [31:0] want, input string what);
      checks++;
      if (got !== want) begin
         $display("FAIL: %s -- read %08x, expected %08x", what, got, want);
         fail++;
      end
   endtask

   // ------------------------------------------------------------------
   initial begin
      logic [31:0] rd;
      bit          err;
      int          i, base;

      for (i = 0; i < MEMBYTES; i++) mem[i] = 8'h00;
      repeat (4) @(posedge clk);
      reset <= 1'b0;
      repeat (4) @(posedge clk);

      $display("=== sun2_dvma unit test ===");

      // --- the byte order contract ------------------------------------
      // A full 32-bit write must land little-endian in ascending byte order.
      wb_access(1'b1, 22'h010, 4'b1111, 32'hDDCCBBAA, rd, err);
      expect_byte(22'h010*4 + 0, 8'hAA, "full word write, byte 0");
      expect_byte(22'h010*4 + 1, 8'hBB, "full word write, byte 1");
      expect_byte(22'h010*4 + 2, 8'hCC, "full word write, byte 2");
      expect_byte(22'h010*4 + 3, 8'hDD, "full word write, byte 3");

      // ... and read back identically.
      wb_access(1'b0, 22'h010, 4'b1111, 32'h0, rd, err);
      expect_word(rd, 32'hDDCCBBAA, "full word read back");

      // --- every SEL pattern ------------------------------------------
      // Each single byte must reach exactly its own address and leave the
      // neighbours alone.  0110 is the one that costs two byte cycles.
      for (i = 1; i < 16; i++) begin
         base = 22'h020 + i;
         for (int b = 0; b < 4; b++) mem[base*4 + b] = 8'h00;
         wb_access(1'b1, base[21:0], i[3:0], 32'h44332211, rd, err);
         for (int b = 0; b < 4; b++)
           expect_byte(base*4 + b, i[b] ? (8'h11 * (b+1)) : 8'h00,
                       $sformatf("sel=%04b byte %0d", i[3:0], b));
         wb_access(1'b0, base[21:0], i[3:0], 32'h0, rd, err);
         for (int b = 0; b < 4; b++)
           if (i[b])
             expect_word(rd[b*8 +: 8], 8'h11 * (b+1),
                         $sformatf("sel=%04b readback byte %0d", i[3:0], b));
      end

      // --- a half that needs no cycle at all --------------------------
      // sel=0011 must produce one 68k cycle, sel=1100 one, sel=1111 two.
      begin
         int n0;
         n0 = n_cycles; wb_access(1'b1, 22'h040, 4'b0011, 32'h0, rd, err);
         checks++;
         if (n_cycles - n0 != 1) begin
            $display("FAIL: sel=0011 took %0d bus cycles, expected 1", n_cycles-n0);
            fail++;
         end
         n0 = n_cycles; wb_access(1'b1, 22'h040, 4'b1100, 32'h0, rd, err);
         checks++;
         if (n_cycles - n0 != 1) begin
            $display("FAIL: sel=1100 took %0d bus cycles, expected 1", n_cycles-n0);
            fail++;
         end
         n0 = n_cycles; wb_access(1'b1, 22'h040, 4'b1111, 32'h0, rd, err);
         checks++;
         if (n_cycles - n0 != 2) begin
            $display("FAIL: sel=1111 took %0d bus cycles, expected 2", n_cycles-n0);
            fail++;
         end
      end

      // --- wait states -------------------------------------------------
      // The bus is asynchronous; a slow slave must not change the answer.
      wait_states = 7;
      wb_access(1'b1, 22'h050, 4'b1111, 32'h89ABCDEF, rd, err);
      wb_access(1'b0, 22'h050, 4'b1111, 32'h0, rd, err);
      expect_word(rd, 32'h89ABCDEF, "read back through 7 wait states");
      wait_states = 0;

      // --- bus error ---------------------------------------------------
      // A BERR must come back as Wishbone ERR and must stop the channel:
      // Architecture Manual 6.13, the ERR condition inhibits further activity
      // until the Ethernet reset bit is asserted.
      err_lo = 22'h060*4; err_hi = 22'h060*4 + 3;
      wb_access(1'b0, 22'h060, 4'b1111, 32'h0, rd, err);
      checks++;
      if (!err) begin $display("FAIL: bus error did not produce Wishbone ERR"); fail++; end
      checks++;
      if (!dvma_err) begin $display("FAIL: bus error did not latch dvma_err"); fail++; end

      // A good address must now fail too -- the channel is stopped -- and,
      // crucially, must not put a single cycle on the 68010 bus.  This is what
      // keeps a faulting channel from becoming a memory scribbler: the 82586's
      // units ignore bus errors entirely and will happily carry on with the
      // zero they were handed, deriving a null descriptor pointer that is not
      // the 0xFFFF they check for.  Nothing they then compute can reach memory,
      // because the bridge refuses to run the cycle at all.
      err_lo = -1; err_hi = -1;
      begin
         int n0;
         n0 = n_cycles;
         mem[22'h010*4] = 8'h5A;
         wb_access(1'b1, 22'h010, 4'b1111, 32'hDEADBEEF, rd, err);
         checks++;
         if (!err) begin
            $display("FAIL: channel resumed after a bus error without an Ethernet reset");
            fail++;
         end
         checks++;
         if (n_cycles != n0) begin
            $display("FAIL: a stopped channel still drove %0d bus cycles", n_cycles - n0);
            fail++;
         end
         expect_byte(22'h010*4, 8'h5A, "memory untouched while the channel is stopped");
      end

      // Ethernet reset clears it.
      ether_reset <= 1'b1; repeat (2) @(posedge clk);
      ether_reset <= 1'b0; repeat (2) @(posedge clk);
      wb_access(1'b1, 22'h010, 4'b1111, 32'hDDCCBBAA, rd, err);
      wb_access(1'b0, 22'h010, 4'b1111, 32'h0, rd, err);
      checks++;
      if (err) begin $display("FAIL: channel still stopped after Ethernet reset"); fail++; end
      expect_word(rd, 32'hDDCCBBAA, "read after error recovery");

      // --- EN_DVMA gate -------------------------------------------------
      // Cleared on power-up per Architecture Manual 4.5; nothing may reach
      // memory until software sets it.
      EN_DVMA <= 1'b0; @(posedge clk);
      mem[22'h010*4] = 8'h5A;
      wb_access(1'b1, 22'h010, 4'b1111, 32'h00000099, rd, err);
      checks++;
      if (!err) begin $display("FAIL: DVMA ran with EN_DVMA clear"); fail++; end
      expect_byte(22'h010*4, 8'h5A, "memory untouched with EN_DVMA clear");
      EN_DVMA <= 1'b1; @(posedge clk);

      // --- the bus is given back ----------------------------------------
      checks++;
      if (!P_BR_n) begin $display("FAIL: bus request still asserted when idle"); fail++; end
      checks++;
      if (dvma_active) begin $display("FAIL: still driving the bus when idle"); fail++; end

      $display("%0d checks, %0d bus cycles", checks, n_cycles);
      if (fail == 0) $display("PASS: sun2_dvma");
      else           $display("FAIL: %0d problems", fail);
      $finish;
   end

   initial begin
      #20_000_000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
