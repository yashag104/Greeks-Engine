# ============================================================================
# Program the ZCU104 and run one evaluation over JTAG, checking all 10 outputs
# (price + 9 Greeks, computed entirely on chip) bit-exact against the emulator.
# The checking logic is zedboard/run_jtag.tcl; this file only points it at the
# ZCU104 project, its FPGA (xczu7) and the 64-bit design's vectors.
#
#   From the Vivado GUI Tcl console, in this folder:  source run_jtag.tcl
#   From a Command Prompt:                            run_board.bat test
#
# Prerequisites: bd_jtag.tcl built the bitstream; the board is powered, its
# JTAG USB port is connected, and the boot-mode switch (SW6) is set to JTAG.
# Generate the vectors first (in hardware/gen):
#   python board_vectors.py --wl 64 --fl 32 --mults 32 --crot 1 --cvec 1 --pipe-cordic --name heston_aad_zu
# ============================================================================
set ::JTAG_DIR [file dirname [file normalize [info script]]]
set ::JTAG_DEVICE xczu*
set ::JTAG_BOARD ZCU104
if {![info exists ::JTAG_VEC]} {
  set ::JTAG_DEFAULT_VEC [file normalize "$::JTAG_DIR/../../gen/build/heston_aad_zu_lite_vector.tcl"]
}
source [file join $::JTAG_DIR ../zedboard/run_jtag.tcl]
