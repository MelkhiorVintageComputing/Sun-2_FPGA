create_clock -name MAX10_CLK1_50 -period 20.000 [get_ports MAX10_CLK1_50]
derive_clock_uncertainty

# The card is an asynchronous device on a slow serial link; blk_sd samples MISO
# with the same clock it drives SCK from, and the SPI divider guarantees the
# margin.  Constraining these as timed paths would be a fiction.
set_false_path -to   [get_ports {SD_* LED[*]}]
set_false_path -from [get_ports {SD_MISO}]
