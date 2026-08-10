# Simulation of the MultiBus Sun-2 replica.
#
#   make xsim              boot the patched PROM against the Wishbone memory
#   make xsim MEM=sim_only use the 512 KiB in-core SRAM instead
#   make xsim ROM=pristine use the unmodified PROM (very slow)
#   make xsim MEM_MIB=1    pretend only 1 MiB is installed (much faster boot)
#   make iverilog          the open-source flow (GHDL-converted CPU), best effort
#   make check             assert the console reached the monitor prompt
#
# Extra plusargs go through XSIMARGS, e.g.
#   make xsim XSIMARGS="-testplusarg vcd_full"

TOP     = ..
BUILD   = $(TOP)/build/sim

# Installed memory, in MiB.  The PROM writes all of it during setup, and that
# dominates run time, so use a small machine unless memory size is the thing
# under test.  7 is the architectural maximum; real Sun-2s usually had 2 or 4.
MEM_MIB ?= 7

# --- configuration knobs -> `define's -------------------------------------
DEFINES = MEM_PAGES=$(shell expr $(MEM_MIB) \* 512)
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
TIMEOUT_MS ?= 6000
STOP_ON    ?= ">"

PLUSARGS = -testplusarg timeout_ms=$(TIMEOUT_MS) -testplusarg stop_on=$(STOP_ON)

all: xsim

rom:
	$(MAKE) -C $(TOP)/tools

xsim: rom
	SUN2_DEFINES="$(DEFINES)" ./run_xsim.sh $(PLUSARGS) $(XSIMARGS)

iverilog: rom
	SUN2_DEFINES="$(DEFINES)" ./run_iverilog.sh $(PLUSARGS) $(IVSIMARGS)

check:
	./check_console.sh $(BUILD)/xsim/console.log

clean:
	rm -rf $(BUILD)

.PHONY: all rom xsim iverilog check clean
