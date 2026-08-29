`timescale 1ns / 1ps
//
// A 3Com 3C400 MultiBus Ethernet controller.
//
// The alternative to rtl/sun2-multibus/sun2_mb_ether.sv, and the reason it
// exists is arithmetic: the Sun card carries 256 KiB of on-card RAM, which is
// 2,097,152 bits, which is 256 M9K on a MAX 10 that has 182.  It cannot fit on
// the DECA at any clock with anything else removed.  This card's entire
// aperture is 8 KiB and its real storage is 6156 bytes -- three 2 KiB buffers,
// twelve bytes of address ROM and RAM, and two registers -- so it fits in six
// M9K and leaves the machine room for a disk as well.
//
// The two cards are mutually exclusive, and not merely by taste: top_fpga.v
// has one MII port and both `ifdef arms drive it.
//
// ---------------------------------------------------------------- sources
//
// Inputs/doc/3com_3C400_Multibus_Ethernet_Jul82.pdf is 3Com's own manual;
// chapter 4 is the programming chapter and Figures 4-1 to 4-4 are images, so
// the bit numbers have to be read as pictures rather than grepped.  The 21 Jul
// 1982 addendum bound in front of it exists almost entirely to correct two
// status-bit polarities -- see MEAHDR below.
//
// Three independent drivers describe the same device and agree bit for bit:
// Sun's PROM monitor (Inputs/sunos-34-src/sun/prom_monitor/msun/sys/sunstand/
// if_ec.c, 123 lines, the whole thing), Sun's kernel driver (sun/sys/sunif/
// if_ec.c) and NetBSD's.  Where the manual and the drivers disagree the
// drivers win, because they are what will actually run.
//
// ------------------------------------------------------- the register map
//
//   0x0000  MECSR   control/status      replicated every 4 bytes to 0x3FF
//   0x0002  MEBACK  backoff, WRITE-ONLY a read of +2 returns MECSR
//   0x0400  arom    station address ROM 8-byte block, aliased to 0x5FF
//   0x0600  aram    station address RAM 8-byte block, aliased to 0x7FF
//   0x0800  MEXHDR + 2048-byte transmit buffer
//   0x1000  MEAHDR + 2048-byte receive buffer A
//   0x1800  MEBHDR + 2048-byte receive buffer B
//
// The aliasing is not decoration.  Manual 4.3: "MECSR and MEBACK are
// replicated all through the control region", and the address ROM and RAM are
// each "the first six bytes of an eight byte block; this eight byte block is
// replicated throughout the region".  So the decode below looks at low address
// bits only and ignores the rest.
//
// ----------------------------------------- the bit that is not in the manual
//
// **Writing a one SETS an ownership bit; writing a zero does nothing.**  The
// manual never says so and every driver depends on it: NetBSD's ec_init()
// writes a literal 0x0000 to MECSR immediately after setting AMSW and expects
// AMSW to stay set, and Sun's ECCLR macro writes zeros into the whole high
// byte on every interrupt while the card keeps its buffers.  JAM is the
// inverse -- the addendum says "the JAM bit is cleared by setting it".
//
// Get this wrong and nothing works, in a way no amount of staring at the
// manual will explain.
//
`timescale 1ns / 1ps

`include "sun2_attr.vh"

