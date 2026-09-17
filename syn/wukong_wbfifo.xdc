# Read by syn/build.tcl for the FIFO bridge (WB_FIFO=1).  The crossing between
# cpu_clk and MIG's ui_clk is inside sun2_fifo_bridge, in two sun2_async_fifo
# instances: req_fifo writes on cpu_clk and reads on ui_clk, rsp_fifo the other
# way.  wb_mig_sync, beyond it, is entirely in ui_clk.  The cpu_clk handle comes
# from wukong_common.xdc, which is read first.
#
# What crosses, per FIFO: the registered gray write pointer into the read
# side's first synchroniser, the registered gray read pointer into the write
# side's, and the storage -- read asynchronously, as LUT RAM -- into whatever
# the read side registers from its head.  Each is bounded by the destination
# clock's period, as wb_to_mig_ui's paths were: generous for a pointer that
# has a whole extra synchroniser stage behind it, and a real bound for the
# storage, which is stable for two read clocks before the read side looks.
#
# `get_cells -hier -filter' rather than literal paths, because the bridge sits
# under machine/sun2/wbridge and a literal path that stops matching after a
# hierarchy change is dropped with nothing louder than a warning.  build.tcl
# checks that every one of these lists is non-empty.

set cpu_period [get_property PERIOD $cpu_clk]
set ui_period  12.000

# request FIFO: cpu_clk -> ui_clk
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *wbridge/req_fifo/wgray_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *wbridge/req_fifo/wgray_r1_reg[*]}] $ui_period
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *wbridge/req_fifo/rgray_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *wbridge/req_fifo/rgray_w1_reg[*]}] $cpu_period
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *wbridge/req_fifo/mem_reg*}] \
    -to   [get_clocks clk_pll_i] $ui_period

# response FIFO: ui_clk -> cpu_clk
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *wbridge/rsp_fifo/wgray_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *wbridge/rsp_fifo/wgray_r1_reg[*]}] $cpu_period
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *wbridge/rsp_fifo/rgray_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *wbridge/rsp_fifo/rgray_w1_reg[*]}] $ui_period
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *wbridge/rsp_fifo/mem_reg*}] \
    -to   $cpu_clk $cpu_period
