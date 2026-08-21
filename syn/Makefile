# FPGA build for the QMTech Wukong, V1 or V3.
#
#   make ip                 generate the MIG DDR3 controller from mig/sun2_mig.prj
#   make bitstream          build at the default 12.5 MHz CPU clock
#   make bitstream CPU_HZ=40000000
#   make bitstream MACHINE=vme
#   make bitstream MB_ETHER=1     with the MultiBus Ethernet card
#   make bitstream BOARD=v3       for a Wukong V3 instead of a V1
#   make bitstream FB=1           with the frame buffer on HDMI
#   make bitstream XY450=1        with the Xylogics 450 disk controller
#   make bitstream CPU=rd68011    with the RD68011 core instead of Suska
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

IPDIR   = $(TOP)/build/ip/$(BOARD)/sun2_mig
TAG     = $(if $(filter 1,$(MB_ETHER)),-mbether,)$(if $(filter 1,$(FB)),-fb,)$(if $(filter 1,$(XY450)),-xy450,)
OUTDIR  = $(TOP)/build/syn/$(BOARD)-$(MACHINE)$(TAG)-cpu$(shell expr $(CPU_HZ) / 1000000)$(if $(filter-out suska,$(CPU)),-$(CPU),)
WORKDIR = $(TOP)/build/syn/work-$(BOARD)

all: bitstream

$(WORKDIR):
	mkdir -p $(WORKDIR)

$(IPDIR)/sun2_mig.xci: mig/sun2_mig.prj generate_ip.tcl | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(HERE)/generate_ip.tcl -tclargs $(BOARD)

ip: $(IPDIR)/sun2_mig.xci

# The boot PROM has to exist before synthesis: bootrom.v includes it.
rom:
	$(MAKE) -C $(TOP)/tools

# Immutable inputs that need a patch are copied and patched into build/inputs.
inputs:
	$(TOP)/tools/patch_inputs.sh Wish82586
	$(TOP)/tools/patch_inputs.sh Wish5380
	$(TOP)/tools/patch_inputs.sh Suska_Configware

bitstream: ip rom inputs | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(HERE)/build.tcl -tclargs $(CPU_HZ) $(MACHINE) $(MB_ETHER) $(BOARD) $(FB) $(XY450) $(CPU)
	@echo "bitstream: $(OUTDIR)/sun2_wukong_$(BOARD).bit"

both:
	$(MAKE) bitstream CPU_HZ=12500000
	$(MAKE) bitstream CPU_HZ=40000000

clean:
	rm -rf $(TOP)/build/syn

clean-ip:
	rm -rf $(TOP)/build/ip

.PHONY: all ip rom inputs bitstream both clean clean-ip
