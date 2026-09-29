# Greeks-Engine

Fixed-point FPGA hardware that computes a Heston stochastic-volatility option
price **and all 9 sensitivities in one forward + reverse-mode AAD pass**. It
uses the COS Fourier method, and each design is compared with bump-and-reprice
on the same hardware.

## Layout (`Greek Engine/`)

| path | contents |
|---|---|
| `hardware/gen/` | **datapath generator**: operation-graph IR, bit-accurate emulator, error bound, modulo scheduler, Verilog generator, testbenches, wrappers |
| `hardware/verilog/gen/` | generated RTL: Zynq-7020 (`heston_aad_z7h`, `heston_aad_z7`), 64-bit (`heston_aad_zu`), price-only pricers, bump-and-reprice baselines, AXI4-Stream wrappers |
| `hardware/verilog/` | first-generation FSM engine (Heston, Black-Scholes) and its arithmetic library |
| `hardware/vivado/` | out-of-context implementation flow + report parser |
| `software/` | Python AAD engine, Black-Scholes and Heston-COS models, tests |
| `validation/` | double-precision references, precision model, sweeps, figures (`validation/figures/`) |
| `docs/` | theory notes, `course.html` (the whole project end to end: maths, architecture, every experiment, results, novelty, next steps), `architecture.md` (hardware design + results), `precision_bound.md` (fixed-point analysis) |

## Quick start

```bash
cd "Greek Engine"
./verify_all.sh                                   # every testbench and check (~3 min)
python validation/run_gen_sweeps.py               # generated-architecture data
python validation/make_figures.py                 # figures + tables
cd hardware/vivado && PARTS=xc7z020clg400-1 TOPS=heston_aad_z7h ./make_all.sh   # needs Vivado
```

Requirements: Icarus Verilog 12, Python 3 with the packages in `software/requirements.txt`
(the scripts use `Greek Engine/.venv`).

## Headline results (RTL simulation, 128 COS terms)

| design | cycles for price + 9 Greeks | bump-and-reprice on same hardware | worst relative error (21 cases) |
|---|---|---|---|
| Zynq-7020 config (56-bit, 8 shared multipliers) | 4,733 | 86,860 (18.4×) | price 6e-7, Greeks ≤ 1.2e-5 |
| 64-bit config (32 shared multipliers) | 1,593 | 19,562 (12.3×) | price 3e-8, Greeks ≤ 7e-7 |
| first-generation FSM engine | 433,779 | 3,811,647 | price 3e-7, Greeks ≤ 5e-5 |

Implementation (Vivado 2025.2): the Zynq-7020 host-setup design routes at 36.5K LUT
(68.6%) / 72 DSP, Fmax about 79 MHz (57.8 µs per evaluation). On a ZedBoard at 70 MHz,
50 random cases ran bit-exact against the emulator. The 64-bit design is estimated by
Yosys at 108K LUT / 60K FF / 512 DSP48E2 (fits a ZCU104).

Status at a glance: `Greek Engine/dashboard.html`. Full write-up:
`Greek Engine/docs/report/greeks_engine_report.pdf` (source: `docs/report/make_report.py`).

Details and limitations: `Greek Engine/docs/architecture.md`.
