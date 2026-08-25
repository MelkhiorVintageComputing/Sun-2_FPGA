# An SD card on a QMTech Wukong V1, which has no slot of its own.
#
# Read only when XY450=1.  The V1's feature list runs camera, two PMODs, a
# 40-pin header, switches, LEDs, HDMI, GTP and JTAG; there is no Micro SD
# symbol anywhere in its schematic.  So a disk on this board means a breakout
# on PMOD **J11**, which is unused on both revisions and is the same four balls
# either way -- BANK35_H4/F4/A4/A5 on the top row, J4/G4/B4/B5 on the bottom
# (V3 schematic, sheet with J11; the V1 sheet gives the same four).
#
# The assignment below is the **Digilent PMOD Interface Type 2 (SPI)**
# convention -- pin 1 /CS, pin 2 MOSI, pin 3 MISO, pin 4 SCK -- because that is
# what an off-the-shelf micro-SD PMOD expects.  It is a convention, not
# something measured on this board: nothing has ever been plugged in here.
# Check it against whatever breakout is actually used before trusting it.
#
# All four are in bank 35, which is 3.3 V.

set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33} [get_ports sd_dat3]  ;# pin 1, /CS
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33} [get_ports sd_cmd]   ;# pin 2, MOSI
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33} [get_ports sd_dat0]  ;# pin 3, MISO
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports sd_clk]   ;# pin 4, SCK
set_property -dict {PACKAGE_PIN J4 IOSTANDARD LVCMOS33} [get_ports sd_cd]    ;# pin 7, card detect

# Asynchronous as far as the tools are concerned -- see the note in
# syn/wukong_sd_v3.xdc.
set_false_path -from [get_ports sd_dat0]
set_false_path -from [get_ports sd_cd]
