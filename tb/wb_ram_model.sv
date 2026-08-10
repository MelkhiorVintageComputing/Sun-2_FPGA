`timescale 1ns / 1ps

//
// Behavioural Wishbone B4 classic slave, standing in for the LiteDRAM
// controller that backs main memory in the FPGA build.
//
// sun2_wishbone_bridge presents a 32-bit word address and replicates the
// 16-bit CPU data across both halves of the bus, selecting the half with
// wb_sel_o (see sun2_wishbone_bridge.v).  This model therefore only has to be
// self-consistent: it stores the 32-bit word as presented, honouring the byte
// enables on writes, and hands it back unchanged on reads.  All the endianness
// juggling stays in the bridge, exactly as it does against real LiteDRAM.
//
// Storage is an associative array, so the 16 MiB address span costs nothing
// until it is actually touched.
//

module wb_ram_model #(
    parameter int ACK_LATENCY = 0,      // extra wait states before ack
    parameter logic [31:0] FILL = 32'h00000000  // value returned by never-written locations
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire [29:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_we_i,
    output reg  [31:0] wb_dat_o,
    output reg         wb_ack_o
);

   logic [31:0] mem [int unsigned];

   int unsigned n_reads  = 0;
   int unsigned n_writes = 0;

   integer      waits = 0;

   function automatic logic [31:0] fetch(input int unsigned a);
      return mem.exists(a) ? mem[a] : FILL;
   endfunction

   always @(posedge clk) begin
      if (reset) begin
         wb_ack_o <= 1'b0;
         wb_dat_o <= 32'h0;
         waits    <= 0;
      end else if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
         if (waits < ACK_LATENCY) begin
            waits <= waits + 1;
         end else begin
            automatic int unsigned a = wb_adr_i;
            automatic logic [31:0] cur = fetch(a);

            waits <= 0;
            if (wb_we_i) begin
               if (wb_sel_i[0]) cur[ 7: 0] = wb_dat_i[ 7: 0];
               if (wb_sel_i[1]) cur[15: 8] = wb_dat_i[15: 8];
               if (wb_sel_i[2]) cur[23:16] = wb_dat_i[23:16];
               if (wb_sel_i[3]) cur[31:24] = wb_dat_i[31:24];
               mem[a]   = cur;
               n_writes = n_writes + 1;
            end else begin
               n_reads = n_reads + 1;
            end
            wb_dat_o <= cur;
            wb_ack_o <= 1'b1;
         end
      end else begin
         wb_ack_o <= 1'b0;
      end
   end

   // Report how much memory the ROM actually touched -- a quick way to tell
   // "the memory test ran" from "the bus never came up".
   task automatic report();
      $display("[wb_ram] %0d reads, %0d writes, %0d distinct words touched (%0d KiB)",
               n_reads, n_writes, mem.num(), (mem.num() * 4) / 1024);
   endtask

endmodule
