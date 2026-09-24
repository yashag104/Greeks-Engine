# Shared-multiplier Heston AAD datapath generator

This directory replaces the hand-written FSM engine (`hardware/verilog/heston_*.v`) with a generated datapath:

```
heston.py (datapath as an operation graph)
   ├── emulate()          bit-accurate fixed-point golden model
   ├── eval_float()       same algorithm in double precision
   ├── error_bound()      first-order bound for the price and every Greek
   ├── ranges.py          measured shift ranges -> narrow barrel shifters + range_err
   └── sched.py           modulo schedule: M shared multipliers, CORDIC units
          └── rtlgen.py   synthesizable Verilog
                 ├── gen_tb.py     self-checking testbench (bit-exact vs emulate)
                 ├── wrappers.py   AXI4-Stream wrapper, bump-and-reprice baseline
                 └── host.py       host-side setup/finish for host-setup designs
```

The design notes and results are in `docs/architecture.md`. Run
`./verify_all.sh` (repository `Greek Engine/` directory) to re-verify everything.

## Why it is small and fast

- **No dividers or bit-serial square roots.** Reciprocals and inverse square
  roots are Newton iterations on a normalized mantissa with an 8-bit ROM seed
  (`prims.recip`, `prims.rsqrt`). They cost *multiplier uses*, which are shared,
  instead of dedicated area and ~100 cycles each. In the old engine, dividers
  were 80 % of the per-term latency.
- **Reciprocals are computed once and reused.** Forward and reverse passes need
  1/den, g/den, 1/omg, ratio/omg, 1/omge, … Each denominator is inverted once
  (`prims.cinv`), with the complex value normalized before |b|² is formed.
- **Everything that doesn't depend on u_k is hoisted into setup**, which runs
  once per evaluation, either on the FPGA or on the host CPU (`--host-setup`).
- **Terms overlap.** Term k starts at S + k·II, and each shared unit serves one
  term per phase (t mod II).
- **Narrow shifters.** Every data-dependent shift was measured over 150 random
  parameter sets and given only the range it needs (+3 margin). A sticky
  `range_err` output flags any input that leaves that range. Yosys LUT count
  went from 90.6K to 59.0K.

One COS term (forward + reverse) = 251 multiplies, 3 CORDIC rotations,
2 CORDIC vectorings, ~380 add/shift/mux operations.

## Designs (committed in `hardware/verilog/gen/`)

| design | what | flags |
|---|---|---|
| `heston_aad_z7h` | AAD loop, setup/finish on the ARM (**Zynq-7020 target**) | `--wl 56 --fl 28 --mults 8 --crot 3 --cvec 2 --host-setup` |
| `heston_aad_z7` | same, fully on-chip | `--wl 56 --fl 28 --mults 8 --crot 3 --cvec 2` |
| `heston_aad_zu` | fully on-chip, high throughput (UltraScale+) | `--wl 64 --fl 32 --mults 32 --crot 1 --cvec 1 --pipe-cordic` |
| `z7_pricer`, `zu_pricer` | price only (same architecture) | `--price-only` |
| `heston_bump_z7`, `heston_bump_zu` | bump-and-reprice baseline on the pricer | `wrappers.py bump` |
| `*_axi` | AXI4-Stream wrappers (`m_axis_tuser` = range_err) | `wrappers.py axi` |
| `heston_aad_z7h_host.json` | what each `hs_*` port of the host-setup design holds | |

## Usage

```bash
python gen_tb.py --wl 56 --fl 28 --mults 8 --crot 3 --cvec 2 --host-setup --name heston_aad_z7h
python wrappers.py axi  --wl 56 --fl 28 --mults 8 --crot 3 --cvec 2 --host-setup --name heston_aad_z7h
python wrappers.py bump --wl 56 --fl 28 --mults 8 --crot 3 --cvec 2 --name z7
python host.py            # host setup + FPGA loop + host finish == fully on-chip
python check_accuracy.py 28
python sched.py           # schedule / estimate table
```

`gen_tb.py` checks every setup and finish register, and every register of terms
0–2 at the cycle its value becomes valid, against `heston.emulate`. It also
checks all outputs for 3 parameter sets, and that `range_err` fires for an
out-of-domain input (T = 0.01).

## Interface

Fully on-chip: `(clk, rst, start, S0, K, T, r, v0, kappa, theta, xi, rho, is_call)
-> (price, delta, strike_sens, theta_greek, rho_greek, vega, kappa_sens, theta_sens,
xi_sens, rho_corr, done, range_err)`, all signed Q(WL−FL).FL. Outputs are valid
when `done` pulses.

Host setup: the same parameter inputs plus 19 `hs_*` constants (see the JSON), and
outputs `sum_*` (the 9 undiscounted COS sums). `host.finish` turns them into the
10 outputs, bit-identical to the on-chip design.

Verified domain (shift ranges + no overflow): S0 = 100, K ∈ [60, 150],
T ∈ [0.1, 3], r ∈ [0, 0.1], v0, θ ∈ [0.005, 0.25], κ ∈ [0.2, 6], ξ ∈ [0.1, 1],
ρ ∈ [−0.95, 0.6]. Scale S0 and K together for other spot levels.
