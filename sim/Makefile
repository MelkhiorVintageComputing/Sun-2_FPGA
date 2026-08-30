# Simulation of the MultiBus Sun-2 replica.
#
#   make xsim              boot the patched PROM against the Wishbone memory
#   make xsim MEM=sim_only use the 512 KiB in-core SRAM instead
#   make xsim ROM=pristine use this machine's unmodified PROM (very slow)
#   make xsim MEM_MIB=1    pretend only 1 MiB is installed (much faster boot)
#   make xsim MEM_LATENCY=7  memory as slow as the real DDR3 path
#   make xsim MACHINE=vme  be a Sun 2/50 (VME) instead of a 2/120 (MultiBus)
#   make xsim MB_ETHER=1   fit the Sun MultiBus Ethernet board (MultiBus only)
#   make xsim MB_3C400=1   fit a 3Com 3C400 instead (MultiBus only, exclusive)
#   make xsim FB=1         fit the frame buffer (either machine)
#   make xsim XY450=1      fit the Xylogics 450 disk controller (MultiBus only)
#   make xsim CPU=rd68011  build with the RD68011 core instead of Suska
#   make iverilog          the open-source flow (GHDL-converted CPU), best effort
#   make check             assert the console reached the monitor prompt
#                          (pass the same MACHINE= as the run it is checking)
#
# Board level -- the Sun-2 as it will be on a QMTech Wukong:
#
#   make board                     behavioural RAM and clocks, boots to prompt
#   make board BOARD_MEM=ddr3      real MIG plus Micron's DDR3 model
#   make board CPU=rd68011         with the RD68011 core instead of Suska
#   make board-check               assert that boot reached the prompt
#   make board-phy                 ... then type at the prompt and read the
#                                  PHY status register in device page 0xFE7
#   make clkgen                    measure what the clock generator produces
#   make adapter                   check the Wishbone-to-MIG adapter
#   make bridge                    the Wishbone bridge against back-to-back cycles
#   make dvma                      check the Wishbone-to-68010 DVMA bridge
#   make phy                       check the RTL8211EG bring-up sequence
#   make mbether                   check the Sun MultiBus Ethernet board
#   make mb3c400                   check the 3Com 3C400 MultiBus Ethernet board
#   make vtiming                   check the video raster against VESA DMT
#   make adv7513                   check the DECA's HDMI transmitter setup
#   make xy450                     check the Xylogics 450's registers
#   make xychain                   boot a 68010 program that drives real chains
#   make scanout                   check the frame buffer scan-out
#   make screenshot                render what the last FB=1 boot drew, as a PPM
#
# Extra plusargs go through XSIMARGS, e.g.
#   make xsim XSIMARGS="-testplusarg vcd_full"

TOP     = ..
BUILD   = $(TOP)/build/sim

# Installed memory, in MiB.  The PROM writes all of it during setup, and that
# dominates run time, so use a small machine unless memory size is the thing
# under test.  7 is the architectural maximum; real Sun-2s usually had 2 or 4.
MEM_MIB ?= 7

# ... or name the page count outright, when the interesting sizes are not whole
# mebibytes.  A page is 2 KiB, so MEM_PAGES=48 is 96 KiB.  This exists because
# an FPGA with no external memory has whatever its block RAM holds and nothing
# else, and the question "what is the least this PROM will boot in" is then a
# real one -- sun2_config.vh:285 claims 256 KiB and nothing here has ever
# measured it.  MEM_MIB stays the knob for ordinary use; give one or the other.
MEM_PAGES ?= $(shell expr $(MEM_MIB) \* 512)

# Which machine to be: multibus (a 2/120, the default) or vme (a 2/50).  This
# is the only knob needed -- rtl/sun2-common/sun2_config.vh derives the device space base,
# the size of memory space, the ID PROM's machine type and which boot PROM is
# compiled in from it.
MACHINE ?= multibus

# --- configuration knobs -> `define's -------------------------------------
DEFINES = MEM_PAGES=$(MEM_PAGES)
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
# Or a 3Com 3C400 instead.  Mutually exclusive with the above -- one card cage,
# one MII port, and sun2_fpga.v $fatals on the pair.  This is the MultiBus
# Ethernet that fits on a MAX 10: 8 KiB of buffers against the Sun card's
# 256 KiB, which is 256 M9K on a device that has 182.
ifeq ($(MB_3C400),1)
DEFINES += SUN2_MB_3C400
endif
# Fit the 2/50's frame buffer.  VME only, and note it changes what the machine
# looks like from outside: with a display the boot PROM puts the console on the
# screen and the serial port goes quiet.
ifeq ($(FB),1)
DEFINES += SUN2_FB
endif
# Fit a Xylogics 450 disk controller in the MultiBus card cage, with an SD card
# where four SMD drives used to be.  MultiBus only -- a 2/50 takes a 451 on the
# VME bus, which is a different card in a different space.
ifeq ($(XY450),1)
DEFINES += SUN2_XY450
endif

