# Negative control: the board model corrupts case 7 and raises range_err on case 12.
# emulate one GUI session: leftover argv, single run, sweep, single run again
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
# corrupt: case 7 (sweep index 6) sum_v0 off by 1 LSB in the board model; case 12 raises range_err
set e [lindex $::cases 7 2]; lset e 3 2 [expr {[lindex $e 3 2] + 1}]; lset ::cases 7 2 $e
rename start start_ok
proc start {} { start_ok; if {[rd 8] == [lindex $::cases 12 1 2 1] && [rd 12] == [lindex $::cases 12 1 3 1]} { dict set ::mem 260 3 } }
foreach s {run_sweep.tcl} {
  puts "=================== source $s"
  set ::ntx 0
  source $s
  puts "MOCK: $::ntx AXI transactions"
}
