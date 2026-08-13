# What is specific to the QMTech Wukong V3 (XC7A100T-1FGG676C).
#
# Read *before* syn/wukong_common.xdc, which holds everything the revisions
# share.  The order is load-bearing: common creates the MII clocks and then
# groups them, and a get_clocks for a clock that does not exist yet returns
# nothing and drops the group silently -- no error, no warning, just an
# asynchronous crossing that quietly gets timed.
#
# Only five things differ from a V1.  DDR3, Ethernet, the serial console and
# the PMOD are on identical balls: QMTech's V1 and V3 DDR3.ucf files diff
# clean, their two GMII reference designs give the same eighteen pins, and the
# two hardware manuals give the same J10 table.  Pin assignments here are from
# the V3 board's own reference designs --
# Inputs/doc/QM_XC7A100T_WUKONG_BOARD/V3/Software/XC7A100T/.

# The 50 MHz oscillator.  M21 *is* clock-capable, so unlike the V1 there is
# deliberately no CLOCK_DEDICATED_ROUTE override here.
set_property -dict {PACKAGE_PIN M21 IOSTANDARD LVCMOS33} [get_ports clk50]

# Reset button, active low.  This is KEY0, which on a V1 was the spare button.
set_property -dict {PACKAGE_PIN H7 IOSTANDARD LVCMOS33} [get_ports cpu_reset]

# On-board LEDs, active low: user_led[0] lit = out of reset.
# user_led[1] answers whichever question is still open -- lit = DRAM
# calibrated until the PHY bring-up finishes, and lit = link up after it.
set_property -dict {PACKAGE_PIN G21 IOSTANDARD LVCMOS33} [get_ports {user_led[0]}]
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} [get_ports {user_led[1]}]

# The second button, KEY1.  Nothing reads it yet; it is constrained so the port
# has somewhere to go.
set_property -dict {PACKAGE_PIN M6 IOSTANDARD LVCMOS33} [get_ports user_btn]