module sun2_mb_3c400 #(
    // MEBASE.  The switches allow any 8 KiB boundary; a Sun-2 puts the card at
    // MBMEM_BASE+0xE0000 and the PROM probes there and at 0xE2000 for a second
    // controller.  Only one is built, so the 0xE2000 probe must still time out.
    parameter logic [19:0] EC_BASE      = 20'hE0000,
    parameter int          PHY_DATA_W   = 4,
    // The station address PROM.  Programmed with the machine's own ID PROM
    // address so the two agree -- the SunOS kernel passes &ec_arom to
    // localetheraddr() and the boot path uses the ID PROM, and while
    // localetheraddr is first-caller-wins so the card's copy is probably never
    // read, making them match is right under either reading and costs nothing.
    parameter logic [47:0] STATION_ADDR = 48'h08_00_20_01_06_E0
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

   initial begin
      if (EC_BASE[12:0] != 13'h0)
        $fatal(1, "sun2_mb_3c400: MEBASE 0x%05x is not 8 KiB aligned", EC_BASE);
   end

   // ------------------------------------------------------------------
   // Window and region decode
   // ------------------------------------------------------------------
   wire        hit = mb_sel & (mb_addr[19:13] == EC_BASE[19:13]);
   wire [12:0] a   = {mb_addr[12:1], 1'b0};

   wire sel_ctl  = hit & (a[12:10] == 3'b000);    // 0x000..0x3FF, aliased /4
   wire sel_arom = hit & (a[12:9]  == 4'b0010);   // 0x400..0x5FF, aliased /8
   wire sel_aram = hit & (a[12:9]  == 4'b0011);   // 0x600..0x7FF, aliased /8
   wire sel_tbuf = hit & (a[12:11] == 2'b01);     // 0x800..0xFFF
   wire sel_abuf = hit & (a[12:11] == 2'b10);     // 0x1000..0x17FF
   wire sel_bbuf = hit & (a[12:11] == 2'b11);     // 0x1800..0x1FFF

   // Inside the control region only A1 matters: even word is MECSR, odd word
   // is MEBACK on a write.  A read of either returns MECSR, because MEBACK is
   // write-only -- manual 4.3, "if the software attempts to read MEBACK, it
   // will read MECSR instead".
   wire sel_csr_wr  = sel_ctl & ~a[1];
   wire sel_back_wr = sel_ctl &  a[1];

   assign mb_hit = hit;

   // Two lookups deep for a buffer, one for a register -- and uniformly two
   // here, because the buffers are the common case and the machine's timeout
   // is twelve clocks away.
   reg [1:0] phase;
   always @(posedge CLK)
     if (RESET | ~hit)       phase <= 2'd0;
     else if (phase != 2'd2) phase <= phase + 2'd1;
   assign mb_ack = hit & (phase == 2'd2);

   wire wr_hi = mb_we & ~mb_uds_n;   // even byte, D15:8
   wire wr_lo = mb_we & ~mb_lds_n;   // odd byte,  D7:0

   // ------------------------------------------------------------------
   // MECSR
   // ------------------------------------------------------------------
   reg        bbsw, absw, tbsw, jam, amsw, rbba;
   reg        binten, ainten, tinten, jinten;
   reg [3:0]  pa;
   reg [15:0] meback;                // written, never read, never acted on

   // RESET (bit 8) always reads zero, and bit 9 does not exist.  The whole
   // register must read 0x0000 out of reset: NetBSD's ec_match() is literally
   // `peek_2(csr) == 0' and will not attach otherwise.
   wire [15:0] csr_rd = {bbsw, absw, tbsw, jam, amsw, rbba, 1'b0, 1'b0,
                         binten, ainten, tinten, jinten, pa};

   wire soft_reset = sel_csr_wr & wr_hi & mb_din[8];

   // Set by the transmit and receive engines below.
   wire tx_take;
   wire rx_fill_a, rx_fill_b;

   // The two resets are not the same reset, and the difference is the manual's
   // own wording.  MultiBus INIT clears the whole register, because NetBSD's
   // ec_match() is literally `peek_2(csr) == 0' and a card that powers up with
   // anything at all in there does not attach.  The RESET *bit* "merely gives
   // the memory buffers back to the Multibus (resetting TBSW, ABSW, and
   // BBSW)" -- merely -- so it leaves the enables and PA to the write that
   // carried it, which is what ECSET(EC_RESET) means by preserving EC_INTPA.
   //
   // No live caller depends on that: the kernel's one ECSET(EC_RESET) is
   // inside `#ifdef notdef' and both drivers' other resets are bare writes
   // whose low byte is zero anyway.  It is implemented the manual's way
   // regardless, because the alternative is a difference that would only ever
   // surface in whatever someday enables that code.
   always @(posedge CLK) begin
      if (RESET) begin
         bbsw   <= 1'b0;  absw   <= 1'b0;  tbsw <= 1'b0;
         jam    <= 1'b0;  amsw   <= 1'b0;  rbba <= 1'b0;
         binten <= 1'b0;  ainten <= 1'b0;
         tinten <= 1'b0;  jinten <= 1'b0;
         pa     <= 4'h0;
         meback <= 16'h0;
      end else begin
         // AMSW goes too, since both drivers reset and then rewrite the
         // address RAM, which the card would otherwise be ignoring.
         if (soft_reset) begin
            bbsw <= 1'b0;  absw <= 1'b0;  tbsw <= 1'b0;
            jam  <= 1'b0;  amsw <= 1'b0;  rbba <= 1'b0;
         end
         // Write-one-to-set for the ownership bits; a written zero is a no-op.
         else if (sel_csr_wr & wr_hi) begin
            if (mb_din[15]) bbsw <= 1'b1;
            if (mb_din[14]) absw <= 1'b1;
            if (mb_din[13]) tbsw <= 1'b1;
            if (mb_din[12]) jam  <= 1'b0;   // write-one-to-CLEAR
            if (mb_din[11]) amsw <= 1'b1;
         end
         // The low byte is ordinary read/write.
         if (sel_csr_wr & wr_lo) begin
            binten <= mb_din[7];
            ainten <= mb_din[6];
            tinten <= mb_din[5];
            jinten <= mb_din[4];
            pa     <= mb_din[3:0];
         end

         // MEBACK.  Accepted and ignored: this card never asserts JAM, so
         // there is never a backoff to program.  See the note on collisions
         // at the bottom of this file.
         if (sel_back_wr & wr_hi) meback[15:8] <= mb_din[15:8];
         if (sel_back_wr & wr_lo) meback[7:0]  <= mb_din[7:0];

         // The engines take and return buffers.  These lose to a host write in
         // the same cycle only for JAM, which cannot happen here.
         if (tx_take)       tbsw <= 1'b0;
         if (rx_fill_a)     absw <= 1'b0;
         if (rx_fill_b) begin
            bbsw <= 1'b0;
            // "state of ABSW at the moment B was filled" -- not "which filled
            // last".  The kernel consults it only when both buffers are full,
            // to decide which packet is older.
            rbba <= absw;
         end
      end
   end

   // Level triggered, no acknowledge, purely combinational from the register.
   // Manual 4.2: "interrupts are not edge triggered, but level triggered.  An
   // interrupt routine should not leave an interrupt enabled unless it turns
   // around the buffer that caused the interrupt."  Both drivers set an
   // ownership bit and its enable in the same 16-bit write, so this has to be
   // evaluated from the post-write state, which a continuous assignment is.
   assign int_o = (jinten & jam) | (tinten & ~tbsw)
                | (ainten & ~absw) | (binten & ~bbsw);

   // ------------------------------------------------------------------
   // Station address ROM and RAM
   // ------------------------------------------------------------------
   // Six bytes each, as three 16-bit words, big-endian: the TRB switch is off
   // (the factory setting, "most significant byte at EVEN address, e.g. UNLIKE
   // the 8086"), which is 68000 order.  Word 3 of each 8-byte block is
   // undefined on the real card and reads zero here.
   wire [1:0] addr_word = a[2:1];

   // Word index inside a 2 KiB buffer.  Every buffer is addressed the same
   // way, so this is shared rather than recomputed three times.
   wire [9:0] cpu_w = a[10:1];
   reg [47:0] aram;

   wire [15:0] arom_rd = (addr_word == 2'd0) ? STATION_ADDR[47:32]
                       : (addr_word == 2'd1) ? STATION_ADDR[31:16]
                       : (addr_word == 2'd2) ? STATION_ADDR[15:0]
                       :                       16'h0000;
   wire [15:0] aram_rd = (addr_word == 2'd0) ? aram[47:32]
                       : (addr_word == 2'd1) ? aram[31:16]
                       : (addr_word == 2'd2) ? aram[15:0]
                       :                       16'h0000;

   always @(posedge CLK) begin
      if (RESET | soft_reset) begin
         aram <= 48'h0;
      end else if (sel_aram & ~amsw) begin
         // "Software must write the station address into the RAM and give the
         // address to the controller by writing one into AMSW.  Any further
         // references to the address memory are ignored until reset."
         if (addr_word == 2'd0) begin
            if (wr_hi) aram[47:40] <= mb_din[15:8];
            if (wr_lo) aram[39:32] <= mb_din[7:0];
         end else if (addr_word == 2'd1) begin
            if (wr_hi) aram[31:24] <= mb_din[15:8];
            if (wr_lo) aram[23:16] <= mb_din[7:0];
         end else if (addr_word == 2'd2) begin
            if (wr_hi) aram[15:8]  <= mb_din[15:8];
            if (wr_lo) aram[7:0]   <= mb_din[7:0];
         end
      end
   end

   // ------------------------------------------------------------------
   // The transmit buffer
   // ------------------------------------------------------------------
   // MEXHDR is a register rather than the first word of the RAM, and that is
   // deliberate: the frame is read out by mii_tx in the *PHY's* clock domain
   // while the offset is needed by the FSM in this one.  Keeping the offset in
   // a flop lets the buffer itself be a plain simple-dual-port RAM -- one
   // write clock, one read clock -- which is the shape dp_ram already has and
   // which wish82586 already proves infers on both vendors.  A true dual-port
   // with two clocks would be legal and is exactly the sort of template a
   // synthesiser declines silently, putting two kilobytes into logic.
   //
   // Nothing ever reads the transmit buffer back: ecxmit writes it and sets
   // TBSW.  A host read returns the offset for word 0 and zero elsewhere,
   // which satisfies "will not cause a bus error, but nothing will happen".
   reg [15:0] mexhdr;
   wire [10:0] tx_byte_hi = {cpu_w, 1'b0};
   wire [10:0] tx_byte_lo = {cpu_w, 1'b1};

   wire tbuf_host_wr = sel_tbuf & ~tbsw;

   always @(posedge CLK)
     if (RESET | soft_reset) mexhdr <= 16'h0;
     else if (tbuf_host_wr & (cpu_w == 10'd0)) begin
        if (wr_hi) mexhdr[15:8] <= mb_din[15:8];
        if (wr_lo) mexhdr[7:0]  <= mb_din[7:0];
     end

   // mii_tx indexes the frame from zero; the frame starts at MEXHDR.
   wire [10:0] tx_ram_addr;
   wire [7:0]  tx_ram_data;
   wire [10:0] tx_rd_addr = mexhdr[10:0] + tx_ram_addr;

   // Two write ports would be needed for a 16-bit host write into a byte-wide
   // RAM, so the buffer is two byte-wide halves: even bytes and odd bytes.
   wire [7:0] tx_rd_e, tx_rd_o;
   reg        tx_rd_odd_q;
   always @(posedge mii_tx_clk) tx_rd_odd_q <= tx_rd_addr[0];
   assign tx_ram_data = tx_rd_odd_q ? tx_rd_o : tx_rd_e;

   dp_ram #(.WIDTH(8), .DEPTH(1024)) tbuf_e (
       .wclk(CLK), .wr_en(tbuf_host_wr & wr_hi), .wr_addr(cpu_w), .wr_data(mb_din[15:8]),
       .rclk(mii_tx_clk), .rd_addr(tx_rd_addr[10:1]), .rd_data(tx_rd_e));
   dp_ram #(.WIDTH(8), .DEPTH(1024)) tbuf_o (
       .wclk(CLK), .wr_en(tbuf_host_wr & wr_lo), .wr_addr(cpu_w), .wr_data(mb_din[7:0]),
       .rclk(mii_tx_clk), .rd_addr(tx_rd_addr[10:1]), .rd_data(tx_rd_o));

   // ------------------------------------------------------------------
   // The receive buffers
   // ------------------------------------------------------------------
   // Split the same way, so the receive writer can place a single byte at an
   // arbitrary offset without a read-modify-write and the host still gets a
   // 16-bit word in one lookup.  1024 x 8 twice per buffer, four M9K in all.
   `SUN2_RAM_BLOCK reg [7:0] abuf_e [0:1023];
   `SUN2_RAM_BLOCK reg [7:0] abuf_o [0:1023];
   `SUN2_RAM_BLOCK reg [7:0] bbuf_e [0:1023];
   `SUN2_RAM_BLOCK reg [7:0] bbuf_o [0:1023];

   // The receive writer's port, driven by the FSM below.
   reg         rxw_en;      // write strobe
   reg         rxw_b;       // 0 = buffer A, 1 = buffer B
   reg  [10:0] rxw_addr;    // byte offset within the buffer
   reg  [7:0]  rxw_data;

   wire rxw_a_e = rxw_en & ~rxw_b & ~rxw_addr[0];
   wire rxw_a_o = rxw_en & ~rxw_b &  rxw_addr[0];
   wire rxw_b_e = rxw_en &  rxw_b & ~rxw_addr[0];
   wire rxw_b_o = rxw_en &  rxw_b &  rxw_addr[0];

   reg [7:0] abuf_e_q, abuf_o_q, bbuf_e_q, bbuf_o_q;

   always @(posedge CLK) begin
      if (rxw_a_e)                        abuf_e[rxw_addr[10:1]] <= rxw_data;
      else if (sel_abuf & ~absw & wr_hi)  abuf_e[cpu_w]          <= mb_din[15:8];
      abuf_e_q <= abuf_e[rxw_a_e ? rxw_addr[10:1] : cpu_w];
   end
   always @(posedge CLK) begin
      if (rxw_a_o)                        abuf_o[rxw_addr[10:1]] <= rxw_data;
      else if (sel_abuf & ~absw & wr_lo)  abuf_o[cpu_w]          <= mb_din[7:0];
      abuf_o_q <= abuf_o[rxw_a_o ? rxw_addr[10:1] : cpu_w];
   end
   always @(posedge CLK) begin
      if (rxw_b_e)                        bbuf_e[rxw_addr[10:1]] <= rxw_data;
      else if (sel_bbuf & ~bbsw & wr_hi)  bbuf_e[cpu_w]          <= mb_din[15:8];
      bbuf_e_q <= bbuf_e[rxw_b_e ? rxw_addr[10:1] : cpu_w];
   end
   always @(posedge CLK) begin
      if (rxw_b_o)                        bbuf_o[rxw_addr[10:1]] <= rxw_data;
      else if (sel_bbuf & ~bbsw & wr_lo)  bbuf_o[cpu_w]          <= mb_din[7:0];
      bbuf_o_q <= bbuf_o[rxw_b_o ? rxw_addr[10:1] : cpu_w];
   end

   wire [15:0] abuf_q = {abuf_e_q, abuf_o_q};
   wire [15:0] bbuf_q = {bbuf_e_q, bbuf_o_q};
   wire [15:0] tbuf_q = (cpu_w == 10'd0) ? mexhdr : 16'h0000;

   // ------------------------------------------------------------------
   // The wire
   // ------------------------------------------------------------------
   // mii_rx, mii_tx, crc32_eth and async_fifo come from Inputs/Wish82586
   // unchanged.  None of them references wish82586_pkg or knows anything about
   // an 82586: mii_tx reads a staged frame out of a RAM through an 11-bit
   // address, which is 2048 bytes, which is exactly this card's transmit
   // buffer.  The 3C400 and the Sun card share a wire and nothing else.
   wire        rx_fifo_wr, rx_fifo_full, rx_fifo_empty;
   wire [11:0] rx_fifo_wdata, rx_fifo_rdata;
   wire        rx_fifo_rd;

   // Reset into the PHY's clock, asserted asynchronously and released
   // synchronously -- a reset shorter than one 400 ns MII period is otherwise
   // missed entirely.
   (* ASYNC_REG = "TRUE" *) reg rxr1, rxr2, txr1, txr2;
   always @(posedge mii_rx_clk or posedge RESET)
     if (RESET) begin rxr1 <= 1'b1; rxr2 <= 1'b1; end
     else       begin rxr1 <= 1'b0; rxr2 <= rxr1; end
   always @(posedge mii_tx_clk or posedge RESET)
     if (RESET) begin txr1 <= 1'b1; txr2 <= 1'b1; end
     else       begin txr1 <= 1'b0; txr2 <= txr1; end

   mii_rx #(.DATA_W(PHY_DATA_W)) u_mii_rx (
       .rx_clk(mii_rx_clk), .rst(rxr2),
       .rxd(mii_rxd), .rx_dv(mii_rx_dv), .rx_er(mii_rx_er),
       .fifo_wr_o(rx_fifo_wr), .fifo_data_o(rx_fifo_wdata),
       .fifo_full_i(rx_fifo_full),
       .active_o(), .byte_count_o());

   async_fifo #(.WIDTH(12), .DEPTH(256)) u_rx_fifo (
       .wclk(mii_rx_clk), .wrst(rxr2), .wr_en(rx_fifo_wr),
       .wr_data(rx_fifo_wdata), .wfull(rx_fifo_full),
       .rclk(CLK), .rrst(RESET), .rd_en(rx_fifo_rd),
       .rd_data(rx_fifo_rdata), .rempty(rx_fifo_empty));

   wire       tx_go_tx, tx_done_tx, tx_ok_tx;
   reg        tx_go;
   reg [15:0] tx_len;

   (* ASYNC_REG = "TRUE" *) reg go1, go2, dn1, dn2;
   always @(posedge mii_tx_clk) begin go1 <= tx_go;      go2 <= go1; end
   always @(posedge CLK)        begin dn1 <= tx_done_tx; dn2 <= dn1; end
   assign tx_go_tx = go2;

   mii_tx #(.DATA_W(PHY_DATA_W)) u_mii_tx (
       .tx_clk(mii_tx_clk), .rst(txr2),
       .go_i(tx_go_tx), .len_i(tx_len),
       .done_o(tx_done_tx), .ok_o(tx_ok_tx),
       .ncoll_o(), .xcoll_o(), .defer_o(), .no_crs_o(),
       // Plain 802.3 numbers, not 82586 policy.  min_len_i is the one that
       // matters here and it is a deliberate departure -- see the note at the
       // foot of this file.
       .retry_limit_i(4'hF), .ifs_i(8'd96), .slot_time_i(11'd512),
       .min_len_i(8'd64), .no_crc_i(1'b0),
       .ram_addr_o(tx_ram_addr), .ram_data_i(tx_ram_data),
       .txd(mii_txd), .tx_en(mii_tx_en), .tx_er(mii_tx_er),
       .crs(mii_crs), .col(mii_col));

   // ------------------------------------------------------------------
   // Transmit sequencer
   // ------------------------------------------------------------------
   // Four phase, because that is what mii_tx documents and because it is what
   // makes the crossing safe: go rises, done rises, go falls, done falls, with
   // two flops in each direction and len/offset stable for the whole exchange.
   //
   // TBSW is cleared on *any* completion, ok or not.  The manual says only a
   // RESET frees the buffer after sixteen collisions, and that is faithfully
   // unreachable here because this card never collides; what is reachable is
   // mii_tx giving up on a stuck carrier, and a machine that hangs forever
   // serves no purpose when the driver's own recovery path is
   // `#ifdef notdef'.
   localparam [1:0] T_IDLE = 2'd0, T_GO = 2'd1, T_WAIT = 2'd2;
   reg [1:0] tstate;

   // One clock, on the phase where done is first seen -- not a level, or a
   // host that set TBSW again inside the same handshake would have it taken
   // away again.
   assign tx_take = (tstate == T_GO) & dn2;

   always @(posedge CLK) begin
      if (RESET | soft_reset) begin
         tstate <= T_IDLE; tx_go <= 1'b0; tx_len <= 16'h0;
      end else case (tstate)
        T_IDLE:
          if (tbsw) begin
             // len is implicit: the frame ends at the last byte of the buffer.
             tx_len <= 16'd2048 - {5'h0, mexhdr[10:0]};
             tx_go  <= 1'b1;
             tstate <= T_GO;
          end
        T_GO:   if (dn2) begin tx_go <= 1'b0; tstate <= T_WAIT; end
        T_WAIT: if (!dn2) tstate <= T_IDLE;
        default: tstate <= T_IDLE;
      endcase
   end

   // ------------------------------------------------------------------
   // Receive sequencer
   // ------------------------------------------------------------------
   // The FIFO is show-ahead -- async_fifo assigns rd_data straight out of the
   // array indexed by the read pointer -- so a word is on rd_data whenever
   // rempty is low and rd_en simply advances past it.
   //
   // The frame is written speculatively into whichever buffer the card owns
   // and committed only at the end, once the destination address and the
   // error bits are both known.  Rejecting is then free: leave the ownership
   // bit set and the buffer is still the card's, with rubbish in it that
   // nobody will ever look at.
   //
   // mii_rx strips the FCS -- "holding the last four bytes back so the frame
   // handed on never includes it" -- but this card is specified to keep it,
   // and SunOS computes `length = doff - 2 - sizeof(ether_header) - 4' with
   // the comment `/* 4 == FCS */'.  So four bytes are appended and counted.
   // They are written rather than left stale so that a capture is
   // deterministic; nothing reads them.
   localparam [2:0] R_IDLE = 3'd0, R_DATA = 3'd1, R_FCS = 3'd2,
                    R_ST0  = 3'd3, R_ST1  = 3'd4;
   reg [2:0]  rstate;
   reg [10:0] rx_off;      // next byte offset to write
   reg [10:0] rx_n;        // payload bytes seen, FCS excluded
   reg        rx_bsel;     // 0 = A, 1 = B
   reg        rx_active;   // a buffer was available when the frame started
   reg        rx_last_b;   // round robin, so RBBA means something
   reg [47:0] rx_dst;
   reg        e_fcs, e_fr, e_ovr;
   reg [1:0]  fcs_cnt;

   // Which buffer to fill.  Alternating rather than always-A is what makes
   // RBBA -- "the state of ABSW at the moment B was filled" -- carry any
   // information at all; always-A would leave it stuck at zero and the
   // kernel's both-full ordering would silently always take the same branch.
   //
   // rx_last_b powers up SET, so the first frame after a reset goes to A.
   // Nothing in either driver requires that -- both poll the two ownership
   // bits and take whichever is ready -- but A-then-B is the order every
   // description of this card is written in, and starting on B makes every
   // trace read backwards for no gain.
   wire pick_b = bbsw & (~absw | ~rx_last_b);
   wire pick_a = absw & ~pick_b;

   wire [10:0] doff = rx_off;          // first free byte, FCS filler included
   wire rx_bcast = (rx_dst == 48'hFFFFFFFFFFFF);
   wire rx_multi = rx_dst[40];         // LSB of the first octet
   wire rx_mine  = (rx_dst == aram);
   wire rx_rg    = (rx_n < 11'd60) | (rx_n > 11'd1514);
   wire rx_anyer = rx_rg | e_fcs | e_fr;
   wire rx_ffer  = e_fcs | e_fr;

   // Manual 4.2's acceptance table, all nine modes.  Only 1 and 7 are ever
   // used -- promiscuous and normal -- but the field is four bits wide and a
   // driver is entitled to the rest.
   wire class_ok = (pa <= 4'd2) ? 1'b1
                 : (pa <= 4'd5) ? (rx_mine | rx_multi)
                 : (pa <= 4'd8) ? (rx_mine | rx_bcast)
                 :                 rx_mine;
   wire err_ok   = (pa == 4'd0 | pa == 4'd3 | pa == 4'd6) ? 1'b1
                 : (pa == 4'd1 | pa == 4'd4 | pa == 4'd7) ? ~rx_anyer
                 :                                          ~rx_ffer;
   wire rx_accept = rx_active & class_ok & err_ok & ~e_ovr;

   // Bits 14 and 12 are INVERTED: nought means "is broadcast" and "does
   // match".  That inversion is the entire content of the July 1982 addendum,
   // and since neither driver reads either bit, getting it wrong would never
   // show up in anything but a packet capture.
   wire [15:0] rx_status = {e_fcs, ~rx_bcast, rx_rg, ~rx_mine, e_fr, doff};

   // async_fifo is show-ahead -- rd_data is combinational on the read pointer
   // -- so rd_en must be the *same* cycle the word is consumed, not a
   // registered one clock later, which would read every word twice.
   assign rx_fifo_rd = ~rx_fifo_empty &
                       (((rstate == R_IDLE) & rx_fifo_rdata[11]) |
                         (rstate == R_DATA));

   assign rx_fill_a = (rstate == R_ST1) & rx_accept & ~rx_bsel;
   assign rx_fill_b = (rstate == R_ST1) & rx_accept &  rx_bsel;

   always @(posedge CLK) begin
      rxw_en <= 1'b0;

      if (RESET | soft_reset) begin
         rstate <= R_IDLE; rx_active <= 1'b0; rx_last_b <= 1'b1;
         rx_off <= 11'd2;  rx_n <= 11'd0;
         e_fcs  <= 1'b0;   e_fr <= 1'b0;  e_ovr <= 1'b0;
      end else case (rstate)

        R_IDLE:
          if (!rx_fifo_empty) begin
             if (rx_fifo_rdata[11]) begin
                ;                            // a stray end word; drop it
             end else begin
                rx_bsel   <= pick_b;
                rx_active <= pick_a | pick_b;
                rx_off    <= 11'd2;
                rx_n      <= 11'd0;
                e_fcs     <= 1'b0; e_fr <= 1'b0; e_ovr <= 1'b0;
                rx_dst    <= 48'h0;
                rstate    <= R_DATA;
             end
          end

        R_DATA:
          if (!rx_fifo_empty) begin
             if (rx_fifo_rdata[11]) begin
                e_fcs   <= rx_fifo_rdata[10];
                e_fr    <= rx_fifo_rdata[9];
                e_ovr   <= rx_fifo_rdata[8];
                fcs_cnt <= 2'd0;
                rstate  <= R_FCS;
             end else begin
                // 2046 is the largest first-free-byte offset SunOS accepts;
                // past it the frame is over length and will be rejected, so
                // stop writing rather than wrap into the status word.
                if (rx_active & (rx_off < 11'd2046)) begin
                   rxw_en   <= 1'b1;
                   rxw_b    <= rx_bsel;
                   rxw_addr <= rx_off;
                   rxw_data <= rx_fifo_rdata[7:0];
                end
                // Saturate rather than wrap.  doff is eleven bits and so is
                // this counter, so an over-length frame would otherwise come
                // back round to a small offset and look like a short valid
                // one -- and under PA 0, which accepts errors, it would be
                // handed to the driver that way.  2047 is outside the (2,2046]
                // bound SunOS calls garbled, which is the right answer.
                if (rx_off < 11'd2047) rx_off <= rx_off + 11'd1;
                if (rx_n   < 11'd2047) rx_n   <= rx_n   + 11'd1;
                if (rx_n < 11'd6) rx_dst <= {rx_dst[39:0], rx_fifo_rdata[7:0]};
             end
          end

        R_FCS: begin
           if (rx_active & (rx_off < 11'd2046)) begin
              rxw_en   <= 1'b1;
              rxw_b    <= rx_bsel;
              rxw_addr <= rx_off;
              rxw_data <= 8'h00;
           end
           if (rx_off < 11'd2047) rx_off <= rx_off + 11'd1;
           fcs_cnt <= fcs_cnt + 2'd1;
           if (fcs_cnt == 2'd3) rstate <= R_ST0;
        end

        // The status word goes in before the ownership bit is released: the
        // host polls the bit and then reads the word, so the other order is a
        // race it would lose exactly as often as the bus is quick.
        R_ST0: begin
           if (rx_active) begin
              rxw_en   <= 1'b1;
              rxw_b    <= rx_bsel;
              rxw_addr <= 11'd0;
              rxw_data <= rx_status[15:8];
           end
           rstate <= R_ST1;
        end

        R_ST1: begin
           if (rx_active) begin
              rxw_en   <= 1'b1;
              rxw_b    <= rx_bsel;
              rxw_addr <= 11'd1;
              rxw_data <= rx_status[7:0];
           end
           if (rx_accept) rx_last_b <= rx_bsel;
           rstate <= R_IDLE;
        end

        default: rstate <= R_IDLE;
      endcase
   end

   // ------------------------------------------------------------------
   // Two deliberate departures from the 1982 card, both recorded rather than
   // hidden, and both consequences of the link this thing actually runs on.
   //
   // **JAM is never asserted.**  The DECA's PHY links 10 Mb/s full duplex, so
   // mii_col cannot assert and a collision cannot happen.  MEBACK is accepted
   // and ignored, EC_JAM reads zero for ever, and the drivers' backoff paths --
   // SunOS's ecdocoll(), its `ec%d: ethernet jammed' message, the PROM's mask
   // shifting in ecxmit() -- are unreachable.  That is the truthful behaviour
   // for this link rather than a simplification.
   //
   // **Minimum-length frames are padded.**  The manual is explicit that this
   // is the driver's job and the card sends exactly 2048-MEXHDR bytes; the
   // boot PROM, unlike the kernel, does not clamp to ECMAXTDOFF and asks for a
   // 58-byte ND request, 62 on the wire.  A real 3C400 put the runt on coax
   // and the ND server took it.  A modern switch drops it, so mii_tx's
   // min_len_i is 64 and the machine can actually boot.
   // ------------------------------------------------------------------

   // ------------------------------------------------------------------
   // The read mux
   // ------------------------------------------------------------------
   // Everything in the 8 KiB answers, including a buffer the card owns, which
   // returns whatever is in the RAM.  That is not politeness: ecprobe peeks
   // ec_bbuf[2046] with BBSW set, so a card-owned buffer that bus-errored
   // would fail the kernel's probe.  There is no fall-through to 16'hDEAD
   // here for the same reason -- sel_* covers the whole window by
   // construction, since hit compares only the seven bits above it.
   assign mb_dout = sel_ctl  ? csr_rd     // MEBACK is write-only; +2 reads MECSR
                  : sel_arom ? arom_rd
                  : sel_aram ? aram_rd
                  : sel_tbuf ? tbuf_q
                  : sel_abuf ? abuf_q
                  :            bbuf_q;

endmodule
