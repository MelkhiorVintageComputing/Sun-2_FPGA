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
// The eight on-board device pages sit at a different base on the two machines:
// page 0x000 on MultiBus, 0xFE0 (byte address 0x7F0000) on VME.  Most hold the
// same device in the same slot -- PROM, encryption processor, serial SCC and
// timer are pages 0, 2, 4 and 5 either way -- but pages 1, 3, 6 and 7 do not
// agree, and sun2_fpga instantiates the two that matter (Ethernet at 1,
// keyboard/mouse at 3) only for VME.  This is the first thing the two boot PROMs
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
// it does not recognise.  rtl/sun2-common/idprom.v recomputes the checksum from this, so
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

//---------------------------------------------------------------------
// The MultiBus Ethernet board
//---------------------------------------------------------------------
// A Sun-2 Ethernet card in the MultiBus card cage: an 82586 with its own
// dual-ported memory and its own page map, reached as a MultiBus memory slave.
// Nothing like the VME machine's on-board Ethernet, which DMAs into main
// memory through the CPU's MMU -- see rtl/sun2-multibus/sun2_mb_ether.sv.
//
// Optional, because a 2/120 with no Ethernet card is equally a real machine,
// and it is the one the 23,629-bus-error regression fingerprint describes.
//
// Two windows in the 1 MiB of MultiBus memory space, both jumpered on the real
// card.  The register base is the one the boot PROM knows: ieprobe() only ever
// looks at iestd[0], and that is 0x88000.  The memory window base is ours to
// pick, because the driver reads it back out of the status register rather
// than assuming it -- but it has to avoid everything else the PROM probes, or
// the machine hallucinates hardware:
//
//   0x80000            SCSI
//   0x88000, 0x8C000   this card, controllers 0 and 1
//   0xE0000, 0xE2000   3Com `ec' -- and ecprobe() is just "did it answer?"
//
// The window is naturally aligned, as it is on the card -- F7 compares A19:A16
// with F13 masking A16 and A17 out to choose 64, 128 or 256 KiB -- so a 256 KiB
// window can only start at 0x00000, 0x40000, 0x80000 or 0xC0000.  0x80000
// holds the SCSI and this card's own registers, 0xC0000 reaches up into the
// 3Com, and low memory is where other cards conventionally sit.  That leaves
// 0x40000.
//
//`define SUN2_MB_ETHER

`ifndef MB_ETHER_REG_BASE
 `define MB_ETHER_REG_BASE 20'h88000
`endif

`ifndef MB_ETHER_MEM_BASE
 `define MB_ETHER_MEM_BASE 20'h40000
`endif

// Local memory actually implemented, in KiB, and the size of the MultiBus
// window onto it.  The boot PROM touches only the first 8 KiB (IEPHYMEMSIZ in
// if_ie.c); SunOS uses the full 256 KiB (IEPMEMSIZ in if_mie.h).  Page-map
// entries pointing above what is implemented alias back down.
//
`ifndef MB_ETHER_MEM_KIB
 `define MB_ETHER_MEM_KIB 256
`endif

//---------------------------------------------------------------------
// The station Ethernet address
//---------------------------------------------------------------------
// 8:0:20:1:6:e0.  It lives here rather than in idprom.v because two devices
// now need it: the ID PROM, which is what the PROM and the kernel actually
// read, and the 3C400's address ROM, which the kernel passes to
// localetheraddr().  Two copies of a MAC address would drift, and the way
// that would present is a machine whose boot server hands it the wrong root.
//
// The last byte is overridable, because a boot server picks which root it
// hands out by MAC address: building with a different ETH5 is how one board
// asks for a different operating system.  Given as a plain integer rather than
// 8'hXX so it survives the trip through -verilog_define without quoting.
//
`ifndef SUN2_IDPROM_ETH5
 `define SUN2_IDPROM_ETH5 224
`endif
`ifndef SUN2_IDPROM_ETH_HI
 `define SUN2_IDPROM_ETH_HI 40'h08_00_20_01_06
