# ============================================================================
# One engine, end to end: out-of-context implementation, then SAIF power.
#   vivado -mode batch -nojournal -source run_engine_power.tcl -tclargs <top> <part> <clk_ns>
# -> runs/<part>/<top>/ (post_route.dcp, util.rpt, timing.rpt, power.rpt
#    [vectorless], power_saif.rpt [simulated activity], summary.txt)
# tb_power_<top>.v must have been generated for the same clock (gen_power_tb.py).
# ============================================================================
set pwr_dir [file dirname [file normalize [info script]]]   ;# not "here": synth_impl.tcl sets that
lassign $argv top part clk_ns
set out [file join $pwr_dir runs $part $top]
file mkdir $out
set argv [list $top $part $clk_ns $out]
source [file join $pwr_dir .. synth_impl.tcl]
close_project
set argv [list $top $out]
source [file join $pwr_dir power_saif.tcl]
