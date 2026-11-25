# ============================================================================
# Quick health check of the ZCU102 processor side over JTAG (about 15 s), before
# run_app.tcl:   xsdb probe_ps.tcl     (or ../../vivado/zcu102/run_board.sh probe)
# Lists the debug targets, recovers a hung debug port the way that worked on the
# lab board (rst -dap, then rst -system), and writes and reads back one word of
# the on-chip memory (OCM), where the program and its log live. It programs
# nothing and touches neither the DDR nor the PL.
# ============================================================================
fconfigure stdout -buffering line
set ::t0 [clock seconds]
proc step {msg} { puts [format "PROBE %3ds  %s" [expr {[clock seconds] - $::t0}] $msg]; flush stdout }

step "connect"
connect
step "targets before:"
puts [targets]

proc have {pat} { return [expr {![catch {targets -set -nocase -filter [list name =~ $pat]}]}] }
if {![have "APU*"]} {
  step "APU not visible: resetting the debug port, then the system"
  catch {targets -set -nocase -filter {name =~ "DAP*"}; rst -dap; after 1000; rst -system; after 3000}
} else {
  step "system reset"
  catch {targets -set -nocase -filter {name =~ "APU*"}; rst -system; after 3000}
}
step "targets after reset:"
puts [targets]
if {![have "APU*"]} {
  puts "PROBE RESULT: FAIL - the APU is not reachable even after rst -dap / rst -system."
  puts "              Only a hardware reset (POR_B button or a power cycle) clears this."
  exit 1
}
set a53 [have "*A53*#0"]
step "Cortex-A53 #0 visible: [expr {$a53 ? "yes" : "NO"}]"

targets -set -nocase -filter {name =~ "APU*"}
set ok 1
foreach {addr val} {0xFFFC0000 0x600DCAFE 0xFFFC4000 0x13579BDF 0xFFFFFFF0 0x2468ACE0} {
  if {[catch {mwr -force $addr $val; set got [mrd -force -value $addr]} err]} {
    step "OCM $addr: access error: $err"; set ok 0; continue
  }
  set pass [expr {$got == $val}]
  if {!$pass} { set ok 0 }
  step [format "OCM %s: wrote 0x%08X read 0x%08X  %s" $addr $val $got [expr {$pass ? "ok" : "MISMATCH"}]]
}
if {$ok && $a53} {
  puts "PROBE RESULT: PASS - debug port, APU and OCM all respond; run ./run_board.sh run next"
  exit 0
}
puts "PROBE RESULT: FAIL - see the lines above"
exit 1
