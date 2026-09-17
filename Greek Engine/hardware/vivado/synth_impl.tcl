# ============================================================================
# Out-of-context synthesis + implementation + reports for one design point.
#
#   vivado -mode batch -source synth_impl.tcl -tclargs <top> <part> <clk_ns> <outdir>
#
#   <top>    heston_aad_z7h     (generated AAD loop, setup/finish on the ARM: Zynq-7020 target)
#            heston_aad_z7      (generated shared-multiplier AAD engine, fully on-chip)
#            heston_bump_z7/zu  (bump-and-reprice on the generated pricer, same architecture)
#            heston_aad_zu      (generated, 32 multipliers, high throughput)
#            heston_top_level   (previous FSM AAD engine: price + 9 sensitivities)
#            heston_bump_top    (bump-and-reprice baseline, same pricing core)
#            heston_cos_forward (price only; one "reprice")
#   <part>   e.g. xc7z020clg400-1 (Zynq-7000, PYNQ-Z2 / Zybo Z7-20)
#                 xczu7ev-ffvc1156-2-e (Zynq UltraScale+, ZCU104)
#   <clk_ns> target clock period in ns (e.g. 10.0)
#
# Out-of-context mode: the engines have ~1300 parallel I/O bits, far more than
# any package has pins, and in a real system they sit behind heston_axi_top.
# OOC gives the core's own LUT/FF/DSP/BRAM, Fmax and power, which is what the
# comparison needs. Run make_all.sh for the full matrix.
# ============================================================================
set top    [lindex $argv 0]
set part   [lindex $argv 1]
set clk_ns [lindex $argv 2]
set outdir [lindex $argv 3]

set here   [file dirname [file normalize [info script]]]
set vdir   [file normalize "$here/../verilog"]
file mkdir $outdir

if {[string match "heston_aad_*" $top] || [string match "heston_bump_z*" $top]} {
  # generated shared-multiplier designs (hardware/gen): self-contained files
  read_verilog "$vdir/gen/$top.v"
  if {[string match "heston_bump_z7" $top]} { read_verilog "$vdir/gen/z7_pricer.v" }
  if {[string match "heston_bump_zu" $top]} { read_verilog "$vdir/gen/zu_pricer.v" }
  if {[string match "*_axi" $top]} { read_verilog "$vdir/gen/[string range $top 0 end-4].v" }
} else {
  set srcs {
    heston_top_level.v heston_bump_top.v heston_cos_forward.v heston_char_func.v
    heston_payoff_coeff.v complex_div.v complex_exp.v complex_log.v complex_mult.v
    complex_sqrt.v cordic.v fp_div.v fp_exp.v fp_log.v fp_sqrt.v
  }
  foreach f $srcs { read_verilog "$vdir/$f" }
}

synth_design -top $top -part $part -mode out_of_context \
             -include_dirs $vdir -flatten_hierarchy rebuilt
create_clock -name clk -period $clk_ns [get_ports clk]
write_checkpoint -force "$outdir/post_synth.dcp"
report_utilization -file "$outdir/util_synth.rpt"

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force "$outdir/post_route.dcp"

report_utilization    -file "$outdir/util.rpt"
report_utilization    -hierarchical -file "$outdir/util_hier.rpt"
report_timing_summary -file "$outdir/timing.rpt"
# Vectorless power estimate at the default 12.5% toggle rate. For an
# activity-based estimate, simulate in xsim, write a SAIF, and add
#   read_saif -input <file>.saif -strip_path <tb>/uut
# before this line (see README.md).
report_power          -file "$outdir/power.rpt"

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fp [open "$outdir/summary.txt" w]
puts $fp "top $top"
puts $fp "part $part"
puts $fp "clk_ns $clk_ns"
puts $fp "wns_ns $wns"
close $fp
