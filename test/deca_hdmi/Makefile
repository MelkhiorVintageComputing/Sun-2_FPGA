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

# Prerequisites, so editing a source actually rebuilds.  Without them the rule
# fires once and never again, and an edit looks like it did nothing -- which is
# a slow way to lose an afternoon.
SRCS := build.tcl deca_hdmi_test_top.sv hdmi_test.sdc hdmi_test_pins.qsf \
        $(TOP)/boards/DECA/deca_vidclk.sv \
        $(TOP)/boards/DECA/deca_hdmi_out.sv \
        $(TOP)/boards/DECA/deca_adv7513_init.sv \
        $(TOP)/rtl/sun2-common/video_timing.sv \
        $(TOP)/rtl/sun2-common/reset_sync.sv

all: $(SOF)

$(SOF): $(SRCS)
	mkdir -p $(OUT)
	cd $(OUT) && $(QUARTUS) quartus_sh -t $(abspath build.tcl) \
		$(abspath $(TOP)) $(OUT) $(CLK_INVERT)

program: $(SOF)
	$(QUARTUS) quartus_pgm -c 1 -m jtag -o "p;$(SOF)"

clean:
	rm -rf $(OUT)

.PHONY: all program clean
