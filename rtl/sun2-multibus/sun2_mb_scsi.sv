`timescale 1ns / 1ps

`include "sun2_attr.vh"

//
// The Sun-2 MultiBus SCSI host adapter: a disk for a 2/120, and four serial
// ports beside it.
//
// A single MultiBus card carrying the same SCSI interface as the VME SCSI/RTC
// board and, in place of that board's clock, **two Zilog Z8530s** -- four serial
// lines with full modem control.  Documented in Inputs/doc/Sun-2_SCSI/: the
// Programmers' Manual (Jul 83), two Theories of Operation, the 1984-04-05
// schematic, and four PAL listings.
//
// **The SCSI interface is not here.**  It is rtl/sun2-common/sun2_scsi_core.sv,
// shared with rtl/sun2-vme/sun2_vme_scsi.sv, because Sun built one design and
// packaged it twice -- their Theory of Operation says "The SCSI bus interface is
// the same for both this board (for the P796 bus) and the Sun-2 Single Board",
// and the two boards' drivers are byte-identical files.  This file is what the
// MultiBus backplane adds: a 16 KiB window of three 2 KiB pages, no interrupt
// vector, and a 20-bit DMA address.
//
// ---- The window ----------------------------------------------------------
//
// Theory of Operation section 4.2: "The SCSI board responds to a 16 Kbyte bank
// of addresses.  The first 2 K is used for the SCSI registers.  The second 2 K
// is used for one UART chip (2 channels), and the third 2 K is used for the
// other UART chip (2 channels).  The SCSI registers and the UARTS are on
// separate 2 K boundaries so that the memory protection hardware on the CPU can
// protect the devices separately (protection applies to 2 K pages)."
//
//   base + 0x0000   SCSI host adapter, eight registers aliasing every 16 bytes
//   base + 0x0800   Z8530 #1 -- channel B ctl/data at +0/+2, channel A at +4/+6
//   base + 0x1000   Z8530 #2 -- channel D ctl/data at +0/+2, channel C at +4/+6
//
// **The kernel's own configuration file confirms that layout independently**,
// which is worth more than either document alone because neither could have been
// derived from the other -- conf.sun2/GENERIC:59,67,78-81:
//
//   controller sc0 at mbmem ? csr 0x80000 priority 2
//   controller sc1 at mbmem ? csr 0x84000 priority 2
//   device     zs2 at mbmem ? csr 0x80800 flags 3 priority 3
//   device     zs3 at mbmem ? csr 0x81000 flags 3 priority 3
//   device     zs4 at mbmem ? csr 0x84800 flags 3 priority 3
//
// so two cards, 16 KiB apart, each with its SCCs at +0x800 and +0x1000.
//
// ---- Why 0x80000 and not 0x84000 ----------------------------------------
//
// Both are real dip-switch settings (section 4.2: the base is "set with Dip
// Switch U305 ... the six high order address bits P1.A14 - P1.A19").  0x80000 is
// the default here because it is the one that works at both ends:
//
//   * the kernel calls it **sc0**, so its disks are sd0/sd1 and root is sd0a;
//   * the PROM can still boot it.  sdstd[] is { SCSI_BASE, MBMEM_BASE+0x84000, 0 }
//     (sunstand/sd.c:17) and SCSI_BASE is 0xEE2800 -- which on a MultiBus
//     machine the monitor maps *out to the bus at 0x80000*:
//
//        {(char *)SCSI_BASE, 0,
//              {1, ..., MPM_BUSMEM, 0, 0, 0x80000>>BYTES_PG_SHIFT}}
//                                      -- msun/mon/kernel/sunmon.c:168-171
//
//     The same table entry on a VME machine points at VME A24 0x200000 instead,
//     which is how one PROM source serves both.  So 0xEE2800 is an alias page
//     for sc0 and not an on-board device: there is no on-board SCSI page number
//     anywhere in s2map.h.
//
// A card at 0x84000 answers `sd(1,0,0)' and is called sc1, with disks sd2/sd3.
// That is the second board, and MB_SCSI_BASE is how you build it.
//
// ---- Interrupts ----------------------------------------------------------
//
// **Non-vectored**, unlike the VME board.  Architectural Specification,
// "Interrupts": "The SCSI board interrupts with non-vectored Multibus
// interrupts.  A switch on the board selects the interrupt level as either
// 3,4,5, or 6."  What the Sun-2 does with those MultiBus levels is settled by
// the software rather than by that sentence: GENERIC gives the adapter
// `priority 2' with no vector clause, and the SCCs `priority 3'.  So the card
// has **two** interrupt outputs at two different levels, which is why scc_int_o
// exists in the port list before the SCCs do.
//
// The vector register is still written.  scattach() has no MultiBus/VME
// conditional beyond this one (sundev/sc.c:160-165):
//
//     if (mc->mc_intr) { c->c_har->intvec = mc->mc_intr->v_vec; ... }
//     else             { c->c_har->intvec = AUTOBASE + mc->mc_intpri; }
//
// so a card that bus-errored at +0x0F would kill autoconfig on the machine that
// has no vector at all.  sun2_scsi_core's HAS_INTVEC(0) accepts and discards it.
//
module sun2_mb_scsi #(
    // MultiBus memory space, 16 KiB aligned.  sc0; sc1 is 20'h84000.
    parameter logic [19:0] MB_SCSI_BASE = 20'h80000,

    // Where a MultiBus address the card masters lands in the CPU's world.  The
    // PROM's FAKES1BOOT remap puts virtual 0xF00000 on MultiBus 0, so a
    // dma_addr of X is virtual DVMA_BASE + X -- the arrangement sun2_xy450.sv
    // uses, and the reason a build needs at least 1 MiB installed.
    parameter logic [23:0] DVMA_BASE = 24'hF00000
) (
    input  wire        CLK,
    input  wire        RESET,          // the machine's reset, ie MultiBus INIT

    // ---- MultiBus slave, memory space (page-map TYPE 2) -----------------
    input  wire        mb_sel,
    input  wire [19:0] mb_addr,        // byte address, bit 0 always 0
    input  wire        mb_we,
    input  wire        mb_uds_n,       // D15:8, the even byte
    input  wire        mb_lds_n,       // D7:0,  the odd byte
    input  wire [15:0] mb_din,
    output wire [15:0] mb_dout,
    output wire        mb_hit,
    output wire        mb_ack,         // this card's MultiBus XACK

    output wire        int_o,          // to IPL 2, autovectored -- GENERIC:59
    output wire        scc_int_o,      // to IPL 3 -- GENERIC:78-79, stage 2

    // ---- DVMA master ----------------------------------------------------
    output wire        wb_cyc_o,
    output wire        wb_stb_o,
    output wire        wb_we_o,
    output wire [3:0]  wb_sel_o,
    output wire [21:0] wb_adr_o,
    output wire [31:0] wb_dat_o,
    input  wire [31:0] wb_dat_i,
    input  wire        wb_ack_i,
    input  wire        wb_err_i,
    output wire        wb_clr_o,

    // ---- the drive's block back end, flattened the way top_fpga carries it
    output wire        blk_start,
    output wire        blk_we,
    output wire [31:0] blk_lba,
    output wire [7:0]  blk_buf_rdata,
    input  wire        blk_done,
    input  wire        blk_err,
    input  wire        blk_ready,
    input  wire [31:0] blk_count,
    input  wire        blk_buf_we,
    input  wire [8:0]  blk_buf_addr,
    input  wire [7:0]  blk_buf_wdata
);

   initial begin
      if (MB_SCSI_BASE[13:0] != 14'h0)
        $fatal(1, "sun2_mb_scsi: base 0x%05x is not 16 KiB aligned -- dip switch U305 selects P1.A14..A19",
               MB_SCSI_BASE);
   end

   // ------------------------------------------------------------------
   // Window and page decode
   // ------------------------------------------------------------------
   // Six bits, because that is what the dip switch compares (section 4.2).
   wire       hit  = mb_sel & (mb_addr[19:14] == MB_SCSI_BASE[19:14]);
   wire [2:0] page = mb_addr[13:11];

   wire sel_scsi = hit & (page == 3'd0);
   wire sel_zs0  = hit & (page == 3'd1);   // zs2 / zs4
   wire sel_zs1  = hit & (page == 3'd2);   // zs3 / zs5

   assign mb_hit = hit;

   // Only A01..A03 inside the SCSI page, so the eight registers repeat every
   // sixteen bytes for the whole 2 KiB: "U200 and U210 further decode A00 - A03
   // to separately address the different SCSI registers" (section 4.2).
   wire [2:0] reg_sel = mb_addr[3:1];

   // ------------------------------------------------------------------
   // Acknowledge
   // ------------------------------------------------------------------
   // Window-wide, including the two pages whose chips are not fitted yet.
   //
   // That is what the board does -- XACK is gated by the board select and not by
   // the page: "The output signal from U304 drives P1.XACK\ through U316 section
   // 2, which is enabled by the board select line SEL\" (section 4.3), where
   // SEL\ is the six-bit dip-switch compare over the whole 16 KiB.  It is also
   // what the machine needs: a bus error on page 1 would make a later zs2 probe
   // read as a missing chip rather than as a silent one, and the difference
   // between those two is a device that autoconfig reports and one it does not.
   //
   // The real board varies the delay by page, because "The SCSI registers
   // require less than 100 nsec for reading or writing, whereas the UART's take
   // about 500 nsec" (section 4.3) and U302/U304 pick a delay from A11-A13.  A
   // Z8530 here is a synchronous model that answers as fast as the SCSI
   // registers, and nothing in software measures the difference -- the same
   // argument sun2_vme_scsi.sv makes for the MM58167 -- so one count serves all
   // three pages.  Two clocks, well inside the twelve C_S24 allows.
   localparam [4:0] ACK_AT = 5'd2;
   reg [4:0] phase;
   always @(posedge CLK)
     if (RESET | ~hit)          phase <= 5'd0;
     else if (phase != ACK_AT)  phase <= phase + 5'd1;
   assign mb_ack = hit & (phase == ACK_AT);

   // One clock of "the cycle has just been acknowledged", for side effects that
   // must happen once however long the strobes stay low.
   wire fire = hit & (phase == ACK_AT - 5'd1);

   // ------------------------------------------------------------------
   // The SCSI interface
   // ------------------------------------------------------------------
   wire [15:0] scsi_rd;

   sun2_scsi_core #(.DVMA_BASE    (DVMA_BASE),
                    .DMA_ADDR_BITS(20),          // MultiBus is 20 address bits
                    .HAS_INTVEC   (0),           // non-vectored; see the header
                    .PRODUCT      ("SUN MB SCSI SD  "))
   scsi (.CLK(CLK), .RESET(RESET),

         .sel_i(sel_scsi), .fire_i(fire), .reg_i(reg_sel),
         .we_i(mb_we), .uds_n_i(mb_uds_n), .lds_n_i(mb_lds_n),
         .din_i(mb_din), .dout_o(scsi_rd),

         .int_o(int_o), .intvec_o(),

         .wb_cyc_o(wb_cyc_o), .wb_stb_o(wb_stb_o), .wb_we_o(wb_we_o),
         .wb_sel_o(wb_sel_o), .wb_adr_o(wb_adr_o), .wb_dat_o(wb_dat_o),
         .wb_dat_i(wb_dat_i), .wb_ack_i(wb_ack_i), .wb_err_i(wb_err_i),
         .wb_clr_o(wb_clr_o),

         .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
         .blk_buf_rdata(blk_buf_rdata),
         .blk_done(blk_done), .blk_err(blk_err), .blk_ready(blk_ready),
         .blk_count(blk_count), .blk_buf_we(blk_buf_we),
         .blk_buf_addr(blk_buf_addr), .blk_buf_wdata(blk_buf_wdata));

   // ------------------------------------------------------------------
   // The serial lines
   // ------------------------------------------------------------------
   // Two Z8530s, four channels, at +0x800 and +0x1000.  Not fitted yet: the
   // pages decode and acknowledge, and read as zero.
   //
   // They are deliberately decoded ahead of being built, because the window size
   // and the acknowledge boundary are what the *machine* sees, and changing
   // either later would change the address map rather than add a device.  The
   // model to instantiate here already exists and is already patched and tested
   // -- Inputs/z8530_scc/z8530_scc.sv, driven the Sun-2 way by `make -C sim scc'
   // -- and its interrupt goes to scc_int_o at IPL 3, not to int_o.
   assign scc_int_o = 1'b0;

   assign mb_dout = sel_scsi ? scsi_rd : 16'h0000;

endmodule
