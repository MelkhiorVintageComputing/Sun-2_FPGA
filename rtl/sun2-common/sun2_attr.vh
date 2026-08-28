`ifndef SUN2_ATTR_VH
`define SUN2_ATTR_VH
//
// Two synthesis tools, two spellings, one copy of the RTL.
//
// Vivado reads `ram_style` and ignores `ramstyle`; Quartus reads `ramstyle` and
// ignores `ram_style`.  Neither complains loudly about the one it does not
// know -- an unrecognised attribute is a declined optimisation, which looks
// from the outside exactly like an attribute that did nothing.  This project
// has been bitten repeatedly by that shape of silence (a define that reached
// nothing, a port left off an instantiation, a knob that never reached the
// logic it named), so the spelling is chosen here, once, per tool.
//
// The payoff is that a typo becomes a *missing macro* -- a hard elaboration
// error in both tools -- rather than an attribute that is silently dropped.
//
// syn/quartus.tcl defines SUN2_QUARTUS; nothing else does.
//
// On ASYNC_REG: Quartus has no per-register equivalent, and the honest answer
// is that it does not need one here -- Quartus Lite does no register retiming
// by default, so a two-flop synchroniser survives as written.  What does the
// real work is the global SYNCHRONIZER_IDENTIFICATION assignment in
// quartus.tcl plus set_clock_groups -asynchronous in the SDC.  The macro
// exists so that both arms name the intent at the same place in the source,
// and so there is somewhere obvious to put the next vendor.
//
`ifdef SUN2_QUARTUS
 `define SUN2_RAM_BLOCK (* ramstyle = "M9K" *)
 `define SUN2_ASYNC_REG
`else
 `define SUN2_RAM_BLOCK (* ram_style = "block" *)
 `define SUN2_ASYNC_REG (* ASYNC_REG = "TRUE" *)
`endif

`endif // SUN2_ATTR_VH
