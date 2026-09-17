# Shared-multiplier Heston AAD datapath generator

This directory replaces the hand-written FSM engine (`hardware/verilog/heston_*.v`) with a generated datapath:

```
heston.py (datapath as an operation graph)
   ├── emulate()          bit-accurate fixed-point golden model
   ├── eval_float()       same algorithm in double precision
   ├── error_bound()      first-order bound for the price and every Greek
   └── sched.py           modulo schedule: M shared multipliers, CORDIC units
          └── rtlgen.py   synthesizable Verilog
                 └── gen_tb.py   self-checking testbench (bit-exact vs emulate)
```

## Why it is small and fast

- **No dividers or bit-serial square roots.** Reciprocals and inverse square
  roots are Newton iterations on a normalized mantissa with an 8-bit ROM seed
  (`prims.recip`, `prims.rsqrt`). They cost *multiplier uses*, which are shared,
  instead of dedicated area and ~100 cycles each. In the old engine,
  dividers were 80 % of the per-term latency.
- **Reciprocals are computed once and reused.** Forward and reverse passes need
  1/den, g/den, 1/omg, ratio/omg, 1/omge, … Each denominator is inverted once
  (`prims.cinv`), with the complex value normalized before |b|² is formed, so
  no bits are lost.
- **Everything that doesn't depend on u_k is hoisted into setup**, which runs
  once per evaluation.
- **Terms overlap.** Term k starts at S + k·II, and each shared unit serves one
  term per phase (t mod II). II is set by the multiplier count.

One COS term (forward + reverse) = 251 multiplies, 3 CORDIC rotations,
2 CORDIC vectorings, and ~380 add/shift/mux operations.

## Usage

```bash
# Zynq-7020 configuration (Q28.28 in 56 bits, 8 multipliers, iterative CORDIC)
python gen_tb.py --wl 56 --fl 28 --mults 8 --crot 3 --cvec 2 --name heston_aad_z7

# high-throughput configuration (Q32.32, 32 multipliers, pipelined CORDIC)
python gen_tb.py --wl 64 --fl 32 --mults 32 --crot 1 --cvec 1 --pipe-cordic --name heston_aad_zu

# accuracy and error bound of a word length (emulator, no simulation)
python check_accuracy.py 28

# schedule / cost table across configurations
python sched.py
```

`gen_tb.py` writes `build/<name>.v` (the RTL) and `build/tb_<name>.v`, then runs
Icarus Verilog. It checks every setup and finish register, and every register of
terms 0–2 at the cycle its value becomes valid, against `heston.emulate`. It also
checks all 10 outputs for each parameter set.

## Measured (RTL simulation, 128 COS terms)

| configuration | II | cycles / evaluation | vs. old FSM (433 779) | relative accuracy |
|---|---|---|---|---|
| WL56/FL28, 8 mults, iterative CORDIC (Zynq-7020) | 32 | 4 731 | 92× fewer | ~4e-7 |
| WL64/FL32, 32 mults, pipelined CORDIC | 8 | 1 599 | 271× fewer | ~2e-8 |

Area: run the Vivado flow on the generated files. `sched.py` gives estimates only.

## Interface

`module <name>(clk, rst, start, S0, K, T, r, v0, kappa, theta, xi, rho, is_call,
price, delta, strike_sens, theta_greek, rho_greek, vega, kappa_sens, theta_sens,
xi_sens, rho_corr, done)`. All values are signed Q(WL−FL).FL. Outputs are valid
when `done` pulses and stay stable until the next `start`.

Preconditions: κ > 0, ξ > 0, T > 0, S0, K > 0. Maturity/vol-of-vol ranges were
checked in emulation for no overflow (T ≥ 0.1, ξ ≤ 1).
