//
// Compile-time configuration for the Sun-2 replica.
//
// Every option is guarded with `ifndef so it can be forced from the simulator
// or synthesis command line (xelab -d FOO, iverilog -D FOO).  The defaults
// match the last known-working configuration of the design.
//

`ifndef SUN2_CONFIG_VH
`define SUN2_CONFIG_VH

//=====================================================================
// Which machine
//=====================================================================
//
// Define one of:
//
//   SUN2_MULTIBUS   a Sun 2/120 or 2/170 -- "Machine Type 1" in the
//                   Architecture Manual, the MultiBus/IEEE-796 implementation.
//                   The default, and the configuration that is known to boot.
//   SUN2_VME        a Sun 2/50 or 2/160 -- "Machine Type 2", the VME/Eurocard
//                   implementation.  Boots as far as probing the I/O bus; the
//                   VME bus and the on-board devices are not implemented.
//
// Everything below that depends on which machine this is derives from that
// choice: where device space lives, how large memory space is, what the ID
// PROM claims, and which boot PROM is compiled in.  Each remains individually
// overridable, so an experiment can still deviate from the machine's defaults.
//
`ifndef SUN2_VME
 `ifndef SUN2_MULTIBUS
  `define SUN2_MULTIBUS
 `endif
`endif

`ifdef SUN2_VME
 `define SUN2_MACHINE_NAME "Sun-2/50 or 2/160 (VME, Machine Type 2)"
`else
 `define SUN2_MACHINE_NAME "Sun-2/120 or 2/170 (MultiBus, Machine Type 1)"
`endif

//---------------------------------------------------------------------
// Device space base page
//---------------------------------------------------------------------
// The eight on-board device pages hold the same devices in the same order on
// both buses, but at a different base: page 0x000 on MultiBus, 0xFE0 (byte
// address 0x7F0000) on VME.  This is the first thing the two boot PROMs
// disagree about -- each writes a single page-map entry pointing at the timer,
// page 0x005 or 0xFE5 -- so a PROM run against the wrong base takes a bus
// timeout within 50 us and double-faults.
//
// Plain decimal, so it survives being passed through make and the shell:
// 0 = 0x000, 4064 = 0xFE0.
//
`ifndef DEV_PAGE_BASE
 `ifdef SUN2_VME
  `define DEV_PAGE_BASE 4064
 `else
  `define DEV_PAGE_BASE 0
 `endif
`endif

//---------------------------------------------------------------------
// Size of memory space
//---------------------------------------------------------------------
// How much of memory space answers on the bus at all, in 2 KiB pages, whether
// or not memory is installed there.  Deliberately larger than MEM_PAGES: the
// boot PROM sizes memory by writing and reading back, and needs an
// out-of-range access to return the wrong value rather than take a bus error,
// so the addressable range has to cover everything it will probe.
//
// The Architecture Manual's Type 0 assignments give 1..4 MiB for Machine
// Type 1 and 1..8 MiB for Machine Type 2.  3584 (0xE00, 7 MiB) is what the
// MultiBus design has always used -- more than the manual's 4 MiB, and left
// alone because it is the configuration that boots.  The 2/50 PROM probes at
// exactly 7 MiB, one page past that, so VME needs the full 4096.
//
// Plain decimal, not a sized literal: 12'h1000 would truncate to zero in a
// 12-bit comparison and make nothing addressable.
//
`ifndef MEM_SPACE_PAGES
 `ifdef SUN2_VME
  `define MEM_SPACE_PAGES 4096
 `else
  `define MEM_SPACE_PAGES 3584
 `endif
`endif

//---------------------------------------------------------------------
// ID PROM machine type
//---------------------------------------------------------------------
// 1 = MultiBus, 2 = VME.  A boot PROM prints "ID PROM INVALID" for anything
// it does not recognise.  rtl/idprom.v recomputes the checksum from this, so
// the two cannot fall out of step.
//
`ifndef IDPROM_MACHINE_TYPE
 `ifdef SUN2_VME
  `define IDPROM_MACHINE_TYPE 2
 `else
  `define IDPROM_MACHINE_TYPE 1
 `endif
`endif

//---------------------------------------------------------------------
// Boot PROM
//---------------------------------------------------------------------
// BOOTROM_FILE names the generated Verilog `case` body included by bootrom.v.
// By default it is this machine's own PROM, with the two speedups applied
// (tools/sim_speedup*.txt): a diagnostic delay loop shortened, and the
// destructive main memory test jumped over.  Without those, simulating to the
// monitor prompt is not practical.
//
// The MultiBus default is bit-for-bit the image the last known-working build
// used, which is what full-system validation should run.
//
//   ROM_PRISTINE   this machine's PROM exactly as dumped from hardware
//   ROM_FASTBOOT   MultiBus only: additionally shortens the PROM's RAM
//                  initialisation pass 64-fold.  Much quicker to boot; not for
//                  memory-related work.
//
`ifndef BOOTROM_FILE
 `ifdef SUN2_VME
  `ifdef ROM_PRISTINE
   `define BOOTROM_FILE "bootrom_sun250_16bits.vh"
  `else
   `define BOOTROM_FILE "bootrom_sun250_patched_16bits.vh"
  `endif
 `else
  `ifdef ROM_PRISTINE
   `define BOOTROM_FILE "bootrom_16bits.vh"
  `elsif ROM_FASTBOOT
   `define BOOTROM_FILE "bootrom_fastboot_16bits.vh"
  `else
   `define BOOTROM_FILE "bootrom_patched_16bits.vh"
  `endif
 `endif
`endif

//=====================================================================
// Independent of which machine
//=====================================================================

//
// Main memory
// -----------
// By default main memory lives outside sun2_fpga, behind a Wishbone master
// (sun2_wishbone_bridge), with DTACK driven by the Wishbone ack.  That is what
// the FPGA build uses, with DDR3 on the other side.
//
// Defining MEM_SIM_ONLY instead instantiates a 512 KiB synchronous SRAM inside
// sun2_fpga and drives DTACK from the fixed bus timing.  Smaller and simpler,
// but a different DTACK path -- useful as a cross-check, not as the reference.
//
//`define MEM_SIM_ONLY

//
// How much memory is "physically installed", in 2 KiB pages.  The boot PROM
// sizes memory by probing, so this is what it will find and then walk during
// its setup pass -- and that walk is the single most expensive thing in a
// simulated boot, so turn it down when the memory size is not what is under
// test.  A real Sun-2 typically shipped with 2 or 4 MiB, and the PROM is happy
// with as little as 256 KiB.
//
//   256 KiB = 128     512 KiB = 256     1 MiB = 512
//     2 MiB = 1024      4 MiB = 2048    7 MiB = 3584    8 MiB = 4096
//
// This only changes what the machine reports as installed; MEM_SPACE_PAGES is
// what answers on the bus, so the PROM's sizing still works by reading back
// wrong values rather than by taking a bus error.
//
`ifndef MEM_PAGES
 `define MEM_PAGES 3584
`endif

`endif // SUN2_CONFIG_VH
