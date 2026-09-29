# Stand-in for the Vivado hw_* commands: a register-file model of the
# AXI4-Lite engine that answers with the emulator's expected sums for
# whichever case's inputs were written. Tests run_jtag.tcl's plumbing only.
set ::mem [dict create]
set ::cases {}
set ::txn [dict create]
set ::ntx 0
proc open_hw_manager {args} {}
proc close_hw_manager {args} {}
proc get_hw_servers {args} { return localhost:3121 }
proc connect_hw_server {args} {}
proc open_hw_target {args} {}
proc get_hw_devices {args} {
  set all {arm_dap_0 xc7z020_1}
  set pat [lindex [lsearch -inline -all -not $args -*] end]
  if {$pat eq ""} { return $all }
  return [lsearch -all -inline -glob $all $pat]
}
proc current_hw_device {d} { if {$d ne "xc7z020_1"} { error "mock: programmed wrong device $d" } }
proc set_property {args} {}
proc program_hw_devices {d} { puts "INFO: \[Labtools 27-3164\] End of startup status: HIGH"; set ::mem [dict create] }
proc refresh_hw_device {args} {}
proc get_hw_axis {args} { return hw_axi_1 }
proc reset_hw_axi {args} {}
proc get_hw_axi_txns {args} {
  set n [lindex [lsearch -inline -all -not $args -*] end]
  if {$n eq ""} { return [dict keys $::txn] }
  if {[dict exists $::txn $n]} { return $n }
  return {}
}
proc delete_hw_axi_txn {args} { foreach n [lindex [lsearch -inline -all -not $args -*] end] { dict unset ::txn $n } }
proc create_hw_axi_txn {args} {
  set pos [lsearch -inline -all -not $args -*]
  set name [lindex $pos 0]
  if {[dict exists $::txn $name]} { return }   ;# -quiet: silently keeps the stale one, as Vivado does
  set d [dict create]
  foreach k {-address -data -type} { set i [lsearch $args $k]; if {$i >= 0} { dict set d $k [lindex $args [expr {$i+1}]] } }
  dict set ::txn $name $d
}
proc rd {a} { if {[dict exists $::mem $a]} { return [dict get $::mem $a] } ; return 0 }
proc run_hw_axi {args} {
  incr ::ntx
  set name [lindex [lsearch -inline -all -not $args -*] end]
  set t [dict get $::txn $name]
  set a [expr {"0x[dict get $t -address]" + 0}]
  if {$a >= 0x1000} { dict set ::txn $name DATA ""; return }   ;# outside the 4K slave: DECERR
  if {[dict get $t -type] eq "write"} {
    set v [expr {"0x[dict get $t -data]" + 0}]
    if {$a == 0x100 && ($v & 1)} { start } else { dict set ::mem $a $v }
  } else {
    dict set ::txn $name DATA [format %08x [rd $a]]
  }
}
proc get_property {p obj} {
  if {$p eq "PART"} { return xc7z020 }
  if {$p eq "DATA"} { return [dict get $::txn $obj DATA] }
}
# on start: find the case whose input words match what was written
proc start {} {
  foreach c $::cases {
    lassign $c label writes expect
    set hit 1
    foreach w $writes { if {[rd [expr {[lindex $w 0]}]] != [lindex $w 1]} { set hit 0; break } }
    if {!$hit} continue
    foreach e $expect {
      lassign $e n off v
      set raw [expr {$v & ((1 << 56) - 1)}]
      dict set ::mem [expr {$off}] [expr {$raw & 0xffffffff}]
      dict set ::mem [expr {$off + 4}] [expr {$raw >> 32}]
    }
    dict set ::mem 0x104 1
    dict set ::mem 260 1
    return
  }
  error "mock: no case matches the written inputs"
}
