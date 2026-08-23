# A standalone HDMI test for the QMTech Wukong V1: the hdl-util/hdmi block, a
# colour-bar pattern, and nothing else.  See README.md for what it settled.
#
#   make            720p60
#   make MODE=1080  1080p60
#   make MODE=1030  1080p30 -- the same 2200x1125 raster, half the clock
#   make MODE=1280  1280x1024 at 60 Hz -- the mode the Sun-2 build settled on
#   make program [MODE=1080]

TOP     := ../..
XILINX_VIVADO ?= /opt/Xilinx/2025.2/Vivado
VIVADO  ?= $(XILINX_VIVADO)/bin/vivado
MODE    ?= 720
OUT     := $(TOP)/build/test-hdmi$(MODE)
BIT     := $(abspath $(OUT))/hdmitest.bit

all: $(BIT)

$(BIT): inputs
	mkdir -p $(OUT)/work
	cd $(OUT)/work && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(abspath build.tcl) -tclargs $(MODE) $(abspath $(OUT))

# The library is patched now -- 1280x1024 is not a CEA mode and had to be added
# -- so this builds the same copy under build/inputs that the Sun-2 does, and
# not Inputs/ directly.  Otherwise the test and the machine would be driving
# two different versions of the block the test exists to vouch for.
inputs:
	$(TOP)/tools/patch_inputs.sh hdmi

program:
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(abspath $(TOP)/syn/program.tcl) -tclargs $(BIT)

clean:
	rm -rf $(TOP)/build/test-hdmi720 $(TOP)/build/test-hdmi1080 \
	       $(TOP)/build/test-hdmi1030 $(TOP)/build/test-hdmi1280

.PHONY: all inputs program clean
