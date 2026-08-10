all: sim

# Boot PROM images (build/rom/)
rom:
	$(MAKE) -C tools

# Simulate the machine; see sim/Makefile for the knobs.
sim:
	$(MAKE) -C sim xsim

check:
	$(MAKE) -C sim check

clean:
	$(MAKE) -C tools clean
	$(MAKE) -C sim clean

.PHONY: all rom sim check clean
