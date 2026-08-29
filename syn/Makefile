# FPGA build for the QMTech Wukong, V1 or V3.
#
#   make ip                 generate the MIG DDR3 controller from mig/sun2_mig.prj
#   make ip-ila             generate the ILA (seconds, unlike MIG)
#   make bitstream          build at the default 12.5 MHz CPU clock
#   make bitstream CPU_HZ=40000000
#   make bitstream MACHINE=vme
#   make bitstream MB_ETHER=1     with the MultiBus Ethernet card
#   make bitstream BOARD=v3       for a Wukong V3 instead of a V1
#   make bitstream FB=1           with the frame buffer on HDMI
#   make bitstream XY450=1        with the Xylogics 450 disk controller
#   make bitstream CPU=rd68011    with the RD68011 core instead of Suska
#   make bitstream ILA=1          with the ILA on the MMU debug bus
#   make program                  put the built bitstream on the board
#   make hw                       ... and leave the Hardware Manager open on it
#   make both               both CPU clocks
#
# Nothing here is committed; everything lands in ../build.  Vivado is run from
# a scratch directory rather than from here, because it drops .Xil/ and
# clockInfo.txt wherever it is invoked and those do not belong in the source
# tree.

TOP     = ..
HERE   := $(CURDIR)
# Same default as sim/run_xsim.sh, so neither flow needs Vivado's settings64.sh
# to have been sourced.  Override XILINX_VIVADO for another install, or VIVADO
# to point straight at the binary.
XILINX_VIVADO ?= /opt/Xilinx/2025.2/Vivado
VIVADO        ?= $(XILINX_VIVADO)/bin/vivado
CPU_HZ  ?= 12500000

# multibus (a 2/120, the default) or vme (a 2/50).  See "Which machine" in the
# README: the whole machine-dependent configuration follows from this.
MACHINE ?= multibus

# Fit the Sun-2 Ethernet card in the MultiBus cage.  MultiBus only.
MB_ETHER ?= 0

# Fit the frame buffer and its HDMI output.  Either machine.
FB ?= 0

# Fit the Xylogics 450 disk controller.  MultiBus only.
XY450 ?= 0

# Which QMTech Wukong revision: v1 or v3.  They share all their RTL and differ
# in the FPGA speed grade and four pins -- see syn/boards.tcl.  The default
# stays v1 so every result verified against it keeps its meaning; a V3 is what
# you can actually buy.
BOARD ?= v1

# Which MC68010.  `suska' is the VHDL core the machine is developed and
# measured against; `rd68011' is the SystemVerilog core in Inputs/RD68011,
# which top_fpga.v instantiates as the alternative under SUN2_CPU_RD68011.
# It gets its own output directory, so a result from one core can never be
# mistaken for a build with the other.  Neither is a reference for the other.
CPU ?= suska

# Fit the integrated logic analyser on the MMU's debug bus.  Off by default and
# in its own output directory: a bitstream with a debug hub in it is a
# different artefact, and BRINGUP.md explains when it is worth building one.
ILA ?= 0

# The video mode.  On this part that is a question about the TMDS serial clock:
# 1080p60 asks a global buffer rated for 628 MHz to carry 742, which works with
# little else in the die and does not work in the full machine.  1280x1024 is
# the mode that fits the Sun-2's 1152x900 screen inside every rating.
#
#   1280x1024  the default: 108.125 / 540.625 MHz, VESA DMT, every clock
#              inside its rating, and 1152x900 fits with a 64x62 border.
#   1080p60    what the board is wired for and what does NOT work in the full
#              design -- 742 MHz past a BUFG's 628.  Needs ALLOW_PW=1.
#   1080p30    the 1080p60 raster at half the clock; many sinks reject 30 Hz.
#   720p60     half the clock at a raster more sinks take.  FBDEBUG=1 only.
#
HDMI_MODE ?= 1280x1024

# Drive the display from a test pattern instead of the frame buffer, and put
# the video domain on the LED header.  Needs FB=1.  See test/hdmi/README.md.
FBDEBUG ?= 0

