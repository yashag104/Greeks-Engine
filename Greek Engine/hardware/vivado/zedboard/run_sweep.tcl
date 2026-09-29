# ============================================================================
# Run the multi-case board test: program the ZedBoard once, then every case in
# heston_aad_z7h_lite_sweep.tcl back to back, each checked bit-exact against
# the emulator. Generate the cases first (in hardware/gen):
#
#   python board_vectors.py --host-setup --name heston_aad_z7h --sweep 48
#
# From the Vivado GUI Tcl console, in this folder:  source run_sweep.tcl
# From a Command Prompt:                            run_board.bat sweep
# ============================================================================
set ::JTAG_VEC [file normalize [file join [file dirname [info script]] \
                ../../gen/build/heston_aad_z7h_lite_sweep.tcl]]
source [file join [file dirname [info script]] run_jtag.tcl]