# Power the segment and page map RAMs up as zeros, the way a 7-series block RAM
# comes out of configuration, instead of leaving them X as the model otherwise
# does.  An experiment rather than a default: it is what the board really does,
# and the boot's first bus cycle -- the reset vector fetch, a supervisor *data*
# access, so translated rather than served from the PROM -- reads an entry that
# software has not written yet.
# Anything else to `define, for one-off experiments: EXTRA_DEFINES="FOO BAR".
# It does not tag the run directory, so use it only for things that change what
# is printed rather than what the machine does.
DEFINES += $(EXTRA_DEFINES)

MAPS_ZERO ?= 0
ifeq ($(MAPS_ZERO),1)
DEFINES += SRAM_POWERUP_ZERO
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

# Simulated milliseconds before giving up.  The VME machine needs more than the
# MultiBus one and always did: with no disk it tries the network, and `nd' gives
# up only after three retries -- which the PROM times in NMI ticks, so once the
# Am9513 was fixed and the NMI ran at its intended 40 Hz instead of 98.9, the
# prompt moved from inside 6 s out to 8.3 s.  STOP_ON ends the run at the
# prompt anyway, so the larger number costs nothing when the boot is healthy.
TIMEOUT_MS ?= $(if $(filter vme,$(MACHINE)),12000,6000)
STOP_ON    ?= ">"

# The CPU clock, for both the board-level and the core-level simulation.
# 12.5 MHz is the real machine and every fingerprint in the tree.
#
# Raising it does not make a long run finish sooner, which is worth knowing
# before spending an evening on it.  Boot to the monitor prompt, MEM_MIB=1
# ROM=fast, identical console and the same 23629 bus errors either way:
#
#     12.5 MHz   1.63 s simulated   602 s wall
#     40   MHz   0.70 s simulated   807 s wall
#
# xsim's cost tracks cpu_clk edges, not simulated time, and those went up --
# simulated time fell by 2.3x while the clock rose by 3.2x, because a fixed
# 270 ms of the boot is the PROM talking at 9600 baud and a faster CPU only
# spins harder waiting for it.  tb_sun2.sv has the full arithmetic.
#
# It gets its own build/sim directory, so a 40 MHz run and a 12.5 MHz one can
# be in flight at once.
CPU_HZ ?= 12500000

# Console rate.  The machine's is set by the SCC's clock, which +clk4m_bit
# scales -- see tb_sun2.sv.  This tells the log decoder what to expect, and has
# to be moved in step with it or the console comes out as line noise.
BAUD ?= 9600

# Which MC68010 to build with.  `suska' is the Suska VHDL core the machine is
# developed and measured against; `rd68011' is the SystemVerilog core in
# Inputs/RD68011, which top_fpga.v instantiates as the alternative under
# SUN2_CPU_RD68011 -- so the machine either core plugs into is the same file.
# It gets its own build/sim directory.  Neither core is a reference for the
# other: run short experiments -- boot blocks, unit tests, device probes --
# with both, and report both.
CPU ?= suska

PLUSARGS = -testplusarg timeout_ms=$(TIMEOUT_MS) -testplusarg stop_on=$(STOP_ON)

all: xsim

rom:
	$(MAKE) -C $(TOP)/tools

xsim: rom
	SUN2_DEFINES="$(DEFINES)" SUN2_MEM_LATENCY=$(MEM_LATENCY) \
	SUN2_CPU_HZ=$(CPU_HZ) SUN2_BAUD=$(BAUD) SUN2_CPU=$(CPU) \
	SUN2_MACHINE=$(MACHINE) ./run_xsim.sh $(PLUSARGS) $(XSIMARGS)

# --- board level: the Sun-2 as it will be on the Wukong --------------------
#   make board                     behavioural RAM and clocks, boots to prompt
#   make board BOARD_MEM=ddr3      real MIG plus Micron's DDR3 model
#   make board CPU=rd68011         with the RD68011 core instead of Suska
BOARD_MEM ?= fast

# Which Wukong revision.  The board RTL is shared between V1 and V3, so this
# only selects which MIG IP the ddr3 configuration picks up.
BOARD ?= v1

# The CPU core tags the run directory, as it does for `make xsim'; board-check
# has to build the same name, so CPUTAG is shared between the two.
CPUTAG = $(if $(filter-out suska,$(CPU)),-$(CPU),)

board: rom
	SUN2_DEFINES="$(DEFINES)" BOARD=$(BOARD) BOARD_MEM=$(BOARD_MEM) SUN2_CPU_HZ=$(CPU_HZ) \
	SUN2_CPU=$(CPU) \
	SUN2_MACHINE=$(MACHINE) ./run_xsim_board.sh $(PLUSARGS) $(XSIMARGS)

