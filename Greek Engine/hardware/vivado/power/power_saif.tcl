# ============================================================================
# Power of the routed engine from simulated switching activity (SAIF).
#
#   vivado -mode batch -nojournal -source power_saif.tcl -tclargs <top> <rundir>
#
# <rundir> is an out-of-context run of synth_impl.tcl for <top> (it holds
# post_route.dcp and clock.xdc). Steps:
#   1. write the routed netlist as a functional simulation model
#   2. simulate it in xsim with tb_power_<top>.v (gen_power_tb.py): four
#      evaluations back to back at the clock the design was routed for, every
#      output checked against the emulator, while logging every net's toggles
#   3. read that activity back (read_saif) and report power
# Vectorless power (synth_impl.tcl's power.rpt) assumes 12.5% toggle rates; this
# replaces the assumption with the design's real activity on real inputs.
# Writes <rundir>/power_saif.rpt and <rundir>/power_saif_summary.txt.
# ============================================================================
set top    [lindex $argv 0]
set rundir [file normalize [lindex $argv 1]]
set here   [file dirname [file normalize [info script]]]
set tb     "$here/tb_power_$top.v"
foreach f [list "$rundir/post_route.dcp" $tb] {
  if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
}
set sim "$rundir/saif_sim"
file delete -force $sim     ;# a stale snapshot from an earlier run can block xsim
file mkdir $sim

open_checkpoint "$rundir/post_route.dcp"
write_verilog -mode funcsim -force "$sim/netlist_funcsim.v"

# The xsim tools are .bat files. cmd mis-parses command lines with spaces in
# paths (this repository lives under "Greek Engine"), so a batch file in the
# simulation folder changes into its own folder and uses only relative paths
# and the space-free install paths.
set bin  [file nativename [file join $::env(XILINX_VIVADO) bin]]
set glbl [file nativename [file join $::env(XILINX_VIVADO) data verilog src glbl.v]]
file copy -force $tb "$sim/tb_power.v"
set fp [open "$sim/saif_run.tcl" w]
puts $fp "open_saif activity.saif"
puts $fp "log_saif \[get_objects -r /tb/uut/*\]"
puts $fp "run all"
puts $fp "close_saif"
puts $fp "quit"
close $fp
set fp [open "$sim/run_sim.bat" w]
puts $fp "@echo off"
puts $fp "cd /d \"%~dp0\""
puts $fp "call \"$bin\\xvlog.bat\" netlist_funcsim.v tb_power.v \"$glbl\" || exit /b 1"
puts $fp "call \"$bin\\xelab.bat\" -debug typical -L unisims_ver -s pwr tb glbl || exit /b 1"
puts $fp "call \"$bin\\xsim.bat\" pwr -tclbatch saif_run.tcl -log sim.log"
close $fp
if {[catch {exec [file nativename "$sim/run_sim.bat"]} out]} { puts $out }
set log ""
if {[file exists "$sim/sim.log"]} { set fp [open "$sim/sim.log"]; set log [read $fp]; close $fp }
puts $log
if {![regexp {PASS: power testbench} $log]} {
  puts "ERROR: the netlist simulation did not reproduce the emulator's outputs; no power figure written"
  exit 1
}

read_saif -strip_path tb/uut "$sim/activity.saif"
report_power -file "$rundir/power_saif.rpt"
set fp [open "$rundir/power_saif_summary.txt" w]
puts $fp "top $top"
puts $fp [report_power -return_string]
close $fp
puts "RESULT: power_saif.rpt written; activity from 4 bit-exact netlist evaluations"
