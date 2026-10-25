# ============================================================================
# Program the ZCU102 and run one evaluation over JTAG, checking all 10 outputs
# (price + 9 Greeks, computed entirely on chip) bit-exact against the emulator.
# The checking logic is zedboard/run_jtag.tcl; this file only points it at the
# ZCU102 project, its FPGA (xczu9) and the 64-bit design's vectors.
#
#   vivado -mode batch -nojournal -log run_jtag.log -source run_jtag.tcl
#   (or ./run_board.sh test; from the Vivado GUI Tcl console: source run_jtag.tcl)
#
# Prerequisites: bd_jtag.tcl built the bitstream; the board is powered, its
# JTAG USB port is connected, and the boot-mode switch (SW6) is set to JTAG.
# ============================================================================
set ::JTAG_DIR [file dirname [file normalize [info script]]]
set ::JTAG_DEVICE xczu9*
set ::JTAG_BOARD ZCU102
if {![info exists ::JTAG_VEC]} {
  set ::JTAG_DEFAULT_VEC [file normalize "$::JTAG_DIR/../../gen/build/heston_aad_zu_lite_vector.tcl"]
}
source [file join $::JTAG_DIR ../zedboard/run_jtag.tcl]