# Drive the real display, but put the path to it on the LED header: DISPEN, the
# DDR3 fetch, its answer, whether that answer was non-zero, and whether a
# non-black pixel came out.  For a black screen the monitor is happy to sync
# on.  Needs FB=1, and is exclusive with FBDEBUG.
FBPROBE ?= 0

# Tie the scan-out's DISPEN high, leaving the video control register alone.
# Answers "is everything past DISPEN sound?" on its own.  Needs FB=1.
FBFORCE ?= 0

# Build even though a clock exceeds the rating of the resource carrying it.
# 1080p60's TMDS clock does, by 245 ps on the BUFG, and works on the bench --
# test/hdmi is the evidence.  Off by default so it has to be chosen.
ALLOW_PW ?= 0

# Where hw_server is listening for the JTAG cable.  localhost:3121 is a local
# one; override for a board on another machine.
HW_URL ?= localhost:3121

IPDIR   = $(TOP)/build/ip/$(BOARD)/sun2_mig
ILADIR  = $(TOP)/build/ip/$(BOARD)/sun2_ila
# The last byte of the ID PROM Ethernet address, in hex.  e0 is the identity
# this project has always had; anything else gets its own output directory, so
# two identities can exist side by side without one overwriting the other.
# Name the MMCM's CPU divider directly, when the frequency you want is not a
# whole number of hertz.  CPU_DIV=51 is VCO/51 = 19.607843 MHz, which no
# integer CPU_HZ can express.  Empty means "derive it from CPU_HZ", the old
# behaviour.  The output directory is tagged with the divider, because two
# builds at "cpu19" could otherwise mean different clocks.
CPU_DIV ?=

# The clock that will actually exist.  CPU_DIV wins over CPU_HZ in
# wukong_clkgen.sv, and build.tcl derives cpu_hz the same way -- both copies of
# the OUTDIR rule below have to agree or make reports one directory while
# Vivado writes another, which is how a working bitstream got overwritten once.
CPU_HZ_EFF = $(if $(CPU_DIV),$(shell expr 1000000000 / $(CPU_DIV)),$(CPU_HZ))

# ... and the tag that names it, in MHz with one decimal where there is one.
# Truncating to whole MHz collides: VCO/51 is 19.607843 MHz and VCO/52 is
# 19.230769, and both used to read `cpu19'.  The -div suffix disambiguated
# them, but the frequency in the name was then worse than useless.  A whole
# number keeps its old spelling, so cpu20 and cpu40 are unchanged; 12.5 MHz
# becomes cpu12.5, which is what it always should have said.
# build.tcl computes this the same way -- the two must agree.
CPU_MHZ_TAG = $(shell h=$(CPU_HZ_EFF); i=$$(( $$h / 1000000 )); \
                      f=$$(( ($$h % 1000000) / 100000 )); \
                      if [ $$f -eq 0 ]; then echo $$i; else echo $$i.$$f; fi)

ETH5   ?= e0
ETH5_D  = $(shell printf '%d' 0x$(ETH5))

TAG     = $(if $(filter 1,$(MB_ETHER)),-mbether,)$(if $(filter 1,$(FB)),-fb,)$(if $(filter 1,$(XY450)),-xy450,)
OUTDIR  = $(TOP)/build/syn/$(BOARD)-$(MACHINE)$(TAG)-cpu$(CPU_MHZ_TAG)$(if $(filter-out suska,$(CPU)),-$(CPU),)$(if $(filter 1,$(ILA)),-ila,)$(if $(filter 1,$(FB)),-$(HDMI_MODE),)$(if $(filter 1,$(FBDEBUG)),-fbdbg,)$(if $(filter 1,$(FBPROBE)),-fbprobe,)$(if $(filter 1,$(FBFORCE)),-fbforce,)$(if $(filter-out e0,$(ETH5)),-eth$(ETH5),)$(if $(CPU_DIV),-div$(CPU_DIV),)
# Absolute, because the recipes below run Vivado from $(WORKDIR) and $(OUTDIR)
# is relative to here: a relative path resolves against the wrong directory and
# program.tcl reports a bitstream that was never at that address.
BIT     = $(abspath $(OUTDIR))/sun2_wukong_$(BOARD).bit
LTX     = $(if $(filter 1,$(ILA)),$(abspath $(OUTDIR))/sun2_wukong_$(BOARD).ltx,)
WORKDIR = $(TOP)/build/syn/work-$(BOARD)

