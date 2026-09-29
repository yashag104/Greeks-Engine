# Test run_jtag.tcl / run_sweep.tcl with no board, in any Tcl 8.6 (Git for
# Windows ships one: <Xilinx>\tps\win64\git-*\mingw64\bin\tclsh.exe):
#   cd zedboard ; tclsh mock/drive.tcl       -> three PASS lines
#   cd zedboard ; tclsh mock/drive_neg.tcl   -> exactly cases 7 and 12 FAIL
# Emulates one GUI session: leftover argv, single run, sweep, single run again.
set here [file dirname [file dirname [file normalize [info script]]]]
source [file join [file dirname [info script]] mock_vivado.tcl]
foreach f {heston_aad_z7h_lite_vector.tcl heston_aad_z7h_lite_sweep.tcl} {
  unset -nocomplain VEC_CASES VEC_WRITES VEC_EXPECT
  source "$here/../../gen/build/$f"
  if {![info exists VEC_CASES]} { set VEC_CASES [list [list x $VEC_WRITES $VEC_EXPECT]] }
  lappend ::cases {*}$VEC_CASES
}
cd $here
set argv 70
foreach s {run_jtag.tcl run_sweep.tcl run_jtag.tcl} {
  puts "=================== source $s"
  set ::ntx 0
  source $s
  puts "MOCK: $::ntx AXI transactions"
}
