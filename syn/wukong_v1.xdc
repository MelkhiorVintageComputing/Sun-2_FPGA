# Board constraints for the Sun-2 on a QMTech Wukong V1 (XC7A100T-2FGG676).
#
# Board pins only.  The DDR3 pins are NOT here: MIG emits them from
# syn/mig/sun2_mig.prj, and hand-copying them is how two sources drift apart.
# The old LiteX XDC shows exactly that failure -- it constrains ddram_cs_n to
# E22, a pin the V1 schematic shows is connected to nothing.
#
# Pin assignments taken from Old/qmtech_wukong_V1_0.xdc, which agrees with
# QMTech's own documentation.

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ---------------------------------------------------------------------------
# Clock and reset
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN M22 IOSTANDARD LVCMOS33} [get_ports clk50]
create_clock -name clk50 -period 20.000 [get_ports clk50]

# On the V1 board the 50 MHz oscillator is not on a clock-capable pin, so the
# route from the input buffer to the MMCMs cannot use dedicated clock routing.
# (V2/V3 moved the oscillator to M21, which is clock-capable.)  If synthesis
# renames this net, the placer error message names the net to use here.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk50_IBUF]

# Reset button, active low
set_property -dict {PACKAGE_PIN J8 IOSTANDARD LVCMOS33} [get_ports cpu_reset]

# ---------------------------------------------------------------------------
# Serial console -- the Sun-2's only interface for now
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports serial_tx]
set_property -dict {PACKAGE_PIN F3 IOSTANDARD LVCMOS33} [get_ports serial_rx]

# ---------------------------------------------------------------------------
# LEDs and button
# ---------------------------------------------------------------------------
# On-board LEDs, active low: user_led[0] lit = out of reset,
#                            user_led[1] lit = DRAM calibrated
set_property -dict {PACKAGE_PIN J6 IOSTANDARD LVCMOS33} [get_ports {user_led[0]}]
set_property -dict {PACKAGE_PIN H6 IOSTANDARD LVCMOS33} [get_ports {user_led[1]}]

set_property -dict {PACKAGE_PIN H7 IOSTANDARD LVCMOS33} [get_ports user_btn]

# The Sun-2 front panel diagnostic LEDs, on a PMOD
set_property -dict {PACKAGE_PIN E5 IOSTANDARD LVCMOS33} [get_ports {diag_leds0[0]}]
set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33} [get_ports {diag_leds0[1]}]
set_property -dict {PACKAGE_PIN E6 IOSTANDARD LVCMOS33} [get_ports {diag_leds0[2]}]
set_property -dict {PACKAGE_PIN G5 IOSTANDARD LVCMOS33} [get_ports {diag_leds0[3]}]
set_property -dict {PACKAGE_PIN D6 IOSTANDARD LVCMOS33} [get_ports {diag_leds0[4]}]
set_property -dict {PACKAGE_PIN G7 IOSTANDARD LVCMOS33} [get_ports {diag_leds0[5]}]
set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports {diag_leds0[6]}]
set_property -dict {PACKAGE_PIN G8 IOSTANDARD LVCMOS33} [get_ports {diag_leds0[7]}]

# ---------------------------------------------------------------------------
# Clock domains
# ---------------------------------------------------------------------------
# Everything derives from clk50, so Vivado would otherwise try to time paths
# between the CPU, serial and DRAM user-interface domains as if they were
# related.  They are not: the crossings that exist are the handshake inside
# wb_to_mig_ui and the SCC's own internal synchronisers.
set cpu_clk    [get_clocks -of_objects [get_pins clkgen/mmcm_a/CLKOUT1]]
set serial_clk [get_clocks -of_objects [get_pins clkgen/mmcm_b/CLKOUT0]]
set mig_clk    [get_clocks -of_objects [get_pins clkgen/mmcm_a/CLKOUT0]]

# clk50 belongs in here too: the reset assembly and the hold counter run on it,
# and they reach every other domain through reset_sync.  Leaving it out is what
# made the first build fail a recovery check into the SCC.
set_clock_groups -asynchronous \
    -group [get_clocks clk50] \
    -group $cpu_clk \
    -group $serial_clk \
    -group [get_clocks -include_generated_clocks $mig_clk]

# ---------------------------------------------------------------------------
# The Wishbone/MIG clock crossing
# ---------------------------------------------------------------------------
# wb_to_mig_ui crosses with a two-phase toggle handshake.  The toggles go
# through two-flop synchronisers; the address, data and read-data buses are
# held stable for the whole transaction and so are a classic multi-cycle path.
# Bound both by one destination clock period rather than leaving them false, so
# a wildly slow route still gets flagged.
set cpu_period 80.000
set ui_period  12.000

set_max_delay -datapath_only \
    -from [get_cells adapter/req_tgl_reg] \
    -to   [get_cells adapter/req_tgl_s1_reg] $ui_period
set_max_delay -datapath_only \
    -from [get_cells adapter/ack_tgl_reg] \
    -to   [get_cells adapter/ack_tgl_s1_reg] $cpu_period

# clk_pll_i is MIG's ui_clk (83.33 MHz); the name is MIG's own and appears in
# build/syn/*/clocks.rpt if it ever changes.
set_max_delay -datapath_only \
    -from [get_cells {adapter/req_adr_reg[*] adapter/req_dat_reg[*] \
                      adapter/req_sel_reg[*] adapter/req_we_reg}] \
    -to   [get_clocks clk_pll_i] $ui_period
set_max_delay -datapath_only \
    -from [get_cells {adapter/rd_lane_reg[*]}] \
    -to   $cpu_clk $cpu_period
