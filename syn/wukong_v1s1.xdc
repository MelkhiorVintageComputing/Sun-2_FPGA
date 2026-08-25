# What is specific to the QMTech Wukong V1 (XC7A100T-2FGG676I).
#
# Read *before* syn/wukong_common.xdc, which holds everything the revisions
# share.  The order is load-bearing: common creates the MII clocks and then
# groups them, and a get_clocks for a clock that does not exist yet returns
# nothing and drops the group silently -- no error, no warning, just an
# asynchronous crossing that quietly gets timed.
#
# Only five things differ from a V3.  Pin assignments are from
# Old/qmtech_wukong_V1_0.xdc, which agrees with QMTech's own documentation.

# The 50 MHz oscillator.
set_property -dict {PACKAGE_PIN M22 IOSTANDARD LVCMOS33} [get_ports clk50]

# On the V1 this ball is not clock-capable, so the route from the input buffer
# to the MMCMs cannot use dedicated clock routing and Vivado has to be told to
# allow it.  The V3 moved the oscillator to M21, which is clock-capable, and
# must not carry this override.  If synthesis renames the net, the placer error
# message names the one to use here.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk50_IBUF]

# Reset button, active low.
set_property -dict {PACKAGE_PIN J8 IOSTANDARD LVCMOS33} [get_ports cpu_reset]

# On-board LEDs, active low: user_led[0] lit = out of reset.
# user_led[1] answers whichever question is still open -- lit = DRAM
# calibrated until the PHY bring-up finishes, and lit = link up after it.
set_property -dict {PACKAGE_PIN J6 IOSTANDARD LVCMOS33} [get_ports {user_led[0]}]
set_property -dict {PACKAGE_PIN H6 IOSTANDARD LVCMOS33} [get_ports {user_led[1]}]

# The second button.  Nothing reads it yet; it is constrained so the port has
# somewhere to go.
set_property -dict {PACKAGE_PIN H7 IOSTANDARD LVCMOS33} [get_ports user_btn]
