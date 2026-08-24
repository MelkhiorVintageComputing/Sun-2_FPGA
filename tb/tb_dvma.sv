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

   // Declared here rather than beside the memory model, because the always
   // blocks that police arbitration sit above it and count into them.
   int fail = 0, checks = 0;

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
   // What memory is returning on the bus this cycle.  Both masters see the
   // same wires, because on the machine they are the same wires.  Declared
   // here, above every use: xvlog rejects a wire used before its declaration
   // where Vivado would invent an undriven one and say nothing.
   reg  [15:0] bus_din_r = 16'hxxxx;
   wire [15:0] bus_din   = bus_din_r;
   wire [15:0] dvma_din  = bus_din;
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
   // A 68010 that runs bus cycles, and grants the bus when asked
   // ------------------------------------------------------------------
   // The CPU side used to be three regs that never moved: cpu_as_n was tied
   // high for the whole test, so no CPU cycle was ever modelled and the one
   // question a bus arbiter exists to answer -- what happens when the two
   // masters want the bus at once -- was never put.  It has these signals now,
   // and section 11 drives them.
   reg  [23:1] cpu_a     = 23'h0;
   reg         cpu_rw_n  = 1'b1, cpu_uds_n = 1'b1, cpu_lds_n = 1'b1;
   reg  [15:0] cpu_dout  = 16'h0;

   // rtl/sun2-common/top_fpga.v, verbatim in shape: one master drives the
   // 68010 wires and everything downstream is told nothing about which.
   wire [23:1] bus_a     = dvma_active ? dvma_a     : cpu_a;
   wire        bus_as_n  = dvma_active ? dvma_as_n  : cpu_as_n;
   wire        bus_rw_n  = dvma_active ? dvma_rw_n  : cpu_rw_n;
   wire        bus_uds_n = dvma_active ? dvma_uds_n : cpu_uds_n;
   wire        bus_lds_n = dvma_active ? dvma_lds_n : cpu_lds_n;
   wire [15:0] bus_dout  = dvma_active ? dvma_dout  : cpu_dout;

   // Two-wire arbitration, as on the 2/50: BG follows BR, and BUS_EN drops to
   // say the core has genuinely let go of the address and strobes.
   //
   // A real 68010 finishes the cycle it is in before it grants, which is why
   // the grant waits on cpu_as_n.  `hostile_grant' takes that away on purpose:
   // it grants mid-cycle, so that what stops sun2_dvma from driving is its own
   // reading of cpu_as_n and BUS_EN rather than the model's good manners.  A
   // master that only behaves because the CPU never misbehaves is not one this
   // machine can rely on.
   // `cpu_busy' is the core's own knowledge that a cycle is starting -- set
   // before the address goes out and cleared after AS is released.  Without it
   // the model has a race it cannot win: there are clock edges between "the
   // bus looks free" and "AS is asserted", and a grant landing in that window
   // makes the model, not the arbiter, produce the overlap.  A real 68010 has
   // no such gap because its arbitration is inside it.
   bit cpu_busy = 1'b0;
   bit hostile_grant = 1'b0;
   // How long after BG the core keeps driving the pins.  Long by default, so
   // that BUS_EN is load-bearing; short under a hostile grant, so that the
   // pins are released while a cycle is still in progress and cpu_as_n is
   // load-bearing too.  One window cannot do both: with the pins held for
   // twelve clocks the CPU's cycle is always over before they drop, and
   // mutating cpu_as_n out of sun2_dvma goes unnoticed.
   int busen_dly = 12;
   int grant_dly = 0;
   always @(posedge clk) begin
      if (!P_BR_n) begin
         if ((cpu_as_n && !cpu_busy) || hostile_grant) begin
            grant_dly <= grant_dly + 1;
            // BG first, the pins some clocks later.  A core does not do both
            // at once, and the gap is what gives BUS_EN any meaning here: with
            // the two dropping together a master that ignores BUS_EN entirely
            // behaves exactly like one that honours it, so mutating the term
            // out of sun2_dvma passed.  Twelve clocks is generous on purpose
            // -- the master's own state machine takes several clocks to get
            // from its start condition to driving, and a window shorter than
            // that closes before the mutant can be caught in it.
            if (grant_dly >= 2)          P_BG_n <= 1'b0;
            if (grant_dly >= busen_dly)  BUS_EN <= 1'b0;
         end
      end else begin
         grant_dly <= 0;
         P_BG_n <= 1'b1;
         // The pins come back only once the master has actually let go.
         if (!dvma_active) BUS_EN <= 1'b1;
      end
   end

   // The contract the whole of section 11 rests on, checked on every edge of
   // every test rather than only where it is being provoked.
   always @(posedge clk) begin
      if (dvma_active && !cpu_as_n) begin
         $display("FAIL: [%t] DVMA drove the bus while the CPU had a cycle in progress (hostile=%0d BG_n=%0d BUS_EN=%0d dvma_as_n=%0d)",
                  $realtime, hostile_grant, P_BG_n, BUS_EN, dvma_as_n);
         fail++;
      end
      if (dvma_active && BUS_EN) begin
         $display("FAIL: [%t] DVMA drove the bus while the CPU still owned the pins (hostile=%0d BG_n=%0d cpu_as_n=%0d)",
                  $realtime, hostile_grant, P_BG_n, cpu_as_n);
         fail++;
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

   reg [15:0]  rd_next;
   reg         rd_valid = 1'b0;

   wire [23:0] cyc_byte = {bus_a, 1'b0};
   wire        cyc_err  = (err_lo >= 0) && (cyc_byte >= err_lo) && (cyc_byte <= err_hi);

   always @(posedge clk) begin
      if (bus_as_n) begin
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
            if (bus_rw_n) begin
               // read: even byte on the upper lane, odd on the lower
               rd_next  <= {bus_uds_n ? 8'h00 : mem[cyc_byte],
                            bus_lds_n ? 8'h00 : mem[cyc_byte + 1]};
               rd_valid <= 1'b1;
            end else begin
               if (!bus_uds_n) mem[cyc_byte]     <= bus_dout[15:8];
               if (!bus_lds_n) mem[cyc_byte + 1] <= bus_dout[7:0];
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
     if (bus_as_n) begin
        rd_valid <= 1'b0;
        bus_din_r <= 16'hxxxx;
     end else begin
        bus_din_r <= rd_valid ? rd_next : 16'hxxxx;
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

   // ------------------------------------------------------------------
   // The CPU running bus cycles of its own
   // ------------------------------------------------------------------
   // One 68010 read cycle: address and strobes out, wait for DTACK, latch the
   // data the clock *after* the acknowledge -- which is where a 68010 latches
   // and, more to the point, where the memory model above puts it.  A master
   // that sampled on the DTACK edge would collect the previous cycle's data,
   // which is the bug this file already records catching once.
   task automatic cpu_read_word(input [23:1] a, output [15:0] d);
      int guard;
      // Claim the bus, and keep re-checking until AS is actually out.
      //
      // The check has to be repeated because a grant can land between "the bus
      // looks free" and "AS is asserted" -- there are clock edges in between,
      // and a model that only looks once drives on top of the master it just
      // granted to and then reports the arbiter for it.  Two earlier versions
      // of this task did exactly that; the failures looked like a real defect
      // and were the testbench's.  A real 68010 has no such gap: its
      // arbitration is inside it and it knows a cycle is starting.
      forever begin
         while (dvma_active || !BUS_EN) @(posedge clk);
         cpu_busy = 1'b1;
         @(posedge clk);
         if (dvma_active || !BUS_EN) begin cpu_busy = 1'b0; continue; end
         cpu_a <= a; cpu_rw_n <= 1'b1;
         @(posedge clk);
         if (dvma_active || !BUS_EN) begin cpu_busy = 1'b0; continue; end
         cpu_as_n <= 1'b0; cpu_uds_n <= 1'b0; cpu_lds_n <= 1'b0;
         break;
      end
      guard = 0;
      forever begin
         @(posedge clk);
         if (!P_DTACK_n) break;
         if (++guard > 500) begin
            $display("FAIL: CPU read of %06x never acknowledged", {a, 1'b0});
            fail++;
            break;
         end
      end
      // Latch the clock after the acknowledge, which is where a 68010 latches
      // and where the memory model above puts the data.
      @(posedge clk);
      d = bus_din;
      cpu_as_n <= 1'b1; cpu_uds_n <= 1'b1; cpu_lds_n <= 1'b1;
      @(posedge clk);
      cpu_busy = 1'b0;
   endtask

   //
   // A longword read, which is what makes this interesting.
   //
   // The 68010 has a 16-bit bus, so `moveal (An),%a0' is *two* word cycles
   // with a gap between them, and the bus may legally be granted in that gap.
   // On a VME 2/50 that is exactly what happens: the boot PROM's Channel
   // Attention routine reloads its pointer with
   //
   //     ef4322  moveal %a5@(1118),%a0
   //
   // in the window where the 82586 -- just given the attention the preceding
   // `bset' raised -- is fetching its SCP, and the pointer comes back wrong.
   // The `bclr' at ef4326 then clears bit 5 of address 0x000004 instead of the
   // Ethernet control register, CA is never dropped, the next attention makes
   // no rising edge, and the machine hangs waiting for a chip that was never
   // asked to do anything.  `gap' is the tunable that places the interleave.
   //
   task automatic cpu_read_long(input [23:1] a, input int gap, output [31:0] d);
      logic [15:0] hi, lo;
      cpu_read_word(a, hi);
      repeat (gap) @(posedge clk);
      cpu_read_word(a + 23'd1, lo);
      d = {hi, lo};
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

      // --- 11. DVMA inside a CPU longword read --------------------------
      //
      // The failure this section exists for is not a wrong byte lane or a
      // dropped cycle -- those are covered above -- but a CPU read whose
      // *data* is wrong because a master took the bus in the middle of it.
      // Nothing here had ever run a CPU cycle at all, so the arbiter's whole
      // reason for existing was untested.
      //
      // A recognisable pointer, so a corrupted read is obvious rather than
      // merely unequal: 0x00EE3000 is the Ethernet control register, which is
      // the value the PROM's moveal is supposed to load.
      begin
         logic [31:0] got;
         int          g;
         int          n_before;

         mem[22'h100*4 + 0] = 8'h00;
         mem[22'h100*4 + 1] = 8'hEE;
         mem[22'h100*4 + 2] = 8'h30;
         mem[22'h100*4 + 3] = 8'h00;

         // (a) baseline: no master anywhere near it.
         cpu_read_long(23'h000200, 0, got);
         checks++;
         if (got !== 32'h00EE3000) begin
            $display("FAIL: quiet longword read gave %08x, expected 00ee3000", got);
            fail++;
         end

         // (b) a master asking for the bus at every offset through the read.
         // The gap is swept because the damaging alignment is not known in
         // advance -- on the board it is wherever the 82586's SCP fetch
         // happens to fall, and a single hand-picked gap would prove only that
         // one alignment is safe.
         for (g = 0; g <= 12; g++) begin
            n_before = n_cycles;
            fork
               begin
                  logic [31:0] rd2;
                  bit          e2;
                  repeat (g) @(posedge clk);
                  wb_access(1'b0, 22'h200, 4'b1111, 32'h0, rd2, e2);
               end
               begin
                  cpu_read_long(23'h000200, g, got);
               end
            join
            checks++;
            if (got !== 32'h00EE3000) begin
               $display("FAIL: longword read with DVMA at gap %0d gave %08x, expected 00ee3000",
                        g, got);
               fail++;
            end
            checks++;
            if (n_cycles == n_before) begin
               $display("FAIL: gap %0d -- the master never got the bus, so nothing was interleaved", g);
               fail++;
            end
         end

         // (c) the same, with the CPU granting mid-cycle.  Nothing but
         // sun2_dvma's own reading of cpu_as_n and BUS_EN stops it driving on
         // top of a cycle in progress; the always block above is what fails if
         // it does.
         // A cycle long enough to still be running when the grant lands.  With
         // the memory answering immediately the CPU's cycle is over in three
         // clocks, the grant always arrives after it, and cpu_as_n never has
         // to be honoured -- so mutating it out of sun2_dvma goes unnoticed.
         // Wait states are how a real device makes that window.
         wait_states   = 6;
         hostile_grant = 1'b1;
         busen_dly     = 2;      // pins released while the cycle is running
         for (g = 0; g <= 6; g++) begin
            fork
               begin
                  logic [31:0] rd3;
                  bit          e3;
                  repeat (g) @(posedge clk);
                  wb_access(1'b0, 22'h200, 4'b1111, 32'h0, rd3, e3);
               end
               begin
                  cpu_read_long(23'h000200, g, got);
               end
            join
            checks++;
            if (got !== 32'h00EE3000) begin
               $display("FAIL: hostile grant at gap %0d gave %08x, expected 00ee3000", g, got);
               fail++;
            end
         end
         hostile_grant = 1'b0;
         busen_dly     = 12;
         wait_states   = 0;
         @(posedge clk);
      end

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