`endif

//---------------------------------------------------------------------
// The 3Com 3C400 MultiBus Ethernet board
//---------------------------------------------------------------------
// The other MultiBus Ethernet, and the one that fits on a MAX 10.  Where the
// Sun card is an 82586 behind 256 KiB of dual-ported RAM -- 256 M9K on a
// device that has 182, so it cannot be built there at all -- the 3C400 is
// three 2 KiB buffers and two registers in an 8 KiB window, which is 6 M9K.
// See rtl/sun2-multibus/sun2_mb_3c400.sv.
//
// Mutually exclusive with SUN2_MB_ETHER: there is one MII port and both cards
// would drive it.  sun2_fpga.v $fatals on the pair rather than leaving it to
// synthesis to report a multiply-driven net in whatever way it chooses.
//
// The software is already in the tree.  The MultiBus boot PROM probes `ec'
// fifth, right after `ie', and the SunOS 4.0.3 GENERIC kernel this project
// boots carries the whole driver -- _ecprobe, _ecattach, _ecinit, _ecintr,
// _ecoutput, _ecread, _ecstart, _ecreset, _ecdocoll -- so this is a network
// under SunOS and not merely a boot path.
//
// MEBASE is switch-selectable on any 8 KiB boundary; the PROM's ecstd[] is
// { 0xE0000, 0xE2000 }, controllers 0 and 1.  Only controller 0 is fitted, so
// the 0xE2000 probe must still time out -- see the note about a blanket TYPE 2
// decode making the machine hallucinate a 3Com, which is exactly this address.
//
//`define SUN2_MB_3C400

`ifndef MB_3C400_BASE
 `define MB_3C400_BASE 20'hE0000
`endif

//---------------------------------------------------------------------
// The Xylogics 450 disk controller
//---------------------------------------------------------------------
// A Xylogics 450 in the MultiBus card cage, with its four SMD drives replaced
// by one SD card.  See rtl/sun2-multibus/sun2_xy450.sv.
//
// Unlike the Ethernet card, this one is a bus *master*: it fetches its command
// block from memory and moves the data itself, through DVMA -- MultiBus memory
// address X becomes virtual 0xF00000 + X, supervisor data, through the MMU.
// That is the same path rtl/sun2-vme/sun2_dvma.v drives for the 2/50's
// Ethernet, and it is why a MultiBus machine with a disk has a DVMA master
// where it never had one before.
//
// Its registers are six bytes in MultiBus *I/O* space, page-map TYPE 3, which
// is a different space from the TYPE 2 the Ethernet card lives in.  The boot
// PROM knows two addresses and probes both -- 0xEE40 for controller 0 and
// 0xEE48 for controller 1 (msun/mon/prom2/xy.c: `xystd[]`) -- and only one
// controller is built, so the 0xEE48 probe must still time out.
//
// Optional and off by default, like every other card: the 23,629-bus-error
// regression fingerprint describes a 2/120 with an empty cage.
//
//`define SUN2_XY450

//---------------------------------------------------------------------
// The Sun VME SCSI/RTC board
//---------------------------------------------------------------------
// A dual-height VME board carrying SCSI and a battery-backed clock, which is
// how a 2/50 gets a local disk -- its Xylogics equivalent is a 451, a
// different card in a different space.  There is no SCSI protocol chip on it
// at all: the whole interface is discrete TTL and seven PALs, so what software
// sees is a sixteen-byte register file and that is the entire specification.
//
// One 4 KiB decode at VME A24 0x200000, split by A11: SCSI below, the MM58167
// above.  The board does that deliberately so the MMU can protect the two
// separately.
//
// VME only, and off by default like every other card.
//
//`define SUN2_VME_SCSI

//---------------------------------------------------------------------
// Does this build have block media?
//---------------------------------------------------------------------
// Two different controllers reach the same micro-SD slot -- the Xylogics 450
// on a 2/120 and the SCSI board on a 2/50 -- and a board top cares only that
// *something* wants a disk, not which card it is.  Without this the SD back
// end is instantiated under SUN2_XY450 alone, so a SCSI build gets the tie-off
// arm: the card probes correctly, reports itself present, and then finds no
// medium, which reads on a bench as a broken drive rather than as a missing
// wire.
`ifdef SUN2_XY450
 `define SUN2_HAS_DISK
