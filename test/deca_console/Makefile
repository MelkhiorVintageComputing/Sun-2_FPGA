# A standalone console test for the Arrow DECA: the two PLLs, the JTAG console
# bridge, a pattern generator, and nothing else.  See README.md.
#
#   make                    build it
#   make CPU_DIV=100        at 10 MHz instead of 12.5
#   make program            put it on the board
#   make terminal           open the console on it

TOP     := ../..
QUARTUS_ROOTDIR ?= /opt/Altera/quartus
QUARTUS  = QUARTUS_ROOTDIR=$(QUARTUS_ROOTDIR) $(TOP)/syn/altera.sh
CPU_DIV ?= 80
OUT     := $(abspath $(TOP))/build/test-deca-console-div$(CPU_DIV)
SOF     := $(OUT)/console_test.sof

all: $(SOF)

$(SOF):
	mkdir -p $(OUT)
	cd $(OUT) && $(QUARTUS) quartus_sh -t $(abspath build.tcl) \
		$(abspath $(TOP)) $(OUT) $(CPU_DIV)

program: $(SOF)
	$(QUARTUS) quartus_pgm -c 1 -m jtag -o "p;$(SOF)"

# juart-terminal is the host end of the JTAG UART.  It needs jtagd running and
# the USB-Blaster udev rule installed; without the rule it reports no hardware,
# which is a permissions problem and not a board problem.
terminal:
	$(QUARTUS) juart-terminal

clean:
	rm -rf $(OUT)

.PHONY: all program terminal clean
