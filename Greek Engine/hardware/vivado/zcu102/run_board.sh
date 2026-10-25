#!/bin/sh
# ZCU102 bring-up of the 64-bit engine on Linux (Vivado in PATH: source settings64.sh first).
#
#   ./run_board.sh dry            block design only: checks board files, part, clock (minutes)
#   ./run_board.sh build [mhz]    bd_jtag.tcl -> bitstream (default 100 MHz)
#   ./run_board.sh test           program the board, one case, all 10 outputs bit-exact
#   ./run_board.sh sweep          50 cases back to back
#   ./run_board.sh nifty          50 real NIFTY inputs back to back
cd "$(dirname "$0")" || exit 1
command -v vivado >/dev/null || { echo "vivado not in PATH: source <install>/Vivado/<ver>/settings64.sh"; exit 1; }
v() { vivado -mode batch -nojournal -log "$1" -source "$2" ${3:+-tclargs $3}; }
case "$1" in
  dry)   v bd_jtag.log bd_jtag.tcl dry;  grep -E "^(RESULT|ERROR)" bd_jtag.log ;;
  build) v bd_jtag.log bd_jtag.tcl "$2"; grep -E "^(RESULT|WARNING: timing|ERROR)" bd_jtag.log ;;
  test)  v run_jtag.log run_jtag.tcl;    grep -E "^(PASS|FAIL|ERROR|INFO:|  ok)" run_jtag.log ;;
  sweep) v run_sweep.log run_sweep.tcl;  grep -E "^(PASS|FAIL|ERROR|INFO:|CASE)" run_sweep.log ;;
  nifty) v run_nifty.log run_nifty.tcl;  grep -E "^(PASS|FAIL|ERROR|INFO:|CASE)" run_nifty.log ;;
  *) echo "usage: ./run_board.sh dry | build [clk_mhz] | test | sweep | nifty"; exit 1 ;;
esac
