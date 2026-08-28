# Timing for the standalone console test.
#
# derive_pll_clocks before any clock group -- a group naming a clock that does
# not exist yet is dropped silently, which is the lesson syn/deca.sdc records
# and the one that carries unchanged from XDC.

create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]
derive_pll_clocks -create_base_clocks
derive_clock_uncertainty

set_clock_groups -asynchronous \
    -group [get_clocks clk50] \
    -group [get_clocks {*clkgen*pll_a*}] \
    -group [get_clocks {*clkgen*pll_b*}]

set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to   [get_ports {LED[*] GPIO0_D[*]}]
