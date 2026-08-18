// EXPERIMENTAL -- not part of either machine.
//
// A pin-compatible stand-in for Suska's WF68K10_TOP, implemented with the
// RD68011 core from ../RD68011.  Compiling this instead of the Suska VHDL swaps
// the CPU out from under the Sun-2 without touching a single line of the
// machine: top_fpga.v still instantiates `WF68K10_TOP' and cannot tell.
//
// That is the point.  RD68011 is early and its microcode "is not yet much",
// so nothing it does should be allowed to influence the Sun-2, whose MultiBus
// and VME builds are a working reference measured to the bus error.  A
// separate copy of top_fpga.v would have been the obvious way to do this and
// is the wrong one: 565 lines duplicated, drifting the moment either side is
// touched, and every later fix applied to one of them.  A shim is 60 lines and
// cannot drift, because the machine it plugs into is the same file the real
// build uses.
//
// ---------------------------------------------------------------------------
// Where the two cores disagree
// ---------------------------------------------------------------------------
// RD68011 splits every three-state pin into _i / _o / _oe (doc/pinout.md);
// Suska exposes DATA_EN and one BUS_EN covering "ADR, ASn, UDSn, LDSn, RWn,
// RMCn and FC".  So BUS_EN comes from a_oe and DATA_EN from d_oe.
//
// VPA is the interesting one.  A real 68010 has a single VPA pin doing two
// jobs -- 6800-style peripheral cycles, and autovectoring an interrupt
// acknowledge -- and RD68011 models the real pin.  Suska splits them into VPAn
// and AVECn, which is why top_fpga.v puts the Sun-2's VPA on AVECn and ties
// VPAn high (there are no 6800 peripherals on a Sun-2, and asserting VPAn
// there would start an E/VMA cycle).  Recombining is just the AND of the two
// active-low inputs, which with VPAn tied high is AVECn alone -- so the Sun-2
// autovectors exactly as it means to.
//
// RMCn and DBENn have no equivalent and are tied deasserted.  top_fpga.v
// leaves both unused, so this loses nothing.
//
// rst_n is not an MC68010 pin at all -- it is RD68011's asynchronous init --
// and takes the board reset, the same signal Suska sees as RESET_INn.
//
// The open-drain outputs inverve: RD68011 gives an _oe that means "driving
// low", Suska gives a level.  RESET_OUT is active high in Suska's naming, so
// it is reset_n_oe directly; HALT_OUTn is active low, so it is the inverse.
//
module WF68K10_TOP (
    input  wire        CLK,

    // Address and data
    output wire [31:0] ADR_OUT,
    input  wire [15:0] DATA_IN,
    output wire [15:0] DATA_OUT,
    output wire        DATA_EN,

    // System control
    input  wire        BERRn,
    input  wire        RESET_INn,
    output wire        RESET_OUT,
    input  wire        HALT_INn,
    output wire        HALT_OUTn,

    // Processor status
    output wire  [2:0] FC_OUT,

    // Interrupt control
    input  wire        AVECn,
    input  wire  [2:0] IPLn,

    // Asynchronous bus control
    input  wire        DTACKn,
    output wire        ASn,
    output wire        RWn,
    output wire        RMCn,
    output wire        UDSn,
    output wire        LDSn,
    output wire        DBENn,
    output wire        BUS_EN,

    // Synchronous peripheral control
    output wire        E,
    output wire        VMAn,
    output wire        VMA_EN,
    input  wire        VPAn,

    // Bus arbitration control
    input  wire        BRn,
    output wire        BGn,
    input  wire        BGACKn,

    // Other controls
    input  wire        K6800n
);

   wire [23:1] a_o;
   wire        a_oe, d_oe, as_oe, rw_oe, ds_oe, fc_oe;
   wire        reset_n_o, reset_n_oe, halt_n_o, halt_n_oe;

   rd68011_top u_cpu (
       .clk        (CLK),
       .rst_n      (RESET_INn),      // async init; not a 68010 pin

       .a_o        (a_o),
       .a_oe       (a_oe),

       .d_i        (DATA_IN),
       .d_o        (DATA_OUT),
       .d_oe       (d_oe),

       .as_n_o     (ASn),
       .as_oe      (as_oe),
       .rw_o       (RWn),
       .rw_oe      (rw_oe),
       .uds_n_o    (UDSn),
       .lds_n_o    (LDSn),
       .ds_oe      (ds_oe),
       .dtack_n_i  (DTACKn),

       .br_n_i     (BRn),
       .bg_n_o     (BGn),
       .bgack_n_i  (BGACKn),

       .ipl_n_i    (IPLn),

       .berr_n_i   (BERRn),
       .reset_n_i  (RESET_INn),
       .reset_n_o  (reset_n_o),
       .reset_n_oe (reset_n_oe),
       .halt_n_i   (HALT_INn),
       .halt_n_o   (halt_n_o),
       .halt_n_oe  (halt_n_oe),

       // one real pin doing both of Suska's jobs -- see the header
       .e_o        (E),
       .vpa_n_i    (AVECn & VPAn),
       .vma_n_o    (VMAn),
       .vma_oe     (VMA_EN),

       .fc_o       (FC_OUT),
       .fc_oe      (fc_oe)
   );

   // Suska hands the machine a 32-bit address; the Sun-2 uses [23:1] of it.
   assign ADR_OUT   = {8'h00, a_o, 1'b0};

   // Suska's BUS_EN covers address, strobes, RW and FC together; RD68011 has
   // one enable per group.  They are asserted and released together, so the
   // address enable stands for all of them.
   assign BUS_EN    = a_oe;
   assign DATA_EN   = d_oe;

   assign RESET_OUT = reset_n_oe;     // open drain: driving low == asserted
   assign HALT_OUTn = ~halt_n_oe;

   assign RMCn      = 1'b1;           // no equivalent; unused by top_fpga.v
   assign DBENn     = 1'b1;

   // Silence unused: these exist so the port list matches Suska's exactly.
   wire _unused = &{1'b0, K6800n, as_oe, rw_oe, ds_oe, fc_oe,
                    reset_n_o, halt_n_o, 1'b0};

endmodule