board-check:
	./check_console.sh $(BUILD)/board-$(BOARD)-$(BOARD_MEM)-$(MACHINE)$(CPUTAG)/console.log $(MACHINE)

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
clkgen adapter migddr3 dvma bridge phy mbether mb3c400 xy450 scc mm58167 scanout vtiming adv7513 vmescsi decauart decaconsole decaddr3 decaphy trace: rom
	BOARD=$(BOARD) XSIMARGS="$(XSIMARGS)" ./run_unit.sh $@

# --- a picture of what the machine drew -----------------------------------
# The frame buffer as a PPM, rendered by the real fb_scanout rather than read
# out of the memory model -- so it exercises the line addressing, the bit order
# inside a beat, the polarity and the windowbox, none of which exist at the
# level tb_sun2 checks the logo at.
#
# Two steps rather than one because the boot that captures the frame buffer is
# the better part of an hour and a render is under a minute: the image can be
# looked at, the RTL changed and the image redrawn without booting again.
#
# The image path has to be absolute.  TOP is "..", and run_unit.sh cd's into
# build/sim/unit-scanout before running, so a relative one resolves against the
# wrong directory -- and $readmemh on a file that is not there is not an error.
# It leaves the array X, which every structural check below survives; only the
# white-coverage and logo checks notice.
FBIMAGE = $(abspath $(BUILD)/xsim-$(MACHINE)$(RUNTAG)/fb.mem)
SCREEN  = $(BUILD)/unit-scanout/screen.ppm

screenshot:
	@if [ ! -f $(FBIMAGE) ]; then \
		echo "no frame buffer capture at $(FBIMAGE)"; \
		echo "boot the machine with a display first:"; \
		echo "    make -C sim xsim MACHINE=$(MACHINE) FB=1 MEM_MIB=1"; \
		exit 1; \
	fi
	$(MAKE) scanout XSIMARGS='-testplusarg fb_image=$(FBIMAGE) \
		-testplusarg fb_ppm=screen.ppm -testplusarg fb_logo'
	@echo "screenshot: $(SCREEN)"

# --- chained IOPBs, driven from inside the machine -------------------------
# tb_xy450 replays what the SunOS driver does against a memory model; this is
# the other half.  tools/xychain is a 68010 program the boot PROM loads off the
# disk, which builds chains in the DVMA window, drives them through the real
# MMU and takes the real level 2 autovector interrupt -- the first thing in
# this design to do any of those.  It needs an m68k cross-compiler, so it is
# its own target rather than part of any sweep.
XYCHAIN_BIN = $(abspath $(TOP)/build/disk/xychain.bin)
XYCHAIN_IMG = $(abspath $(TOP)/build/disk/xychain.img)

xychain: rom
	$(MAKE) -C $(TOP)/tools xychain
	$(TOP)/tools/mkxydisk -o $(XYCHAIN_IMG) --boot $(XYCHAIN_BIN) \
		--label "xychain exerciser"
	$(MAKE) xsim XY450=1 MEM_MIB=1 ROM=fast TIMEOUT_MS=8000 \
		STOP_ON=xychain-finished \
		XSIMARGS="-testplusarg blk_image=$(XYCHAIN_IMG) $(XSIMARGS)"
	./check_console.sh $(BUILD)/xsim-$(MACHINE)-xy450$(CPUTAG)/console.log $(MACHINE) xychain

iverilog: rom
	SUN2_DEFINES="$(DEFINES)" ./run_iverilog.sh $(PLUSARGS) $(IVSIMARGS)

# Must match the run directory run_xsim.sh chooses, which composes the two.
# CPUTAG goes last because run_xsim.sh appends it last; without it `make check
# CPU=rd68011' reads the Suska run's log and passes on it.  Note this still
# does not carry CPU_HZ or BAUD, which also tag a run directory -- pass
# FBIMAGE= or the log path by hand for those.
RUNTAG  = $(if $(filter 1,$(MB_ETHER)),-mbether,)$(if $(filter 1,$(MB_3C400)),-3c400,)$(if $(filter 1,$(FB)),-fb,)$(if $(filter 1,$(XY450)),-xy450,)$(CPUTAG)
# What check_console.sh should expect, in order of what wins.  A display wins
# outright: with one fitted the console moves to the screen and there is no
# serial output left to check, whatever else is in the cage.  A disk beats an
# Ethernet card because `xy' comes before `ie' in the PROM's boot list, so
# auto-boot reaches the disk and never tries the network.
FITTED  = $(if $(filter 1,$(FB)),fb,\
          $(if $(filter 1,$(XY450)),xy450,\
          $(if $(filter 1,$(MB_ETHER)),mbether,\
          $(if $(filter 1,$(MB_3C400)),mb3c400,))))

check:
	./check_console.sh $(BUILD)/xsim-$(MACHINE)$(RUNTAG)/console.log $(MACHINE) $(FITTED)

clean:
	rm -rf $(BUILD)

.PHONY: all rom xsim board board-check board-phy iverilog check clean
.PHONY: clkgen adapter migddr3 dvma bridge phy mbether mb3c400 xy450 xychain vtiming adv7513 vmescsi mm58167 scanout decauart decaconsole decaddr3 decaphy screenshot
