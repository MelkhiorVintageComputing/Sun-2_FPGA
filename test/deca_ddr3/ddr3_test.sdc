# Timing for the standalone DDR3 test.
#
# The controller's PLL generates every DDR3-side clock, so derive_pll_clocks
# does the real work -- and it must come before anything that names a generated
# clock, the ordering lesson this project has recorded for both XDC and SDC.
create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]
derive_pll_clocks -create_base_clocks
derive_clock_uncertainty

set_false_path -from [get_ports {KEY[*]}]
set_false_path -to   [get_ports {LED[*]}]
