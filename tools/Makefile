# Boot PROM preparation for the Sun-2 replica.
#
# The PROM image in Inputs/ is immutable; everything here is generated into
# build/rom/.  Three variants are produced:
#
#  * pristine  - the image exactly as dumped from a real Sun 2/120
#  * patched   - the same image with the delay loop shortened and the
#                destructive memory test skipped (see sim_speedup.txt); this is
#                what makes simulation to the monitor prompt take minutes
#                instead of days, and it reproduces the image the last known
#                working build of the old design used.
#  * fastboot  - patched, plus the RAM initialisation pass shortened 64-fold
#                (see sim_fastboot.txt).  For runs where memory is not what is
#                being tested.
#
# The output is a Verilog `case` body included by rtl/sun2-common/bootrom.v.

TOP     = ..
ROMDIR  = $(TOP)/build/rom
DISKDIR = $(TOP)/build/disk
PROM    = $(TOP)/Inputs/sun2-multi-rev-R.bin

# The VME machine's PROM, for experimenting with a Sun 2/50 on hardware that is
# currently wired as a MultiBus 2/120.  Used pristine: the speedup patches are
# addresses and opcodes specific to the MultiBus image, and rompatch refuses to
# apply them here, which is exactly what it is for.
PROM250 = $(TOP)/Inputs/sun250_prom_combined.bin

CC     ?= cc
CFLAGS ?= -O2 -Wall

all: $(ROMDIR)/bootrom_16bits.vh $(ROMDIR)/bootrom_patched_16bits.vh \
     $(ROMDIR)/bootrom_fastboot_16bits.vh $(ROMDIR)/bootrom_sun250_16bits.vh \
     $(ROMDIR)/bootrom_sun250_patched_16bits.vh

$(ROMDIR):
	mkdir -p $(ROMDIR)

rom: rom.c
	$(CC) $(CFLAGS) -o $@ $<

rompatch: rompatch.c
	$(CC) $(CFLAGS) -o $@ $<

$(ROMDIR)/sun2-multi-rev-R-patched.bin: rompatch sim_speedup.txt $(PROM) | $(ROMDIR)
	./rompatch $(PROM) $@ sim_speedup.txt

$(ROMDIR)/bootrom_16bits.vh: rom $(PROM) | $(ROMDIR)
	./rom W <$(PROM) >$@

$(ROMDIR)/bootrom_patched_16bits.vh: rom $(ROMDIR)/sun2-multi-rev-R-patched.bin
	./rom W <$(ROMDIR)/sun2-multi-rev-R-patched.bin >$@

# ... and the same again with the RAM initialisation pass shortened, for runs
# where memory is not what is under test.
$(ROMDIR)/sun2-multi-rev-R-fastboot.bin: rompatch sim_speedup.txt sim_fastboot.txt $(PROM) | $(ROMDIR)
	./rompatch $(PROM) $@ sim_speedup.txt sim_fastboot.txt

$(ROMDIR)/bootrom_fastboot_16bits.vh: rom $(ROMDIR)/sun2-multi-rev-R-fastboot.bin
	./rom W <$(ROMDIR)/sun2-multi-rev-R-fastboot.bin >$@

$(ROMDIR)/bootrom_sun250_16bits.vh: rom $(PROM250) | $(ROMDIR)
	./rom W <$(PROM250) >$@

# ... and the same two speedups sim_speedup.txt applies to the MultiBus PROM,
# at the addresses the VME one uses.  Without them it is not simulable to the
# monitor prompt in reasonable time.
$(ROMDIR)/sun250-patched.bin: rompatch sim_speedup_sun250.txt $(PROM250) | $(ROMDIR)
	./rompatch $(PROM250) $@ sim_speedup_sun250.txt

$(ROMDIR)/bootrom_sun250_patched_16bits.vh: rom $(ROMDIR)/sun250-patched.bin
	./rom W <$(ROMDIR)/sun250-patched.bin >$@

# Sanity check: our patches plus legacy_baud.txt must reproduce the PROM
# compiled into the last known-working build of the old design, bit for bit.
# The one word in legacy_baud.txt is where we deliberately differ -- it halves
# the console baud rate, and we would rather have the PROM's own 9600.  Only
# runs where Old/ is available (it is deliberately not in this repository).
OLDROM = $(TOP)/Old/sun2-fpga/rtl-fpga/bootrom_patched_16bits.v

$(ROMDIR)/sun2-multi-rev-R-legacy.bin: rompatch sim_speedup.txt legacy_baud.txt $(PROM) | $(ROMDIR)
	./rompatch $(PROM) $@ sim_speedup.txt legacy_baud.txt

$(ROMDIR)/bootrom_legacy_16bits.vh: rom $(ROMDIR)/sun2-multi-rev-R-legacy.bin
	./rom W <$(ROMDIR)/sun2-multi-rev-R-legacy.bin >$@

check: $(ROMDIR)/bootrom_legacy_16bits.vh
	@if [ -f $(OLDROM) ]; then \
		cmp $< $(OLDROM) && \
		echo "OK: patches + legacy_baud reproduce the old working build exactly"; \
	else \
		echo "skipped: $(OLDROM) not present"; \
	fi

clean:
	rm -f rom rompatch
	rm -rf $(ROMDIR)

.PHONY: all check clean caprobe

