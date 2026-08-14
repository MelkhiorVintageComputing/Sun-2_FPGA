# Timing for the frame buffer's HDMI output.
#
# Read by syn/build.tcl only when FB=1, because the clocks named here do not
# exist otherwise and a set_clock_groups naming a clock that is not there is
# dropped in silence.  It is a separate file rather than an `if' in
# wukong_common.xdc because Vivado's XDC parser does not accept `if'.
#
# One group on its own means "asynchronous to every clock outside it", which is
# exactly the claim: the pixel clock and its 5x partner are related to each
# other and to nothing else in the design.
#
# This matters more than it looks.  fb_scanout's line buffer is written on
# MIG's ui_clk and read on the pixel clock, and the two toggles that carry
# start-of-frame and start-of-line cross the same way.  Without this the tools
# time those as though the clocks were related, and the build misses by
# nanoseconds on paths that are asynchronous by construction.
set_clock_groups -asynchronous -group [get_clocks {mmcm_pixel mmcm_x5}]
