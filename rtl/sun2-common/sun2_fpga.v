`timescale 1ns / 1ps

`include "sun2_config.vh"

module sun2_fpga(input         cpu_clk,
		 input 	       clk40,
		 input 	       clk4m9152,
		 output        C100,
		 input 	       sys_reset, // board reset => also CPU reset
		 output        P_VPA_n,
		 output        P_BERR_n,
		 output        P_DTACK_n,

		 input 	       P_RESET_n, // CPU reset, not full board
		 output        P_HALT_n, // checkme

		 input 	       P_AS_n,
		 input 	       P_RW_n,
		 input 	       P_UDS_n,
		 input 	       P_LDS_n,
		 input 	       P_BG_n,
		 input 	       BUS_EN,

		 output        IPL2_n,
		 output        IPL1_n,
		 output        IPL0_n,

		 input [2:0]   P_FC,
   
		 input [23:1]  P_A,

		 input [15:0]  P_DIN,
		 output [15:0] P_DOUT,
		 input 	       DATA_EN,
		 /* serial */
		 output        tx,
		 input 	       rx,
		 /* DVMA and on-board Ethernet.  The controller and its bus
		  master live in top_fpga, because that is where the CPU bus is
		  muxed; what belongs here is the control register in device
		  space and the enable bit in the system register. */
		 output        EN_DVMA_o,
		 output        ether_core_reset_n,
		 output        ether_loopback_n,
		 output        ether_ca,
		 output        ether_int_en,
		 input 	       ether_int,
		 input 	       ether_bus_err,
		 /* The board's Ethernet PHY, surfaced read-only in device page
		  0xFE7 so a machine at the monitor prompt can be asked what it
		  did.  See rtl/sun2-vme/sun2_phy_status.v.  A Sun-2 has no PHY: these
		  come from the board layer and are tied off everywhere else. */
		 input [15:0]  phy_id,
		 input 	       phy_present,
		 input 	       phy_cfg_done,
		 input 	       phy_link,
		 input 	       phy_fd,
		 input [1:0]   phy_speed,
		 input 	       phy_crs_stuck,
		 /* The 2/50 frame buffer's display enable, for the scan-out */
		 output        fb_video_en_o,
		 /* The MultiBus system bus, page-map TYPE 2.  A space, not a
		  device: this says a cycle is aimed at it and gives the bus
		  address, and whatever is plugged in answers.  With nothing
		  plugged in mb_hit stays low and the cycle takes the usual
		  timeout, which is how every one of the PROM's probes
		  discovers there is no card. */
		 output        mb_sel,
		 output [19:0] mb_addr,
		 output        mb_we,
		 output        mb_uds_n,
		 output        mb_lds_n,
		 output [15:0] mb_dout,   // CPU -> card
		 input [15:0]  mb_din,    // card -> CPU
		 input 	       mb_hit,
		 input 	       mb_ack,
		 /* The MultiBus I/O space, page-map TYPE 3.  The same contract
		  as mb_* above and a separate set of wires because it is a
		  separate address space on the real bus: a card decodes one or
		  the other, never both, and the same 16-bit number means
		  different things in each.  The monitor maps 64 KiB of it at
		  BUSIO_BASE (0xEB0000), which is where every controller's
		  registers live -- the Xylogics at 0xEE40, the Interphase at
		  0xEE48. */
		 output        mbio_sel,
		 output [15:0] mbio_addr,
		 output        mbio_we,
		 output        mbio_uds_n,
		 output        mbio_lds_n,
		 output [15:0] mbio_dout,  // CPU -> card
		 input [15:0]  mbio_din,   // card -> CPU
		 input 	       mbio_hit,
		 input 	       mbio_ack,
		 /* A MultiBus card's interrupt, jumpered to level 2 -- which is
		  where conf.sun2/XY100 puts the Xylogics 450.  Autovectored:
		  the Sun-2 does not take a vector from the bus. */
		 input 	       mbio_int,
		 /* debug */
		 output [7:0]  diag_leds,
		 output        en_boot,
		 output [7:0]  todebug,

`ifdef SUN2_ILA
		 // Everything an ILA needs to answer one question: does the
		 // page map output the protection check consumes match the
		 // entry a later FC=3 read gets back?  Packed here, threaded
		 // out the way todebug is, and sampled in the board layer --
		 // see the field map at the assignment below.
		 output [100:0] dbg_bus,
`endif
		 /* wishbone */
		 output        wb_cyc_o,
		 output        wb_stb_o,
		 output [29:0] wb_adr_o,
		 output [31:0] wb_dat_o,
		 output [3:0]  wb_sel_o,
		 output        wb_we_o,
		 input [31:0]  wb_dat_i,
		 input 	       wb_ack_i
		   );
   // 180° clock
   wire 	       C100_n;

   
   assign P_HALT_n = 1'b1; // FIXME ?

   wire CLK;
   assign CLK = C100;

   // Say which machine this was built as.  The settings that differ between
   // the two are easy to get into a combination that half works, and the
   // symptom is a bus error thousands of cycles later, so state it up front.
   initial begin
      $display("Sun-2: %s", `SUN2_MACHINE_NAME);
      $display("   device pages at %0d (0x%03x), memory space %0d KiB, installed %0d KiB, ID PROM type %0d",
               `DEV_PAGE_BASE, `DEV_PAGE_BASE, `MEM_SPACE_PAGES * 2, `MEM_PAGES * 2,
               `IDPROM_MACHINE_TYPE);
`ifdef SUN2_VME
 `ifdef SUN2_MULTIBUS
      $fatal(1, "sun2_config.vh: define SUN2_MULTIBUS or SUN2_VME, not both");
 `endif
 `ifdef ROM_FASTBOOT
      $fatal(1, "ROM_FASTBOOT is MultiBus only: there is no fastboot image for the 2/50 PROM");
 `endif
 `ifdef SUN2_MB_ETHER
      $fatal(1, "SUN2_MB_ETHER is MultiBus only: a 2/50 has its Ethernet on board, in device page 1");
 `endif
 `ifdef SUN2_XY450
      $fatal(1, "SUN2_XY450 is MultiBus only: a 2/50 takes a Xylogics 451 on the VME bus");
 `endif
`endif
`ifdef SUN2_MB_ETHER
      $display("   MultiBus Ethernet: registers at 0x%05x, %0d KiB of memory at 0x%05x",
               `MB_ETHER_REG_BASE, `MB_ETHER_MEM_KIB, `MB_ETHER_MEM_BASE);
