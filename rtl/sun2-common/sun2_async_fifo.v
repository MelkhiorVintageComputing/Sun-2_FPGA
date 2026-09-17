`timescale 1ns / 1ps

`include "sun2_attr.vh"

//
// A dual-clock FIFO: gray-coded pointers, two-flop synchronisers, and a
// first-word-fall-through read.
//
// It exists for sun2_fifo_bridge, which puts one of these on each side of the
// crossing between the machine's cpu_clk and the memory controller's clock:
// requests out, read data back.  It is written here rather than borrowed from
// Inputs/Wish82586/src/async_fifo.sv -- which it follows closely -- because the
// machine's memory path should not depend on an Ethernet submodule, and
// because rtl/sun2-common is Verilog-2001 and that one is SystemVerilog.
//
// **First word fall through.**  `rd_data' is the head of the queue whenever
// `rempty' is low, with no read strobe needed to see it, and `rd_en' consumes
// it.  The bridge needs that: it looks at the head's tag before deciding
// whether to take it.  The storage is therefore read asynchronously -- LUT RAM
// on a Xilinx part, registers on a MAX 10, which has no asynchronous-read
// memory -- and that is only acceptable because the depths used are tiny.
//
// **Why the asynchronous read is safe across the domains.**  An entry is
// written on a wclk edge and the write pointer that covers it is registered on
// that same edge, then passes two rclk flops before `rempty' can fall.  So the
// storage cell has been stable for at least two read clocks before anything in
// the read domain looks at it.  Nothing reads a cell that is being written:
// the write side only ever writes the one entry the read side cannot yet see.
//
// **Pointers cross as registered gray code**, one bit changing per step, with
// no logic between the source register and the first synchroniser flop, so a
// synchroniser that resolves late sees either the old pointer or the new one
// and never a mixture.  Simulation cannot check any of that -- there is no
// metastability in a simulator -- which is why the structure is written out
// plainly and left for report_cdc to confirm on the netlist.
//
// **Resets.**  `wrst' and `rrst' are synchronous to their own clocks and
// clear their own side.  The FIFO is only consistent if both are held long
// enough to overlap, as the bridge does; releasing one side alone while the
// other holds a non-empty queue desynchronises the pointers.
//
// DEPTH is 2**ADDR, and ADDR must be at least 2: the full comparison inverts
// the top two bits of the synchronised read pointer.
//
module sun2_async_fifo #(
   parameter WIDTH = 8,
   parameter ADDR  = 2
) (
   // ---- write side -----------------------------------------------------------
   input              wclk,
   input              wrst,
   input              wr_en,
   input  [WIDTH-1:0] wr_data,
   output             wfull,

   // ---- read side ------------------------------------------------------------
   input              rclk,
   input              rrst,
   input              rd_en,
   output [WIDTH-1:0] rd_data,
   output             rempty
);

`ifdef SUN2_SIM
   initial if (ADDR < 2) begin
      $display("sun2_async_fifo: ADDR must be at least 2 (DEPTH >= 4), not %0d", ADDR);
      $finish;
   end
`endif

   reg [WIDTH-1:0] mem [0:(1<<ADDR)-1];

   reg  [ADDR:0] wbin, wgray, rbin, rgray;
   `SUN2_ASYNC_REG reg [ADDR:0] rgray_w1;
   `SUN2_ASYNC_REG reg [ADDR:0] rgray_w2;     // read pointer, seen by the write side
   `SUN2_ASYNC_REG reg [ADDR:0] wgray_r1;
   `SUN2_ASYNC_REG reg [ADDR:0] wgray_r2;     // write pointer, seen by the read side

   // ---- write side -------------------------------------------------------------
   wire          do_wr     = wr_en & ~wfull;
   wire [ADDR:0] wbin_next = wbin + {{ADDR{1'b0}}, do_wr};

   always @(posedge wclk) begin
      if (wrst) begin
         wbin     <= {(ADDR+1){1'b0}};
         wgray    <= {(ADDR+1){1'b0}};
         rgray_w1 <= {(ADDR+1){1'b0}};
         rgray_w2 <= {(ADDR+1){1'b0}};
      end else begin
         wbin     <= wbin_next;
         wgray    <= wbin_next ^ (wbin_next >> 1);
         rgray_w1 <= rgray;
         rgray_w2 <= rgray_w1;
      end
   end

   always @(posedge wclk)
     if (do_wr) mem[wbin[ADDR-1:0]] <= wr_data;

   // Full: the pointers agree except in their two most significant gray bits,
   // i.e. the write pointer is exactly one lap ahead.
   assign wfull = (wgray == {~rgray_w2[ADDR:ADDR-1], rgray_w2[ADDR-2:0]});

   // ---- read side --------------------------------------------------------------
   wire          do_rd     = rd_en & ~rempty;
   wire [ADDR:0] rbin_next = rbin + {{ADDR{1'b0}}, do_rd};

   always @(posedge rclk) begin
      if (rrst) begin
         rbin     <= {(ADDR+1){1'b0}};
         rgray    <= {(ADDR+1){1'b0}};
         wgray_r1 <= {(ADDR+1){1'b0}};
         wgray_r2 <= {(ADDR+1){1'b0}};
      end else begin
         rbin     <= rbin_next;
         rgray    <= rbin_next ^ (rbin_next >> 1);
         wgray_r1 <= wgray;
         wgray_r2 <= wgray_r1;
      end
   end

   assign rempty  = (rgray == wgray_r2);
   assign rd_data = mem[rbin[ADDR-1:0]];

endmodule
