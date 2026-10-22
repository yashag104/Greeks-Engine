# ============================================================================
# Program the board once, then run 50 real-market inputs back to back: the
# Heston parameters calibrated to real NIFTY option quotes on 50 trading days
# (Sep 2025 - Sep 2026; validation/hedging/board_cases.py), each checked
# bit-exact against the emulator. Generate the vectors first (in hardware/gen):
#   python board_vectors.py <config> --name heston_aad_zu --cases-csv ../../validation/hedging/results/board_cases.csv
#
#   From the Vivado GUI Tcl console, in this folder:  source run_nifty.tcl
#   From a Command Prompt:                            run_board.bat nifty
# ============================================================================
set ::JTAG_VEC [file normalize [file join [file dirname [info script]] \
                ../../gen/build/heston_aad_zu_lite_nifty.tcl]]
source [file join [file dirname [info script]] run_jtag.tcl]
