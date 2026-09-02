# A standalone micro-SD test for the Arrow DECA: blk_sd, a pattern, and a
# write/read/verify walk over an unused part of the card.
#
#   make              build, fit, assemble
#   make program      load it
#   make probe        read the result over JTAG

TOP     := ../..
QUARTUS_ROOTDIR ?= /opt/Altera/quartus
QUARTUS  = QUARTUS_ROOTDIR=$(QUARTUS_ROOTDIR) $(TOP)/syn/altera.sh
OUT     := $(abspath $(TOP))/build/test-deca-sdtest
SOF     := $(OUT)/sdtest.sof

all: $(SOF)

$(SOF):
	$(TOP)/tools/patch_inputs.sh Wish5380
	mkdir -p $(OUT)
	cd $(OUT) && $(QUARTUS) quartus_sh -t $(abspath build.tcl) $(abspath $(TOP)) $(OUT)

program: $(SOF)
	$(QUARTUS) quartus_pgm -c 1 -m jtag -o "p;$(SOF)"

probe:
	$(QUARTUS) quartus_stp -t $(abspath $(TOP))/tools/deca_sdtest_probe.tcl

clean:
	rm -rf $(OUT)

.PHONY: all program probe clean
