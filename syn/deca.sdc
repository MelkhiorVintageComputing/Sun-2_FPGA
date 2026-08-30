# Timing constraints for the Arrow DECA.
#
# The twin of syn/wukong_common.xdc, and it carries the same lesson about
# ordering: a set_clock_groups naming a clock that has not been created yet
# matches nothing and is dropped **silently**, surfacing much later as a real
# hold violation on a crossing that should have been ignored.  So
# derive_pll_clocks comes before every group below, not after.

# ------------------------------------------------------------------ sources
create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]

# The MII clocks come from the DP83620, not from us.  A Sun-2 only ever runs at
# 10 Mb/s, where these are 2.5 MHz -- but the PHY autonegotiates and may come up
# at 100 until something tells it otherwise, so constrain the tighter case.
create_clock -name net_tx_clk -period 40.000 [get_ports NET_TX_CLK]
create_clock -name net_rx_clk -period 40.000 [get_ports NET_RX_CLK]

# ------------------------------------------------------------------ derived
derive_pll_clocks -create_base_clocks

# Quartus adds no clock uncertainty unless asked, where Vivado includes it by
# default.  Omitting this is a silent optimism of tens of picoseconds on every
# path, which is exactly the sort of difference that makes a board behave
# unlike its own timing report.
derive_clock_uncertainty

# -------------------------------------------------------------- clock groups
# The two PLLs are unrelated to each other and to the board oscillator.  They
# are separate groups even though both derive from clk50, for the same reason
# wukong_common.xdc separates its two MMCMs: the only paths that cross are the
# SCC's own internal synchronisers and the two-flop chains in ttl_am9513.v and
# mm58167.v, and timing them would be meaningless.
#
# clk50 must be a group in its own right.  Leaving it out is what made the
# Wukong's first build fail a recovery check into the SCC.
set_clock_groups -asynchronous \
    -group [get_clocks clk50] \
    -group [get_clocks net_tx_clk] \
    -group [get_clocks net_rx_clk] \
    -group [get_clocks {*clkgen*pll_a*}] \
    -group [get_clocks {*clkgen*pll_b*}] \
    -group [get_clocks {*ddr3*DDR3_PLL*}] \
    -group [get_clocks {*vidclk*pll_v*}]

# The pixel bus is source-synchronous at 108 MHz and has to be constrained as
# one.  A false path here would report a clean build for a bus that arrives
# whenever it likes.  tCO figures from BrianHG's DECA project, whose comment
# says -7.5 for a -6 part, which this device is.  With no frame buffer fitted
# these ports exist but carry nothing, and get_ports still matches them.
set_output_delay -clock [get_clocks {*vidclk*pll_v*}] -max -7.500 \
    [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
set_output_delay -clock [get_clocks {*vidclk*pll_v*}] -min -3.800 \
    [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
set_false_path -to   [get_ports {HDMI_TX_CLK HDMI_I2C_SCL HDMI_I2C_SDA}]
set_false_path -from [get_ports {HDMI_I2C_SDA HDMI_TX_INT}]

# ------------------------------------------------------------- false paths
# The DDR3 controller's own clocks are unrelated to the machine's: the adapter
# crosses between them with a two-phase toggle handshake and three-stage
# synchronisers, which is the whole point of doing it that way.  Timing those
# paths would be meaningless, and leaving the group out is what makes a
# recovery check fail on a crossing that should have been ignored -- the lesson
# wukong_common.xdc records.

# CRS and COL are asynchronous to both MII clocks by clause 22 -- the same
# argument wukong_common.xdc makes for the Wukong's PHY.
set_false_path -from [get_ports {NET_CRS NET_COL}]

# Buttons and switches are human-operated and synchronised in logic.
set_false_path -from [get_ports {KEY[*] SW[*]}]

# Outputs nothing samples on a clock: LEDs, the debug headers, the PHY's reset
# and its management pins.  Real input/output delays on the MII belong here in
# stage 3, when the PHY is actually brought up; false-pathing them now is
# honest only because nothing drives them yet, and this comment is the record
# of that debt.
set_false_path -to   [get_ports {LED[*] GPIO0_D[*] GPIO1_D[*]}]
set_false_path -to   [get_ports {NET_RESET_n NET_PCF_EN NET_MDC}]
set_false_path -from [get_ports NET_MDIO]
set_false_path -to   [get_ports NET_MDIO]

# The micro-SD, in SPI mode.  There is deliberately no create_clock on SD_CLK:
# it is a counter-divided output of cpu_clk inside sd_spi.sv, not a clock net,
# so there is no clock here to constrain.  MISO comes back from a card whose
# only timing relationship to us is the one blk_sd enforces in logic.
set_false_path -from [get_ports SD_MISO]
set_false_path -to   [get_ports {SD_CLK SD_CMD SD_CS_N SD_DAT1 SD_DAT2 SD_SEL \
                                 SD_CMD_DIR SD_D0_DIR SD_D123_DIR}]
