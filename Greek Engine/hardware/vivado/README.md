# Vivado implementation flow

```bash
cd "Greek Engine/hardware/vivado"
PARTS="xc7z020clg400-1 xczu7ev-ffvc1156-2-e" CLK_NS=10 ./make_all.sh   # set PARTS to your boards
python parse_reports.py                     # -> validation/results/vivado.csv
python ../../validation/make_figures.py     # adds fig6_resources, fig7_energy_latency
```

Designs implemented out of context (engine cores; `heston_axi_top` wraps them in a real system):

| top | what |
|---|---|
| `heston_top_level` | AAD: price + 9 sensitivities, one forward + reverse pass (433 779 cycles) |
| `heston_bump_top` | bump-and-reprice baseline on the same core, 19 pricings (3 811 647 cycles) |
| `heston_cos_forward` | one price-only pass (200 562 cycles) |

Latency = simulated cycles / Fmax; energy per evaluation = power x latency.

**Power:** `synth_impl.tcl` reports vectorless power (12.5 % default toggle rate).
For activity-based power, simulate the post-route netlist or RTL in xsim with
`open_saif`/`log_saif` on the `uut` scope, then add `read_saif` before
`report_power`. State in the paper which one you used. For a board measurement,
put the core behind `heston_axi_top` in a Zynq block design and read PMBus/INA
rails while it runs.

**Expect the Zynq-7020 run to fail placement on DSPs.** A Yosys coarse synthesis
of the current RTL counts 159 multiplier cells in `heston_top_level` and 110 in
`heston_bump_top`, mostly 64x64, each ~10 DSP48 slices. The FSMs share
control but not multipliers. See `docs/precision_bound.md` §6.
