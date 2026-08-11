//
// Compile-time configuration for the Sun-2 replica.
//
// Every option is guarded with `ifndef so it can be forced from the simulator
// or synthesis command line (xelab -d FOO, iverilog -D FOO).  The defaults
// match the last known-working configuration of the design.
//

`ifndef SUN2_CONFIG_VH
`define SUN2_CONFIG_VH

//
// Main memory
// -----------
// By default main memory lives outside sun2_fpga, behind a Wishbone master
// (sun2_wishbone_bridge): 7 MiB, DTACK driven by the Wishbone ack.  That is
// what the FPGA build uses, with LiteDRAM on the other side.
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
// test.  A real Sun-2 typically shipped with 2 or 4 MiB; the PROM is happy
// with as little as 256 KiB, and 7 MiB is the architectural maximum.
//
//   256 KiB = 128     512 KiB = 256     1 MiB = 512
//     2 MiB = 1024      4 MiB = 2048    7 MiB = 3584 (0xE00, the default)
//
// MEM_PAGES only changes what the machine reports as installed; the address
// range that answers on the bus at all (MATCH_MEMX) stays at the 7 MiB
// maximum, so the PROM's sizing still works by reading back wrong values
// rather than by taking a bus error.
//
`ifndef MEM_PAGES
 `define MEM_PAGES 3584
`endif

//
// Device space base page
// ----------------------
// The eight on-board device pages sit at page 0x000 on a MultiBus Sun-2 and at
// 0xFE0 (byte address 0x7F0000) on a VME one; the ordering within them is the
// same.  This is the first thing the two boot PROMs disagree about -- each
// writes a single page-map entry pointing at the timer, page 0x005 or 0xFE5 --
// so a VME PROM on the MultiBus base takes a bus timeout within 50 us.
//
`ifndef DEV_PAGE_BASE
 `define DEV_PAGE_BASE 12'h000
`endif

//
// Boot PROM
// ---------
// BOOTROM_FILE names the generated Verilog `case` body included by bootrom.v.
// Three images are available:
//
//   default        a diagnostic delay loop shortened and the destructive main
//                  memory test skipped (tools/sim_speedup.txt).  Without this,
//                  simulating to the monitor prompt is not practical.  This is
//                  bit-for-bit the image the old working build used, so it is
//                  what full-system validation should run.
//   ROM_FASTBOOT   the same, plus the PROM's RAM initialisation pass shortened
//                  64-fold (tools/sim_fastboot.txt).  Much quicker to boot; do
//                  not use it for memory-related work.
//   ROM_PRISTINE   the PROM exactly as dumped from real hardware.
//
// ROM_SUN250 selects the VME Sun 2/50 PROM instead, unpatched.  The machine
// this design models is a MultiBus 2/120, so that PROM is being run on
// hardware it was not written for; see the notes in README.md.
//
`ifndef BOOTROM_FILE
 `ifdef ROM_PRISTINE
  `define BOOTROM_FILE "bootrom_16bits.vh"
 `elsif ROM_FASTBOOT
  `define BOOTROM_FILE "bootrom_fastboot_16bits.vh"
 `elsif ROM_SUN250
  `define BOOTROM_FILE "bootrom_sun250_16bits.vh"
 `else
  `define BOOTROM_FILE "bootrom_patched_16bits.vh"
 `endif
`endif

`endif // SUN2_CONFIG_VH
