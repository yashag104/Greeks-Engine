# Test run_jtag.tcl / run_sweep.tcl for the ZCU104 with no board, in any Tcl 8.6:
#   cd zcu104 ; tclsh mock/drive.tcl       -> four PASS lines
# Reuses the ZedBoard mock of Vivado's hardware manager with a ZCU104 JTAG chain
# (arm_dap_0, then xczu7_0) and the 64-bit design's vectors.
set here [file dirname [file dirname [file normalize [info script]]]]
source [file join $here ../zedboard/mock/mock_vivado.tcl]
set ::mock_wl 64                       ;# the engine returns 64-bit words
proc get_hw_devices {args} {
  set all {arm_dap_0 xczu7_0}
  set pat [lindex [lsearch -inline -all -not $args -*] end]
  if {$pat eq ""} { return $all }
  return [lsearch -all -inline -glob $all $pat]
}
proc current_hw_device {d} { if {$d ne "xczu7_0"} { error "mock: programmed wrong device $d" } }
proc get_property {p obj} {
  if {$p eq "PART"} { return xczu7ev }
  if {$p eq "DATA"} { return [dict get $::txn $obj DATA] }
}
foreach f {heston_aad_zu_lite_vector.tcl heston_aad_zu_lite_sweep.tcl heston_aad_zu_lite_nifty.tcl} {
  unset -nocomplain VEC_CASES VEC_WRITES VEC_EXPECT
  source "$here/../../gen/build/$f"
  if {![info exists VEC_CASES]} { set VEC_CASES [list [list x $VEC_WRITES $VEC_EXPECT]] }
  lappend ::cases {*}$VEC_CASES
}
cd $here
# Never touch the real project: a real build may be running in proj/. The base
# address and a placeholder bitstream are passed as arguments instead, which
# run_jtag.tcl accepts (argv: <base_addr_hex> <bitfile>).
set tmpdir [file join [expr {[info exists ::env(TEMP)] ? $::env(TEMP) : "/tmp"}] zcu104_mock_[pid]]
file mkdir $tmpdir
set fakebit [file join $tmpdir heston_jtag_wrapper.bit]
close [open $fakebit w]
set argv [list 0x00000000 $fakebit]
foreach s {run_jtag.tcl run_sweep.tcl run_nifty.tcl run_jtag.tcl} {
  puts "=================== source $s"
  set ::ntx 0
  source $s
  puts "MOCK: $::ntx AXI transactions"
}
file delete -force $tmpdir
