# ============================================================================
# Implementation only, resumed from a checkpoint. Synthesis of this design
# takes ~17 minutes; there is no reason to repeat it when only routing failed.
#
#   vivado -mode batch -source impl_from_dcp.tcl -tclargs <outdir> [<clk_ns>]
#
# Picks up post_place.dcp if it exists, else post_synth.dcp, and runs the rest
# of the flow, writing the same reports and summary.txt that synth_impl.tcl
# does so parse_reports.py works either way.
# ============================================================================
set outdir [lindex $argv 0]
set clk_ns [expr {[llength $argv] > 1 ? [lindex $argv 1] : 10.0}]

set placed "$outdir/post_place.dcp"
set synthd "$outdir/post_synth.dcp"
if {[file exists $placed]} {
  puts "INFO: resuming from post_place.dcp (routing only)"
  open_checkpoint $placed
  set from_placed 1
} elseif {[file exists $synthd]} {
  puts "INFO: resuming from post_synth.dcp (opt/place/route)"
  open_checkpoint $synthd
  set from_placed 0
} else {
  puts "ERROR: no checkpoint in $outdir; run synth_impl.tcl first"
  exit 1
}

if {!$from_placed} {
  opt_design
  place_design
  write_checkpoint -force "$outdir/post_place.dcp"
}
phys_opt_design
route_design
write_checkpoint -force "$outdir/post_route.dcp"

report_utilization    -file "$outdir/util.rpt"
report_utilization    -hierarchical -file "$outdir/util_hier.rpt"
report_timing_summary -file "$outdir/timing.rpt"
report_power          -file "$outdir/power.rpt"

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fp [open "$outdir/summary.txt" w]
puts $fp "top [get_property TOP [current_design]]"
puts $fp "part [get_property PART [current_design]]"
puts $fp "clk_ns $clk_ns"
puts $fp "wns_ns $wns"
close $fp
puts "RESULT: WNS = $wns ns at a ${clk_ns} ns target"
