# Simulation of the MultiBus Sun-2 replica.
#
#   make xsim              boot the patched PROM against the Wishbone memory
#   make xsim MEM=sim_only use the 512 KiB in-core SRAM instead
#   make xsim ROM=pristine use this machine's unmodified PROM (very slow)
#   make xsim MEM_MIB=1    pretend only 1 MiB is installed (much faster boot)
#   make xsim MEM_LATENCY=7  memory as slow as the real DDR3 path
#   make xsim MACHINE=vme  be a Sun 2/50 (VME) instead of a 2/120 (MultiBus)
#   make iverilog          the open-source flow (GHDL-converted CPU), best effort
#   make check             assert the console reached the monitor prompt
#                          (pass the same MACHINE= as the run it is checking)
#
# Board level -- the Sun-2 as it will be on a QMTech Wukong V1:
#
#   make board                     behavioural RAM and clocks, boots to prompt
#   make board BOARD_MEM=ddr3      real MIG plus Micron's DDR3 model
#   make board-check               assert that boot reached the prompt
#   make clkgen                    measure what the clock generator produces
#   make adapter                   check the Wishbone-to-MIG adapter
#   make dvma                      check the Wishbone-to-68010 DVMA bridge
#
# Extra plusargs go through XSIMARGS, e.g.
#   make xsim XSIMARGS="-testplusarg vcd_full"

TOP     = ..
BUILD   = $(TOP)/build/sim

# Installed memory, in MiB.  The PROM writes all of it during setup, and that
# dominates run time, so use a small machine unless memory size is the thing
# under test.  7 is the architectural maximum; real Sun-2s usually had 2 or 4.
MEM_MIB ?= 7

# Which machine to be: multibus (a 2/120, the default) or vme (a 2/50).  This
# is the only knob needed -- rtl/sun2_config.vh derives the device space base,
# the size of memory space, the ID PROM's machine type and which boot PROM is
# compiled in from it.
MACHINE ?= multibus

# --- configuration knobs -> `define's -------------------------------------
DEFINES = MEM_PAGES=$(shell expr $(MEM_MIB) \* 512)
ifeq ($(MACHINE),vme)
DEFINES += SUN2_VME
else
DEFINES += SUN2_MULTIBUS
endif
ifeq ($(MEM),sim_only)
DEFINES += MEM_SIM_ONLY
endif
ifeq ($(ROM),pristine)
DEFINES += ROM_PRISTINE
endif
ifeq ($(ROM),fast)
DEFINES += ROM_FASTBOOT
endif

# Simulated milliseconds before giving up, and the console string that means
# we got there: the Rev R monitor prompt.  A full boot needs a bit over four
# simulated seconds, nearly all of it the PROM's map diagnostics and the pass
# that fills all 7 MiB of RAM.
# Wait states before main memory acknowledges.  0 is the ideal memory every
# simulation used until the real path was measured; MEM_LATENCY=7 is what a
# Wishbone read actually costs through MIG (make -C sim migddr3 reports it),
# and is the setting to use before believing anything about DVMA bandwidth.
MEM_LATENCY ?= 0

TIMEOUT_MS ?= 6000
STOP_ON    ?= ">"

# CPU clock for the board-level simulation; the core-level one has no MMCMs.
CPU_HZ ?= 12500000

PLUSARGS = -testplusarg timeout_ms=$(TIMEOUT_MS) -testplusarg stop_on=$(STOP_ON)

all: xsim

rom:
	$(MAKE) -C $(TOP)/tools

xsim: rom
	SUN2_DEFINES="$(DEFINES)" SUN2_MEM_LATENCY=$(MEM_LATENCY) \
	SUN2_MACHINE=$(MACHINE) ./run_xsim.sh $(PLUSARGS) $(XSIMARGS)

# --- board level: the Sun-2 as it will be on the Wukong --------------------
#   make board                     behavioural RAM and clocks, boots to prompt
#   make board BOARD_MEM=ddr3      real MIG plus Micron's DDR3 model
BOARD_MEM ?= fast

board: rom
	SUN2_DEFINES="$(DEFINES)" BOARD_MEM=$(BOARD_MEM) SUN2_CPU_HZ=$(CPU_HZ) \
	SUN2_MACHINE=$(MACHINE) ./run_xsim_board.sh $(PLUSARGS) $(XSIMARGS)

board-check:
	./check_console.sh $(BUILD)/board-$(BOARD_MEM)-$(MACHINE)/console.log $(MACHINE)

# --- unit tests for the board layer ---------------------------------------
clkgen adapter migddr3 dvma: rom
	./run_unit.sh $@

iverilog: rom
	SUN2_DEFINES="$(DEFINES)" ./run_iverilog.sh $(PLUSARGS) $(IVSIMARGS)

check:
	./check_console.sh $(BUILD)/xsim-$(MACHINE)/console.log $(MACHINE)

clean:
	rm -rf $(BUILD)

.PHONY: all rom xsim iverilog check clean
