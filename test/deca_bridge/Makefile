# A standalone bridge->DDR3 test for the Arrow DECA: BrianHG's controller, the board's
# own DDR3, and a write/read/verify walk.  See README.md.
#
#   make              build, fit, assemble
#   make program      load it
#   make probe        read the result over JTAG

TOP     := ../..
QUARTUS_ROOTDIR ?= /opt/Altera/quartus
QUARTUS  = QUARTUS_ROOTDIR=$(QUARTUS_ROOTDIR) $(TOP)/syn/altera.sh
OUT     := $(abspath $(TOP))/build/test-deca-bridge
SOF     := $(OUT)/bridge_test.sof

all: $(SOF)

$(SOF):
	mkdir -p $(OUT)
	cd $(OUT) && $(QUARTUS) quartus_sh -t $(abspath build.tcl) $(abspath $(TOP)) $(OUT)

program: $(SOF)
	$(QUARTUS) quartus_pgm -c 1 -m jtag -o "p;$(SOF)"

probe:
	$(QUARTUS) quartus_stp -t $(abspath $(TOP))/tools/deca_bridge_probe.tcl

clean:
	rm -rf $(OUT)

.PHONY: all program probe clean
