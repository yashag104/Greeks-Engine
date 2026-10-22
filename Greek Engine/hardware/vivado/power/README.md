# Power from simulated switching activity (SAIF)

Vivado's default power figure assumes every signal toggles 12.5% of the time. Here
the routed engine's netlist is simulated on real evaluations and that activity is
used instead.

1. Out-of-context implementation of the engine (`../synth_impl.tcl <top> <part> <clk_ns> <outdir>`).
2. `python gen_power_tb.py <top> <clk_ns>`: a port-only testbench running four
   evaluations back to back (two board-sweep cases, two real NIFTY days) at that
   clock, checking every output against the emulator.
3. `vivado -mode batch -source power_saif.tcl -tclargs <top> <outdir>`: writes the
   routed netlist, simulates it in xsim with SAIF logging, refuses to report if the
   netlist simulation is not bit-exact, then `read_saif` and `report_power` ->
   `<outdir>/power_saif.rpt`.