all: bitstream

$(WORKDIR):
	mkdir -p $(WORKDIR)

$(IPDIR)/sun2_mig.xci: mig/sun2_mig.prj generate_ip.tcl | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(HERE)/generate_ip.tcl -tclargs $(BOARD)

ip: $(IPDIR)/sun2_mig.xci

# Its own target, and its own recipe argument: `make ip' is keyed on the MIG
# .xci and would not notice this one.  Generating the ILA takes seconds where
# MIG takes minutes, so keeping them separable is worth the extra target.
$(ILADIR)/sun2_ila.xci: generate_ip.tcl | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(HERE)/generate_ip.tcl -tclargs $(BOARD) ila

ip-ila: $(ILADIR)/sun2_ila.xci

# The boot PROM has to exist before synthesis: bootrom.v includes it.
rom:
	$(MAKE) -C $(TOP)/tools

# Immutable inputs that need a patch are copied and patched into build/inputs.
inputs:
	$(TOP)/tools/patch_inputs.sh Wish82586
	$(TOP)/tools/patch_inputs.sh Wish5380
	$(TOP)/tools/patch_inputs.sh Suska_Configware
	$(TOP)/tools/patch_inputs.sh hdmi
	$(TOP)/tools/patch_inputs.sh z8530_scc

bitstream: ip rom inputs $(if $(filter 1,$(ILA)),ip-ila,) | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(HERE)/build.tcl -tclargs $(CPU_HZ) $(MACHINE) $(MB_ETHER) $(BOARD) $(FB) $(XY450) $(CPU) $(ILA) $(HDMI_MODE) $(FBDEBUG) $(ALLOW_PW) $(FBPROBE) $(FBFORCE) $(ETH5_D) $(if $(CPU_DIV),$(CPU_DIV),0)
	@echo "bitstream: $(BIT)"

# Programming.  Same knobs as bitstream, so `make program ILA=1 CPU=rd68011
# MB_ETHER=1' puts on the board exactly what the matching build produced --
# there is no separate place to say which artefact is meant.
program: | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(HERE)/program.tcl -tclargs $(BIT) "$(LTX)" $(HW_URL)

# The ILA session: program, then leave the Hardware Manager open on the device
# to set triggers, arm and capture.
hw: | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode gui \
		-source $(HERE)/program.tcl -tclargs $(BIT) "$(LTX)" $(HW_URL)

# --- the Altera path ------------------------------------------------------
#
# One makefile rather than two, because CPU_HZ, MACHINE, CPU, ETH5 and RTC_DATE
# mean the same thing on both boards and a second copy of them is exactly the
# knob-drift this project has been bitten by three times.  The *targets* are
# disjoint, which is the same shape Inputs/RD68011/Makefile uses for its two
# vendors: Vivado keeps ip/bitstream/program/hw, Quartus gets its own names.
#
#   make lint-quartus       read the RTL with Quartus, no board, no fit
#   make quartus            full fit, timing and assembly for the DECA
#   make quartus-eram-delta the measurement that proves the ERAM assignment
#
QUARTUS_ROOTDIR ?= /opt/Altera/quartus
QUARTUS  = QUARTUS_ROOTDIR=$(QUARTUS_ROOTDIR) $(HERE)/altera.sh
AJOBS   ?= 8
# 2 KiB pages of main memory.  3584 = 7 MiB, the Sun-2's architectural maximum
# and what the VME reference machine reports.
#
# It was 32 (64 KiB) while main memory was on-chip M9K, which was enough to
# reach the monitor prompt -- measured, the PROM gets there in 32 KiB -- and not
# enough to netboot, because the boot loader's buffer is at 0x0a0462, 640 KiB
# up.  With the board's DDR3 behind the Wishbone port that limit is gone, and
# the machine can be the size a real one was.
MEM_PAGES ?= 3584
ERAM      ?= 1
QSTAGE    ?= map
QTOPENT   ?= top
QSEED    ?= 0
# The seed is part of the directory name for the reason MEM_LATENCY is not, and
# should have been: two builds that differ only in a knob absent from the name
# share a directory and clobber each other, which is exactly the comparison the
# knob was added to make.
QDIR = $(abspath $(TOP))/build/quartus/$(BOARD)-$(MACHINE)-$(CPU)-p$(MEM_PAGES)-cpu$(CPU_MHZ_TAG)-$(QTOPENT)$(if $(filter 0,$(ERAM)),-noeram,)$(if $(filter 0,$(QSEED)),,-seed$(QSEED))

