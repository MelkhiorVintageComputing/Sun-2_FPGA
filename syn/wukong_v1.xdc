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

# The PHY-sourced MII clocks.  Both land on clock-capable balls (M2 and P4 are
# SRCC), which is what makes a plain IBUF + BUFG capture sound.  400 ns is
# 2.5 MHz, the MII rate at 10 Mb/s.
#
# These are defined *here*, not down with the Ethernet pins, because the
# set_clock_groups below names them.  A get_clocks for a clock that does not
# exist yet returns nothing and the group is silently dropped -- no error, no
# warning, just an asynchronous crossing that quietly gets timed.  That is how
# the receive FIFO's read path came out as a hold violation the first time.
create_clock -name phy_tx_clk -period 400.000 [get_ports phy_mii_tx_clk]
create_clock -name phy_rx_clk -period 400.000 [get_ports phy_mii_rx_clk]

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
    -group [get_clocks phy_tx_clk] \
    -group [get_clocks phy_rx_clk] \
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

# ---------------------------------------------------------------------------
# Ethernet -- RTL8211EG, bank 34
# ---------------------------------------------------------------------------
# Bank 34 carries nothing but Ethernet and is fixed at 3.3 V.  Pins are from
# QMTech's own GMII reference design (Software/Test08_GMII_Ethernet.zip), which
# is the authoritative pinout for this board, cross-checked against the
# schematic and the LiteX platform file.
#
# Only the low four data bits are used: the PHY presents a 4-bit MII at 10 and
# 100 Mb/s and sources both clocks itself.  TXD7:4 (K1 K2 L2 M1) are left
# unconstrained and undriven.
#
# CAUTION.  Seven of these balls are PHY configuration straps, latched when the
# PHY's reset releases: L3 (PHY_AD2), U5 (AN1), R3 (SELRGV), T3 (TXDLY),
# T4 (RXDLY), T5 (AN0) and U4 (Mode).  They are inputs and must stay inputs,
# with no PULLUP/PULLDOWN/KEEPER property -- the board already pulls each to the
# level it wants.  Driving L3 or U4 changes the PHY's address, or puts the part
# into RGMII mode where nothing works in a way that resembles a MAC fault.
set_property -dict {PACKAGE_PIN M2 IOSTANDARD LVCMOS33} [get_ports phy_mii_tx_clk]
set_property -dict {PACKAGE_PIN P4 IOSTANDARD LVCMOS33} [get_ports phy_mii_rx_clk]

set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports {phy_mii_txd[0]}]
set_property -dict {PACKAGE_PIN P1 IOSTANDARD LVCMOS33} [get_ports {phy_mii_txd[1]}]
set_property -dict {PACKAGE_PIN N2 IOSTANDARD LVCMOS33} [get_ports {phy_mii_txd[2]}]
set_property -dict {PACKAGE_PIN N1 IOSTANDARD LVCMOS33} [get_ports {phy_mii_txd[3]}]
set_property -dict {PACKAGE_PIN T2 IOSTANDARD LVCMOS33} [get_ports phy_mii_tx_en]
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33} [get_ports phy_mii_tx_er]

set_property -dict {PACKAGE_PIN M4 IOSTANDARD LVCMOS33} [get_ports {phy_mii_rxd[0]}]
set_property -dict {PACKAGE_PIN N3 IOSTANDARD LVCMOS33} [get_ports {phy_mii_rxd[1]}]
set_property -dict {PACKAGE_PIN N4 IOSTANDARD LVCMOS33} [get_ports {phy_mii_rxd[2]}]
set_property -dict {PACKAGE_PIN P3 IOSTANDARD LVCMOS33} [get_ports {phy_mii_rxd[3]}]
set_property -dict {PACKAGE_PIN L3 IOSTANDARD LVCMOS33} [get_ports phy_mii_rx_dv]
set_property -dict {PACKAGE_PIN U5 IOSTANDARD LVCMOS33} [get_ports phy_mii_rx_er]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports phy_mii_crs]
set_property -dict {PACKAGE_PIN U4 IOSTANDARD LVCMOS33} [get_ports phy_mii_col]

set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33} [get_ports phy_gtx_clk]
set_property -dict {PACKAGE_PIN R1 IOSTANDARD LVCMOS33} [get_ports phy_reset_n]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports phy_mdc]
set_property -dict {PACKAGE_PIN H1 IOSTANDARD LVCMOS33} [get_ports phy_mdio]

# The two PHY clocks are created near the top, with clk50 -- see the note there.

# MII clause 22.3.2 setup/hold, with vast margin at 2.5 MHz.
set_input_delay  -clock phy_rx_clk -max 10.000 [get_ports {phy_mii_rxd[*] phy_mii_rx_dv phy_mii_rx_er}]
set_input_delay  -clock phy_rx_clk -min  0.000 [get_ports {phy_mii_rxd[*] phy_mii_rx_dv phy_mii_rx_er}]
set_output_delay -clock phy_tx_clk -max 25.000 [get_ports {phy_mii_txd[*] phy_mii_tx_en phy_mii_tx_er}]
set_output_delay -clock phy_tx_clk -min  0.000 [get_ports {phy_mii_txd[*] phy_mii_tx_en phy_mii_tx_er}]

# CRS and COL are asynchronous to both MII clocks by the standard (clause
# 22.2.2.11/12); sun2_ethernet synchronises them into the transmit domain, so
# the pins themselves carry no timing requirement.
set_false_path -from [get_ports {phy_mii_crs phy_mii_col}]

# The PHY reset and the tied-off gigabit clock are static.
set_false_path -to [get_ports {phy_reset_n phy_gtx_clk}]

# Management runs at 125 kHz against a 2.5 MHz ceiling, from the CPU clock, so
# there is nothing to time here that the CPU domain does not already cover.
set_false_path -to   [get_ports {phy_mdc phy_mdio}]
set_false_path -from [get_ports phy_mdio]
