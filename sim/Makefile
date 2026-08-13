# Simulation of the MultiBus Sun-2 replica.
#
#   make xsim              boot the patched PROM against the Wishbone memory
#   make xsim MEM=sim_only use the 512 KiB in-core SRAM instead
#   make xsim ROM=pristine use this machine's unmodified PROM (very slow)
#   make xsim MEM_MIB=1    pretend only 1 MiB is installed (much faster boot)
#   make xsim MEM_LATENCY=7  memory as slow as the real DDR3 path
#   make xsim MACHINE=vme  be a Sun 2/50 (VME) instead of a 2/120 (MultiBus)
#   make xsim MB_ETHER=1   fit the MultiBus Ethernet board (MultiBus only)
#   make xsim FB=1         fit the frame buffer (VME only)
#   make iverilog          the open-source flow (GHDL-converted CPU), best effort
#   make check             assert the console reached the monitor prompt
#                          (pass the same MACHINE= as the run it is checking)
#
# Board level -- the Sun-2 as it will be on a QMTech Wukong:
#
#   make board                     behavioural RAM and clocks, boots to prompt
#   make board BOARD_MEM=ddr3      real MIG plus Micron's DDR3 model
#   make board-check               assert that boot reached the prompt
#   make board-phy                 ... then type at the prompt and read the
#                                  PHY status register in device page 0xFE7
#   make clkgen                    measure what the clock generator produces
#   make adapter                   check the Wishbone-to-MIG adapter
#   make dvma                      check the Wishbone-to-68010 DVMA bridge
#   make phy                       check the RTL8211EG bring-up sequence
#   make mbether                   check the MultiBus Ethernet board
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
# is the only knob needed -- rtl/sun2-common/sun2_config.vh derives the device space base,
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
# Fit a Sun-2 Ethernet board in the MultiBus card cage.  Off by default: a
# 2/120 with no card is equally a real machine, and it is the one the
# 23,629-bus-error fingerprint describes.
ifeq ($(MB_ETHER),1)
DEFINES += SUN2_MB_ETHER
endif
# Fit the 2/50's frame buffer.  VME only, and note it changes what the machine
# looks like from outside: with a display the boot PROM puts the console on the
# screen and the serial port goes quiet.
ifeq ($(FB),1)
DEFINES += SUN2_FB
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

# Which Wukong revision.  The board RTL is shared between V1 and V3, so this
# only selects which MIG IP the ddr3 configuration picks up.
BOARD ?= v1

board: rom
	SUN2_DEFINES="$(DEFINES)" BOARD=$(BOARD) BOARD_MEM=$(BOARD_MEM) SUN2_CPU_HZ=$(CPU_HZ) \
	SUN2_MACHINE=$(MACHINE) ./run_xsim_board.sh $(PLUSARGS) $(XSIMARGS)

board-check:
	./check_console.sh $(BUILD)/board-$(BOARD)-$(BOARD_MEM)-$(MACHINE)/console.log $(MACHINE)

# Boot the board, then type at the monitor prompt and read the PHY status
# register in device page 0xFE7 -- see "Asking the machine what the PHY did" in
# the README.  VME only; the register does not exist on a MultiBus machine.
#
# The stop string has to be off or the run ends at the first prompt with
# nothing typed, and 1 MiB is not optional either: at the full 7 MiB the PROM's
# RAM pass alone does not leave enough simulated time to reach the prompt.
board-phy:
	$(MAKE) board MACHINE=vme MEM_MIB=1 STOP_ON= TIMEOUT_MS=8000 \
		XSIMARGS="-testplusarg phy_probe $(XSIMARGS)"
	$(MAKE) board-check MACHINE=vme

# --- unit tests for the board layer ---------------------------------------
clkgen adapter migddr3 dvma phy mbether: rom
	BOARD=$(BOARD) ./run_unit.sh $@

iverilog: rom
	SUN2_DEFINES="$(DEFINES)" ./run_iverilog.sh $(PLUSARGS) $(IVSIMARGS)

# Must match the run directory run_xsim.sh chooses.
ifeq ($(MB_ETHER),1)
RUNTAG  = -mbether
FITTED  = mbether
else ifeq ($(FB),1)
RUNTAG  = -fb
FITTED  = fb
else
RUNTAG  =
FITTED  =
endif

check:
	./check_console.sh $(BUILD)/xsim-$(MACHINE)$(RUNTAG)/console.log $(MACHINE) $(FITTED)

clean:
	rm -rf $(BUILD)

.PHONY: all rom xsim board board-check board-phy iverilog check clean
.PHONY: clkgen adapter migddr3 dvma phy mbether