`endif
`ifdef SUN2_VME_SCSI
 `define SUN2_HAS_DISK
`endif

//---------------------------------------------------------------------
// The time-of-day clock's power-up reading
//---------------------------------------------------------------------
// Baked in at build time so a machine with no battery still comes up with a
// plausible date.  Here rather than beside either instantiation because there
// are two: on a 2/120 the MM58167 is soldered to the board and lives in
// sun2_fpga.v, and on a 2/50 it is on the SCSI card and so is instantiated
// from top_fpga.v.  A default that only one of them can see is a clock that
// silently reads January in half the builds.
`ifndef SUN2_RTC_MON
 `define SUN2_RTC_MON  1
`endif
`ifndef SUN2_RTC_DAY
 `define SUN2_RTC_DAY  1
`endif
`ifndef SUN2_RTC_WDAY
 `define SUN2_RTC_WDAY 1
`endif
`ifndef SUN2_RTC_HOUR
 `define SUN2_RTC_HOUR 0
`endif
`ifndef SUN2_RTC_MIN
 `define SUN2_RTC_MIN  0
`endif
`ifndef SUN2_RTC_SEC
 `define SUN2_RTC_SEC  0
`endif

`ifndef VME_SCSI_BASE
 `define VME_SCSI_BASE 24'h200000
`endif

`ifndef XY450_IO_BASE
 `define XY450_IO_BASE 16'hEE40
`endif

//---------------------------------------------------------------------
// The frame buffer
//---------------------------------------------------------------------
// The Sun-2 monochrome frame buffer: 1152x900, one bit per pixel, in a 128 KiB
// aperture, with a video control register.  Both machines have one, and it is
// the same screen with the same drawing code -- mon/dpy/ has no VME
// conditionals anywhere -- but they are different hardware in different places:
//
//   2/50    on-board.  Page-map TYPE 1, pages 0..63 for the pixels and page
//           0x40 for the control register.
//   2/120   a board in the cage, addressed on the P2 bus rather than the
//           MultiBus.  Page-map TYPE 0, the eighth megabyte: pixels at page
//           0xE00 (0x700000), the keyboard/mouse SCC on the same board at
//           0xF00, and the control register at 0xF03 (0x781800).
//
// See rtl/sun2-common/sun2_fb_ctl.v, and MATCH_FB in sun2_fpga.v for the decode.
//
// Optional, and off by default, because it changes what the machine *is* from
// the outside: when s2fbthere() succeeds the boot PROM moves the console to
// the screen and the serial port goes quiet.  That is correct -- it is what a
// Sun-2 with a display does -- but it is not what you want during bring-up, and
// every console regression so far assumes the serial console.
//
// On a MultiBus machine it also decides whether the keyboard/mouse SCC exists
// at all, because that SCC is on the video board: sunmon.c:601 is "On Multibus,
// keyboard can't be there if there's no frame buffer", and the monitor touches
// 0xEEC000 without a bus-error catcher as soon as it has found a display.
//
//`define SUN2_FB

// Where the pixels live in DDR3, as a Wishbone *word* address.
//
// 0x03E00000 words = byte 0x0F800000 = 248 MiB, the start of the top 8 MiB of
// the board's 256 MiB.  The CPU's own memory master can only ever generate
// byte addresses below 8 MiB -- the Sun-2 has nowhere to put a bigger number --
// so the two cannot collide by construction.
//
// 8 MiB for a 128 KiB frame buffer is deliberate room to grow: a colour or
// higher-resolution buffer would still fit.
//
`ifndef FB_WB_BASE
 `define FB_WB_BASE 30'h03E00000
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
// The default is MEM_SPACE_PAGES -- as much memory as the machine's memory
// space can hold -- rather than a number, so each machine gets its own maximum
// rather than the smaller of the two.  A 2/50 has the whole 8 MiB; a 2/120 has
// 7, because its video board decodes from page 0xE00 up and memory may not
// reach it.  Writing 3584 here gave the VME machine a megabyte less than it can
// address, for no reason beyond the constant having been chosen on a MultiBus.
`ifndef MEM_PAGES
 `define MEM_PAGES `MEM_SPACE_PAGES
`endif

`endif // SUN2_CONFIG_VH
