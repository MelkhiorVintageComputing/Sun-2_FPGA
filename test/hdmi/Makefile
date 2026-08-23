# A standalone HDMI test for the QMTech Wukong V1: the hdl-util/hdmi block, a
# colour-bar pattern, and nothing else.  See README.md for what it settled.
#
#   make            720p60
#   make MODE=1080  1080p60
#   make program [MODE=1080]

TOP     := ../..
XILINX_VIVADO ?= /opt/Xilinx/2025.2/Vivado
VIVADO  ?= $(XILINX_VIVADO)/bin/vivado
MODE    ?= 720
OUT     := $(TOP)/build/test-hdmi$(MODE)
BIT     := $(abspath $(OUT))/hdmitest.bit

all: $(BIT)

$(BIT):
	mkdir -p $(OUT)/work
	cd $(OUT)/work && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(abspath build.tcl) -tclargs $(MODE) $(abspath $(OUT))

program:
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -nolog \
		-source $(abspath $(TOP)/syn/program.tcl) -tclargs $(BIT)

clean:
	rm -rf $(TOP)/build/test-hdmi720 $(TOP)/build/test-hdmi1080

.PHONY: all program clean
