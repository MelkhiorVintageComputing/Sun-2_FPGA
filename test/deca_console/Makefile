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
LOOPBACK ?= 0
CON_ON_CPU ?= 0
OUT     := $(abspath $(TOP))/build/test-deca-console-div$(CPU_DIV)$(if $(filter 1,$(LOOPBACK)),-loop,)$(if $(filter 1,$(CON_ON_CPU)),-cpuclk,)
SOF     := $(OUT)/console_test.sof

# Prerequisites, so editing a source actually rebuilds.  Without them the rule
# fires once and never again, and an edit looks like it did nothing -- which is
# a slow way to lose an afternoon, and was already one here before
# test/deca_hdmi grew the same list.
SRCS := build.tcl deca_console_test_top.sv console_test.sdc console_test_pins.qsf \
        $(TOP)/boards/DECA/deca_clkgen.sv \
        $(TOP)/boards/DECA/deca_uart_rx.sv \
        $(TOP)/boards/DECA/deca_uart_tx.sv \
        $(TOP)/boards/DECA/deca_jtag_console.sv \
        $(TOP)/rtl/sun2-common/reset_sync.sv

all: $(SOF)

$(SOF): $(SRCS)
	mkdir -p $(OUT)
	cd $(OUT) && $(QUARTUS) quartus_sh -t $(abspath build.tcl) \
		$(abspath $(TOP)) $(OUT) $(CPU_DIV) $(LOOPBACK) $(CON_ON_CPU)

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
