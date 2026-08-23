set_property -dict {PACKAGE_PIN M22 IOSTANDARD LVCMOS33} [get_ports clk50]
create_clock -period 20.000 -name clk50 [get_ports clk50]

set_property -dict {PACKAGE_PIN D4 IOSTANDARD TMDS_33} [get_ports tmds_clk_p]
set_property -dict {PACKAGE_PIN C4 IOSTANDARD TMDS_33} [get_ports tmds_clk_n]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD TMDS_33} [get_ports {tmds_p[0]}]
set_property -dict {PACKAGE_PIN D1 IOSTANDARD TMDS_33} [get_ports {tmds_n[0]}]
set_property -dict {PACKAGE_PIN F2 IOSTANDARD TMDS_33} [get_ports {tmds_p[1]}]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD TMDS_33} [get_ports {tmds_n[1]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD TMDS_33} [get_ports {tmds_p[2]}]
set_property -dict {PACKAGE_PIN G1 IOSTANDARD TMDS_33} [get_ports {tmds_n[2]}]

set_property -dict {PACKAGE_PIN J6 IOSTANDARD LVCMOS33} [get_ports {user_led[0]}]
set_property -dict {PACKAGE_PIN H6 IOSTANDARD LVCMOS33} [get_ports {user_led[1]}]

# The V1's 50 MHz ball is not clock-capable, so the route from the input
# buffer to the MMCM cannot use dedicated clock routing -- same override the
# Sun-2 build carries in syn/wukong_v1.xdc.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk50_IBUF]
