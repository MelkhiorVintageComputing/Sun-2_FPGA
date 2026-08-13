`timescale 1ns / 1ps

//
// The Sun-2 Ethernet board, as it was on a MultiBus 2/120.
//
// Nothing about this resembles the VME machine's on-board Ethernet.  There the
// 82586 becomes a bus master on the 68010 bus and its virtual DMA addresses are
// translated by the machine's own MMU (rtl/sun2_dvma.v).  Here the chip never
// leaves the card: it DMAs into the board's own dual-ported memory through the
// board's own page map, and the CPU reaches the same memory as an ordinary
// MultiBus slave.  On the real card P1.BPRN is passed straight to P1.BPRO --
// the board does not even arbitrate for MultiBus.
//
// Sources: Inputs/Sun2-Multibus-Ethernet/Sun2_Ethernet_Interface_Spec.pdf and
// the 1984-06-22 schematic beside it, and -- the authority when those two
// disagree -- struct mie_device in
// Inputs/sunos-34-src/sun/prom_monitor/msun/sys/sunif/if_mie.h, with its
// drivers in .../sunstand/if_ie.c and sun/sys/sunif/if_ie.c.
//
// Two windows in MultiBus memory space, both jumpered on the real card:
//
//   REG_BASE +0x000..0x7FE   page map, 1024 entries of 16 bits
//            +0x800..0x83E   board ID PROM, 32 bytes, low byte of each word
//            +0x840          status (read) / control (write)
//            +0x842          undefined
//            +0x844..0x847   parity error address -- see below
//
//   MEM_BASE +0..256K        the local memory, translated by the page map and
//                            byte-swapped per page
//
// Page map entry, from `struct miepg':
//
//   15    mp_swab   1 = 68000 byte order.  MultiBus accesses only; it has no
//                   effect on anything the 82586 does.
//   13    mp_p2mem  P2 expansion memory rather than on board.  Always 0 here.
//   11:0  mp_pfnum  physical page number, 1 KiB pages
//
// Status/control at +0x840, from the anonymous struct in if_mie.h:
//
//   15  mies_reset   R/W  1 holds the board in reset -- note the polarity is
//                         the opposite of the VME register's RESET-
//   14  mies_noloop  R/W  1 = normal, 0 = loopback.  The interface spec calls
//                         this "Loopback Enable" with the opposite sense; the
//                         header name and both drivers say otherwise, and they
//                         win: if_ie.c clears it during initialisation and
//                         sets it afterwards to "enable cable".
//   13  mies_ca      R/W  channel attention, a level -- software sets it and
//                         then clears it again
//   12  mies_ie      R/W  interrupt enable
//   11  mies_pie     R/W  parity interrupt enable
//    9  mies_pe      R/O  parity error
//    8  mies_intr    R/O  interrupt request from the chip
//    5  mies_p2mem   R/O  P2 expansion fitted
//    4  mies_bigram  R/O  0 = 256 KiB on board, 1 = 1 MiB
//  3:0  mies_mbmhi   R/O  A19:A16 of the memory window
//
// Three deliberate departures from the card, all of them things an FPGA cannot
// have rather than things left undone:
//
//   * No parity.  Nothing here can produce a parity error, so mies_pe reads 0
//     and the error address register reads 0.  It must still *answer*: the
//     first thing ieinit() does is `mie->mie_peack = 1', a byte
//     read-modify-write at +0x844, and a bus error there kills initialisation
//     before it starts.
//   * No P2 expansion.  mies_p2mem reads 0 and mp_p2mem is ignored; both
//     drivers only ever clear it.
//   * Page-map entries above the memory actually implemented alias back down.
//     The real card answers for 256 KiB and reports it in mies_bigram; MEM_KIB
//     can be turned down for a build where block RAM is scarce, and the boot
//     PROM will not notice because it only ever touches the first 8 KiB
//     (IEPHYMEMSIZ in if_ie.c).
//
module sun2_mb_ether #(
    parameter logic [19:0] REG_BASE   = 20'h88000,
    parameter logic [19:0] MEM_BASE   = 20'h40000,
    parameter int          MEM_KIB    = 256,
    parameter int          PHY_DATA_W = 4
) (
    input  wire        CLK,
    input  wire        RESET,          // the machine's reset, ie MultiBus INIT

    // ---- MultiBus slave -------------------------------------------------
    // mb_sel says the cycle is aimed at MultiBus memory space and mb_addr is
    // the bus address; mb_hit says this card is the one being addressed.
    input  wire        mb_sel,
    input  wire [19:0] mb_addr,        // byte address, bit 0 always 0
    input  wire        mb_we,
    input  wire        mb_uds_n,       // D15:8, the even byte
    input  wire        mb_lds_n,       // D7:0,  the odd byte
    input  wire [15:0] mb_din,
    output wire [15:0] mb_dout,
    output wire        mb_hit,
    output wire        mb_ack,         // this card's MultiBus XACK

    output wire        int_o,          // to IPL 3, autovectored

    // ---- MII ------------------------------------------------------------
    input  wire                   mii_tx_clk,
    output wire [PHY_DATA_W-1:0]  mii_txd,
    output wire                   mii_tx_en,
    output wire                   mii_tx_er,
    input  wire                   mii_rx_clk,
    input  wire [PHY_DATA_W-1:0]  mii_rxd,
    input  wire                   mii_rx_dv,
    input  wire                   mii_rx_er,
    input  wire                   mii_crs,
    input  wire                   mii_col
);

   // Local memory, in 32-bit words.  1 KiB pages, so 256 words per page.
   localparam int MEM_WORDS = MEM_KIB * 256;
   localparam int MEM_AW    = $clog2(MEM_WORDS);

   // The windows are naturally aligned on the card and the decode below
   // assumes it.  A misaligned memory base does not fail loudly, it quietly
   // spreads the window over four times its size and swallows whatever else
   // lives there -- which is how 0xA0000 came to answer for the SCSI at
   // 0x80000 and for this card's own second controller at 0x8C000.
   initial begin
      if (MEM_BASE[17:0] != 18'h0)
        $fatal(1, "sun2_mb_ether: memory window base 0x%05x is not 256 KiB aligned", MEM_BASE);
      if (REG_BASE[11:0] != 12'h0)
        $fatal(1, "sun2_mb_ether: register base 0x%05x is not 4 KiB aligned", REG_BASE);
      if (REG_BASE[19:18] == MEM_BASE[19:18])
        $fatal(1, "sun2_mb_ether: register base 0x%05x falls inside the memory window at 0x%05x",
               REG_BASE, MEM_BASE);
   end

   // ------------------------------------------------------------------
   // Window decode
   // ------------------------------------------------------------------
   // The register window is 4 KiB, compared on A19:A12 (schematic F1, an
   // LS2621 against a DIP switch).  The whole 4 KiB answers, not just the
   // 0x848 bytes that mean anything -- that is what the card's MBDecode PAL
   // does, and the interface spec says as much: writing an unimplemented
   // register "will not cause a bus error, but nothing will happen".
   //
   // The memory window is 256 KiB on A19:A18.  It is fixed at 256 KiB even
   // when less memory is implemented, because mies_mbmhi tells software only
   // where the window starts, never how big it is.
   wire hit_reg = mb_sel & (mb_addr[19:12] == REG_BASE[19:12]);
   wire hit_mem = mb_sel & (mb_addr[19:18] == MEM_BASE[19:18]);

   assign mb_hit = hit_reg | hit_mem;

   // Within the register window
   wire sel_pgmap  = hit_reg & (mb_addr[11] == 1'b0);                  // +0x000..0x7FE
   wire sel_prom   = hit_reg &  (mb_addr[11:6] == 6'b100000);          // +0x800..0x83E
   wire sel_status = hit_reg &  (mb_addr[11:1] == 11'h420);            // +0x840
   wire sel_perr   = hit_reg & ((mb_addr[11:1] == 11'h422) |
                                (mb_addr[11:1] == 11'h423));           // +0x844..0x847

   // ------------------------------------------------------------------
   // Status / control register
   // ------------------------------------------------------------------
   // The card's control register is a 74LS273 cleared by P1.INIT, so a system
   // reset leaves every writable bit at zero: the chip *running* -- mies_reset
   // is active high -- but in loopback, with both interrupt sources disabled.
   //
   // Note what is deliberately NOT reset here: the page map and the local
   // memory.  ieinit() programs the page map and only then calls iereset(),
   // which pulses mies_reset; if that pulse cleared the map the chip would go
   // looking for its SCP through a map of zeros.
   reg ctl_reset, ctl_noloop, ctl_ca, ctl_ie, ctl_pie;

   wire wr_status_hi = sel_status & mb_we & ~mb_uds_n;

   always @(posedge CLK)
     if (RESET) begin
        ctl_reset  <= 1'b0;
        ctl_noloop <= 1'b0;
        ctl_ca     <= 1'b0;
        ctl_ie     <= 1'b0;
        ctl_pie    <= 1'b0;
     end else if (wr_status_hi) begin
        ctl_reset  <= mb_din[15];
        ctl_noloop <= mb_din[14];
        ctl_ca     <= mb_din[13];
        ctl_ie     <= mb_din[12];
        ctl_pie    <= mb_din[11];
     end

   wire mac_int;

   wire [15:0] status_out = {ctl_reset, ctl_noloop, ctl_ca, ctl_ie, ctl_pie,
                             1'b0,          // 10, unused
                             1'b0,          //  9, mies_pe: no parity here
                             mac_int,       //  8, mies_intr
                             2'b00,         // 7:6, unused
                             1'b0,          //  5, mies_p2mem: no P2 bus
                             (MEM_KIB > 256) ? 1'b1 : 1'b0,   // 4, mies_bigram
                             MEM_BASE[19:16]};                // 3:0, mies_mbmhi

   // Channel attention is a level in the register and a one-clock pulse at the
   // chip, exactly as on the VME side.
   reg  ca_d;
   always @(posedge CLK)
     if (RESET) ca_d <= 1'b0;
     else       ca_d <= ctl_ca;
   wire ca_pulse = ctl_ca & ~ca_d;

   // ------------------------------------------------------------------
   // Board ID PROM
   // ------------------------------------------------------------------
   // 32 bytes, readable one at a time on the low byte of a word; the high byte
   // is undefined on the card and zero here.  Writes are accepted and thrown
   // away -- that is not laziness, it is the probe contract:
   //
   //     if (poke(sp, 0x6789))       return (-1);   /* must not bus-error */
   //     if (peek(sp) == 0x6789)     return (-1);   /* must not stick */
   //
   // so ieprobe() distinguishes this card from plain RAM at the same address.
   // Nothing ever reads the contents for meaning: on a MultiBus machine the
   // Ethernet address comes from the *CPU* board's ID PROM, via ndinit() and
   // localetheraddr(), not from here.  The bytes below are the same identity
   // rtl/idprom.v serves, so a curious reader sees something sensible, and no
   // word of it can read back as 0x6789.
   reg [7:0] ie_prom [0:31];
   integer   i;
   initial begin
      for (i = 0; i < 32; i = i + 1) ie_prom[i] = 8'h00;
      ie_prom[0]  = 8'h01;              // format 1
      ie_prom[1]  = 8'h01;              // machine type: MultiBus
      ie_prom[2]  = 8'h08;              // Ethernet address 8:0:20:1:6:E0
      ie_prom[3]  = 8'h00;
      ie_prom[4]  = 8'h20;
      ie_prom[5]  = 8'h01;
      ie_prom[6]  = 8'h06;
      ie_prom[7]  = 8'hE0;
   end

   wire [7:0] prom_byte = ie_prom[mb_addr[5:1]];

   // ------------------------------------------------------------------
   // Slave timing
   // ------------------------------------------------------------------
   // Both ports are two lookups deep for a memory access -- page map, then
   // memory -- and one deep for a register.  A small phase counter per port
   // sequences that; declared here because the memory blocks below qualify
   // their writes with it, and xvlog will not take a wire used before it is
   // declared.
   //
   // Everything is far inside the machine's twelve-clock bus timeout.
   reg [1:0] phase;
   always @(posedge CLK)
     if (RESET | ~mb_hit)      phase <= 2'd0;
     else if (phase != 2'd2)   phase <= phase + 2'd1;

   // The cycle on which a window access has its translation and may commit.
   wire mem_ready = hit_mem & (phase == 2'd1);

   // ------------------------------------------------------------------
   // The page map
   // ------------------------------------------------------------------
   // 1024 entries of 16 bits, shared by both ports through an address mux on
   // the real card.  Here it is a dual-port memory instead: port A serves the
   // CPU, which is either reading/writing an entry as a register or having a
   // window access translated -- never both in the same cycle -- and port B
   // serves the 82586.
   //
   // The MultiBus port's index is the *offset within the window*, 0..255, not
   // the raw bus address: ieinit() sets mie_pgmap[0].mp_pfnum and then writes
   // to the first kilobyte of the window, which only works if the two are the
   // same page.
   (* ram_style = "block" *)
   reg [15:0] pgmap [0:1023];

   wire [9:0] pg_idx_cpu = sel_pgmap ? mb_addr[10:1]              // as a register
                                     : {2'b00, mb_addr[17:10]};   // as a translation

   reg [15:0] pg_cpu_q;
   always @(posedge CLK) begin
      if (sel_pgmap & mb_we) begin
         if (~mb_uds_n) pgmap[pg_idx_cpu][15:8] <= mb_din[15:8];
         if (~mb_lds_n) pgmap[pg_idx_cpu][7:0]  <= mb_din[7:0];
      end
      pg_cpu_q <= pgmap[pg_idx_cpu];
   end

   wire        pg_swab  = pg_cpu_q[15];
   wire [11:0] pg_pfnum = pg_cpu_q[11:0];

   // ------------------------------------------------------------------
   // The 82586 and its side of the map
   // ------------------------------------------------------------------
   wire        wbm_cyc, wbm_stb, wbm_we, wbm_ack;
   wire [3:0]  wbm_sel;
   wire [29:0] wbm_adr;
   wire [31:0] wbm_dat_w, wbm_dat_r;

   // "Board ignores high order nibble of chip generated addresses" (if_mie.h),
   // so the chip's 24-bit space folds to 20 bits and the page map covers all of
   // it.  wbm_adr is a word address: byte address bits 19:2.
   wire [17:0] mac_word = wbm_adr[17:0];
   wire [9:0]  pg_idx_mac = mac_word[17:8];

   wire mac_req = wbm_cyc & wbm_stb;

   // Same two-deep sequence as the CPU side, and for the same reason.
   reg [1:0] mac_phase;
   always @(posedge CLK)
     if (RESET | ~mac_req)         mac_phase <= 2'd0;
     else if (mac_phase != 2'd2)   mac_phase <= mac_phase + 2'd1;

   wire mac_ready = mac_req & (mac_phase == 2'd1);

   reg [15:0] pg_mac_q;
   always @(posedge CLK)
     pg_mac_q <= pgmap[pg_idx_mac];

   // ------------------------------------------------------------------
   // Local memory
   // ------------------------------------------------------------------
   // True dual-port, one port each side, which is what the 8207 gave the real
   // card: the CPU cannot starve the chip and no arbiter is needed.
   //
   // Byte lane k of a word holds board byte address 4N+k.  That is the 82586's
   // own convention -- the lane crossing in sun2_dvma.v exists to undo the
   // 68000's big-endian byte-in-word order, not because the MAC is unusual --
   // so the chip's port needs no swapping at all, and the memory ends up
   // holding Intel byte order, exactly as the interface spec says it should.
   //
   // Four separate byte-wide banks rather than one array of four-byte words.
   // That is how the memory is really organised -- byte lanes with their own
   // write enables -- and it is also the only way Vivado will take it: a single
   // variable is capped at 1,000,000 bits, and 256 KiB is 2,097,152.  The banks
   // are declared inside the generate below so each is its own variable.

   // Physical byte address: page frame then offset within the 1 KiB page.
   // Frame bits above the memory implemented are dropped, so a map entry
   // pointing past the end aliases rather than vanishing.
   wire [19:0]       mac_phys  = {pg_mac_q[11:0], mac_word[7:0]};
   wire [19:0]       cpu_phys  = {pg_pfnum,       mb_addr[9:2]};
   wire [MEM_AW-1:0] mem_a_word = mac_phys[MEM_AW-1:0];
   wire [MEM_AW-1:0] mem_b_word = cpu_phys[MEM_AW-1:0];

   // Which byte lane each side of a 16-bit CPU access lands in.
   //
   // mp_swab = 1, "68000 byte order", is the *identity*: D15:8 is board byte B
   // and D7:0 is byte B+1, exactly as a 68000 addresses memory.  It is worth
   // being sure of this, because the name invites the opposite reading and
   // getting it wrong produces a chip that reads plausible rubbish.
   //
   // The driver byte-reverses every multi-byte field in software before
   // storing it -- to_ieaddr() and to_ieoff() in if_ie.c, and the note at the
   // top of if_iereg.h, "all fields are byte-swapped because the damn chip
   // wants bytes in Intel byte order only".  Take a 16-bit offset of 0x0400:
   // to_ieoff() turns it into the bytes {0x00, 0x04}, a 68000 store puts 0x00
   // at B and 0x04 at B+1, and the chip reads little-endian and gets 0x0400.
   // That only works if the CPU's byte B is the chip's byte B.  And the same
   // conversions are used unchanged on the VME machine, which has no page map
   // and no swapper at all -- so the byte path the software expects is plainly
   // the straight one.  mp_swab = 1 is what the driver sets on every page it
   // builds control blocks in, so mp_swab = 1 is the straight path.
   //
   // mp_swab = 0 is then the exchanging one, and it is what all 1024 entries
   // are left at by the loop that clears the map -- which only ever writes
   // zeros, where the distinction cannot show.
   wire       half = mb_addr[1];              // which 16 bits of the word
   wire [1:0] lane_even = {half, 1'b0};       // board byte B
   wire [1:0] lane_odd  = {half, 1'b1};       // board byte B+1

   wire [1:0] lane_hi = pg_swab ? lane_even : lane_odd;    // -> D15:8
   wire [1:0] lane_lo = pg_swab ? lane_odd  : lane_even;   // -> D7:0

   wire wr_hi = mem_ready & mb_we & ~mb_uds_n;
   wire wr_lo = mem_ready & mb_we & ~mb_lds_n;

   wire [31:0] mem_a_q;                       // to the chip, 32 bits
   wire [31:0] b_qw;                          // all four banks, to be picked from

   // Each bank is a true dual-port memory: the chip on one port, the MultiBus
   // window on the other, which is what the 8207 gave the real card -- the CPU
   // cannot starve the chip and no arbiter is needed.  Both ports have to be
   // plain "if (we) mem[a] <= d; q <= mem[a];" blocks, one per port, or Vivado
   // will not recognise the template and refuses to infer block RAM at all.
   genvar k;
   generate
      for (k = 0; k < 4; k = k + 1) begin : bank
         (* ram_style = "block" *) reg [7:0] mem [0:MEM_WORDS-1];
         reg [7:0] a_q, b_q;

         // Port A -- the 82586.  Lane k is board byte address 4N+k, always.
         wire a_we = mac_ready & wbm_we & wbm_sel[k];

         always @(posedge CLK) begin
            if (a_we) mem[mem_a_word] <= wbm_dat_w[8*k +: 8];
            a_q <= mem[mem_a_word];
         end

         // Port B -- the window.  This bank is written when whichever of the
         // two CPU byte lanes the page map points at happens to be this one.
         wire b_we = (wr_hi & (lane_hi == k[1:0])) |
                     (wr_lo & (lane_lo == k[1:0]));
         wire [7:0] b_wd = (wr_hi & (lane_hi == k[1:0])) ? mb_din[15:8]
                                                         : mb_din[7:0];

         always @(posedge CLK) begin
            if (b_we) mem[mem_b_word] <= b_wd;
            b_q <= mem[mem_b_word];
         end

         assign mem_a_q[8*k +: 8] = a_q;
         assign b_qw[8*k +: 8]    = b_q;
      end
   endgenerate

   // The lane each byte came from is only known once the page map has been
   // read, so it is registered alongside the data and the pick happens after.
   reg [1:0] lane_hi_q, lane_lo_q;
   always @(posedge CLK) begin
      lane_hi_q <= lane_hi;
      lane_lo_q <= lane_lo;
   end

   // Written out rather than wrapped in a function on purpose: a function call
   // in a continuous assignment is sensitive only to its arguments, so a
   // pick(lane_hi_q) would never re-evaluate when the bank outputs changed and
   // every read would come back X.
   wire [7:0] b_hi = (lane_hi_q == 2'd0) ? b_qw[7:0]
                   : (lane_hi_q == 2'd1) ? b_qw[15:8]
                   : (lane_hi_q == 2'd2) ? b_qw[23:16]
                   :                       b_qw[31:24];
   wire [7:0] b_lo = (lane_lo_q == 2'd0) ? b_qw[7:0]
                   : (lane_lo_q == 2'd1) ? b_qw[15:8]
                   : (lane_lo_q == 2'd2) ? b_qw[23:16]
                   :                       b_qw[31:24];

   wire [15:0] mem_b_q = {b_hi, b_lo};

   // A register access answers one lookup deep, a window access two.
   assign mb_ack = hit_reg ? (phase != 2'd0)
                           : (phase == 2'd2);

   assign mb_dout = sel_pgmap  ? pg_cpu_q
                  : sel_prom   ? {8'h00, prom_byte}
                  : sel_status ? status_out
                  : sel_perr   ? 16'h0000
                  : hit_mem    ? mem_b_q
                  :              16'h0000;

   // ------------------------------------------------------------------
   // The chip
   // ------------------------------------------------------------------
   // Acknowledge once the translation and then the memory have both been read.
   // There is no error to report: unlike the VME machine, where a DMA cycle
   // goes out through the MMU and can take a bus error, everything the chip
   // touches here is on the card.
   assign wbm_ack   = mac_req & (mac_phase == 2'd2);
   assign wbm_dat_r = mem_a_q;

   wish82586 #(.PHY_DATA_W(PHY_DATA_W)) mac (
       .clk        (CLK),
       .rst        (RESET),
       .core_rst_i (ctl_reset),          // active high, unlike the VME card
       .ca_i       (ca_pulse),
       .scp_addr_i (32'h00ff_fff6),      // hard-wired on the part
       .cus_o      (),
       .rus_o      (),
       .busy_o     (),
       .int_o      (mac_int),
       .bus_err_o  (),                   // nothing on this card can fault
       .wbm_cyc_o  (wbm_cyc),
       .wbm_stb_o  (wbm_stb),
       .wbm_we_o   (wbm_we),
       .wbm_sel_o  (wbm_sel),
       .wbm_adr_o  (wbm_adr),
       .wbm_dat_o  (wbm_dat_w),
       .wbm_dat_i  (wbm_dat_r),
       .wbm_ack_i  (wbm_ack),
       .wbm_err_i  (1'b0),
       .mii_tx_clk (mii_tx_clk),
       .mii_txd    (mii_txd),
       .mii_tx_en  (mii_tx_en),
       .mii_tx_er  (mii_tx_er),
       .mii_rx_clk (mii_rx_clk),
       .mii_rxd    (mii_rxd),
       .mii_rx_dv  (mii_rx_dv),
       .mii_rx_er  (mii_rx_er),
       .mii_crs    (mii_crs),
       .mii_col    (mii_col)
   );

   // The card drives one of P1.INT0..7 through a jumper; SunOS has it at
   // priority 3, autovectored, the same level the VME machine's on-board part
   // uses.  The boot PROM never enables it -- it polls throughout -- so this
   // matters only to a kernel.
   assign int_o = ctl_ie & mac_int;

endmodule
