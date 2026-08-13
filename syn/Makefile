# FPGA build for the QMTech Wukong V1.
#
#   make ip                 generate the MIG DDR3 controller from mig/sun2_mig.prj
#   make bitstream          build at the default 12.5 MHz CPU clock
#   make bitstream CPU_HZ=40000000
#   make bitstream MACHINE=vme
#   make bitstream MB_ETHER=1     with the MultiBus Ethernet card
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

IPDIR   = $(TOP)/build/ip/sun2_mig
TAG     = $(if $(filter 1,$(MB_ETHER)),-mbether,)
OUTDIR  = $(TOP)/build/syn/$(MACHINE)$(TAG)-cpu$(shell expr $(CPU_HZ) / 1000000)
WORKDIR = $(TOP)/build/syn/work

all: bitstream

$(WORKDIR):
	mkdir -p $(WORKDIR)

$(IPDIR)/sun2_mig.xci: mig/sun2_mig.prj generate_ip.tcl | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(HERE)/generate_ip.tcl

ip: $(IPDIR)/sun2_mig.xci

# The boot PROM has to exist before synthesis: bootrom.v includes it.
rom:
	$(MAKE) -C $(TOP)/tools

# Immutable inputs that need a patch are copied and patched into build/inputs.
inputs:
	$(TOP)/tools/patch_inputs.sh Wish82586

bitstream: ip rom inputs | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(HERE)/build.tcl -tclargs $(CPU_HZ) $(MACHINE) $(MB_ETHER)
	@echo "bitstream: $(OUTDIR)/sun2_wukong_v1.bit"

both:
	$(MAKE) bitstream CPU_HZ=12500000
	$(MAKE) bitstream CPU_HZ=40000000

clean:
	rm -rf $(TOP)/build/syn

clean-ip:
	rm -rf $(TOP)/build/ip

.PHONY: all ip rom inputs bitstream both clean clean-ip
