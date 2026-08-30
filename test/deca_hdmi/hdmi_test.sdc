# Timing for the standalone DECA HDMI test.
#
# derive_pll_clocks before any clock group, because a group naming a clock that
# does not exist yet is dropped *silently* -- the lesson syn/deca.sdc records
# and the one that carries unchanged from XDC.

create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]
derive_pll_clocks -create_base_clocks
derive_clock_uncertainty

set_clock_groups -asynchronous \
    -group [get_clocks clk50] \
    -group [get_clocks {*vidclk*pll_v*}]

# The pixel bus is source-synchronous at 108 MHz and must be constrained as
# such.  A set_false_path here would be wrong and comfortable: it would report
# a clean build for a bus that arrives whenever it likes.
#
# tCO figures from BrianHG's DECA project, whose comment says to use -7.5 for a
# -6 part, which the DECA's 10M50DAF484C6GES is.
set tCO  -7.500
set tCOm -3.800
set_output_delay -clock [get_clocks {*vidclk*pll_v*}] -max $tCO \
    [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
set_output_delay -clock [get_clocks {*vidclk*pll_v*}] -min $tCOm \
    [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]

# HDMI_TX_CLK is the forwarded clock itself, not data on it.
set_false_path -to [get_ports {HDMI_TX_CLK}]

# I2C is bit-banged at ~100 kHz against a 50 MHz clock and the interrupt is
# synchronised in three flops.  Neither is a timed path.
set_false_path -to   [get_ports {HDMI_I2C_SCL HDMI_I2C_SDA}]
set_false_path -from [get_ports {HDMI_I2C_SDA HDMI_TX_INT}]

set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to   [get_ports {LED[*]}]
