# MIG configuration

`sun2_mig.prj` configures the MIG 7 Series DDR3 controller for the QMTech
Wukong V1. It is the source of truth; everything MIG generates from it lands in
`build/ip/` and is not committed.

Keep this file free of XML comments — MIG's parser fails on them, reporting the
target device as empty and then segfaulting.

## Provenance

Derived from QMTech's own board example, `mig_a.prj`, inside
`Inputs/doc/QM_XC7A100T_WUKONG_BOARD/V1/Software/Test04_DDR3_mig_7series_0_3_ex.zip`
(`mig_7series_0_ex.ip_user_files/mem_init_files/mig_a.prj`). Its `<Version>` is
4.2, the same MIG version Vivado 2025.2 ships, so it imports with no migration.

The 50 pin assignments are the vendor's, left exactly as they were. They agree
pin-for-pin with the V1 schematic and with the old LiteX build.

## Changes from QMTech's file — and only these

| Field | From | To | Why |
|---|---|---|---|
| `ModuleName` | `mig_7series_0` | `sun2_mig` | ours |
| `Debug_En` | `ON` | `OFF` | no ILA/VIO debug cores in our build |
| `ReferenceClock` | `Use System Clock` | `No Buffer` | MIG only allows "Use System Clock" when the input clock *is* 200 MHz. Ours is 166.667 MHz, so IDELAYCTRL takes its own exact 200 MHz from `wukong_clkgen`. |
| `FPGADevice/selected` | `7a/xc7a75t-fgg676` | `7a/xc7a100t-fgg676` | stale in the vendor file; `TargetFPGA` already said 100T |
| `System_Control` pins | `sys_rst`=H7, `init_calib_complete`=J6, `tg_compare_error`=H6 | all `No connect` | see below |

QMTech's demo brings the system signals out to real board pins — the user
button and the two user LEDs. We drive `sys_rst` from the reset sequencer in
`wukong_top.sv` and consume `init_calib_complete` in the same logic, so
those must not be pins; left as they were, MIG's generated XDC would constrain
top-level ports that do not exist, and would lay claim to H7/J6/H6 which we
want for the button and LEDs. `PADName="No connect"` is the syntax MIG accepts,
and it drops the `PACKAGE_PIN`/`IOSTANDARD` lines while keeping the internal
`set_false_path` on the IODELAY reset. The 47 DDR3 pin constraints are
unaffected.

## Deliberately not changed

* **`MemoryDevice` = `MT41K128M16XX-15E`.** The board fits an
  MT41K128M16JT-125, which MIG's library does not list. `-15E` is the nearest
  entry and marginally more conservative (tRCD/tRP 13.5 ns vs 13.75 ns, which
  round to the same clock count at this period).
* **`TimePeriod` = 3000 ps** → DDR3-667, `ui_clk` 83.33 MHz. A -2 part can
  reach 2500 ps (800 Mbps) in 4:1 mode, but with no margin above it, and a
  12.5 MHz 68010 needs a rounding error of that bandwidth. This is the
  operating point QMTech validated on this board.
* **`emrCSSelection` = `Disable`.** The DRAM's `CS#` (U9 pin L2, net `DDR_CS`)
  is tied low on the board through R35, a 4.7 kΩ pull-down, and is not routed
  to the FPGA at all — see sheet 3 of the V1 schematic,
  `Inputs/doc/QM_XC7A100T_WUKONG_BOARD/V1/Hardware/`. E22 is an unnamed free
  I/O. Note the old LiteX XDC gets this wrong, constraining `ddram_cs_n` to
  E22, a pin connected to nothing; QMTech's `.ucf` and `.prj` both correctly
  omit it.
* **`PortInterface` = `NATIVE`.** `boards/Wukong/wb_to_mig_ui.sv` adapts Wishbone
  to it directly. `app_wdf_mask` gives per-byte write masking, so no
  read-modify-write is needed.
