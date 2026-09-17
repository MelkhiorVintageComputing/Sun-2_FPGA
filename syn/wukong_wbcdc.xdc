# Read by syn/build.tcl for the synchronous bridge (WB_FIFO=0), where
# wb_to_mig_ui crosses from cpu_clk to MIG's ui_clk.  The cpu_clk handle comes
# from wukong_common.xdc, which is read first.

# ---------------------------------------------------------------------------
# The Wishbone/MIG clock crossing
# ---------------------------------------------------------------------------
# wb_to_mig_ui crosses with a two-phase toggle handshake.  The toggles go
# through two-flop synchronisers; the address, data and read-data buses are
# held stable for the whole transaction and so are a classic multi-cycle path.
# Bound both by one destination clock period rather than leaving them false, so
# a wildly slow route still gets flagged.
#
# Ask the design what the CPU period actually is rather than writing it down:
# this used to be a literal 80.000, which is 12.5 MHz, and stayed 80 ns when
# built at CPU_HZ=40000000 -- leaving these four bounds 3.2x too loose without
# failing, because they are upper bounds on datapaths rather than clock
# constraints.
set cpu_period [get_property PERIOD $cpu_clk]
set ui_period  12.000

set_max_delay -datapath_only \
    -from [get_cells adapter/req_tgl_reg] \
    -to   [get_cells adapter/req_tgl_s1_reg] $ui_period
set_max_delay -datapath_only \
    -from [get_cells adapter/ack_tgl_reg] \
    -to   [get_cells adapter/ack_tgl_s1_reg] $cpu_period

# clk_pll_i is MIG's ui_clk (83.33 MHz); the name is MIG's own and appears in
# build/syn/vivado/*/clocks.rpt if it ever changes.
set_max_delay -datapath_only \
    -from [get_cells {adapter/req_adr_reg[*] adapter/req_dat_reg[*] \
                      adapter/req_sel_reg[*] adapter/req_we_reg}] \
    -to   [get_clocks clk_pll_i] $ui_period
set_max_delay -datapath_only \
    -from [get_cells {adapter/rd_lane_reg[*]}] \
    -to   $cpu_clk $cpu_period

