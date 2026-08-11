# Simulation of the MultiBus Sun-2 replica.
#
#   make xsim              boot the patched PROM against the Wishbone memory
#   make xsim MEM=sim_only use the 512 KiB in-core SRAM instead
#   make xsim ROM=pristine use the unmodified PROM (very slow)
#   make xsim MEM_MIB=1    pretend only 1 MiB is installed (much faster boot)
#   make xsim MACHINE=vme ROM=sun250   be a Sun 2/50 instead of a 2/120
#   make iverilog          the open-source flow (GHDL-converted CPU), best effort
#   make check             assert the console reached the monitor prompt
#
# Board level -- the Sun-2 as it will be on a QMTech Wukong V1:
#
#   make board                     behavioural RAM and clocks, boots to prompt
#   make board BOARD_MEM=ddr3      real MIG plus Micron's DDR3 model
#   make board-check               assert that boot reached the prompt
#   make clkgen                    measure what the clock generator produces
#   make adapter                   check the Wishbone-to-MIG adapter
#
# Extra plusargs go through XSIMARGS, e.g.
#   make xsim XSIMARGS="-testplusarg vcd_full"

TOP     = ..
BUILD   = $(TOP)/build/sim

# Installed memory, in MiB.  The PROM writes all of it during setup, and that
# dominates run time, so use a small machine unless memory size is the thing
# under test.  7 is the architectural maximum; real Sun-2s usually had 2 or 4.
MEM_MIB ?= 7

# Which machine to be: multibus (a 2/120, the default) or vme (a 2/50).  The
# three settings that differ are collected here -- device space base, the size
# of memory space, and what the ID PROM claims -- all of them MultiBus values
# that were constants until the 2/50 PROM ran into them.
MACHINE ?= multibus

# --- configuration knobs -> `define's -------------------------------------
DEFINES = MEM_PAGES=$(shell expr $(MEM_MIB) \* 512)
ifeq ($(MACHINE),vme)
DEFINES += DEV_PAGE_BASE=4064 MEM_SPACE_PAGES=4096 IDPROM_MACHINE_TYPE=2
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
ifeq ($(ROM),sun250)
DEFINES += ROM_SUN250
endif
ifeq ($(ROM),sun250-raw)
DEFINES += ROM_SUN250_RAW
endif

# Simulated milliseconds before giving up, and the console string that means
# we got there: the Rev R monitor prompt.  A full boot needs a bit over four
# simulated seconds, nearly all of it the PROM's map diagnostics and the pass
# that fills all 7 MiB of RAM.
TIMEOUT_MS ?= 6000
STOP_ON    ?= ">"

# CPU clock for the board-level simulation; the core-level one has no MMCMs.
CPU_HZ ?= 12500000

PLUSARGS = -testplusarg timeout_ms=$(TIMEOUT_MS) -testplusarg stop_on=$(STOP_ON)

all: xsim

rom:
	$(MAKE) -C $(TOP)/tools

xsim: rom
	SUN2_DEFINES="$(DEFINES)" ./run_xsim.sh $(PLUSARGS) $(XSIMARGS)

# --- board level: the Sun-2 as it will be on the Wukong --------------------
#   make board                     behavioural RAM and clocks, boots to prompt
#   make board BOARD_MEM=ddr3      real MIG plus Micron's DDR3 model
BOARD_MEM ?= fast

board: rom
	SUN2_DEFINES="$(DEFINES)" BOARD_MEM=$(BOARD_MEM) SUN2_CPU_HZ=$(CPU_HZ) \
		./run_xsim_board.sh $(PLUSARGS) $(XSIMARGS)

board-check:
	./check_console.sh $(BUILD)/board-$(BOARD_MEM)/console.log

# --- unit tests for the board layer ---------------------------------------
clkgen adapter migddr3: rom
	./run_unit.sh $@

iverilog: rom
	SUN2_DEFINES="$(DEFINES)" ./run_iverilog.sh $(PLUSARGS) $(IVSIMARGS)

check:
	./check_console.sh $(BUILD)/xsim/console.log

clean:
	rm -rf $(BUILD)

.PHONY: all rom xsim iverilog check clean