`endif
`ifdef SUN2_XY450
      $display("   Xylogics 450: registers at MultiBus I/O 0x%04x", `XY450_IO_BASE);
      // Every boot remaps virtual 0xF00000..0xF3FFFF -- the DVMA window the
      // controller DMAs through -- onto physical page 0x180, byte 0xC0000
      // (fakemapinit2 in the monitor, and in the Rev R image at 0xEF6F04).  A
      // machine with less than a megabyte installed has nothing there, and the
      // symptom would be a disk that reads zeroes rather than an obvious fault.
      if (`MEM_PAGES < 512)
        $fatal(1, "SUN2_XY450 needs at least 1 MiB installed (MEM_PAGES >= 512, have %0d): the DVMA window lands on physical 0xC0000",
               `MEM_PAGES);
`endif
      if (`MEM_PAGES > `MEM_SPACE_PAGES)
        $fatal(1, "MEM_PAGES (%0d) exceeds MEM_SPACE_PAGES (%0d): memory is installed where nothing answers",
               `MEM_PAGES, `MEM_SPACE_PAGES);
`ifdef SUN2_FB
 `ifndef SUN2_VME
      // The 2/120's video board owns the whole eighth megabyte -- pages 0xE00
      // and up -- so installed memory has to stop below it.  The boot PROM's
      // own memory sizing does exactly this (diag.s: "Meg 7 is reserved for
      // framebuf"); this is here so a MEM_PAGES override cannot quietly put
      // RAM where MATCH_FB will answer first.
      if (`MEM_PAGES > 3584)
        $fatal(1, "MEM_PAGES (%0d) runs into the video board at page 0xE00 (3584)",
               `MEM_PAGES);
 `endif
`endif
   end

   // ------------------------------------------------------------------
   // Power-on reset, as distinct from a board reset
   // ------------------------------------------------------------------
   // A real 2/50 resets some devices and not others, and the distinction is
   // load-bearing.  The Am9513 is "not affected by power-on resets, watchdog
   // resets, or 68010 resets" (Architecture Manual 6.8), and the two Z8530s
   // have no reset at all -- the part has no reset pin, and the board cannot
   // produce the RD+WR software reset because those two strobes come from
   // separate decoders enabled by Q.R/W and Q.R/W-.  So on real hardware all
   // three come up in whatever state they powered up in and are never
   // disturbed again.  The monitor's own initialisation is what puts them
   // right, and its power-up test -- reading counter 1's mode register back
   // and comparing against CLKM_DEFAULT, trap.s:117 -- works precisely
   // because the timer survives a reset.
   //
   // An FPGA still has to start somewhere.  z8530_scc.sv has no `initial'
   // blocks and no declaration initialisers, so with no reset at all every
   // register in it is X, and several stay X for ever rather than healing:
   // the FIFO gray pointers, the soft-reset counters and the interrupt
   // latches all have else-branch guards that evaluate to X and so never
   // assign.  That puts X on RR0 bit 7 -- ZSRR0_BREAK, the bit the NMI
   // debounce masks and compares against g_debounce at 0x5B6 -- which is the
   // spurious Abort again, with the X sitting directly on the bit instead of
   // reaching it by some path nobody pinned down.
   //
   // por_reset is that one reset: asserted while the machine has never yet
   // been out of reset, and never again.  A button press, a watchdog or a
   // RESET instruction cannot re-arm it, which is what makes it a model of
   // powering the board up rather than of resetting it.  It replaces POR_n,
   // which was an `initial' block with # delays -- simulation-only, and a
   // second continuous driver on P_HALT_n besides.
   reg 	por_done = 1'b0;
   always @(posedge cpu_clk)
     if (~sys_reset) por_done <= 1'b1;
   wire por_reset = sys_reset & ~por_done;

   // layers shortcuts
   wire FC_CTRLLAYER;
   wire FC_CPUCYCLE;
   wire FC_SPROG;
   wire FC_GENERAL;
   
   assign FC_CTRLLAYER = (P_FC == 3'h3);
   assign FC_CPUCYCLE  = (P_FC == 3'h7);
   assign FC_SPROG     = (P_FC == 3'h6);
   assign FC_GENERAL   = ~FC_CTRLLAYER & ~FC_CPUCYCLE;

   assign P_VPA_n = ~(FC_CPUCYCLE);

   // Declared here rather than with the other match wires below because the
   // bus timeout logic just underneath uses MATCH_MEM, and xvlog rejects
   // use-before-declaration.
   wire 			 MATCH_MEM, MATCH_MEMX;
   // Declared up here, with MATCH_MEM, because the bus timeout below exempts
   // both and xvlog rejects a wire used before its declaration -- where Vivado
   // merely warns and invents an implicit undriven one, which builds a
   // bitstream in which the exemption quietly does nothing.  The assignments
   // stay down with the rest of the frame buffer decode.
   wire 			 MATCH_FB, MATCH_FBCTL;

   // P_AS_n timing
   reg C_S3, C_S5, C_S7, C_S9;
   always @(negedge C100)
     begin
	if (~P_AS_n)        C_S3 <= 1'b1;
	if (~P_AS_n & C_S3) C_S5 <= 1'b1;
	if (~P_AS_n & C_S5) C_S7 <= 1'b1;
	if (~P_AS_n & C_S7) C_S9 <= 1'b1;
	if ( P_AS_n)
	  begin
	     C_S3 <= 1'b0;
	     C_S5 <= 1'b0;
	     C_S7 <= 1'b0;
	     C_S9 <= 1'b0;
	  end
     end
   reg C_S4, C_S6, C_S8, C_S10, C_S12, C_S14, C_S16, C_S18, C_S20, C_S22, C_S24, TIMEOUT;
   always @(posedge C100)
     begin
	if (~P_AS_n & C_S3) C_S4 <= 1'b1;
	if (~P_AS_n & C_S4) C_S6 <= 1'b1;
	if (~P_AS_n & C_S6) C_S8 <= 1'b1;
	if (~P_AS_n & C_S8) C_S10 <= 1'b1;
	if (~P_AS_n & C_S10) C_S12 <= 1'b1;
	if (~P_AS_n & C_S12) C_S14 <= 1'b1;
	if (~P_AS_n & C_S14) C_S16 <= 1'b1;
	if (~P_AS_n & C_S16) C_S18 <= 1'b1;
	if (~P_AS_n & C_S18) C_S20 <= 1'b1;
	if (~P_AS_n & C_S20) C_S22 <= 1'b1;
	if (~P_AS_n & C_S22) C_S24 <= 1'b1;
	// Memory is exempt from the bus timeout, and so is the frame buffer,
	// for the same reason: both are answered by the Wishbone bridge out of
	// the same DDR3, and DDR3 is slower than twelve clocks.
	//
	// Measured on a board, with the ILA, on the monitor's own display
	// probe at 0xEC0000: C_S24 fires on clock 12 and DTACK arrives on
	// clock 13.  The two land on the same edge and the timeout wins by
	// one.  AS to DTACK on this machine is bimodal, 8 clocks or 13, so the
	// fast case always worked and the slow case never could -- which is
	// why the frame buffer was found in simulation, where the memory model
	// answers at once, and never on hardware.
	//
	// The consequence is the one memory already carries: an access up here
	// that is never answered hangs instead of raising a bus error.  A real
	// Sun-2's video board is local memory on the card and answers inside
	// the timeout; ours shares the CPU's DRAM, so it inherits the CPU
	// memory's exemption along with its latency.
	if (~P_AS_n & C_S24 & ~MATCH_MEM & ~MATCH_FB) TIMEOUT <= 1'b1;
	if ( P_AS_n)
	  begin
	     C_S4 <= 1'b0;
	     C_S6 <= 1'b0;
	     C_S8 <= 1'b0;
	     C_S10 <= 1'b0;
	     C_S12 <= 1'b0;
	     C_S14 <= 1'b0;
	     C_S16 <= 1'b0;
	     C_S18 <= 1'b0;
	     C_S20 <= 1'b0;
	     C_S22 <= 1'b0;
	     C_S24 <= 1'b0;
	     TIMEOUT <= 1'b0;
	  end
     end

   // match wire for the control/mmu space
   // can match early because they only depend on the P_A address
   wire 			 MATCH_CTX, MATCH_SMAP, MATCH_PMAP_PS, MATCH_PMAP_MA;
   wire 			 MATCH_IDPROM, MATCH_DIAG, MATCH_BERR, MATCH_SYSEN;

   assign MATCH_PMAP_PS = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h0); // Long, MSW
   assign MATCH_PMAP_MA = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h1); // Long, LSW
   assign MATCH_SMAP    = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h2);
   assign MATCH_CTX     = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h3);
   assign MATCH_IDPROM  = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h4);
   assign MATCH_DIAG    = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h5);
   assign MATCH_BERR    = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h6);
   assign MATCH_SYSEN   = (FC_CTRLLAYER) & (P_A[10:4] == 7'h0) & (P_A[3:1] == 3'h7);

   wire [23:0] 			 pa_forshow; // more readbable as a wave, no functional use
   // MMU & control layers
   wire [15:0] 			 ctx_out;
   wire [2:0] 			 cx_dbg;
   wire [7:0] 			 ia_smap2pmap;
   wire [11:0] 			 ma_pmap2devices;
   wire [11:0] 			 ps_pmap2devices;
   
   assign pa_forshow = {1'b0, ma_pmap2devices, P_A[10:1], 1'b0};

   wire 			 MATCH_PROM_BOOT, BOOT_n;
   assign MATCH_PROM_BOOT  = ((FC_SPROG) & (~BOOT_n)); // at boot (bit from SYSEN): all Supervisor Program are from the PROM
   assign en_boot = ~BOOT_n;

   wire 			 WR;
   assign WR = (~P_UDS_n | ~P_LDS_n) & ~P_AS_n & ~P_RW_n;
   wire 			 RD;
   assign RD = (~P_UDS_n | ~P_LDS_n) & ~P_AS_n &  P_RW_n;


   sun2_mmu mmu(.CLK(C100),
		/* matching */
		.MATCH_CTX(MATCH_CTX),
		.MATCH_SMAP(MATCH_SMAP),
		.MATCH_PMAP_PS(MATCH_PMAP_PS),
		.MATCH_PMAP_MA(MATCH_PMAP_MA),
		.WR(WR),
		.RD(RD),
		/* CPU signals */
		.P_DIN(P_DIN),
		.P_A(P_A),
		.P_FC(P_FC),
		.P_UDS_n(P_UDS_n),
		.P_LDS_n(P_LDS_n),
		/* timing signals */
		.C_S4(C_S4),
		.C_S6(C_S6),
		/* MMU outputs */
		.ctx_out(ctx_out),
		.cx_dbg(cx_dbg),
		.ia_smap2pmap(ia_smap2pmap),
		.ma_pmap2devices(ma_pmap2devices),
		.ps_pmap2devices(ps_pmap2devices)
	    );
   
   /* split the 12 protection/status bits by name.
    *
    * ps_pmap2devices[11:0] is page map entry bits 31..20 -- PMREALBITS is
    * 0xFFF00FFF (sys/mon/s2map.h:116), so those twelve and the low twelve are
    * the whole of what exists.  `struct pgmapent' in the same header gives the
    * top as a valid bit followed by the six PMP_* permissions, most
    * significant first:
    *
    *   bit 31  ps[11]  valid
    *   bit 30  ps[10]  PMP_SUP_READ      0x20
    *   bit 29  ps[ 9]  PMP_SUP_WRITE     0x10
    *   bit 28  ps[ 8]  PMP_SUP_EXECUTE   0x08
    *   bit 27  ps[ 7]  PMP_USER_READ     0x04
    *   bit 26  ps[ 6]  PMP_USER_WRITE    0x02
    *   bit 25  ps[ 5]  PMP_USER_EXECUTE  0x01
    *
    * SunOS's own constants corroborate it exactly (sys/sun2/pte.h:49-53):
    * PG_KR 0x50000000 is SUP_READ|SUP_EXECUTE -- a kernel *text* page, readable
    * and executable but not writable.  PG_KW 0x70000000 adds SUP_WRITE, and
    * PG_URKR 0x58000000 adds USER_READ.  None of them decodes sensibly if the
    * fields sit anywhere else.
    */
   wire VALID, SUP_READ, SUP_WRITE, SUP_EXEC, USR_READ, USR_WRITE, USR_EXEC, ACC, MOD;
   wire [2:0] TYPE;

   assign VALID     = ps_pmap2devices[11];
   assign SUP_READ  = ps_pmap2devices[10];
   assign SUP_WRITE = ps_pmap2devices[9];
   assign SUP_EXEC  = ps_pmap2devices[8];
   assign USR_READ  = ps_pmap2devices[7];
   assign USR_WRITE = ps_pmap2devices[6];
   assign USR_EXEC  = ps_pmap2devices[5];
   assign TYPE  = ps_pmap2devices[4:2];
   assign ACC   = ps_pmap2devices[1];
   assign MOD   = ps_pmap2devices[0];
   

   // combinatorial protection check on Page Map output, valid alongside ps_pmap2devices
   wire       PROTERR; //, PROTERR_n;
   wire       PROTERR_raw, PROTERR_raw_n;
   // UNDER TEST -- see the note in CLAUDE.md before trusting the fingerprint.
   //
   // ~P_AS_n is not redundant with C_S8.  The C_S chain only advances while AS
   // is asserted, but it is *cleared* on the posedge after AS goes high, so
   // there is a one-clock window in which AS is already released and C_S4/C_S8
   // are still set.  PROTERR is combinational on the page map, so in that
   // window it re-evaluates against whatever address and function code the CPU
   // has begun driving for its next cycle -- which is not a bus cycle at all.
   //
   // That window was manufacturing essentially every protection violation this
   // machine has ever reported.  Of the 23,629 bus errors in the MultiBus
   // reference boot, 23,607 were protection violations from just seven PROM
   // program-counter values, four of them repeating exactly 4096 times --
   // NUMPMEGS * PGSPERSEG, i.e. one per page-map write in diag.s's PMconst,
   // PMdata and PMaddr passes.  The "physical page" each reported was the test
   // pattern the PROM had just written (0x000, 0x333, 0xccc, 0xfff), not a
   // translation of anything.
   //
   // The PROM cannot be the source of real ones: it never deliberately
   // provokes a protection violation anywhere -- diag.s:41 lists protection as
   // a FIXME, not a test -- and it reads and writes the maps through FC_MAP,
   // which is untranslated.  trap.s:75-80 also records that in boot state all
   // supervisor program fetches come from PROM untranslated, so an FC=6 PROM
   // fetch cannot take a protection fault at all.  Decisively: during PMconst
   // the bus error vector is still uninitialised (monreset does not install a
   // handler until sunmon.c:310), so a real Sun-2 taking 16,448 bus errors
   // there would double-fault on the first one.  It boots only because the
   // pulse lands too late in the cycle for the core to act on.
   //
   // With this term the reference boot reports 22 bus errors -- all timeouts,
   // matching the dozen or so device probes the PROM really does make -- and
   // the console is byte-identical to the 23,629 run.
   //
   // STILL UNPROVEN: the PROM generates *zero* legitimate protection faults, so
   // a monitor boot cannot show whether this preserves real ones or disables
   // the mechanism.  SunOS needs them for copy-on-write and stack growth, and
   // that run is what has to justify this change.
   // An invalid entry must refuse every class, so VALID is a term in its own
   // right.  It used to be reachable only as D4 below, which meant a *user*
   // access to an invalid entry was not refused at all; after the shift below
   // nothing would have checked it.  mon/h/buserr.h keeps the bit in the bus
   // error register precisely so a handler can tell "not valid" from
   // "protection refused it", which only makes sense if both raise the error.
   assign PROTERR   = (PROTERR_raw | ~VALID) & C_S8 & FC_GENERAL & ~P_AS_n;
   //assign PROTERR_n = PROTERR_raw_n | ~C_S8 & FC_GENERAL;
   
   // The permission check.  Select is {P_FC[2], P_FC[1], ~P_RW_n}, so the eight
   // inputs are the eight access classes; D3 and D7 are writes to program
   // space, never permitted whatever the entry says.
   //
   // The permission check.  Select is {P_FC[2], P_FC[1], ~P_RW_n}, so the eight
   // inputs are the eight access classes; D3 and D7 are writes to program
   // space, never permitted whatever the entry says.  Y is ~mux, so a selected
   // bit of 1 means permitted and 0 raises the error.
   //
   // These six used to sit one bit high: supervisor data read was checked
   // against the valid bit, supervisor program read against SUP_WRITE, and
   // USER_EXECUTE against nothing at all.  A comment here warned not to "fix"
   // that without measuring, because shifting them down had once taken the boot
   // from ~23629 bus errors to ~28000.  That measurement was worthless -- 23607
   // of the 23629 were phantoms from the missing ~P_AS_n term above, so both
   // numbers counted artefacts and the shift only changed which artefact fired.
   //
   // With the phantoms gone the real behaviour is visible and unambiguous.
   // SunOS marks its own text PG_KR (SUP_READ|SUP_EXECUTE) in startup(), then
   // could not execute it, because we tested SUP_WRITE -- which PG_KR clears.
   // The kernel took a protection fault on its own instruction stream at
   // _start+0xf8, retried it forever, and each nested 68010 long frame walked
   // the stack down until it wrapped past zero and double-faulted.
   ttl_74F151 gen_proterr(.D0(USR_READ),   // user  data    read
			  .D1(USR_WRITE),  // user  data    write
			  .D2(USR_EXEC),   // user  program read
			  .D3(1'b0),       // user  program write -- never
			  .D4(SUP_READ),   // super data    read
			  .D5(SUP_WRITE),  // super data    write
			  .D6(SUP_EXEC),   // super program read
			  .D7(1'b0),       // super program write -- never
			  .A(~P_RW_n),
			  .B(P_FC[1]),
			  .C(P_FC[2]),
			  .Y(PROTERR_raw),
			  .W(PROTERR_raw_n),
			  .S(1'b0));

   // IDPROM, read-only
   wire [7:0] 			 idprom_out;
   idprom idprom(.CLK(CLK),
		 .idx(P_A[15:11]), // one byte per page...
		 .dout(idprom_out)
		 );

   // Diagnostic register, write-only
   wire [7:0] 			 leds;
   gen8bit_reg diag(.CLK(CLK),
		    .din(P_DIN[7:0]),
		    .WR(WR & MATCH_DIAG & C_S4),
		    .dout(leds),
		    //.CLR_n(1'b1)
		    .CLR_n(~sys_reset)
		    );
   assign diag_leds = ~leds;
   
   // Bus Error Register: read to inspect, *write to clear*.  From the boot
   // monitor's own mon/h/buserr.h:
   //
   //   "If multiple bus errors occur, only the first one is kept.  Software
   //    indicates that it has read out that bus error by writing to the bus
   //    error reg; the data doesn't matter and isn't saved."
   //
   // Both halves of that matter.  The default bus error handler (trap.s
   // _bus_error) reads this register and then writes it back; if the write
   // does not complete, the handler faults inside itself and every nesting
   // pushes another 58-byte 68010 long frame until the stack runs off the
   // bottom of memory and the CPU double-faults.  That is not a VME quirk --
   // it made *any* unprotected bus error unrecoverable.
   //
   // Bit assignment, from the BE_* constants in the same header:
   //
   //   7 VALID     the page map entry's valid bit was on
   //   6 VMEBUSERR bus error signalled on the VME bus
   //   5,4         reserved
   //   3 PROTERR   protection violation
   //   2 TIMEOUT   nothing answered
   //   1 PARERR_U  parity error, upper byte
   //   0 PARERR_L  parity error, lower byte
   //
   // VALID is what separates the two meanings of PROTERR: set means the
   // protection field refused the access, clear means the entry was not valid
   // at all.  VMEBUSERR and the two parity bits have nothing behind them --
   // no system bus of either kind, no parity memory -- so they are honestly
   // zero rather than merely unimplemented.
   wire [7:0] 			 berr_in;
   wire [7:0] 			 berr_out;
   assign berr_in = {VALID, 1'b0, 1'b0, 1'b0, PROTERR, TIMEOUT, 1'b0, 1'b0};
   wire 			 ERR;
   assign ERR = (PROTERR | TIMEOUT) & C_S4;

   // The acknowledge: any write to the register, data discarded.  And a read,
   // which is the part that took a board and an ILA to find.
   //
   // mon/h/buserr.h states the rule this implements: "If multiple bus errors
   // occur, only the first one is kept.  Software indicates that it has read
   // out that bus error by writing to the bus error reg; the data doesn't
   // matter and isn't saved."  Beside the single write the PROM ever does,
   // mon/kernel/trap.s:104 says: "FIXME, remove this when latch is gone."
   //
   // The latch went.  SunOS never writes this register -- getbuserr in
   // sys/sun2/locore.s:972 is a bare `movsw BUSERRREG,d0' and no file in the
   // tree writes it -- so on a machine that only clears on a write, the first
   // bus error of the boot is held for ever.  The first errors of a boot are
   // the PROM's device probes: a timeout on a valid page, 0x84.  Which is
   // exactly what SunOS 4.0.3 printed when it panicked creating pid 1, for a
   // fault the MMU had reported correctly as a protection violation -- the
   // ILA caught that cycle on the board with PROTERR set, TIMEOUT clear, and
   // the register said TIMEOUT because it was still showing a device probe
   // from seconds earlier.
   //
   // So a read re-arms it too.  That keeps the documented behaviour where it
   // matters -- a nested fault on the way to reading this still finds the
   // first error, because nothing has read it yet -- and lets a handler that
   // reads and moves on see its own error next time.  A new error outranks
   // both, so an error arriving on the same clock as a read is not lost.
   wire 			 berr_ack, berr_read;
   assign berr_ack  = WR & MATCH_BERR & C_S4;
   assign berr_read = RD & MATCH_BERR & C_S4;

   reg 				 berr_latched;
   always @(posedge CLK)
     if (sys_reset)                     berr_latched <= 1'b0;
     else if (ERR)                      berr_latched <= 1'b1;
     else if (berr_ack | berr_read)     berr_latched <= 1'b0;

   gen8bit_reg berr(.CLK(CLK),
		    .din(berr_in),
		    .WR(ERR & ~berr_latched),
		    .dout(berr_out),
		    .CLR_n(~(berr_ack | sys_reset))
		    );
   assign P_BERR_n = ~ERR;

   // System Enable register
   wire [7:0] 			 sys_out;
   //
   // Cleared by every board reset -- by sys_reset, not por_reset, since unlike
   // the timer and the SCCs this one really is cleared by a reset on a 2/50:
   // its CLR is INIT-, a PAL output driven by power-on reset, VME reset and the
   // watchdog.  BOOT_n lives in this register,
   // so what clears it decides whether a reset puts the machine back into boot
   // state -- and the boot PROM states the contract in _hardreset: "A hardware
   // reset would clear the enable register, but if this is a software reset,
   // we have to get into boot state explicitly this way."
   //
   // It used to be cleared by POR_n, an `initial' block with # delays that has
   // since been replaced by por_reset.  Simulation ran it and the
   // register is cleared at time zero; synthesis ignores the delays, so on a
   // board nothing cleared this register ever.  Power-up worked by luck -- a
   // Xilinx flip-flop configures to 0, so BOOT_n came up 0 -- but once the PROM
   // left boot state, the reset button could not put it back: the machine
   // restarted with BOOT_n = 1, its reset vector fetch went through a stale
   // page map instead of the PROM, and the cycle hung with no bus error,
   // because memory is exempt from the bus timeout.  Measured on the board as
   // the heartbeat still ticking with only seen_stall lit, and reproduced here
   // with +reset_at_ms=1300, which has to be after en_boot drops to prove
   // anything.
   //
   gen8bit_reg sys(.CLK(CLK),
		   .din(P_DIN[7:0]),
		   .WR(WR & MATCH_SYSEN & C_S4),
		   .dout(sys_out),
		   .CLR_n(~sys_reset)
		   );
   /* split the 8 system bits by name */
   wire 			 EN_PAR, EN_INT1, EN_INT2, EN_INT3, EN_PARERR, EN_DVMA, EN_INT;
   assign EN_PAR    = sys_out[0];
   assign EN_INT1   = sys_out[1];
   assign EN_INT2   = sys_out[2];
   assign EN_INT3   = sys_out[3];
   assign EN_PARERR = sys_out[4];
   assign EN_DVMA   = sys_out[5];
   assign EN_DVMA_o = EN_DVMA;
   assign EN_INT    = sys_out[6];
   assign BOOT_n    = sys_out[7];

   // output readable info when we change sysen
   always @(sys_out) begin
      $display("System Enable Register updated");
      $display("\tEnable Parity Generation: %x", EN_PAR);
      $display("\tCause Interrupt on Level 1: %x", EN_INT1);
      $display("\tCause Interrupt on Level 2: %x", EN_INT2);
      $display("\tCause Interrupt on Level 3: %x", EN_INT3);
      $display("\tEnable Parity Error ChecKing: %x", EN_PARERR);
      $display("\tEnable Direct Virtual Memory Access: %x", EN_DVMA);
      $display("\tEnable all Interrupts: %x", EN_INT);
      $display("\tBoot State (O => boot, 1 => normal): %x", BOOT_n);
   end // always @ (sys_out)

   // PROM (two access modes: at boot using P_A, or mapped but matched through MA), read-only
   // handled by the two match signals in the bus section, the PROM itself always output whatever is addressed
   wire [15:0] 			 prom_out;
   bootrom bootrom(.CLK(CLK),
		   .idx({1'b0, P_A[14:1]}),
		   .dout(prom_out)
		   );

   // match wire for devices
   // matching late as we need to be sure the MA is now valid, two clocks after the address is valid
   // that happens on entry in S2 (rising edge), so on that edge IA becomes valid
   // then on entry in S4 MA becomes valid
   // Device space is eight 2 KiB pages in the same order on both Sun-2 buses,
   // but at a different base: page 0x000 on MultiBus, 0xFE0 (byte 0x7F0000) on
   // VME -- see the device space map in the Architecture Manual.  DEV_PAGE_BASE
   // selects which, so the same decode serves both machines.
   wire 			 MATCH_DEV;
   assign MATCH_DEV      = (FC_GENERAL) & (TYPE == 3'h1) & C_S6 &
                           (ma_pmap2devices[11:3] == (`DEV_PAGE_BASE >> 3));

   wire 			 MATCH_PROM, MATCH_RSVD, MATCH_DPC, MATCH_PARALLEL, MATCH_SERIAL, MATCH_TIMER, MATCH_ROPS, MATCH_RTC;
   assign MATCH_PROM     = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h0);
   assign MATCH_RSVD     = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h1); // Ethernet on VME
   assign MATCH_DPC      = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h2); // not installed
   assign MATCH_PARALLEL = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h3); // keyboard/mouse on VME
   assign MATCH_SERIAL   = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h4);
   assign MATCH_TIMER    = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h5);
   assign MATCH_ROPS     = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h6); // not in prime
   assign MATCH_RTC      = MATCH_DEV & (ma_pmap2devices[2:0] == 3'h7); // not in prime

   // The frame buffer.  Both machines have the same 1152x900 screen, both boot
   // PROMs map it at the same *virtual* addresses -- 0xEC0000 for the pixels
   // and 0xEE3800 for the control register -- and both draw on it with
   // byte-identical code.  What differs, and all that differs, is the page-map
   // entry: mon/kernel/sunmon.c:41-51 is VPM_IO/VIOPG_VIDEO against
   // MPM_MEMORY/MEMPG_VIDEO, and the two tables are in the shipped images as
   // data words (0xEC400000 against 0xEC00FE00).
   //
   //   2/50    TYPE 1, pages 0..63 for the pixels and page 0x40 for the
   //           register, at the bottom of on-board I/O space rather than in the
   //           eight-page window at DEV_PAGE_BASE -- which is why MATCH_DEV
   //           cannot reach them.
   //   2/120   TYPE 0, the eighth megabyte: pixels at page 0xE00 (0x700000),
   //           the keyboard/mouse SCC at 0xF00 and the register at 0xF03
   //           (0x781800).  Memory space, alongside RAM, because the video
   //           board is a P2-bus device rather than a MultiBus one -- its own
   //           manual decodes nothing but P2.* -- and because MEM_SPACE_PAGES
   //           is 3584 = 0xE00 on this machine, the aperture starts exactly one
   //           page past the end of memory.  mon/diag/diag.s:607 clamps memory
   //           sizing there for that reason: "Meg 7 is reserved for framebuf".
   //
   // The MultiBus decode is deliberately coarser than the VME one.  Above
   // 0x700000 the board looks at A19, A12 and A11 and nothing else, so the
   // 128 KiB aperture repeats every 128 KiB up to 0x77FFFE and the register
   // repeats up to 0x7FFFFE -- Figure 2-1 of the board manual says so in as
   // many words ("DO NOT USE, will map to Video Memory").  Matching that costs
   // nothing and is what a probe of 0x720000 would really find.
   //
   // The pixels do not answer here on either machine -- they are in DDR3, and
   // the Wishbone bridge fields MATCH_FB.  Only the control register is local.
   // FB_PAGE is ma_pmap2devices[5:0] either way: 0x000 and 0xE00 agree in the
   // bottom six bits, so the same wires pick the 2 KiB within the aperture.
`ifdef SUN2_FB
 `ifdef SUN2_VME
   assign MATCH_FB       = (FC_GENERAL) & (TYPE == 3'h1) & C_S6 &
                           (ma_pmap2devices[11:6] == 6'h0);
   assign MATCH_FBCTL    = (FC_GENERAL) & (TYPE == 3'h1) & C_S6 &
                           (ma_pmap2devices == 12'h040);
 `else
   assign MATCH_FB       = (FC_GENERAL) & (TYPE == 3'h0) & C_S6 &
                           (ma_pmap2devices[11:8] == 4'hE);
   assign MATCH_FBCTL    = (FC_GENERAL) & (TYPE == 3'h0) & C_S6 &
                           (ma_pmap2devices[11:8] == 4'hF) &
                           (ma_pmap2devices[1:0] == 2'b11);
 `endif
`else
   assign MATCH_FB       = 1'b0;
   assign MATCH_FBCTL    = 1'b0;
`endif


`ifdef MEM_SIM_ONLY
   assign MATCH_MEM      = (FC_GENERAL) & (TYPE == 3'h0) & (ma_pmap2devices[11:8] == 4'h0) & C_S6; // "physically" installed (simulation => reduced)
`else
   // "physically" installed memory, in 2 KiB pages -- see MEM_PAGES in sun2_config.vh
   assign MATCH_MEM      = (FC_GENERAL) & (TYPE == 3'h0) & (ma_pmap2devices[11:0] < `MEM_PAGES) & C_S6;
`endif
   // Addressable memory space, for DTACK: auto-sizing works by reading back
   // wrong values rather than by taking a bus error, so everything the PROM
   // probes has to answer.  See MEM_SPACE_PAGES in sun2_config.vh.
   assign MATCH_MEMX     = (FC_GENERAL) & (TYPE == 3'h0) & (ma_pmap2devices < `MEM_SPACE_PAGES) & C_S6;

   // System bus space -- TYPE 2, MPM_BUSMEM on a MultiBus machine, VPM_VME0 on
   // a VME one.  1 MiB of it on MultiBus (512 pages of 2 KiB), so only nine of
   // the twelve physical-page bits are live and the top three must be zero.
   //
   // This is a *space*, not a device.  It says "the cycle is aimed at the
   // system bus and here is the bus address"; whether anything answers is up to
   // what is plugged in, and DTACK comes from the card, not from here.  With no
   // card the timing chain runs to C_S24 and takes the usual bus-error timeout,
   // which is load-bearing: it is how ieprobe(), ecprobe() and the disk probes
   // all discover they have nothing to talk to.  Decoding this space *blindly*
   // would make ecprobe() -- which is nothing but "did it answer?" -- report a
   // 3Com card that is not there.
   wire 			 MATCH_MBMEM;
   assign MATCH_MBMEM    = (FC_GENERAL) & (TYPE == 3'h2) & C_S6 &
                           (ma_pmap2devices[11:9] == 3'h0);
   assign mb_sel         = MATCH_MBMEM;
   assign mb_addr        = {ma_pmap2devices[8:0], P_A[10:1], 1'b0};
   assign mb_we          = ~P_RW_n;
   assign mb_uds_n       = P_UDS_n;
   assign mb_lds_n       = P_LDS_n;
   assign mb_dout        = P_DIN;

   // MultiBus I/O space -- TYPE 3, MPM_BUSIO.  A space and not a device, on
   // exactly the same terms as TYPE 2 above: nothing here decides whether a
   // card answers, and with an empty cage the cycle runs to C_S24 and takes
   // the bus-error timeout.  That is not a detail -- xyprobe() is a pokec()
   // pair that has to *fail* at 0xEE48 for the monitor to report one
   // controller rather than two.
   //
   // MultiBus I/O is a **16-bit** space, so only five of the twelve page bits
   // reach the bus and the other seven are not decoded at all.  The whole of
   // TYPE 3 therefore aliases onto 64 KiB.
   //
   // This started out requiring the top seven bits to be zero, on the grounds
   // that the monitor maps exactly 32 pages at BUSIO_BASE and anything above
   // that "should time out rather than alias".  That was generalising the
   // monitor's map into a property of the hardware, and SunOS 4.0.3 disproves
   // it on the first disk access: its standalone boot maps the controller with
   // the same all-ones idiom mon/h/video.h uses for the frame buffer --
   // 0xFFFFE800 >> 11, page 0xFFD -- and reads the CSR at page 0xFFD offset
   // 0x644, which is I/O address 0xEE44.  With the restriction in place that
   // is a timeout and the boot dies with
   //
   //     Timeout Bus Error, addr: 00100644 at 240E66
   //
   // Nothing is made to answer by removing it: mbio_hit still comes from the
   // card's own address comparator, so an empty cage times out exactly as
   // before, and xyprobe()'s second address at 0xEE48 still has to fail for
   // the monitor to report one controller rather than two.
   wire 			 MATCH_MBIO;
   assign MATCH_MBIO     = (FC_GENERAL) & (TYPE == 3'h3) & C_S6;
   assign mbio_sel       = MATCH_MBIO;
   assign mbio_addr      = {ma_pmap2devices[4:0], P_A[10:1], 1'b0};
   assign mbio_we        = ~P_RW_n;
   assign mbio_uds_n     = P_UDS_n;
   assign mbio_lds_n     = P_LDS_n;
   assign mbio_dout      = P_DIN;

   wire [15:0] 			 timer_out;
   wire 			 FOUT, timer_int[5:1]; /* FOUT for completeness, not et implemented in the TTL code */
   // X1/X2 is the 4.9152 MHz crystal oscillator (schematic sheet A05: the
   // 9513 shares C.204 with both SCCs), not the CPU clock -- it is what sets
   // every timer period, including the NMI tick the monitor measures wall
   // time with.  CLK is the bus side, which has no equivalent on the real
   // chip and has to be fast enough to sample X2; see the scaler comment in
   // ttl_am9513.v.
   ttl_am9513 timer (
		     .CLK(C100),
		     .reset_n(~por_reset),   // never reset by a board reset -- see por_reset
		   .DIN(P_DIN),
		   .DOUT(timer_out),
		   .CD_n(P_A[1]), // checkme: latched in the original (LA1)
		   .CS_n(1'b0), // always on
		   .RD_n(~MATCH_TIMER | ~RD),
		   .WR_n(~MATCH_TIMER | ~WR),
		   .X1(1'b0),
		   .X2(clk4m9152),
		   .FOUT(FOUT),
		   .SRC1(1'b0),
		   .SRC2(1'b0),
		   .SRC3(1'b0),
		   .SRC4(1'b0),
		   .SRC5(1'b0),
		   .SRC6(1'b0),
		   .GAT1(FOUT),
		   .GAT2(1'b0),
		   .GAT3(1'b0),
		   .GAT4(1'b0),
		   .GAT5(1'b0),
		   .OUT1(timer_int[1]), // FIXME: DOME
		   .OUT2(timer_int[2]),
		   .OUT3(timer_int[3]),
		   .OUT4(timer_int[4]),
		   .OUT5(timer_int[5])
		   );

`ifdef MEM_SIM_ONLY
   /* the actual memory. For now it's just synchronous RAM */
   /* should probably be moved to some "real" RAM with variable timings, which will require changing the bus mux below */
   wire [15:0] 			 mem_out;
   sram_sync_16bits_bytewritable #(.IDX_WIDTH(18)) mainmem (.CLK(C100),
							  .idx({ma_pmap2devices[7:0],P_A[10:1]}),
							  .WRl(WR & MATCH_MEM & ~P_LDS_n),
							  .WRu(WR & MATCH_MEM & ~P_UDS_n),
							  .din(P_DIN),
							  .dout(mem_out)
							  );
   /* no external memory in this configuration: park the Wishbone master */
   assign wb_cyc_o = 1'b0;
   assign wb_stb_o = 1'b0;
   assign wb_adr_o = 30'h0;
   assign wb_dat_o = 32'h0;
   assign wb_sel_o = 4'h0;
   assign wb_we_o  = 1'b0;
`else // !`ifdef SIM_ONLY
   wire [15:0] 			 wishbone_out;
   wire 			 w_ack;
   wire 				 L_M_MAP_SEEN;
   assign L_M_MAP_SEEN = (leds == 8'h8F); 
   
   sun2_wishbone_bridge #(.FB_WB_BASE(`FB_WB_BASE)) wbridge(.CLK(C100),
				// Power-up state, not reset state.  ENABLE is armed
				// when the monitor writes LED code 0x8F and gates
				// wb_cyc/wb_stb, so while it is clear main memory
				// never answers -- and memory is exempt from the bus
				// timeout, so such a cycle hangs for ever rather than
				// taking a bus error.  A cold boot reaches 0x8F before
				// it needs RAM; the monitor's warm-reset path does not,
				// it maps pages 0 and 1 and pushes every register to
				// the stack first (trap.s, after DogSkip1).  Clearing
				// this on a board or watchdog reset therefore hangs the
				// machine on the way back up, which is what the
				// watchdog test found -- and what the original comment
				// here, "don't want to loose memory access then", was
				// already reaching for.
				.RESET_n(~por_reset),
				.SET_ENABLE(L_M_MAP_SEEN),
				.P_ADR_IN({1'h0, ma_pmap2devices[11:0], P_A[10:1]}), // full physical (4 MiB)
				.P_DATA_IN(P_DIN),
				.P_DATA_OUT(wishbone_out),
				.P_RW_n(P_RW_n),
				.EN_LBYTE(~P_LDS_n),
				.EN_UBYTE(~P_UDS_n),
				.FB_PAGE(ma_pmap2devices[5:0]),
				.MATCH_MEM(MATCH_MEM & ~MATCH_PROM_BOOT),
				.MATCH_FB(MATCH_FB),
				.W_ACK(w_ack),
     
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
   
`endif

   
   /* serial port */
   wire [7:0] 			 serial_out;
   wire 			 serial_en;
   wire 			 serial_int_n; // FIXME: DOME
   wire 			 RxDA, TxDA, TxDA_EN;

   assign tx = TxDA;
   assign RxDA = rx;
  
   // A simulation-only hook: an empty module wrapped round TxDA alone, so a VCD
   // can carry that one signal without pulseview choking on the rest.
   //
   // Not built into a bitstream, and that is not tidiness.  An empty module is
   // a black box to Vivado, and opt_design refuses to run on a design that has
   // one.  Every build until now got away with it because synthesis pruned the
   // instance -- it has no outputs -- before DRC could see it; the first ILA
   // build did not, because marking debug nets keeps hierarchy that would
   // otherwise have been optimised through, and the whole run died at
   // opt_design with a black box in a module that has nothing to do with the
   // ILA.  Both simulation flows define SUN2_SIM.
`ifdef SUN2_SIM
   tolog tolog(.TxDA(TxDA));
`endif
   
   z8530_scc  #(.SOFT_RESET_EN(1),
		.RR8_CTRL_POP(1),
		.BRG_SRC_A(1),
		.BRG_SRC_B(1),
		.UNIPLUS_BAUD_PATCH_B(0),
		.AUTO_ENABLES_EN(0),
		.RTXC_XTAL_FULLRATE_A(0),
		.RTXC_XTAL_FULLRATE_B(0),
		.RDWR_RESET_EN(1)
		) serial (
		// System Interface
			  .clk(C100),           // CPU/bus clock (register file, interrupts, RR mux)
			  .pclk(clk4m9152),       // Alternative BRG/serializer clock (Zilog "PCLK")
			  .sclk(clk4m9152),          // Primary BRG/serializer clock (e.g. 3.6864 MHz)
			  .reset_n(~por_reset),       // power-on only: a 2/50 SCC has no reset
			  
			  // CPU Interface
			  .cs_n(1'b0),          // Chip select (active low)
			  .rd_n(~MATCH_SERIAL | ~RD),          // Read strobe (active low)
			  .wr_n(~MATCH_SERIAL | ~WR),          // Write strobe (active low)
			  .a_b(P_A[2]),           // Channel select: 1=A, 0=B
			  .d_c(P_A[1]),           // Data/Control: 1=Data, 0=Control
			  .data_in(P_DIN[15:8]),       // Data input
			  .data_out(serial_out),      // Data output
			  .data_oe(serial_en),       // Data output enable
			  
			  // Interrupt
			  .int_n(serial_int_n),         // Interrupt output (active low)
			  .intack_n(1'b1),      // Interrupt acknowledge
			  
			  // Channel A Serial Interface
			  //
			  // The modem inputs are held deasserted, not left open, and
			  // that is not tidiness.  RR0 bits 5, 4 and 3 are CTS,
			  // Sync/Hunt and DCD taken straight off these pins, so an
			  // unconnected input puts an X in the status byte -- and the
			  // monitor's NMI handler reads RR0 on every tick to debounce
			  // a serial BREAK, ANDs it and compares it with g_debounce
			  // (msun/mon/kernel/trap.s:585-604).  An X there eventually
			  // resolves as "the break bit went 1->0" and the machine
			  // aborts to the monitor out of nowhere, in the middle of
			  // whatever it was doing.  The keyboard SCC below has always
			  // tied these; this one had not, which is why only it read
			  // back XX.  Nothing on the board drives them either: section
			  // 6.7, "Control lines are not used", and no drivers fitted.
			  .rxca(1'b0),      // Receive clock A (BRG_SRC_A, so unused)
			  .txca(1'b0),      // Transmit clock A (likewise)
			  .rxda(RxDA),          // Receive data A
			  .txda(TxDA),          // Transmit data A
			  .ctsa_n(1'b1),    // Clear to send A (active low)
			  .dcda_n(1'b1),    // Data carrier detect A (active low)
			  .synca_n(1'b1),   // Sync A (async-mode input -> RR0[4], active low)
			  .rtsa_n(),        // Request to send A (active low)
			  .dtra_n(),        // Data terminal ready A (active low)
			  
			  // Channel B Serial Interface.  Same treatment: the PROM
			  // programs both channels and reads RR0 of either.
			  .rxcb(1'b0),      // Receive clock B
			  .txcb(1'b0),      // Transmit clock B
			  .rxdb(1'b1),      // Receive data B -- idle mark
			  .txdb(),          // Transmit data B
			  .ctsb_n(1'b1),    // Clear to send B (active low)
			  .dcdb_n(1'b1),    // Data carrier detect B (active low)
			  .syncb_n(1'b1),   // Sync B (async-mode input -> RR0[4], active low)
			  .rtsb_n(),        // Request to send B (active low)
			  .dtrb_n()         // Data terminal ready B (active low)
			  );

   /* keyboard and mouse port */
   //
   // A second Z8530, identical to the serial one above: the Architecture
   // Manual's sections 6.6 and 6.7 give byte-for-byte the same register table
   // (channel B control/data at 0 and 2, channel A at 4 and 6, level 6,
   // 4.9152 MHz clock), and schematic sheet A06 wires U600 and U601 alike.
   // They differ only in what hangs off the pins: channel A is the keyboard,
   // channel B the mouse.  Both boot PROMs reach it at the same virtual
   // address, 0xEEC000, and it is only the page-map entry that differs:
   //
   //   2/50    device page 3 -- TYPE 1 page 0xFE3.  On board.
   //   2/120   TYPE 0 page 0xF00 (0x780000) -- on the *video board*, four words
   //           at 780000/2/4/6, which is why it is built only with SUN2_FB.
   //           Page 3 there is a parallel port, which we do not implement.
   //
   // On MultiBus that coupling is not a simplification, it is the machine:
   // sunmon.c:601 is "On Multibus, keyboard can't be there if there's no frame
   // buffer".  With no display the monitor points g_keybzscc at a fake UART in
   // PROM space and never touches 0xEEC000; with one, it calls
   // reset_uart(g_keybzscc) with no bus-error catcher anywhere in reach.  So a
   // 2/120 that has a frame buffer must have this too.
   //
   // Nothing is attached: the monitor resets the SCC, programs 1200 baud,
   // polls for a keyboard, gets no answer and falls back to the serial console
   // -- "Using RS232 A input.", which is what we want while the console *input*
   // is the serial port.  The point of having it at all is that the write
   // lands, instead of taking a bus error the monitor has no handler for.
   wire [7:0] 			 kbm_out;
   wire 			 MATCH_KBM;
   // KBM_HERE says the machine has somewhere to put it.  It is `undef'd again
   // right after the instance below rather than left defined, because a
   // `define inside a module leaks into every file compiled after this one in
   // the same run.
`ifdef SUN2_VME
 `define KBM_HERE
   assign MATCH_KBM = MATCH_PARALLEL;
`elsif SUN2_FB
 `define KBM_HERE
   // The video board decodes A19, A12 and A11 and nothing else above 0x700000,
   // so the SCC repeats every 8 KiB up to 0x7FFFFE just as the real one does.
   assign MATCH_KBM = (FC_GENERAL) & (TYPE == 3'h0) & C_S6 &
                      (ma_pmap2devices[11:8] == 4'hF) &
                      (ma_pmap2devices[1:0] == 2'b00);
`endif

`ifdef KBM_HERE
   wire 			 kbm_int_n; // FIXME: level 6, not wired to the IPL encoder yet

   z8530_scc  #(.SOFT_RESET_EN(1),
		.RR8_CTRL_POP(1),
		.BRG_SRC_A(1),
		.BRG_SRC_B(1),
		.UNIPLUS_BAUD_PATCH_B(0),
		.AUTO_ENABLES_EN(0),
		.RTXC_XTAL_FULLRATE_A(0),
		.RTXC_XTAL_FULLRATE_B(0),
		.RDWR_RESET_EN(1)
		) keybmouse (
			  .clk(C100),
			  .pclk(clk4m9152),
			  .sclk(clk4m9152),
			  .reset_n(~por_reset),       // power-on only: a 2/50 SCC has no reset

			  .cs_n(1'b0),
			  .rd_n(~MATCH_KBM | ~RD),
			  .wr_n(~MATCH_KBM | ~WR),
			  .a_b(P_A[2]),           // 1=A (keyboard), 0=B (mouse)
			  .d_c(P_A[1]),           // 1=Data, 0=Control
			  .data_in(P_DIN[15:8]),
			  .data_out(kbm_out),
			  .data_oe(),

			  .int_n(kbm_int_n),
			  .intack_n(1'b1),

			  // Channel A -- keyboard.  Nothing plugged in, so the
			  // receive line sits at mark and the transmit line goes
			  // nowhere.  Section 6.7: "Control lines are not used",
			  // and the board fits no drivers for them, so the modem
			  // inputs are held deasserted rather than left floating.
			  .rxca(1'b0),
			  .txca(1'b0),
			  .rxda(1'b1),
			  .txda(),
			  .ctsa_n(1'b1),
			  .dcda_n(1'b1),
			  .synca_n(1'b1),
			  .rtsa_n(),
			  .dtra_n(),

			  // Channel B -- mouse.  Same treatment.
			  .rxcb(1'b0),
			  .txcb(1'b0),
			  .rxdb(1'b1),
			  .txdb(),
			  .ctsb_n(1'b1),
			  .dcdb_n(1'b1),
			  .syncb_n(1'b1),
			  .rtsb_n(),
			  .dtrb_n()
			  );
`else
   // A MultiBus machine with no video board has nowhere to put this, and page 3
   // is the parallel port, which we do not implement.  Held at zero so the read
   // mux and DTACK terms below fold away entirely.
   assign MATCH_KBM = 1'b0;
   assign kbm_out   = 8'h00;
`endif
`undef KBM_HERE

   /* Ethernet control register -- VME machines only */
   //
   // Device page 1.  See rtl/sun2-vme/sun2_ether_ctl.v for the bit assignment and for
   // why this has to answer even though there is no 82586 behind it: the boot
   // PROM decides Ethernet is present from the ID PROM alone, so auto-boot
   // reaches iereset() regardless.  On MultiBus page 1 is an 80287 socket,
   // which we do not implement either.
   wire [7:0] 			 ether_out;
   wire 			 MATCH_ETHER;
`ifdef SUN2_VME
   assign MATCH_ETHER = MATCH_RSVD;

   sun2_ether_ctl etherctl(.CLK(CLK),
			   .RESET(~P_RESET_n),   // P.RESET- clears ALS273 U716
			   .din(P_DIN[15:8]),
			   .WR(WR & MATCH_ETHER & C_S8),
			   .dout(ether_out),
			   .core_reset_n(ether_core_reset_n),
			   .loopback_n(ether_loopback_n),
			   .ca(ether_ca),
			   .int_en(ether_int_en),
			   .int_in(ether_int),
			   .bus_err_in(ether_bus_err)
			   );
`else
   assign MATCH_ETHER = 1'b0;
   assign ether_out   = 8'h00;
   // Driven even though no MultiBus machine has this register, because they
   // are module outputs: leaving them to the `ifdef made them floating nets in
   // synthesis and X in simulation, and one of them was being consumed.
   assign ether_core_reset_n = 1'b0;
   assign ether_loopback_n   = 1'b0;
   assign ether_ca           = 1'b0;
   assign ether_int_en       = 1'b0;
`endif

   /* Video control register -- VME machines only, and only with SUN2_FB */
   wire [15:0] 			 fbctl_out;
   wire 			 fb_video_en, fb_int;
`ifdef SUN2_FB
   sun2_fb_ctl fbctl(.CLK(CLK),
		     .RESET(~P_RESET_n),   // P2.INIT- clears U1610/U1611
		     .din(P_DIN),
		     .WR(WR & MATCH_FBCTL & C_S8),
		     .UDS_n(P_UDS_n),
		     .LDS_n(P_LDS_n),
		     .dout(fbctl_out),
		     .video_en(fb_video_en),
		     .fb_int(fb_int)
		     );
`else
   assign fbctl_out   = 16'h0000;
   assign fb_video_en = 1'b0;
   assign fb_int      = 1'b0;
`endif
   assign fb_video_en_o = fb_video_en;

   /* PHY status register -- VME machines only, and not a Sun-2 device at all */
   //
   // Device page 7, which is unused on a VME machine (0xFE7) and a real-time
   // clock we do not implement on a MultiBus one.  Read-only: no write DTACK
   // term, so a write times out into a bus error, as writing the ID PROM does.
   wire [15:0] 			 phy_status_out;
   wire 			 MATCH_PHY;
`ifdef SUN2_VME
   assign MATCH_PHY = MATCH_RTC;

   sun2_phy_status phystat(.CLK(CLK),
			   .RESET(sys_reset),
			   .P_A1(P_A[1]),
			   .dout(phy_status_out),
			   .phy_id(phy_id),
			   .phy_present(phy_present),
			   .phy_cfg_done(phy_cfg_done),
			   .phy_link(phy_link),
			   .phy_fd(phy_fd),
			   .phy_speed(phy_speed),
			   .crs_stuck(phy_crs_stuck)
			   );
`else
   assign MATCH_PHY       = 1'b0;
   assign phy_status_out  = 16'h0000;
`endif



   // Answering the CPU
   // bus muxer. CPU has priority via DATA_EN, otherwise whomever is matched own the bus
   assign P_DOUT = DATA_EN         ? P_DIN : // loopback
		   MATCH_CTX       ? ctx_out :
		   MATCH_SMAP      ? {8'h0, ia_smap2pmap} :
		   MATCH_PMAP_PS   ? {ps_pmap2devices, 4'h0} :
		   MATCH_PMAP_MA   ? {4'h0, ma_pmap2devices} :
		   MATCH_SYSEN     ? {8'h0, sys_out} :
		   MATCH_BERR      ? {8'h0, berr_out} :
		   MATCH_IDPROM    ? {idprom_out, 8'h0} :
		   MATCH_PROM_BOOT ? prom_out :
		   MATCH_PROM      ? prom_out :
		   MATCH_TIMER     ? timer_out :
`ifdef MEM_SIM_ONLY
		   MATCH_MEM       ? mem_out :
`else
		   MATCH_MEM       ? wishbone_out :
`endif
		   MATCH_SERIAL    ? {serial_out, 8'h0} :
		   MATCH_KBM       ? {kbm_out, 8'h0} :
		   MATCH_ETHER     ? {ether_out, 8'h0} :
		   MATCH_PHY       ? phy_status_out :
		   MATCH_FBCTL     ? fbctl_out :
		   MATCH_FB        ? wishbone_out :
		   mb_hit          ? mb_din :
		   mbio_hit        ? mbio_din :
		   16'hDEAD;

   // DTACK generator. has knowledge of timings for all devices
   // For memory this will need updating if we use "real" (variable-timing) memory
   assign P_DTACK_n = ~(
			/* reads */
			( P_RW_n & C_S4 & (MATCH_CTX | MATCH_IDPROM | MATCH_SYSEN | MATCH_BERR | MATCH_PROM_BOOT)) | // entering S4, quick devices
			( P_RW_n & C_S4 & (MATCH_SMAP)) |  // entering S4, quick devices (CTX is 1 clock but went valid after being written, not affected by P_A)
			( P_RW_n & C_S6 & (MATCH_PMAP_PS | MATCH_PMAP_MA)) |  // entering S6, physical map needed an extra cycle
			( P_RW_n & C_S8 & (MATCH_TIMER | MATCH_PROM | MATCH_SERIAL | MATCH_KBM | MATCH_ETHER | MATCH_PHY | MATCH_FBCTL)) | // entering S8, devices going through the MMU
			( P_RW_n & w_ack & (MATCH_FB)) | // the frame buffer is in DDR3
`ifdef MEM_SIM_ONLY
		        ( P_RW_n & C_S8 & (MATCH_MEMX)) | // entering S8, memory going through the MMU
`else
		        ( P_RW_n & w_ack & (MATCH_MEM)) | // entering S8, memory going through the MMU
			// memory sizing doesn't like timeout ? so ack when out-of-range
		        ( P_RW_n & C_S8 & (MATCH_MEMX & ~MATCH_MEM)) | // entering S8, memory going through the MMU
`endif
			/* writes */
			// MATCH_BERR is a write-to-clear acknowledge -- see the Bus
			// Error Register above.  Leaving it out of this list is
			// what turned every unprotected bus error into a halt.
			(~P_RW_n & C_S4 & (MATCH_CTX | MATCH_SYSEN | MATCH_DIAG | MATCH_BERR)) | // entering S4, quick devices
			(~P_RW_n & C_S4 & (MATCH_SMAP)) |  // entering S4, quick devices (CTX is 1 clock but went valid after being written, not affected by P_A)
			(~P_RW_n & C_S6 & (MATCH_PMAP_PS | MATCH_PMAP_MA)) |  // entering S6, physical map needed an extra cycle
			(~P_RW_n & C_S8 & (MATCH_TIMER |              MATCH_SERIAL | MATCH_KBM | MATCH_ETHER | MATCH_FBCTL)) | // entering S8, devices going through the MMU
			(~P_RW_n & w_ack & (MATCH_FB)) | // the frame buffer is in DDR3
`ifdef MEM_SIM_ONLY
		        (~P_RW_n & C_S8 & (MATCH_MEMX)) | // entering S8, memory going through the MMU
`else
		        (~P_RW_n & w_ack & (MATCH_MEMX)) | // entering S8, memory going through the MMU
		        (~P_RW_n & C_S8 & (MATCH_MEMX & ~MATCH_MEM)) | // entering S8, memory going through the MMU
`endif
			/* the system bus, either direction.  A card answers when
			 it is ready rather than on a fixed count, which is what
			 MultiBus XACK is; with no card mb_hit never rises and
			 the cycle times out. */
			(mb_hit & mb_ack) |
			/* and the same again for MultiBus I/O space */
			(mbio_hit & mbio_ack) |

			1'b0);
   
   
   // LEDS
   // as for the real thing, used for debugging (in simulation)
   always @(leds) begin
      $display("Leds are now %x", ~leds);
      case (~leds)
	8'hff:$display(" => L_RESET");
	8'h00:$display(" => L_RUNNING");
	8'h01:$display(" => L_INITIAL");
	8'h02:$display(" => L_USERDOG");
	8'h03:$display(" => L_GOTMEM");
	8'h04:$display(" => (initial led test only)");
	8'h07:$display(" => L_AFTERDIAG");
	8'h08:$display(" => L_HEARTBEAT");
	8'h10:$display(" => (initial led test only)");
	8'h11:$display(" => L_CONTEXT");
	8'h20:$display(" => (initial led test only)");
	8'h21:$display(" => L_SM_CONST");
	8'h23:$display(" => L_SM_DATA");
	8'h22:$display(" => L_SM_ADDR");
	8'h31:$display(" => L_PM_CONST");
	8'h33:$display(" => L_PM_DATA");
	8'h32:$display(" => L_PM_ADDR");
	8'h40:$display(" => L_PROM");
	8'h50:$display(" => L_UART");
	8'h70:$display(" => L_M_MAP");
	8'h71:$display(" => L_M_CONST");
	8'h72:$display(" => L_M_ADDR");
	8'h7F:$display(" => L_PARITY");
	8'h80:$display(" => (initial led test only)");
	8'h81:$display(" => L_TIMER");
	8'hF1:$display(" => L_SETUP_MEM");
	8'hF2:$display(" => L_SETUP_MAP");
	8'hF3:$display(" => L_SETUP_FB");
	8'hF4:$display(" => L_SETUP_KEYB");
	default: $display(" => unknown pattern!!!");
      endcase
      //$flushlog;
   end // always @ (leds)

   // CLOCKS
`ifdef CPU_CLK_MULTIPLE_SERIAL
   reg clk20;
   reg clk10;
   initial
     begin
	clk20 = 1'b0;
	clk10 = 1'b0;
     end
   always @(posedge clk40) clk20 <= ~clk20;
   always @(posedge clk20) clk10 <= ~clk10;
   assign C100 = clk10;
   assign C100_n = ~clk10;
`else
   assign C100   =  cpu_clk;
   assign C100_n = ~cpu_clk;
`endif

   // interrupts
   wire 	       INT7_n, INT6_n, INT5_n, INT4_n, INT3_n, INT2_n, INT1_n;
   // interrupts encoding
   ttl_74LS148 irq_encoder(.I_n({INT7_n, INT6_n, INT5_n, INT4_n, INT3_n, INT2_n, INT1_n, 1'b0}),
			  .A_n({IPL2_n, IPL1_n, IPL0_n}),
			  .EI_n(~EN_INT),
			  .EO_n(), // unused output
			  .GS_n() // unused output
			   );
   assign INT1_n = ~EN_INT1;
   // Level 2 carries the software-settable interrupt and whatever MultiBus
   // card is jumpered there.  The Xylogics 450 leaves the factory on INT5/ and
   // Sun rejumpers it to INT2/ -- "priority 2" in conf.sun2/XY100 -- so this
   // is the disk.  With no card mbio_int is tied low and this reduces to what
   // it always was.
   assign INT2_n = ~(EN_INT2 | mbio_int);
   // Level 3 carries both the software-settable interrupt and the on-board
   // Ethernet (Architecture Manual 6.13, "Interrupts: Level 3"); the control
   // register's INTEN gates the latter, and sun2_ether_ctl has already applied
   // it.  A MultiBus machine has no on-board Ethernet, so ether_int is tied low
   // there and this reduces to what it always was.
   assign INT3_n = ~(EN_INT3 | ether_int);
   assign INT4_n = 1'b1; // FIXME
   assign INT5_n = ~timer_int[2] & ~timer_int[3] & ~timer_int[4] & ~timer_int[5];
   assign INT6_n = serial_int_n;
   assign INT7_n = ~timer_int[1];

   //
   // todebug goes to the second LED header on the board
   // (boards/Wukong/wukong_top.sv drives extra_leds0 straight from it), so
   // every bit here has to be a level that stays put or a latched "this has
   // happened at least once".  It used to carry AS, RW, DTACK and a decode
   // match, all of which move at cpu_clk: on an LED that is a dim blur at
   // best, and "too fast to see" cannot be told apart from "never happened",
   // which is the only question worth asking when the front panel is frozen.
   //
   // Read left to right as a ladder.  Bit 7 not blinking: no CPU clock, and
   // nothing else on the header means anything.  Blinking with bit 6 lit:
   // held in reset -- and on a board that is usually init_calib_complete,
   // which wukong_top folds into sys_reset_raw.  Bit 6 out but bit 5 dark:
   // out of reset and the core still never drives AS.  Bit 5 without bit 4:
   // fetching, but never from the boot PROM, so boot-mode decode or the map.
   // Bit 4 without bit 3: the PROM is addressed and nothing ever answers,
   // with bit 2 saying the cycles are timing out.  Bit 3 without bit 1: the
   // machine runs but the diagnostic register write never decodes, which
   // makes the front panel lie rather than the machine be dead.
   //
   // Initialised, not just unreset: a Xilinx register powers up at 0 anyway,
   // but without this it is X in simulation and X + 1 is X for ever, so the
   // heartbeat bit would read as unknown in every board sim -- and an X in a
   // status bit is a bug this project has already paid for twice.
   // Initialised, not just unreset: a Xilinx register powers up at 0 anyway,
   // but without this it is X in simulation and X + 1 is X for ever, so the
   // heartbeat bit would read as unknown in every board sim -- and an X in a
   // status bit is a bug this project has already paid for twice.
   reg [23:0] 	       hb_ctr = 24'h0;
   reg 		       seen_err, seen_diag_wr, seen_stall;
   reg [2:0] 	       fc_err;
   reg [9:0] 	       stall_ctr;

   always @(posedge cpu_clk)
     begin
	// Free-running, and deliberately outside the reset: its job is to say
	// the clock is alive even when the reset never releases.
	hb_ctr <= hb_ctr + 24'd1;

	if (sys_reset)
	  begin
	     seen_err     <= 1'b0;
	     fc_err       <= 3'h0;
	     seen_diag_wr <= 1'b0;
	     seen_stall   <= 1'b0;
	     stall_ctr    <= 10'h0;
	  end
	else
	  begin
	     // The first bus error, and the function code of the cycle that
	     // caused it.  Qualified with ~P_AS_n because PROTERR is
	     // combinational: outside a cycle it re-evaluates against an
	     // address and function code that are not a bus cycle, which is
	     // what produced 23,607 phantom protection violations once.
	     if (~P_AS_n & ERR)
	       begin
		  seen_err <= 1'b1;
		  if (~seen_err) fc_err <= P_FC;   // the *first* one only
	       end

	     // A cycle that never ends.  Main memory is exempt from the
	     // timeout above -- `~MATCH_MEM' in the term that sets TIMEOUT --
	     // so a memory access that never gets DTACK holds AS low for ever
	     // with no bus error and no other trace: the CPU stops mid-cycle
	     // while the clock keeps running, which from outside is
	     // indistinguishable from any other kind of stopped.  The longest
	     // legal cycle ends at C_S24, so 1024 clocks cannot be one.
	     if (P_AS_n)         stall_ctr <= 10'h0;
	     else if (~&stall_ctr) stall_ctr <= stall_ctr + 10'd1;
	     if (&stall_ctr)     seen_stall <= 1'b1;

	     if (WR & MATCH_DIAG & C_S4) seen_diag_wr <= 1'b1;
	  end
     end

   //
   // todebug goes to the second LED header on the board
   // (boards/Wukong/wukong_top.sv drives extra_leds0 straight from it), so
   // every bit here has to be a level that stays put or a latched "this has
   // happened at least once".  A signal that moves at cpu_clk is a blur at
   // best on an LED, and "too fast to see" cannot be told apart from "never
   // happened", which is the only question worth asking when the machine has
   // stopped.
   //
   // Bit 7 not blinking: no CPU clock, and nothing else here means anything.
   // Blinking with bit 6 lit: held in reset, which on a board is usually
   // init_calib_complete, folded into sys_reset_raw by wukong_top.
   //
   // Then the two failure bits, and they are exclusive in practice.  Bit 5
   // says a cycle ended in a bus error, and bits 4..2 carry the function code
   // of the *first* one: 3 is control space -- the context register, segment
   // map, bus error register and enable register that _hardreset writes before
   // it touches anything else -- 5 is supervisor data, which includes the
   // 68010's reset vector fetch, and 6 is an instruction fetch.  Bit 0 says a
   // cycle simply never ended, which is what a memory access that never gets
   // DTACK does, since memory is exempt from the timeout by design.
   //
   // Bit 1 is the milestone the other bits exist to explain: the boot PROM's
   // first write to the diagnostic register, `movsb d0,LEDOFF' in _hardreset
   // (rsun/mon/kernel/trap.s:70).  Until that lands the Sun-2 front panel
   // stays at its reset value whatever the machine is doing.
   //
`ifdef SUN2_ILA
   //
   // The debug bus.  Output-only, so it cannot change what the machine does.
   //
   // Behind the define even so.  It costs nothing at all here -- every signal
   // on it already has a load -- but measured against a build without it, the
   // bare port cost 8 LUTs and moved worst hold slack from 0.071 ns to 0.054
   // ns.  Vivado is byte-deterministic on this design, so that is the port and
   // not run-to-run noise, and hold is the number this build has least of.  An
   // instrument that is switched off has no business spending it.
   //
   // Simulation always defines SUN2_ILA (sim/run_xsim.sh), because there the
   // bus is free and it is what proves the packing.
   //
   // The fields, and why each is here.  SunOS panics creating process 1: the
   // machine reported a protection violation as a bus timeout, and
   // sys/sun2/trap.c reads BE_TIMEOUT as "the MMU was satisfied, the memory
   // system failed", so it never tries to grow the stack.  tools/mmuprobe
   // cannot reproduce it from a boot block, so the question moves to the
   // board: sampled every clock of the failing cycle, does ps_pmap2devices in
   // the C_S8 window match the entry getpgmap reads back afterwards?
   //
   //   73:51  P_A[23:1]          which access
   //   50:48  P_FC               the discriminator -- the kernel's access is
   //                             FC 1, every PROM device probe is FC 5
   //   47:42  AS RW UDS LDS DTACK BERR, all active low as the bus has them
   //   41:38  C_S4 C_S6 C_S8 C_S24    where in the cycle
   //   37:30  ia_smap2pmap       segment map output, lookup stage 1
   //   29:18  ps_pmap2devices    page map protection/status -- the answer
   //   17:6   ma_pmap2devices    page map physical address
   //    5:0   VALID PROTERR_raw PROTERR TIMEOUT ERR MATCH_MEM
   //
   // and, added after a session of inferring all three from bus behaviour:
   //
   //   89:74   the data on the bus -- what the CPU is writing, or what the
   //           machine is returning.  Without it a capture can say a register
   //           was written but not with what, which is the difference between
   //           watching a context switch and knowing which context.
   //   97:90   both context registers, supervisor half then user half.  They
   //           share a word and are written a byte at a time; seeing them
   //           apart is the only way to catch one write moving both.
   //  100:98   the context the segment map was actually indexed with, which
   //           is neither of the above but a choice between them made by
   //           P_FC[2] -- and FC 3, control space, counts as user.
   //
   // MATCH_MEM rather than anything about DVMA, which sun2_fpga cannot see --
   // top_fpga.v muxes the master onto these same wires, deliberately, so that
   // nothing downstream knows DVMA exists.  MATCH_MEM is the term that decides
   // TIMEOUT: memory is exempt from the bus timeout, so it says directly
   // whether the cycle was headed for RAM or was left to time out.
   //
   assign dbg_bus = { cx_dbg,                                      // 100:98
		      ctx_out[11:8], ctx_out[3:0],                //  97:90
		      (P_RW_n ? P_DOUT : P_DIN),                  //  89:74
		      P_A,                                        // 73:51
		      P_FC,                                       // 50:48
		      P_AS_n, P_RW_n, P_UDS_n, P_LDS_n,           // 47:44
		      P_DTACK_n, P_BERR_n,                        // 43:42
		      C_S4, C_S6, C_S8, C_S24,                    // 41:38
		      ia_smap2pmap,                               // 37:30
		      ps_pmap2devices,                            // 29:18
		      ma_pmap2devices,                            // 17:6
		      VALID, PROTERR_raw, PROTERR,                //  5:3
		      TIMEOUT, ERR, MATCH_MEM };                  //  2:0
`endif

   assign todebug = { hb_ctr[23],   // 7    cpu_clk runs at all (~0.75 Hz at 12.5 MHz)
		      sys_reset,    // 6    the machine is still in reset
		      seen_err,     // 5    a cycle ended in a bus error
		      fc_err,       // 4..2 function code of the first such cycle
		      seen_diag_wr, // 1    the PROM wrote the diagnostic register
		      seen_stall }; // 0    a cycle never ended: no DTACK, no timeout

endmodule // sun2_fpga
