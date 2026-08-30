# A standalone HDMI test for the Arrow DECA: the pixel PLL, the raster, the
# ADV7513 setup and a test pattern.  No Sun-2 at all.  See README.md.
#
#   make                    build it
#   make CLK_INVERT=0       send the pixel clock uninverted (see below)
#   make program            put it on the board

TOP     := ../..
QUARTUS_ROOTDIR ?= /opt/Altera/quartus
QUARTUS  = QUARTUS_ROOTDIR=$(QUARTUS_ROOTDIR) $(TOP)/syn/altera.sh
CLK_INVERT ?= 1
OUT     := $(abspath $(TOP))/build/test-deca-hdmi$(if $(filter 0,$(CLK_INVERT)),-noinv,)
SOF     := $(OUT)/hdmi_test.sof

all: $(SOF)

$(SOF):
	mkdir -p $(OUT)
	cd $(OUT) && $(QUARTUS) quartus_sh -t $(abspath build.tcl) \
		$(abspath $(TOP)) $(OUT) $(CLK_INVERT)

program: $(SOF)
	$(QUARTUS) quartus_pgm -c 1 -m jtag -o "p;$(SOF)"

clean:
	rm -rf $(OUT)

.PHONY: all program clean