# ---------------------------------------------------------------------------
# The chained-IOPB exerciser
# ---------------------------------------------------------------------------
# A 68010 program that runs *on the machine*, loaded from disk by the boot
# PROM, to drive the Xylogics 450 the way the SunOS kernel does -- real chains
# through the real MMU, and a real level-2 interrupt.  See
# tools/xychain/xychain.c.
#
# Deliberately not part of `all`: it needs an m68k cross-compiler, which
# nothing else here does, and `make -C sim xsim` must keep working without one.
M68K    ?= m68k-linux-gnu
XYCFLAGS = -m68010 -ffreestanding -nostdlib -fno-pic -fomit-frame-pointer \
	   -Os -Wall -Wextra

$(DISKDIR)/xychain.bin: xychain/xychain.c xychain/xychain.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T xychain/xychain.ld -o $(DISKDIR)/xychain.elf \
		xychain/xychain.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/xychain.elf $@
	@echo "xychain: $$(stat -c%s $@) bytes of 7680"

xychain: $(DISKDIR)/xychain.bin

# The bus error frame reproducer.  SunOS dies the first time startup() probes
# DVMA bus space, and getting there costs eight seconds of simulated time
# because the kernel has to be read off the disk first.  This provokes the same
# fault from a boot block in about 1.6 s, and prints the exception frame the
# CPU pushed -- which is the part the kernel's panic dump cannot show.
$(DISKDIR)/beprobe.bin: beprobe/beprobe.c beprobe/beprobe.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T beprobe/beprobe.ld -o $(DISKDIR)/beprobe.elf \
		beprobe/beprobe.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/beprobe.elf $@
	@echo "beprobe: $$(stat -c%s $@) bytes of 7680"

beprobe: $(DISKDIR)/beprobe.bin

$(DISKDIR)/clkprobe.bin: clkprobe/clkprobe.c clkprobe/clkprobe.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T clkprobe/clkprobe.ld -o $(DISKDIR)/clkprobe.elf \
		clkprobe/clkprobe.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/clkprobe.elf $@
	@echo "clkprobe: $$(stat -c%s $@) bytes of 7680"

clkprobe: $(DISKDIR)/clkprobe.bin

$(DISKDIR)/caprobe.bin: caprobe/caprobe.c caprobe/caprobe.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T caprobe/caprobe.ld -o $(DISKDIR)/caprobe.elf \
		caprobe/caprobe.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/caprobe.elf $@
	@echo "caprobe: $$(stat -c%s $@) bytes of 7680"

caprobe: $(DISKDIR)/caprobe.bin

$(DISKDIR)/dogprobe.bin: dogprobe/dogprobe.c dogprobe/dogprobe.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T dogprobe/dogprobe.ld -o $(DISKDIR)/dogprobe.elf \
		dogprobe/dogprobe.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/dogprobe.elf $@
	@echo "dogprobe: $$(stat -c%s $@) bytes of 7680"

dogprobe: $(DISKDIR)/dogprobe.bin

$(DISKDIR)/mmuprobe.bin: mmuprobe/mmuprobe.c mmuprobe/mmuprobe.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T mmuprobe/mmuprobe.ld -o $(DISKDIR)/mmuprobe.elf \
		mmuprobe/mmuprobe.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/mmuprobe.elf $@
	@echo "mmuprobe: $$(stat -c%s $@) bytes of 7680"

mmuprobe: $(DISKDIR)/mmuprobe.bin

$(DISKDIR)/loopprobe.bin: loopprobe/loopprobe.c loopprobe/loopprobe.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T loopprobe/loopprobe.ld -o $(DISKDIR)/loopprobe.elf \
		loopprobe/loopprobe.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/loopprobe.elf $@
	@echo "loopprobe: $$(stat -c%s $@) bytes of 7680"

loopprobe: $(DISKDIR)/loopprobe.bin

$(DISKDIR)/ctxprobe.bin: ctxprobe/ctxprobe.c ctxprobe/ctxprobe.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T ctxprobe/ctxprobe.ld -o $(DISKDIR)/ctxprobe.elf \
		ctxprobe/ctxprobe.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/ctxprobe.elf $@
	@echo "ctxprobe: $$(stat -c%s $@) bytes of 7680"

ctxprobe: $(DISKDIR)/ctxprobe.bin

$(DISKDIR)/refmodprobe.bin: refmodprobe/refmodprobe.c refmodprobe/refmodprobe.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T refmodprobe/refmodprobe.ld \
		-o $(DISKDIR)/refmodprobe.elf \
		refmodprobe/refmodprobe.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/refmodprobe.elf $@
	@echo "refmodprobe: $$(stat -c%s $@) bytes of 7680"

refmodprobe: $(DISKDIR)/refmodprobe.bin

$(DISKDIR)/usrprobe.bin: usrprobe/usrprobe.c usrprobe/usrprobe.ld
	@command -v $(M68K)-gcc >/dev/null || { \
		echo "$(M68K)-gcc not found: the on-machine exerciser needs an m68k"; \
		echo "cross-compiler.  On Debian/Ubuntu: apt install gcc-m68k-linux-gnu"; \
		exit 1; }
	mkdir -p $(DISKDIR)
	$(M68K)-gcc $(XYCFLAGS) -T usrprobe/usrprobe.ld -o $(DISKDIR)/usrprobe.elf \
		usrprobe/usrprobe.c 2>&1 | grep -vE 'RWX|build-id' || true
	$(M68K)-objcopy -O binary $(DISKDIR)/usrprobe.elf $@
	@echo "usrprobe: $$(stat -c%s $@) bytes of 7680"

usrprobe: $(DISKDIR)/usrprobe.bin

.PHONY: xychain beprobe clkprobe dogprobe mmuprobe usrprobe ctxprobe loopprobe refmodprobe
