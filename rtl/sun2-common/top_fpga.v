`timescale 1ns / 1ps

`include "sun2_config.vh"

module top(input         cpu_clk,
	   input 	 clk40,
	   input 	 clk4m9152,
	   input 	 sys_reset,
	   /* serial */
	   output 	 tx,
	   input 	 rx,

	   /* debug */
	   output [7:0]  diag_leds,
	   output 	 en_boot,
	   output [7:0]  todebug,
`ifdef SUN2_ILA
	   output [101:0] dbg_bus,
`endif

	   /* Ethernet diagnostics, for the board top to surface: a PHY that
	    holds carrier sense asserted stops transmission dead, and it is the
	    one failure the machine cannot otherwise report. */
	   output 	 eth_crs_stuck,

	   /* The 2/50 frame buffer's display enable, for the board's scan-out */
	   output 	 fb_video_en,

	   /* What the board's PHY management found out, on its way to the
	    status register in device page 0xFE7.  A Sun-2 has no PHY, so
	    nothing below this level generates these; a testbench with no board
	    layer ties them off. */
	   input [15:0]  phy_id,
	   input 	 phy_present,
	   input 	 phy_cfg_done,
	   input 	 phy_link,
	   input 	 phy_fd,
	   input [1:0] 	 phy_speed,

	   /* MII, for the on-board Ethernet of a VME machine.  Nothing on the
	    Wukong drives these yet; in simulation they go to tb/mii_peer.sv. */
	   input 	 mii_tx_clk,
	   output [3:0]  mii_txd,
	   output 	 mii_tx_en,
	   output 	 mii_tx_er,
	   input 	 mii_rx_clk,
	   input [3:0] 	 mii_rxd,
	   input 	 mii_rx_dv,
	   input 	 mii_rx_er,
	   input 	 mii_crs,
	   input 	 mii_col,

	   /* The block back end the Xylogics 450 keeps its sectors on.  Brought
	    out here for the same reason the MII pins are: what sits on the far
	    end is an SD card on the board and a file-backed model in
	    simulation, and the machine does not care which.  The contract is
	    Inputs/Wish5380/doc/block.md.  Tied off when no card is fitted. */
	   output 	 blk_start,
	   output 	 blk_we,
	   output [31:0] blk_lba,
	   output [7:0]  blk_buf_rdata,
	   input 	 blk_done,
	   input 	 blk_err,
	   input 	 blk_ready,
	   input [31:0]  blk_count,
	   input 	 blk_buf_we,
	   input [8:0] 	 blk_buf_addr,
	   input [7:0] 	 blk_buf_wdata,

	   /* wishbone */
	   output 	 wb_cyc_o,
	   output 	 wb_stb_o,
	   output [29:0] wb_adr_o,
	   output [31:0] wb_dat_o,
	   output [3:0]  wb_sel_o,
	   output 	 wb_we_o,
	   input [31:0]  wb_dat_i,
	   input 	 wb_ack_i
	   );
   wire C100;
   wire P_VPA_n;
   wire P_BERR_n;
   wire P_DTACK_n;
   wire P_BR_n;
   wire P_BGACK_n;

   wire P_RESET_n;
   wire P_HALT_n;

   wire        RESET_INn;
   wire        HALT_INn;
   wire        RESET_OUT;
   wire        HALT_OUTn;   // the watchdog reads it -- see below

   //
   // The watchdog.  Architecture Manual 4.6.1: the board has "a watchdog
   // circuit which generates a signal equivalent to power-on reset (POR)
   // whenever the 68010 halts with a double bus fault", and the Engineering
   // Manual 3.7.1 describes the mechanism -- the CPU drives HALT low and PAL
   // A102 "automatically generates processor reset to continue processing".
   // Both cores present that pin here as HALT_OUTn, so this works either way.
   //
   // It is not a power-on reset, though, whatever 4.6.1 says about how it
   // looks to the CPU: por_reset in sun2_fpga.v stays deasserted through it,
   // which is what lets the monitor tell a watchdog from a power-up by reading
   // the Am9513 back (trap.s:117).  That test only means anything because the
   // timer survives every reset a running machine can cause.
   //
   reg [7:0] dog_ctr = 8'h00;
   reg 	     dog_reset = 1'b0;
   always @(posedge C100)
     begin
	if (sys_reset)
	  begin
	     dog_ctr   <= 8'h00;
	     dog_reset <= 1'b0;
	  end
	else if (~HALT_OUTn & ~dog_reset)
	  begin
	     dog_reset <= 1'b1;
	     dog_ctr   <= 8'hFF;
	  end
	else if (dog_reset)
	  begin
	     dog_ctr <= dog_ctr - 8'd1;
	     if (dog_ctr == 8'h01) dog_reset <= 1'b0;
	  end
     end

   // What the machine sees: the board reset, or the watchdog.
   wire machine_reset = sys_reset | dog_reset;

   assign RESET_INn = ~machine_reset; /* board or watchdog reset => reset CPU */

   //
   // P.RESET- on the schematic, and P2.INIT- on the same wire: the peripheral
   // reset net, driven by the board reset *and* by the CPU's own RESET
   // instruction.  Sheet 1 takes it from the 68010's RESET pin through PAL
   // A102 pin 12, and it reaches the Ethernet control register, the video
   // control register, the VME SYSRESET driver, the VME rerun PAL and the P2
   // connector -- Architecture Manual 4.6.1: "When the 68010 executes a reset
   // instruction, it resets all on-board and off-board I/O devices that offer
   // an external reset function.  No other devices are affected."
   //
   // What it must not reach is as load-bearing as what it does: not the system
   // enable register or the diagnostic register (4.6.1 again -- "Devices of
   // the CPU layer ... are not affected by 68010 Reset"), not the bus error
   // register, not the contexts or the maps, and above all not the SCCs, which
   // have no reset on a 2/50 at all.  SunOS declines to execute the
   // instruction for exactly that fear -- sun2/locore.s:144, "We should reset
   // the world here, but it screws the UART settings".
   //
   assign P_RESET_n = ~machine_reset & ~RESET_OUT;

   // HALT_INn is the input, and stays on the board reset alone: a CPU
   // executing its own RESET instruction must keep running.
   assign HALT_INn = ~machine_reset;

   
   wire P_AS_n;
   wire P_RW_n;
   wire P_UDS_n;
   wire P_LDS_n;
   wire P_BG_n;
   wire BUS_EN;
   
   wire        IPL2_n;
   wire IPL1_n;
   wire IPL0_n;
   
   wire [2:0] P_FC;
   
   wire [23:1] P_A;
   wire [15:0] P_DIN;
   wire [15:0] P_DOUT;
   wire        DATA_EN;
   wire [31:0] ADR_OUT;

   // The CPU's own bus outputs, before the DVMA mux below.
   wire [2:0]  cpu_fc;
   wire        cpu_as_n, cpu_rw_n, cpu_uds_n, cpu_lds_n;
   wire [15:0] cpu_dout;

   // The alternate master's, and the Ethernet control register's signals.
   wire        EN_DVMA, dvma_active, dvma_as_n, dvma_rw_n, dvma_uds_n, dvma_lds_n;
   wire [23:1] dvma_a;
   wire [2:0]  dvma_fc;
   wire [15:0] dvma_dout;
   wire        ether_core_reset_n, ether_loopback_n, ether_ca, ether_int_en;
   wire        ether_int, ether_bus_err;

   // The MultiBus system bus, and whatever is plugged into it.
   wire        mb_sel, mb_we, mb_uds_n, mb_lds_n, mb_hit, mb_ack;
   wire [19:0] mb_addr;
   wire [15:0] mb_cpu_dout;    // CPU -> card
   wire [15:0] mb_card_dout;   // card -> CPU
   wire        mb_ether_int;

   // MultiBus I/O space, a separate set of wires because it is a separate
   // address space -- see the port comment in sun2_fpga.v.
   wire        mbio_sel, mbio_we, mbio_uds_n, mbio_lds_n, mbio_hit, mbio_ack;
   wire [15:0] mbio_addr;
   wire [15:0] mbio_cpu_dout;  // CPU -> card
   wire [15:0] mbio_card_dout; // card -> CPU
   wire        mbio_int;
   
   
   sun2_fpga sun2(.cpu_clk(cpu_clk),
		  .clk40(clk40),
		  .C100(C100),
		  .clk4m9152(clk4m9152),
		  .sys_reset(machine_reset),
		  .P_VPA_n(P_VPA_n),
		  .P_BERR_n(P_BERR_n),
		  .P_DTACK_n(P_DTACK_n),
		  
  		  .P_RESET_n(P_RESET_n),
		  .P_HALT_n(P_HALT_n),
		  
		  .P_AS_n(P_AS_n),
		  .P_RW_n(P_RW_n),
		  .P_UDS_n(P_UDS_n),
		  .P_LDS_n(P_LDS_n),
		  .P_BG_n(P_BG_n),
		  .DATA_EN(DATA_EN),
		  
		  .IPL2_n(IPL2_n),
		  .IPL1_n(IPL1_n),
		  .IPL0_n(IPL0_n),
		  
		  .P_FC(P_FC),
		  
		  .P_A(P_A),
		  
		  .P_DIN(P_DIN),
		  .P_DOUT(P_DOUT),
		  .BUS_EN(BUS_EN),

		  .tx(tx),
		  .rx(rx),

		  .EN_DVMA_o(EN_DVMA),
		  .ether_core_reset_n(ether_core_reset_n),
		  .ether_loopback_n(ether_loopback_n),
		  .ether_ca(ether_ca),
		  .ether_int_en(ether_int_en),
		  .ether_int(ether_int),
		  .ether_bus_err(ether_bus_err),
		  .phy_id(phy_id),
		  .phy_present(phy_present),
		  .phy_cfg_done(phy_cfg_done),
		  .phy_link(phy_link),
		  .phy_fd(phy_fd),
		  .phy_speed(phy_speed),
		  .phy_crs_stuck(eth_crs_stuck),
		  .fb_video_en_o(fb_video_en),
		  .mb_sel(mb_sel),
		  .mb_addr(mb_addr),
		  .mb_we(mb_we),
		  .mb_uds_n(mb_uds_n),
		  .mb_lds_n(mb_lds_n),
		  .mb_dout(mb_cpu_dout),
		  .mb_din(mb_card_dout),
		  .mb_hit(mb_hit),
		  .mb_ack(mb_ack),
		  .mbio_sel(mbio_sel),
		  .mbio_addr(mbio_addr),
		  .mbio_we(mbio_we),
		  .mbio_uds_n(mbio_uds_n),
		  .mbio_lds_n(mbio_lds_n),
		  .mbio_dout(mbio_cpu_dout),
		  .mbio_din(mbio_card_dout),
		  .mbio_hit(mbio_hit),
		  .mbio_ack(mbio_ack),
		  .mbio_int(mbio_int),

		  .diag_leds(diag_leds),
		  .en_boot(en_boot),
		  .todebug(todebug),
		  //.todebug(),
`ifdef SUN2_ILA
		  .dbg_bus(dbg_bus),
		  // The one thing sun2_fpga cannot see about its own bus.
		  .dbg_dvma_active(dvma_active),
`endif
				
		  // wishbone
		  .wb_cyc_o(wb_cyc_o),
		  .wb_stb_o(wb_stb_o),
		  .wb_adr_o(wb_adr_o),
		  .wb_dat_o(wb_dat_o),
		  .wb_sel_o(wb_sel_o),
		  .wb_we_o(wb_we_o),
		  .wb_dat_i(wb_dat_i),
		  .wb_ack_i(wb_ack_i)
		  );
   


   //
   // The bus mux: CPU, or the alternate master doing DVMA.
   //
   // Everything downstream of these wires -- the MMU, the protection check, the
   // bus timing chain, DTACK, the bus error register, every device decode --
   // is shared, which is exactly how the real machine works.  Schematic sheet
   // A03 and Architecture Manual section 7: DVMA cycles are translated and
   // protected identically to CPU cycles, so a DVMA cycle is a supervisor-data
   // CPU cycle as far as anything past this point can tell.
   //
   // dvma_active is only ever asserted after the CPU core has granted the bus
   // *and* dropped BUS_EN, so the two never drive together.
   //
   assign P_A     = dvma_active ? dvma_a     : ADR_OUT[23:1];
   assign P_FC    = dvma_active ? dvma_fc    : cpu_fc;
   assign P_AS_n  = dvma_active ? dvma_as_n  : cpu_as_n;
   assign P_RW_n  = dvma_active ? dvma_rw_n  : cpu_rw_n;
   assign P_UDS_n = dvma_active ? dvma_uds_n : cpu_uds_n;
   assign P_LDS_n = dvma_active ? dvma_lds_n : cpu_lds_n;
   assign P_DIN   = dvma_active ? dvma_dout  : cpu_dout;

   // Two-wire arbitration, as on the 2/50: BGACK is tied high and a master
   // holds BR for as long as it wants the bus.  MC68000UM section 5.2 requires
   // BGACK pulled high for this, and the core's arbiter handles it -- Suska in
   // its GRANT state.  Deliberate, not a stub.
   assign P_BGACK_n = 1'b1;

   wire        P_RMC_n; // unused
   wire [31:0] PC;
   
   //
   // The CPU.  Two cores build this machine and `SUN2_CPU_RD68011' picks
   // which; everything downstream of the wires below is the same either way.
   //
   // Suska (Inputs/Suska_Configware/68K10) is VHDL, and is the core every
   // measured fingerprint in this project was taken against.  RD68011
   // (Inputs/RD68011) is a SystemVerilog MC68010 written alongside it.  They
   // are wired here as alternatives rather than through a wrapper because
   // their pin conventions genuinely differ -- see below -- and reconciling
   // that in the file that owns the wiring keeps it visible.  Neither core is
   // allowed to change the machine: what one of them does that the other does
   // not is an observation about the cores.
   //
`ifdef SUN2_CPU_RD68011
   //
   // RD68011 splits every three-state pin into _i / _o / _oe (doc/pinout.md),
   // where Suska has DATA_EN and a single BUS_EN covering "ADR, ASn, UDSn,
   // LDSn, RWn, RMCn and FC".  The group enables are asserted and released
   // together, so the address enable stands for all of them.
   //
   // VPA is the substantive difference.  A real 68010 has one VPA pin doing
   // two jobs -- 6800-style peripheral cycles, and autovectoring an interrupt
   // acknowledge -- and RD68011 models that pin.  Suska splits it into VPAn
   // and AVECn, which is why the branch below has to put the Sun-2's VPA on
   // AVECn and tie VPAn high.  Here there is nothing to split: the Sun-2
   // asserts VPA for every CPU-space cycle, i.e. every IACK, and has no 6800
   // peripherals for which an E/VMA cycle would be started.
   //
   // rst_n is not an MC68010 pin at all -- it is the core's asynchronous init
   // -- and takes the board reset, the same signal Suska sees as RESET_INn.
   //
   // RMC and DBEN have no equivalent; top_fpga.v uses neither.
   //
   wire [23:1] cpu_a;
   wire        cpu_a_oe, cpu_as_oe, cpu_rw_oe, cpu_ds_oe, cpu_fc_oe;
   wire        cpu_reset_n_o, cpu_reset_n_oe, cpu_halt_n_o, cpu_halt_n_oe;
   wire        cpu_e, cpu_vma_n, cpu_vma_oe;

   rd68011_top cpu_68k10(.clk(C100),
			 .rst_n(RESET_INn), // async init; not a 68010 pin

			 .a_o(cpu_a),
			 .a_oe(cpu_a_oe),

			 .d_i(P_DOUT),      // IN for CPU, OUT for sun2
			 .d_o(cpu_dout),
			 .d_oe(DATA_EN),

			 .as_n_o(cpu_as_n),
			 .as_oe(cpu_as_oe),
			 .rw_o(cpu_rw_n),   // high = read, as RWn
			 .rw_oe(cpu_rw_oe),
			 .uds_n_o(cpu_uds_n),
			 .lds_n_o(cpu_lds_n),
			 .ds_oe(cpu_ds_oe),
			 .dtack_n_i(P_DTACK_n),

			 .br_n_i(P_BR_n),
			 .bg_n_o(P_BG_n),
			 .bgack_n_i(P_BGACK_n),

			 .ipl_n_i({IPL2_n, IPL1_n, IPL0_n}),

			 .berr_n_i(P_BERR_n),
			 .reset_n_i(RESET_INn),
			 .reset_n_o(cpu_reset_n_o),
			 .reset_n_oe(cpu_reset_n_oe),
			 .halt_n_i(HALT_INn),
			 .halt_n_o(cpu_halt_n_o),
			 .halt_n_oe(cpu_halt_n_oe),

			 // the one real pin doing both of Suska's jobs
			 .e_o(cpu_e),
			 .vpa_n_i(P_VPA_n),
			 .vma_n_o(cpu_vma_n),
			 .vma_oe(cpu_vma_oe),

			 .fc_o(cpu_fc),
			 .fc_oe(cpu_fc_oe)
			 );

   // The DVMA mux above takes the 32-bit address Suska hands over; the Sun-2
   // uses [23:1] of it either way.
   assign ADR_OUT   = {8'h00, cpu_a, 1'b0};
   assign BUS_EN    = cpu_a_oe;

   // Open drain, and the two describe it differently: RD68011 gives an _oe
   // that means "driving low", Suska a level.  RESET_OUT is active high in
   // Suska's naming, HALT_OUTn active low.  Both are unused below, as they
   // are with Suska.
   assign RESET_OUT = cpu_reset_n_oe;
   assign HALT_OUTn = ~cpu_halt_n_oe;
   assign P_RMC_n   = 1'b1;

   // Silence unused: pins the Sun-2 has nothing to do with.
   wire _unused_cpu = &{1'b0, cpu_as_oe, cpu_rw_oe, cpu_ds_oe, cpu_fc_oe,
			cpu_reset_n_o, cpu_halt_n_o,
			cpu_e, cpu_vma_n, cpu_vma_oe, 1'b0};
`else
   WF68K10_TOP suska_68k10(.CLK(C100),
			   .DATA_IN(P_DOUT), // IN for CPU, OUT for sun2
			   .BERRn(P_BERR_n),
			   .RESET_INn(RESET_INn),
			   .RESET_OUT(RESET_OUT),
			   .HALT_INn(HALT_INn),
			   .HALT_OUTn(HALT_OUTn),
			   // A real 68010 has one VPA pin doing two jobs: 6800-style
			   // peripheral cycles, and autovectoring an interrupt
			   // acknowledge.  Suska splits them, so the Sun-2's VPA --
			   // asserted for every CPU-space cycle, i.e. every IACK --
			   // belongs on AVECn, not on VPAn.
			   //
			   // Wired the other way round, as it was, AVECn stayed
			   // deasserted and the core took the interrupt vector off
			   // the data bus instead: the read mux's 16'hDEAD
			   // fall-through gave vector 0xAD, and the monitor reported
			   // "Exception 2B4" (173 * 4).  It went unnoticed because
			   // no interrupt had ever reached the CPU -- the timer's
			   // OUT pins were tied to a register nothing drove.
			   //
			   // VPAn stays deasserted: there are no 6800 peripherals on
			   // a Sun-2, and asserting it starts an E/VMA cycle.
			   .AVECn(P_VPA_n),
			   .IPLn({IPL2_n, IPL1_n, IPL0_n}),
			   .DTACKn(P_DTACK_n),
			   .VPAn(1'b1),
			   .BRn(P_BR_n),
			   .BGACKn(P_BGACK_n),
			   .K6800n(1'b1),
			   .ADR_OUT(ADR_OUT),
			   .DATA_OUT(cpu_dout), // OUT for CPU, IN for sun2
			   .DATA_EN(DATA_EN),
			   .FC_OUT(cpu_fc),
			   .ASn(cpu_as_n),
			   .RWn(cpu_rw_n),
			   .RMCn(P_RMC_n),
			   .UDSn(cpu_uds_n),
			   .LDSn(cpu_lds_n),
			    .DBENn(),
			   .BUS_EN(BUS_EN),
			    .E(),
			    .VMAn(),
			    .VMA_EN(),
			   .BGn(P_BG_n)
			   //,.PC(PC)
			   );
`endif

   //
   // DVMA bus master.  Nothing requests through it yet -- the 82586 goes in
   // next -- so dvma_active stays low and the machine behaves exactly as it did
   // before the mux above existed.
   //
`ifdef SUN2_VME
   sun2_ethernet ethernet(.CLK(C100),
			  .RESET(~P_RESET_n),   // P.RESET-: the peripheral net

			  .core_reset_n(ether_core_reset_n),
			  .loopback_n(ether_loopback_n),
			  .ca(ether_ca),
			  .int_en(ether_int_en),
			  .int_o(ether_int),
			  .bus_err_o(ether_bus_err),
			  .crs_stuck_o(eth_crs_stuck),

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
			  .dvma_din(P_DOUT),
			  .P_DTACK_n(P_DTACK_n),
			  .P_BERR_n(P_BERR_n),

			  .mii_tx_clk(mii_tx_clk),
			  .mii_txd(mii_txd),
			  .mii_tx_en(mii_tx_en),
			  .mii_tx_er(mii_tx_er),
			  .mii_rx_clk(mii_rx_clk),
			  .mii_rxd(mii_rxd),
			  .mii_rx_dv(mii_rx_dv),
			  .mii_rx_er(mii_rx_er),
			  .mii_crs(mii_crs),
			  .mii_col(mii_col)
			  );

   // A 2/50 has no card cage: nothing is plugged into the system bus, so a
   // TYPE 2 cycle takes the timeout it always did.
   assign mb_card_dout  = 16'h0;
   assign mb_hit        = 1'b0;
   assign mb_ack        = 1'b0;
   assign mb_ether_int  = 1'b0;

   // ... and no MultiBus I/O space either.  A 2/50 has TYPE 3 for the top half
   // of the VME bus instead, which is not implemented.
   assign mbio_card_dout = 16'h0;
   assign mbio_hit       = 1'b0;
   assign mbio_ack       = 1'b0;
   assign mbio_int       = 1'b0;

   // No disk on this machine either: the 2/50's Xylogics is a 451 on the VME
   // bus, which is a different card in a different space.
   assign blk_start      = 1'b0;
   assign blk_we         = 1'b0;
   assign blk_lba        = 32'h0;
   assign blk_buf_rdata  = 8'h0;
`else
   //
   // MultiBus: nothing on board.  The 2/120's device page 1 is an 80287
   // socket, so the on-board Ethernet control register does not exist and
   // sun2_fpga leaves its outputs undriven -- hence the tie-offs here, which
   // also keep the CPU/DVMA mux above folded away.  A MultiBus machine has no
   // DVMA master at all: the Ethernet card, if fitted, is a MultiBus slave
   // with its own memory and never touches this bus.
   //
   // Level 3, autovectored -- the same level the VME machine's on-board part
   // uses (SunOS: "ie0 at mbmem ? csr 0x88000 priority 3", no vector clause).
   // The boot PROM polls throughout and never enables it.
   assign ether_int     = mb_ether_int;
   assign ether_bus_err = 1'b0;

 `ifndef SUN2_XY450
   assign dvma_active   = 1'b0;
   assign dvma_a        = 23'h0;
   assign dvma_fc       = 3'h0;
   assign dvma_as_n     = 1'b1;
   assign dvma_rw_n     = 1'b1;
   assign dvma_uds_n    = 1'b1;
   assign dvma_lds_n    = 1'b1;
   assign dvma_dout     = 16'h0;
   assign P_BR_n        = 1'b1;
 `endif

 `ifdef SUN2_MB_ETHER
   //
   // The Sun-2 Ethernet board in the card cage.  See rtl/sun2-multibus/sun2_mb_ether.sv:
   // an 82586 with its own dual-ported memory and its own page map, reached
   // through two windows in MultiBus memory space.
   //
   sun2_mb_ether #(.REG_BASE(`MB_ETHER_REG_BASE),
		   .MEM_BASE(`MB_ETHER_MEM_BASE),
		   .MEM_KIB(`MB_ETHER_MEM_KIB),
		   .PHY_DATA_W(4)) mbether
     (.CLK(C100),
      .RESET(~P_RESET_n),   // P.RESET-: a card on the bus

      .mb_sel(mb_sel),
      .mb_addr(mb_addr),
      .mb_we(mb_we),
      .mb_uds_n(mb_uds_n),
      .mb_lds_n(mb_lds_n),
      .mb_din(mb_cpu_dout),
      .mb_dout(mb_card_dout),
      .mb_hit(mb_hit),
      .mb_ack(mb_ack),

      .int_o(mb_ether_int),

      .mii_tx_clk(mii_tx_clk),
      .mii_txd(mii_txd),
      .mii_tx_en(mii_tx_en),
      .mii_tx_er(mii_tx_er),
      .mii_rx_clk(mii_rx_clk),
      .mii_rxd(mii_rxd),
      .mii_rx_dv(mii_rx_dv),
      .mii_rx_er(mii_rx_er),
      .mii_crs(mii_crs),
      .mii_col(mii_col)
      );

   // The card cannot report a stuck carrier -- that flag is part of the VME
   // side's own diagnostics, and there is no device page here to read it from.
   assign eth_crs_stuck = 1'b0;
 `else
   assign eth_crs_stuck = 1'b0;
   assign mii_txd       = 4'h0;
   assign mii_tx_en     = 1'b0;
   assign mii_tx_er     = 1'b0;
   assign mb_card_dout  = 16'h0;
   assign mb_hit        = 1'b0;
   assign mb_ack        = 1'b0;
   assign mb_ether_int  = 1'b0;
 `endif

 `ifdef SUN2_XY450
   //
   // The Xylogics 450 disk controller, in MultiBus I/O space.  See
   // rtl/sun2-multibus/sun2_xy450.sv.  Only controller 0 is fitted, so the
   // PROM's probe of the second address, 0xEE48, still has to time out.
   //
   // This is the first MultiBus *master* in the design.  The card fetches its
   // command block and moves its data itself, and on a Sun-2 that means DVMA:
   // MultiBus address X is virtual 0xF00000 + X, supervisor data, through the
   // MMU.  sun2_dvma turns its Wishbone accesses into 68010 bus cycles, which
   // is the same job it does for the 2/50's on-board Ethernet -- the module is
   // compiled into both builds already and needed no change.
   //
   wire        xy_wb_cyc, xy_wb_stb, xy_wb_we, xy_wb_ack, xy_wb_err, xy_wb_clr;
   wire [3:0]  xy_wb_sel;
   wire [21:0] xy_wb_adr;
   wire [31:0] xy_wb_dat_o, xy_wb_dat_i;

   sun2_xy450 #(.IO_BASE(`XY450_IO_BASE)) xy450
     (.CLK(C100),
      .RESET(~P_RESET_n),   // P.RESET-: a card on the bus

      .mbio_sel(mbio_sel),
      .mbio_addr(mbio_addr),
      .mbio_we(mbio_we),
      .mbio_uds_n(mbio_uds_n),
      .mbio_lds_n(mbio_lds_n),
      .mbio_din(mbio_cpu_dout),
      .mbio_dout(mbio_card_dout),
      .mbio_hit(mbio_hit),
      .mbio_ack(mbio_ack),

      .int_o(mbio_int),

      .wb_cyc_o(xy_wb_cyc),
      .wb_stb_o(xy_wb_stb),
      .wb_we_o(xy_wb_we),
      .wb_sel_o(xy_wb_sel),
      .wb_adr_o(xy_wb_adr),
      .wb_dat_o(xy_wb_dat_o),
      .wb_dat_i(xy_wb_dat_i),
      .wb_ack_i(xy_wb_ack),
      .wb_err_i(xy_wb_err),
      .wb_clr_o(xy_wb_clr),

      .blk_start(blk_start),
      .blk_we(blk_we),
      .blk_lba(blk_lba),
      .blk_buf_rdata(blk_buf_rdata),
      .blk_done(blk_done),
      .blk_err(blk_err),
      .blk_ready(blk_ready),
      .blk_count(blk_count),
      .blk_buf_we(blk_buf_we),
      .blk_buf_addr(blk_buf_addr),
      .blk_buf_wdata(blk_buf_wdata)
      );

   sun2_dvma xy_dvma(.CLK(C100),
		     .RESET(machine_reset),   // machine, not a card

		     .wb_cyc_i(xy_wb_cyc),
		     .wb_stb_i(xy_wb_stb),
		     .wb_we_i(xy_wb_we),
		     .wb_sel_i(xy_wb_sel),
		     .wb_adr_i(xy_wb_adr),
		     .wb_dat_i(xy_wb_dat_o),
		     .wb_dat_o(xy_wb_dat_i),
		     .wb_ack_o(xy_wb_ack),
		     .wb_err_o(xy_wb_err),

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
		     .dvma_din(P_DOUT),
		     .P_DTACK_n(P_DTACK_n),
		     .P_BERR_n(P_BERR_n),

		     // The error latch is named for the Ethernet card it was
		     // written for.  A disk controller reports a fault in its
		     // IOPB and carries on, so the card clears it itself before
		     // every command rather than needing a reset.
		     .ether_reset(xy_wb_clr),
		     .dvma_err()
		     );
 `else
   assign mbio_card_dout = 16'h0;
   assign mbio_hit       = 1'b0;
   assign mbio_ack       = 1'b0;
   assign mbio_int       = 1'b0;

   assign blk_start      = 1'b0;
   assign blk_we         = 1'b0;
   assign blk_lba        = 32'h0;
   assign blk_buf_rdata  = 8'h0;
 `endif
`endif

   // assign todebug = PC[7:0] ;

   //`include "check.v"
   
endmodule
