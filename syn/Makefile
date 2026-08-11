# FPGA build for the QMTech Wukong V1.
#
#   make ip                 generate the MIG DDR3 controller from mig/sun2_mig.prj
#   make bitstream          build at the default 12.5 MHz CPU clock
#   make bitstream CPU_HZ=40000000
#   make bitstream MACHINE=vme
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

IPDIR   = $(TOP)/build/ip/sun2_mig
OUTDIR  = $(TOP)/build/syn/$(MACHINE)-cpu$(shell expr $(CPU_HZ) / 1000000)
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

bitstream: ip rom | $(WORKDIR)
	cd $(WORKDIR) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(HERE)/build.tcl -tclargs $(CPU_HZ) $(MACHINE)
	@echo "bitstream: $(OUTDIR)/sun2_wukong_v1.bit"

both:
	$(MAKE) bitstream CPU_HZ=12500000
	$(MAKE) bitstream CPU_HZ=40000000

clean:
	rm -rf $(TOP)/build/syn

clean-ip:
	rm -rf $(TOP)/build/ip

.PHONY: all ip rom bitstream both clean clean-ip