quartus-run: rom inputs
	@# A port left off an instantiation is an undriven wire, not an error --
	@# that is how fb_video_en spent the frame buffer's whole life at zero.
	@# One mechanical diff, one second, every build.
	@if [ "$(QTOPENT)" != "top" ]; then \
		$(TOP)/tools/portcheck.sh $(TOP)/rtl/sun2-common/top_fpga.v top \
			$(TOP)/boards/DECA/deca_top.sv || exit 1; fi
	@mkdir -p $(QDIR)
	cd $(QDIR) && $(QUARTUS) quartus_sh -t $(HERE)/quartus.tcl \
		-root $(abspath $(TOP)) -board $(BOARD) -machine $(MACHINE) \
		-cpu $(CPU) -topent $(QTOPENT) -stage $(QSTAGE) \
		-mem_pages $(MEM_PAGES) -cpu_hz $(CPU_HZ) \
		-cpu_div $(if $(CPU_DIV),$(CPU_DIV),0) -eth5 $(ETH5_D) \
		-eram $(ERAM) -jobs $(AJOBS) -seed $(QSEED) > $(QDIR)/quartus.log 2>&1 || \
		{ echo "== FAILED, tail of $(QDIR)/quartus.log =="; tail -40 $(QDIR)/quartus.log; exit 1; }
	@grep -E '^== ' $(QDIR)/quartus.log
	@# An implicit net is a mis-parse, not a style point.  Vivado's equivalent
	@# (Synth 8-6901) is promoted to an error in build.tcl for the same reason:
	@# a new term that silently becomes an undriven one-bit wire is how the
	@# frame buffer's timeout exemption once reached a board dead.
	@if grep -q 'Verilog HDL warning.*implicit net' $(QDIR)/quartus.log; then \
		echo "ERROR: implicit nets -- that is a mis-parse, not a style point:"; \
		grep 'implicit net' $(QDIR)/quartus.log | head; exit 1; fi
	@# sram_sync is read-first and sun2_mmu.v:77 depends on it.  M9K has no
	@# native read-first in single-port mode, so if Quartus says it changed
	@# the behaviour rather than adding bypass logic, the MMU is wrong.
	@if grep -qi 'read-during-write' $(QDIR)/quartus.log; then \
		echo "NOTE: read-during-write comments (check smap/datamap/protmap):"; \
		grep -i 'read-during-write' $(QDIR)/quartus.log | head; fi

lint-quartus:
	$(MAKE) quartus-run QSTAGE=map QTOPENT=top BOARD=deca MACHINE=$(MACHINE) CPU=rd68011

quartus:
	$(MAKE) quartus-run QSTAGE=asm QTOPENT=deca_top BOARD=deca MACHINE=$(MACHINE) CPU=rd68011

# The measurement, not the assumption.  INTERNAL_FLASH_UPDATE_MODE has no
# warning when it is missing -- the ROM just becomes logic -- so the only way
# to know it is doing anything is to build both ways and compare memory bits.
quartus-eram-delta:
	$(MAKE) quartus-run QSTAGE=map ERAM=0
	$(MAKE) quartus-run QSTAGE=map ERAM=1
	@echo "=== without ERAM ==="; $(TOP)/tools/quartus_report.py $(QDIR)-noeram || true
	@echo "=== with ERAM ===";    $(TOP)/tools/quartus_report.py $(QDIR) || true

both:
	$(MAKE) bitstream CPU_HZ=12500000
	$(MAKE) bitstream CPU_HZ=40000000

clean:
	rm -rf $(TOP)/build/syn

clean-ip:
	rm -rf $(TOP)/build/ip

.PHONY: all ip ip-ila rom inputs bitstream both program hw clean clean-ip \
	quartus-run lint-quartus quartus quartus-eram-delta
