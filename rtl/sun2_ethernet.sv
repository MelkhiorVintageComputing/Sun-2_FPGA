`timescale 1ns / 1ps

//
// The Sun-2's on-board Ethernet: an Intel 82586 that reaches memory by DVMA.
//
// Three pieces, matching schematic sheet A07:
//
//   * the controller itself (Inputs/Wish82586), standing in for U700;
//   * sun2_dvma, standing in for the address latches U702/U703/U704, the
//     byte-reversing data buffers U707/U708, the E.ERR latch U719 and the
//     arbiter's share of the U214/U215 PALs on sheet A02;
//   * the control register, which lives in sun2_fpga because it is a device in
//     I/O page 0xFE1 and belongs with the rest of the device decode.  Its four
//     writable bits arrive here as ports.
//
// VME machines only.  A MultiBus 2/120 has no on-board Ethernet -- its
// equivalent I/O page is an 80287 socket -- and instantiating this for one
// would be wrong hardware.
//
// The scp_addr_i tie-off is not a simplification: the real part has 0xFFFFF6
// wired into it and a Sun-2 has no way to move it.  The boot PROM copes by
// temporarily re-pointing the page map entry for 0xFFF800 at the page holding
// its own SCP, letting the chip fetch it, and putting the mapping back --
// which works precisely because the fetch goes through the MMU like everything
// else.
//
module sun2_ethernet #(
    parameter int PHY_DATA_W = 4   // 4 = MII.  GMII (8) is for the real board.
) (
    input  wire        CLK,          // the CPU bus clock; the MAC lives here too,
    input  wire        RESET,        // so there is no clock crossing on the bus side

    // From the control register in sun2_fpga (rtl/sun2_ether_ctl.v)
    input  wire        core_reset_n, // 0 => hold the MAC in reset
    input  wire        loopback_n,   // 0 => transceiver isolated
    input  wire        ca,           // channel attention, a level
    input  wire        int_en,
    output wire        int_o,        // to the level 3 interrupt
    output wire        bus_err_o,    // the E.ERR bit, latched until reset
    output wire        crs_stuck_o,  // carrier has been asserted implausibly long

    // Arbitration and the CPU bus, muxed in top_fpga
    input  wire        EN_DVMA,
    output wire        P_BR_n,
    input  wire        P_BG_n,
    input  wire        BUS_EN,
    input  wire        cpu_as_n,

    output wire        dvma_active,
    output wire [23:1] dvma_a,
    output wire [2:0]  dvma_fc,
    output wire        dvma_as_n,
    output wire        dvma_rw_n,
    output wire        dvma_uds_n,
    output wire        dvma_lds_n,
    output wire [15:0] dvma_dout,
    input  wire [15:0] dvma_din,
    input  wire        P_DTACK_n,
    input  wire        P_BERR_n,

    // MII.  Nothing on the Wukong is wired to this yet; in simulation it goes
    // to tb/mii_peer.sv.
    input  wire                  mii_tx_clk,
    output wire [PHY_DATA_W-1:0] mii_txd,
    output wire                  mii_tx_en,
    output wire                  mii_tx_er,
    input  wire                  mii_rx_clk,
    input  wire [PHY_DATA_W-1:0] mii_rxd,
    input  wire                  mii_rx_dv,
    input  wire                  mii_rx_er,
    input  wire                  mii_crs,
    input  wire                  mii_col
);

   // Channel attention is a level in the control register and a one-cycle
   // pulse at the MAC: the real 82586 latches the rising edge of the pin, and
   // the driver's ieca() sets the bit and clears it again.
   reg  ca_d;
   wire ca_pulse = ca & ~ca_d;
   always @(posedge CLK)
     if (RESET) ca_d <= 1'b0;
     else       ca_d <= ca;

   //
   // Carrier sense and collision, synchronised.
   //
   // IEEE 802.3 clause 22.2.2.11/12 defines CRS and COL as asynchronous to
   // both MII clocks -- the PHY is free to move them whenever it likes -- and
   // the MAC consumes them directly in transmit FSM next-state terms and in
   // its CRC enable.  Two flops in the transmit clock domain is the standard
   // answer, and it belongs here rather than in the MAC because this is the
   // module that owns the pins.
   //
   // This matters more than it looks on this board.  R59 pulls CRS *up*, so
   // any moment the PHY is not actively driving it low -- during its own
   // reset, with no link, or depending on how it behaves in full duplex --
   // the line reads as "carrier present".  The MAC's T_DEFER state reloads
   // its interframe counter for as long as carrier is asserted, with no
   // timeout, so a high CRS means the transmit never completes, the command
   // unit waits forever, and the boot PROM's `while (!cb->ie_done)` never
   // returns.  No message, no bus error, no LED: the machine simply stops.
   //
   // Synchronising removes the metastability half of that.  The missing
   // timeout is a Wish82586 matter and is still worth fixing there.
   //
   // Tying mii_tx_clk to a constant, as a board with no PHY does, leaves these
   // registers unclocked and reading zero -- which is the safe direction: no
   // carrier, so nothing defers.
   (* ASYNC_REG = "TRUE" *) reg crs_s1, crs_s2, col_s1, col_s2;
   always @(posedge mii_tx_clk or posedge RESET)
     if (RESET) begin
        crs_s1 <= 1'b0; crs_s2 <= 1'b0;
        col_s1 <= 1'b0; col_s2 <= 1'b0;
     end else begin
        crs_s1 <= mii_crs; crs_s2 <= crs_s1;
        col_s1 <= mii_col; col_s2 <= col_s1;
     end

   // How long carrier has been continuously asserted, for the diagnostic
   // register: a PHY that never lets go is the failure this cannot otherwise
   // report, and on a board that cannot be probed it is worth a counter.
   reg [15:0] crs_stuck_ctr;
   always @(posedge mii_tx_clk or posedge RESET)
     if (RESET)          crs_stuck_ctr <= 16'h0;
     else if (~crs_s2)   crs_stuck_ctr <= 16'h0;
     else if (~&crs_stuck_ctr) crs_stuck_ctr <= crs_stuck_ctr + 16'h1;

   // Saturated is ~26 ms of transmit clock at 10 Mb/s -- orders of magnitude
   // longer than any legitimate deferral.
   assign crs_stuck_o = &crs_stuck_ctr;

   wire        wbm_cyc, wbm_stb, wbm_we, wbm_ack, wbm_err;
   wire [3:0]  wbm_sel;
   wire [29:0] wbm_adr;
   wire [31:0] wbm_dat_w, wbm_dat_r;

   wish82586 #(.PHY_DATA_W(PHY_DATA_W)) mac (
       .clk(CLK),
       .rst(RESET),
       .core_rst_i(~core_reset_n),
       .ca_i(ca_pulse),
       // The part's hard-wired System Configuration Pointer address.
       .scp_addr_i(32'h00ff_fff6),
       .cus_o(),
       .rus_o(),
       .busy_o(),
       .int_o(int_o),
       // bus_err_o is a one-cycle pulse per errored access; the latching that
       // the Sun-2's ERR bit needs happens in sun2_dvma, which sees P_BERR_n
       // directly and also has to stop requesting.
       .bus_err_o(),

       .wbm_cyc_o(wbm_cyc),
       .wbm_stb_o(wbm_stb),
       .wbm_we_o(wbm_we),
       .wbm_sel_o(wbm_sel),
       .wbm_adr_o(wbm_adr),
       .wbm_dat_o(wbm_dat_w),
       .wbm_dat_i(wbm_dat_r),
       .wbm_ack_i(wbm_ack),
       .wbm_err_i(wbm_err),

       .mii_tx_clk(mii_tx_clk),
       .mii_txd(mii_txd),
       .mii_tx_en(mii_tx_en),
       .mii_tx_er(mii_tx_er),
       .mii_rx_clk(mii_rx_clk),
       .mii_rxd(mii_rxd),
       .mii_rx_dv(mii_rx_dv),
       .mii_rx_er(mii_rx_er),
       .mii_crs(crs_s2),
       .mii_col(col_s2)
   );

   // The master drives 22 meaningful address bits -- the 24-bit byte space the
   // 82586 can reach -- and ties the rest low.
   sun2_dvma dvma (
       .CLK(CLK),
       .RESET(RESET),

       .wb_cyc_i(wbm_cyc),
       .wb_stb_i(wbm_stb),
       .wb_we_i(wbm_we),
       .wb_sel_i(wbm_sel),
       .wb_adr_i(wbm_adr[21:0]),
       .wb_dat_i(wbm_dat_w),
       .wb_dat_o(wbm_dat_r),
       .wb_ack_o(wbm_ack),
       .wb_err_o(wbm_err),

       .EN_DVMA(EN_DVMA),
       .P_BR_n(P_BR_n),
       .P_BG_n(P_BG_n),
       .BUS_EN(BUS_EN),
       .cpu_as_n(cpu_as_n),

       .dvma_active(dvma_active),
       .dvma_a(dvma_a),
       .dvma_fc(dvma_fc),
       .dvma_as_n(dvma_as_n),
       .dvma_rw_n(dvma_rw_n),
       .dvma_uds_n(dvma_uds_n),
       .dvma_lds_n(dvma_lds_n),
       .dvma_dout(dvma_dout),
       .dvma_din(dvma_din),
       .P_DTACK_n(P_DTACK_n),
       .P_BERR_n(P_BERR_n),

       .ether_reset(~core_reset_n),
       .dvma_err(bus_err_o)
   );

   // loopback_n and int_en are the transceiver isolation and the interrupt
   // gate.  int_en is already applied by sun2_ether_ctl (irq_o = inten & int),
   // and loopback_n would drive the PHY: the driver keeps the interface
   // isolated across configuration and only goes on air afterwards.  With no
   // PHY attached there is nothing to drive, so both are read here only to
   // keep them from looking accidentally forgotten.
   wire _unused = &{1'b0, loopback_n, int_en, 1'b0};

endmodule
