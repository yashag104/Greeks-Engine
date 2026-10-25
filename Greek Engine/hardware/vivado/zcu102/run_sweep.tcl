# ============================================================================
# ZCU102: program once, then all 50 cases of heston_aad_zu_lite_sweep.tcl back
# to back, each checked bit-exact against the emulator. Generate them first:
#   python board_vectors.py --wl 64 --fl 32 --mults 32 --crot 1 --cvec 1 --pipe-cordic \
#          --name heston_aad_zu --sweep 48
#
#   From the Vivado GUI Tcl console, in this folder:  source run_sweep.tcl
#   From a shell:                                     ./run_board.sh sweep
# ============================================================================
set ::JTAG_VEC [file normalize [file join [file dirname [info script]] \
                ../../gen/build/heston_aad_zu_lite_sweep.tcl]]
source [file join [file dirname [info script]] run_jtag.tcl]
