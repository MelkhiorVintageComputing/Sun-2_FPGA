# What distinguishes one QMTech Wukong revision from another.
#
# Sourced by build.tcl and generate_ip.tcl so the two cannot disagree.
#
# For this design the revisions differ in remarkably little: the FPGA speed
# grade, and four pins.  DDR3, Ethernet, the serial console and the PMOD are on
# identical balls -- established from QMTech's own sources, not inferred, by
# diffing their two DDR3.ucf files (clean), their two GMII reference designs
# (same eighteen pins) and their two hardware manuals (same J10 table).  So
# there is one set of board RTL in boards/Wukong/ and the pins live in
# syn/wukong_<rev>.xdc beside syn/wukong_common.xdc.
#
# On the V3 part: its manual says XC7A100T-1FGG676C, but QMTech's own V3
# example project still says -2 and even names an xc7a75t in another field --
# it was copied from the V1 project and never updated.  We target -1, the
# slower grade, because that is safe in both directions: constraints met on a
# -1 are met by a -2, but not the reverse.  If the chip on the bench turns out
# to be a -2, nothing here needs to change.
#
# v1s1 is a V1 board -- V1 pins, V1 everything -- built for the SLOWER -1 grade,
# and on this bench it is the one to use.
#
# QMTech sold the V1 as a -2 and is known to have shipped -1 dice on some
# boards.  A design signed off against -2 timing on a -1 die has been analysed
# optimistically, and that is not theoretical here: a VME 2/50 built for -2
# stalled in the PROM at "Probing I/O bus: ie" on four builds out of four, with
# timing reported MET throughout, while the identical RTL built for -1 reaches a
# full autoconfig and boots SunOS.  The -2 build had put a hold path inside the
# Ethernet MAC's receive unit at 64 ps (machine/ethernet/mac/u_ru/buf_addr_reg[3]
# -> acc_addr_reg[3]); the -1 build, placed against a much tighter setup
# constraint (WNS 1.281 -> 0.213), does not have it among its tightest at all.
# MultiBus builds and boots on -1 as well, WNS 0.968.
#
# Building -1 is safe in both directions for the same reason the V3 entry gives:
# constraints met on a -1 are met by a -2, never the reverse.  So this costs
# nothing if the die turns out to be a -2 after all.
#
# What this does NOT prove is that the die is a -1.  It proves the -2 build was
# violating something the -2 timing model said was fine, which is equally
# consistent with placement luck.  The discriminator, if it is ever worth the
# board time, is a -2 build with a different placer directive: same part, same
# clock, placement the only variable.
#
# Same XDC as v1, and the same MIG as v3 because the part is identical -- but
# NOT the same ILA: build/ip/<board>/sun2_ila is per board, and seeding v1s1
# from v3 brought a stale 11-probe core that failed synthesis with "probe11 does
# not exist".  Regenerate it (make -C syn ip-ila BOARD=v1s1) rather than copy.
#
# The board is also sold as an XC7A200T in the same package with the same
# pinout.  Adding it would be one more entry below plus its own MIG generation;
# nothing in this design needs the extra resources.

# Vivado part name, for create_project and synth_design.
proc board_part {board} {
    switch -- $board {
        v1      { return xc7a100tfgg676-2 }
        v1s1    { return xc7a100tfgg676-1 }
        v3      { return xc7a100tfgg676-1 }
        default { return "" }
    }
}

# The same part in MIG's own <TargetFPGA> spelling, which is different.
proc board_mig_part {board} {
    switch -- $board {
        v1      { return xc7a100t-fgg676/-2 }
        v1s1    { return xc7a100t-fgg676/-1 }
        v3      { return xc7a100t-fgg676/-1 }
        default { return "" }
    }
}

proc board_check {board} {
    if {[board_part $board] eq ""} {
        puts "ERROR: BOARD must be v1, v1s1 or v3, not '$board'"
        exit 1
    }
}
