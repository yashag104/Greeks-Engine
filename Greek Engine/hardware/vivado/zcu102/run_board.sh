#!/bin/sh
# ZCU102 bring-up of the 64-bit engine on Linux (Vivado in PATH: source settings64.sh first).
#
# JTAG system (Vivado drives the engine over the JTAG cable):
#   ./run_board.sh dry            block design only: checks board files, part, clock (minutes)
#   ./run_board.sh build [mhz]    bd_jtag.tcl -> bitstream (default 100 MHz)
#   ./run_board.sh test           program the board, one case, all 10 outputs bit-exact
#   ./run_board.sh sweep          50 cases back to back
#   ./run_board.sh nifty          50 real NIFTY inputs back to back
# Processor system (the Cortex-A53 drives the engine; timing over the bus and PL power):
#   ./run_board.sh psdry          bd_ps.tcl block design only (minutes)
#   ./run_board.sh ps             bd_ps.tcl -> bitstream + heston_zcu102_ps.xsa
#   ./run_board.sh app            Vitis: the bare-metal program (needs vitis in PATH)
#   ./run_board.sh run            xsdb: program, run, save ../../sw/zcu102/zcu102_ps_run.log
cd "$(dirname "$0")" || exit 1
SW=../../sw/zcu102
need() { command -v "$1" >/dev/null || { echo "$1 not in PATH: source <install>/$2/settings64.sh"; exit 1; }; }
v() { need vivado Vivado; vivado -mode batch -nojournal -log "$1" -source "$2" ${3:+-tclargs $3}; }
case "$1" in
  dry)   v bd_jtag.log bd_jtag.tcl dry;  grep -E "^(RESULT|ERROR)" bd_jtag.log ;;
  build) v bd_jtag.log bd_jtag.tcl "$2"; grep -E "^(RESULT|WARNING: timing|ERROR)" bd_jtag.log ;;
  test)  v run_jtag.log run_jtag.tcl;    grep -E "^(PASS|FAIL|ERROR|INFO:|  ok)" run_jtag.log ;;
  sweep) v run_sweep.log run_sweep.tcl;  grep -E "^(PASS|FAIL|ERROR|INFO:|CASE)" run_sweep.log ;;
  nifty) v run_nifty.log run_nifty.tcl;  grep -E "^(PASS|FAIL|ERROR|INFO:|CASE)" run_nifty.log ;;
  psdry) v bd_ps.log bd_ps.tcl dry;      grep -E "^(RESULT|ERROR)" bd_ps.log ;;
  ps)    v bd_ps.log bd_ps.tcl;          grep -E "^(RESULT|WARNING: timing|ERROR)" bd_ps.log ;;
  app)   need vitis Vitis
         (cd "$SW" && vitis -s build_vitis.py) > vitis_build.log 2>&1
         grep -E "^(RESULT|ERROR|engine base)" vitis_build.log
         grep -q "^RESULT: built" vitis_build.log || { echo "ERROR: the Vitis build failed; the end of vitis_build.log:"; tail -150 vitis_build.log; exit 1; } ;;
  run)   need xsdb Vitis
         rm -rf "$SW/xsa_x" && unzip -o -j -q heston_zcu102_ps.xsa '*psu_init.tcl' -d "$SW/xsa_x" || exit 1
         (cd "$SW" && xsdb run_app.tcl) 2>&1 | tee xsdb_run.log | grep -E "^(PASS|FAIL|TIMING|  |THROUGHPUT|POWER|ENERGY|RESULT|ERROR|INFO|DONE)" ;;
  *) echo "usage: ./run_board.sh dry | build [clk_mhz] | test | sweep | nifty | psdry | ps | app | run"; exit 1 ;;
esac
