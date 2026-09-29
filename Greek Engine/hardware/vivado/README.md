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

**Measured on xc7z020clg400-1 (2025.2):** `heston_aad_z7h` routes at 68.6 % LUT and
72 DSP (32.7 %), but misses 100 MHz by 2.639 ns (Fmax ~79 MHz). The earlier Yosys
estimate that it would fail placement on DSPs was wrong. See `docs/architecture.md` §4.5.

**ZedBoard:** `zedboard/run_board.bat build`, then `test`. It clocks the engine at 70 MHz.
