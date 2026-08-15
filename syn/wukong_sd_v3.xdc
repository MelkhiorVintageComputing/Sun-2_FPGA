# The micro-SD slot, J9 on a QMTech Wukong V3.
#
# Read only when XY450=1, because the sd_* ports on wukong_top exist only then.
# The V1 board has no card slot at all -- its feature list runs camera, two
# PMODs, a 40-pin header, switches, LEDs, HDMI, GTP and JTAG, and its schematic
# has no Micro SD symbol -- so it gets syn/wukong_sd_v1.xdc and a PMOD instead.
#
# SPI mode uses four of the six lines: CLK, CMD as MOSI, DAT0 as MISO and DAT3
# as /CS.  All six have 4.7k pull-ups on the board, which is what makes DAT3
# usable as a chip select in the first place -- an idle card sees it high and
# stays in SD mode until CMD0 arrives with it low.
#
# Note for anyone reading syn/wukong_common.xdc: its remark that "bank 34
# carries nothing but Ethernet and is fixed at 3.3 V" was true on a V1 and is
# not true here.  CLK, DAT0 and card detect are in bank 34; CMD and DAT3 are in
# bank 35.  Both banks are 3.3 V, so LVCMOS33 is right either way.

set_property -dict {PACKAGE_PIN L4 IOSTANDARD LVCMOS33} [get_ports sd_clk]
set_property -dict {PACKAGE_PIN J8 IOSTANDARD LVCMOS33} [get_ports sd_cmd]
set_property -dict {PACKAGE_PIN M5 IOSTANDARD LVCMOS33} [get_ports sd_dat0]
set_property -dict {PACKAGE_PIN J6 IOSTANDARD LVCMOS33} [get_ports sd_dat3]
set_property -dict {PACKAGE_PIN N6 IOSTANDARD LVCMOS33} [get_ports sd_cd]

# The card is clocked from a divider off cpu_clk, not from a clock net, so
# there is nothing to create_clock here.  sd_dat0 is sampled synchronously by
# sd_spi half a bit period after the edge that drove sd_clk, which at the
# 25 MHz it settles on is 20 ns of margin against a 3.3 V CMOS input -- but it
# is a genuinely asynchronous input from the tools' point of view, so tell them
# not to try to time it rather than let them meet it by accident.
set_false_path -from [get_ports sd_dat0]
set_false_path -from [get_ports sd_cd]
