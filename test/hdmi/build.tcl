# vivado -mode batch -source build.tcl -tclargs MODE OUTDIR
#   MODE is 720 (default) or 1080.
set mode 720
set out  [pwd]
if {[llength $argv] > 0} { set mode [lindex $argv 0] }
if {[llength $argv] > 1} { set out  [lindex $argv 1] }
set here [file normalize [file dirname [info script]]]
set sun2 [file normalize $here/../..]
set part xc7a100tfgg676-2

set defines {}
if {$mode == 1080} { lappend defines HDMI_1080P60 }

create_project -in_memory -part $part
read_verilog -sv [list \
    $sun2/Inputs/hdmi/src/tmds_channel.sv \
    $sun2/Inputs/hdmi/src/serializer.sv \
    $sun2/Inputs/hdmi/src/packet_assembler.sv \
    $sun2/Inputs/hdmi/src/packet_picker.sv \
    $sun2/Inputs/hdmi/src/audio_clock_regeneration_packet.sv \
    $sun2/Inputs/hdmi/src/audio_info_frame.sv \
    $sun2/Inputs/hdmi/src/audio_sample_packet.sv \
    $sun2/Inputs/hdmi/src/auxiliary_video_information_info_frame.sv \
    $sun2/Inputs/hdmi/src/source_product_description_info_frame.sv \
    $sun2/Inputs/hdmi/src/hdmi.sv \
    $here/hdmitest_top.sv ]
read_xdc $here/hdmitest.xdc
if {[llength $defines]} {
    synth_design -top hdmitest_top -part $part -verilog_define $defines
} else {
    synth_design -top hdmitest_top -part $part
}
opt_design
place_design
phys_opt_design
route_design
report_utilization    -file $out/utilization.rpt
report_timing_summary -file $out/timing.rpt

puts "== worst setup [get_property SLACK [get_timing_paths -delay_type max]] ns, \
worst hold [get_property SLACK [get_timing_paths -delay_type min]] ns =="

# Reported, not enforced.  1080p60 violates the BUFG's minimum period here and
# works on the bench anyway -- which is the whole point of this test, so it
# must be able to produce that bitstream.  The Sun-2 build gates on the same
# check; see README.md.
set pwbad {}
foreach line [split [report_pulse_width -all_violators -return_string] "\n"] {
    if {[regexp {^\s*(Min Period|Max Period|Low Pulse Width|High Pulse Width|Max Skew)\s} $line] &&
        [regexp {\s(-\d+\.\d+)\s} $line]} { lappend pwbad [string trim $line] }
}
if {[llength $pwbad]} {
    puts "== pulse width violations (expected at 1080p60) =="
    foreach l $pwbad { puts "     $l" }
} else { puts "== pulse width clean ==" }

write_bitstream -force $out/hdmitest.bit
puts "== wrote $out/hdmitest.bit =="
