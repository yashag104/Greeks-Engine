# Shared-Multiplier Datapath for Heston-COS AAD Greeks

This document covers the second-generation hardware architecture (`hardware/gen`,
`hardware/verilog/gen`), its verification, and its measured results. The
fixed-point precision analysis it inherits is in `docs/precision_bound.md`.

**Reproduce everything:** `./verify_all.sh` (all testbenches, ~3 min),
`python validation/run_gen_sweeps.py && python validation/make_figures.py` (data, figures, `validation/figures/tables.md`).

---

## 1. Why a second architecture

The first engine (`hardware/verilog/heston_*.v`) was a hand-written FSM. It
controlled a single set of arithmetic modules in sequence, but did **not** share
their datapaths. Every `*` inside a state inferred its own multiplier, so Yosys
counts 159 64×64 multipliers, which is well over 1,000 DSP slices. It also used
28 bit-serial divisions per COS term, 80 % of its 433,779-cycle latency. It could
not fit the Zynq-7020 (220 DSP48E1), and it had no pipelining across terms.

## 2. Architecture

**One description, four uses.** The Heston-COS price and its reverse-mode
adjoint sweep are written once as an operation graph (`hardware/gen/heston.py`).
The same graph gives:
- a bit-accurate fixed-point emulator (the golden model),
- a double-precision evaluation of the same algorithm,
- the first-order error bound for the price and each Greek,
- the scheduled and bound RTL.

**Divider-free arithmetic** (`prims.py`):

| function | implementation | cost |
|---|---|---|
| 1/x | normalize to [1,2), 8-bit ROM seed, 3 Newton steps | 6 multiplies |
| 1/√x, √x | normalize to [1,4), ROM seed, 3 Newton steps | 9 (+1) multiplies |
| e^x | Tang: 2^(n/32) table, degree-4 Taylor on \|r\| ≤ ln2/64 | 7 multiplies |
| ln x | 64-entry table, degree-4 Taylor on \|t\| ≤ 1/129 | 6 multiplies |
| cos, sin | 2π reduction (2 multiplies) + CORDIC rotation | 1 CORDIC |
| complex 1/b | scale so max(\|b_r\|,\|b_i\|) ∈ [0.5,1), \|b\|², reciprocal | ~10 multiplies |
| complex √, ln | CORDIC vectoring for \|z\| and arg (no squaring) | 1 CORDIC |

**Reuse.** Each complex denominator is inverted once, and the reverse sweep reuses it:
1/den, g/den, 1/omg, ratio/omg, 1/omge, dratio/omge, 1/ratio = omg/omge.
Everything independent of u_k is hoisted into a once-per-evaluation setup.

**One COS term** (forward + reverse sweep, adjoint normalization) costs 250
multiplies, 3 CORDIC rotations, 2 CORDIC vectorings, and ~380 add/shift/mux
operations.

**Modulo scheduling** (`sched.py`). Term k starts at S + k·II. Multipliers and
CORDIC units are shared resources, bound through a modulo reservation table,
so in steady state term k uses unit u at phase (t − S) mod II. II is set by M,
the number of multipliers, and by the CORDIC unit style. Glue logic is dedicated.
A term value consumed ≥ II cycles after it is produced gets a register chain.

**Narrow shifters** (`ranges.py`). Every data-dependent shift amount was measured
with the emulator over 150 random parameter sets in the verified domain. Each
barrel shifter covers only that range (+3 margin; shifts past the word width are
clamped, which is exact). A sticky `range_err` output flags any shift outside its
range.

**Host-setup variant.** On a Zynq, the per-evaluation setup and the final
discounting / chain rule run on the ARM cores. Their fixed-point specification
is `hardware/gen/host.py`. The FPGA runs only the 128-term loop, and
host + FPGA is bit-identical to the fully on-chip design.

## 3. Verification

`./verify_all.sh` — 21 checks, all passing:

| check | method |
|---|---|
| arithmetic library (FSM engine) | unit tests vs double precision |
| FSM engine: AAD, price-only, AXI; Black-Scholes | self-checking testbenches vs reference |
| generated AAD (Zynq-7020, 64-bit, host-setup), price-only pricers | every setup/finish register and every register of terms 0–2 at the cycle it becomes valid (1,254–1,993 checks) + all outputs for 3 parameter sets, **bit-exact** vs the emulator |
| schedule | measured cycles = predicted cycles, every configuration |
| `range_err` | stays 0 in-domain (also over the 9,500 in-domain sweep inputs), raised for T = 0.001 |
| AXI4-Stream wrappers | bit-exact round trip, backpressure, return to idle |
| bump-and-reprice wrappers | bit-exact vs emulated 19 pricings |
| host split | host setup + FPGA sums + host finish == on-chip outputs |
| committed RTL | identical to fresh generator output |
| accuracy | emulator errors < 1e-5 and below the bound |

Beyond the scripted suite, the generator was also checked bit-exact on
48-bit/4-multiplier, 64-bit/16-multiplier and 60-bit/64-multiplier configurations.

## 4. Results

### 4.1 Latency (clock cycles, RTL simulation, 128 terms)

| design | AAD: price + 9 sensitivities | bump-and-reprice, same hardware | bump / AAD |
|---|---|---|---|
| FSM engine (64-bit) | 433,779 | 3,811,647 | 8.8× |
| generated, Zynq-7020 config (56-bit, 8 multipliers) | **4,733** (92× fewer than FSM) | 86,860 | **18.4×** |
| generated, host setup (56-bit, 8 multipliers) | 4,572 (loop only) | — | — |
| generated, 64-bit, 32 multipliers | **1,593** (272× fewer) | 19,562 | **12.3×** |

On the Zynq-7020 configuration, all 9 Greeks cost 1.04 pricings. The iterative
CORDIC units set the pace per term, so the reverse sweep's extra multiplies use
multiplier slots that a price-only design leaves idle.
`fig8_architecture_cycles`, `fig9_cycles_vs_mults`.

### 4.2 Accuracy

Worst relative error over the 21-case grid (S0 = 100, K 80–120, T 0.1–2,
ξ 0.2–1, ρ −0.9…0.5, calls and puts):

| design | price | Greeks (worst: ∂V/∂ρ, ∂V/∂κ) | max error / bound |
|---|---|---|---|
| Zynq-7020 config (56-bit) | 6.1e-7 | ≤ 1.2e-5 | 0.103 |
| 64-bit config | 2.8e-8 | ≤ 7.4e-7 | 0.099 |
| FSM engine (64-bit) | 3.0e-7 | ≤ 5.4e-5 | 0.21 |

Against bump-and-reprice on the same pricer and word length, sweeping h from 1e-8
to 1e-1, AAD is more accurate than the best h for every Greek
(`fig10_gen_bump_vs_aad`). `fig11_gen_accuracy`.

**Large sweep (1 Oct 2026, `validation/run_domain_sweep.py`).** 10,500 cases on the
56-bit design: 6,000 uniform over the verified domain, 500 each in seven hard
regimes (Feller condition violated, ρ near its limits, deep strikes, T ≤ 0.15,
T ≥ 2.5, ξ ≥ 0.8, v0 and θ ≤ 0.01) and 1,000 with one input outside the domain.
Each case runs the bit-accurate model, the error bound and the COS reference, and
checks every variable shift against the ranges the RTL was built for (= range_err).
`results/domain_sweep.csv`, `domain_sweep_summary.csv`.

- **The bound held in every case.** Of 10,482 unflagged results (all 9,500 in the
  domain, 982 of the 1,000 outside it), none exceeded its bound; the worst was
  0.378 of it. No overflow, no failed evaluation. The 18 flagged inputs were all
  outside the domain.
- **Absolute error, 9,500 in-domain cases** (median / 99th percentile / worst):
  price 3.3e-7 / 1.7e-5 / 7.3e-5; delta 3.5e-9 / 1.6e-7 / 2.2e-6; vega 2.8e-7 /
  2.1e-5 / 2.9e-4; ∂V/∂θ 2.0e-6 / 1.1e-4 / 3.7e-4; ∂V/∂ξ 5.9e-7 / 2.5e-4 / 1.3e-3.
  The 21-case grid above understates the tail. The largest relative error is at
  small ξ with large κθ: K = 115.8, T = 0.17, κ = 4.95, θ = 0.244, ξ = 0.105 has
  ∂V/∂ξ wrong by 1.2e-3 on a value of −0.563 (0.2%); the largest absolute error,
  1.3e-3 on −1.42 (0.09%), is at K = 138.6, ξ = 0.11. Both are fixed-point
  rounding (the double-precision algorithm agrees with the reference to 6e-6) and
  inside their bounds (8.8e-3, 9.9e-3). Small ξ is the weak corner of 56 bits.
- **Held-out sweep (6 Oct 2026, seed 20261006, `run_domain_sweep.py --heldout`).**
  The 1 Oct refit was prompted by the sweep above, so it was re-tested on fresh
  inputs: 9,500 in-domain, none flagged, none over its bound (worst 0.356); 1,000
  outside, 9 flagged, every other one within its bound. Significant figures against
  double precision (`sigfig_report.py`; Greeks within 1% of zero excluded), median /
  99th percentile / worst: price, delta, strike, theta, rho and vega 7.6–8.1 /
  5.3–5.9 / 3.3–4.4; ∂V/∂θ, ∂V/∂ρ 7.0–7.2 / 4.9 / 3.5–3.7; ∂V/∂κ 6.0 / 3.5 / 2.2;
  ∂V/∂ξ 5.9 / 3.0 / 1.4 (where it is small, as relative error grows).
- **range_err: fixed false alarms.** The first pass flagged 2.2% of uniform and 55%
  of very-low-variance inputs, but its check was stricter than the RTL (the RTL
  clamps shifts beyond the word width, where the rounded result is exactly 0, and
  a multiplier unit checks the union of its operations' ranges). With the check
  made identical to the RTL, 25 in-domain inputs remained, all from two
  normalization shifts one step past their range at very low variance and very
  short T. `ranges.py` now fits the ranges on 150 uniform samples plus 40 at each
  of ten domain edges (seeds independent of the sweep's): 50 of 113 ranges widen
  by 1 to 4 steps, about 37 more shifter-select bits in total (LUT cost to be
  measured in Vivado), and **no in-domain input is flagged**. T = 0.01 is no longer
  flagged and is computed within its bound (0.115 of it), so the testbench's
  out-of-domain probe is now T = 0.001. All designs regenerated; `verify_all.sh`
  passes (22/22).

### 4.3 Area (Yosys `synth_xilinx`, generic mapping)

| design | target | LUT | + SRL (LUT-based) | FF | DSP | fits? |
|---|---|---|---|---|---|---|
| `heston_aad_z7`, full-range shifters | xc7 | 90,648 | 3,050 | 32,878 | 96 | no (Zynq-7020: 53,200 LUT) |
| `heston_aad_z7`, measured-range shifters | xc7 | 59,024 | 3,058 | 32,731 | 96 | no, ~11 % over |
| **`heston_aad_z7h`** (host setup) | xc7 | **45,504** | 2,922 | 24,856 | 96 / 220 | **yes: 91 % LUT incl. SRL, 23 % FF, 44 % DSP** |
| **`heston_aad_zu`** (64-bit, 32 multipliers) | xcup | **108,330** | 6,409 | 59,953 | 512 DSP48E2 | **ZCU104: 50 % LUT, 30 % DSP**; ZCU102: yes; ZU3EG: no |

### 4.4 Area (Vivado 2025.2, post-synthesis, out of context)

`heston_aad_z7h` on xc7z020clg400-1:

| resource | used | available | util. | Yosys had estimated |
|---|---|---|---|---|
| LUT (incl. SRL) | **37,738** | 53,200 | **70.9 %** | 48,426 (91 %) |
| of which shift-register LUTs | 2,781 | 17,400 | 16.0 % | 2,922 |
| FF | 27,255 | 106,400 | 25.6 % | 24,856 |
| DSP48E1 | **72** | 220 | **32.7 %** | 96 |
| BRAM tile | 4 | 140 | 2.9 % | — |

Yosys' generic mapping overstated LUTs by 28 % and DSPs by a third. The Zynq-7020 fit
is comfortable rather than marginal, and the fallbacks previously recommended here —
sharing storage registers into SRLs, or 48-bit words (`check_accuracy.py 24`) — are
not needed. Use the Yosys figures only to rank configurations against each other, not
as an area result.

### 4.5 Routed (Vivado 2025.2, xc7z020clg400-1, 10 ns target, out of context)

| resource | routed | available | % |
|---|---|---|---|
| LUT | 36,499 | 53,200 | 68.6 % |
| of which shift-register LUTs | 1,401 | 17,400 | 8.1 % |
| FF | 28,559 | 106,400 | 26.8 % |
| DSP48E1 | 72 | 220 | 32.7 % |
| BRAM tile | 4 | 140 | 2.9 % |

| timing / power | value |
|---|---|
| WNS at 100 MHz | **−2.639 ns** (8,172 of 64,408 endpoints fail); WHS +0.037 ns |
| Critical path | 12.31 ns, 29 levels (21 CARRY4), `t_reg[16]` → `cr2_inst/z_reg[63]` |
| Fmax | ≈ 79.1 MHz (1 / (10 + 2.639) ns) |
| AAD latency (price + 9 Greeks) | 4,572 FPGA cycles (host-setup design; setup and finish on the host) / 79.1 MHz ≈ **57.8 µs** |
| Power (vectorless, 12.5 % toggle, at the 100 MHz constraint) | 0.258 W (0.153 dynamic + 0.105 static) |
| Energy per evaluation | ≤ 14.9 µJ (0.258 W × 57.8 µs; an upper bound, since power was estimated at 100 MHz) |

The design fits and routes but does not close at 100 MHz. The failing paths are 64-bit
carry chains; pipelining them, or running at ≤ 79 MHz, are the options. The ZedBoard
bring-up designs run the engine at 70 MHz for margin.

### 4.6 Against a CPU (measured 30 Sep 2026)

`validation/cpu_baseline/`: the same algorithm (COS, 128 terms, puts with calls by
parity, frozen [a, b]) in C++ double precision, g++ 13 -O3 -march=native, on an
Intel Core i5-1155G7 laptop CPU (4 cores, 8 threads). AAD by CoDiPack v2.3.2, a
standard taped reverse-mode tool; forward mode computes all 9 directions in one
pass. Every method matches the Python reference at the base case (AAD to 1.3e-10
relative). Results in `validation/results/cpu_baseline.csv`.

| price + 9 Greeks | µs per evaluation, one core | cost relative to one price |
|---|---|---|
| CPU, price only | 17.2 | 1× |
| CPU, bump-and-reprice (19 pricings) | 257.6 | 15× |
| CPU, AAD (CoDiPack reverse) | 114.9 | 6.7× |
| CPU, forward mode, 9 directions | 91.5 | 5.3× |
| CPU, optimised bump (9 full pricings, characteristic function reused) * | 158.6 | 10.3× |
| **CPU, hand-derived analytic Greeks, one pass** * | **29.3** | **1.9×** |
| FPGA, ZedBoard at 70 MHz | 65.3 | 1.04× |
| FPGA at the routed 79.1 MHz | 57.8 | 1.04× |

\* Added 1 October 2026 (`analytic`, `bumpopt` in `heston_cpu.cpp`), measured on
the same laptop while it was also running another Vivado job; cost ratios use the
price-only time from the same run (15.4 µs). Provisional until `run_baseline.py` is
re-run on an idle machine. Across five loaded runs the analytic method took
28–37 µs, always under the FPGA's 65 µs. It agrees with forward mode to 1.0e-11 over
2,000 random in-domain inputs.

The analytic method writes out, by hand, the derivative of the characteristic
function with respect to each input (chain rule through b, d, g and e, in the
spirit of Cui et al. 2017) and accumulates all ten sums in one pass over the 128
terms. It is the strongest software competitor and it changes the comparison:

- **Latency:** one CPU core with hand-derived Greeks is about 2.2× faster than the
  FPGA engine (29 µs against 65 µs). The FPGA is faster only than the general
  methods: 1.4× faster than forward mode, 1.8× faster than taped AAD and 3.9×
  faster than plain bump-and-reprice. The paper must not claim a latency
  advantage over a CPU.
- **Throughput:** the analytic method on 4 cores / 8 processes reached
  41,000–94,000 evaluations/s on the loaded laptop, against 15,300 for one FPGA
  engine.
- **Energy (estimate):** the FPGA board design is 0.340 W (vectorless, including
  the clock generator), about 22 µJ per evaluation. CPU power could not be
  measured under WSL; at the part's 12–28 W configurable power and the analytic
  method's throughput, about 0.13–0.68 mJ per evaluation, so roughly 6–30× more
  than the FPGA. Energy per Greek set is the FPGA's remaining measured-or-estimated
  advantage, and it rests on a CPU power estimate.
- **Greeks overhead:** the FPGA's Greeks cost 1.04 pricings; the best hand-written
  software costs 1.9, and general AD tools 5–7. The engine reaches this without
  anyone deriving the derivatives of the characteristic function by hand.
- **Optimised bump-and-reprice** (reusing the characteristic function for the S0,
  K, r, v0 and theta bumps) costs 10.3 pricings on the CPU, against 15 for plain
  bumping. The hardware advantage over bumping should therefore be quoted against
  an optimised bump as well, not only the 18.4× against a plain one.

### 4.7 Strike chains (design study, 1 Oct 2026: scheduled and emulated, not built)

`hardware/gen/chain.py`. All strikes of one expiry share the COS grid, because
b − a = 20·sqrt(c2) does not involve K. With the payoff's phase folded into the
characteristic function, Φ_k = φ(u_k)·e^(−i u_k a) = exp(C + v0·D + i u_k (x − a)),
and x − a = 10·sqrt(c2) − c is the same for every strike. So Φ_k, and with [a, b]
frozen its derivatives in T, r, v0, κ, θ, ξ, ρ and x, are shared. One forward
pass and **one reverse sweep per term, seeded with Re Φ_k, serve every strike**.
Each strike adds its payoff coefficient V_jk (one CORDIC rotation, 5 multiplies)
and ten multiply-adds: 16 multiplies and 1 rotation per strike per term, against
234 multiplies, 2 rotations and 2 vectorings shared. `heston.term` was split into
`cf_forward` / `cf_reverse` for this; the one-option graphs are unchanged (same
nodes in the same order, checked by hashing every node).

Accuracy (56-bit, 8 strikes K = 80–120, base case and 4 random parameter sets):
every output's worst error is within 1.7× of the one-option engine's on the same
inputs, for example price 6.1e-7 (one option 6.9e-7), ∂V/∂θ 4.8e-6 (4.3e-6).

Cycles (`validation/results/chain_sweep.csv`):

| strikes | Zynq-7020 style (56-bit, 8 mult., iterative CORDIC) | per strike | LUT (est.) | 64-bit, 32 mult., pipelined CORDIC | per strike | LUT (est.) |
|---|---|---|---|---|---|---|
| 1 | 4,662 (3 rot.) | 4,662 | 43.7K | 1,577 | 1,577 | 74K |
| 2 | 4,907 (4 rot.) | 2,454 | 49.8K | 1,707 | 854 | 80K |
| 4 | 5,436 (6 rot.) | 1,359 | 63.0K | 1,829 | 457 | 93K |
| 8 | 8,701 (7 rot.) | 1,088 | 86.6K | 2,089 | 261 | 122K |
| 16 | 8,767 (10 rot.) | 548 | 136K | 2,854 | 178 | 173K |
| 32 | 12,860 (12 rot.) | 402 | 232K | 4,892 | 153 | 282K |

(The Yosys-style estimate over-counts: it gives 43.7K for the one-strike design
that Vivado placed in about 36.5–38.4K. On a Zynq-7020, 53.2K LUT, about 2 strikes
fit, perhaps 4 after optimisation.)

**The CPU gains as much.** The same sharing in the analytic C++ method
(`m_chain` in `heston_cpu.cpp`, agreeing with the one-strike method to 1e-13):
one core, loaded laptop (price-only 23.4 µs in the same runs, ~1.5× slower than
idle): 1 strike 40.3 µs, 4 strikes 56.2 µs (14.0 per strike), 8 strikes 68.0 µs
(8.5), 16 strikes 93.3 µs (5.8), 32 strikes 122.5 µs (3.8).

- **Zynq-7020 at 70 MHz:** 2 strikes in 70 µs (35 µs per strike), 4 strikes in
  78 µs (19 µs per strike) if they fit. One loaded CPU core does 14 µs per strike
  at 4 strikes. The CPU stays faster.
- **A 64-bit UltraScale+ design** (not built; clock unknown, LUT estimate only):
  16 strikes in 2,854 cycles, 0.7 µs per strike at an assumed 250 MHz, 2.5 µs at
  70 MHz. A 4-core laptop at 32 strikes is roughly 1 µs per strike. At best
  parity, on unverified assumptions.
- **What the study does give:** a hardware cost per extra strike of 16
  multiplies and one rotation per term (about 7% of one option), with the adjoint
  shared; and the honest conclusion that against a CPU running the best known
  algorithm, the FPGA's case is not speed. Energy per strike, measured on both
  sides, is the remaining comparison worth making.

### 4.8 Adjoint against forward mode (6 Oct 2026)

`hardware/gen/tangent.py` builds forward-mode (tangent) datapaths from the same
primitives as the adjoint, with the same frozen [a, b], hoisting and finish, and
`validation/run_mode_baselines.py` schedules them with the same scheduler
(`results/mode_baselines.csv`). All agree with the adjoint to 6e-14 in double
precision. Their tangents have no fixed-point rescaling, so their costs are lower
bounds.

| datapath | multiplies per term | z7, 8 mult. | z7, 16 mult. | zu, 32 mult. | multipliers to reach II 32 (z7) |
|---|---|---|---|---|---|
| price only | 126 | 4,566 | 4,561 | 1,024 | 4 |
| **adjoint** | **250** | **4,731** | 4,619 | **1,591** | **8** |
| forward, factored (hand-derived analytic) | 313 | 5,622 | 4,571 | 1,795 | 10 |
| forward, sparse (structural zeros skipped) | 396 | 6,968 | 4,571 | 2,171 | 13 |
| forward, dense (as an AD tool) | 802 | 13,597 | 7,150 | 3,822 | 26 |

The 1.04× is not unique to the adjoint: with 16 multipliers the CORDIC units set the
pace for every variant but the dense one. What the adjoint saves is multipliers for
the same pace: 8 against 10 (factored) and 26 (dense; 234 DSP, more than the
Zynq-7020 has).

### 4.9 What the error bound covers (6 Oct 2026)

- **First order, rounding only.** The bound drops products of rounding errors and
  measures against the same algorithm computed exactly. `validation/run_mp_check.py`
  evaluates the unrolled graph in 50-digit arithmetic on 100 held-out inputs: the
  hardware's error against it is at most 0.24 of the bound (identical to three
  decimals to the error against double), and double is within 5e-5 of the bound from
  the 50-digit value.
- **COS truncation is a separate term.** `validation/run_method_error.py` compares
  COS (128 terms, double) with the Fourier integral on the 50 board cases: median
  error about 1e-9, worst 4.4e-5 (price) and 7.8e-3 (vega). Of the five worst cases,
  three need more terms (256 matches the integral; high xi, short T) and two a wider
  range (1.5x matches; deep out-of-the-money put). Total error against the Heston
  model is at most the rounding bound plus this method error.

## 5. Limitations and open items

- **What the latency figures include.** Three configurations are quoted and must
  not be mixed: `z7` (fully on-chip, 4,733 cycles, **never routed**, so its clock is
  unknown and any µs figure for it borrows z7h's clock), `z7h` (host setup and
  finish, FPGA term loop only, 4,572 cycles, routed: 79.1 MHz out of context, 70 MHz
  on the ZedBoard) and `zu` (64-bit, 1,593 cycles, **Yosys estimate only, never
  through Vivado**). The board figures 65.3 µs (70 MHz) and 57.8 µs (79.1 MHz) are
  z7h's loop alone: they exclude the host's setup and finish (about 100 multiplies
  plus a few exp, log and sqrt, in double precision on the ARM; not yet ported or
  timed) and the AXI4-Lite transfers (51 input words, 9 sums back), which on the
  ARM would take some microseconds and over JTAG took about a second per case. The
  CPU figures include everything. Until the PS design (`bd_lite.tcl` with a C host
  step) is timed, quote the FPGA number as "engine latency, excluding host steps".
- **Timing does not close at 100 MHz** (§4.5): WNS −2.639 ns, Fmax ≈ 79 MHz. Routing
  was reached after three obstacles: Vivado ML Enterprise refused to launch without a
  licence (resolved by moving to ML Standard 2025.2); `read_verilog`, `read_xdc` and
  `-include_dirs` take Tcl *lists*, so the space in the repository path tore every
  filename in two (fixed by wrapping in `[list ...]`); and two runs were killed
  mid-flow with no error message, most likely memory pressure (the flow now
  checkpoints after placement, `impl_from_dcp.tcl` resumes from a checkpoint, and
  `run_native.bat` runs the flow outside WSL). Power is vectorless; activity-based
  (SAIF) power is still open.
- **On silicon: 50 cases, bit-exact (2026-09-29, repeated 2026-10-06).** The AXI4-Stream wrappers are
  up to 1,456 bits wide, which no Zynq PS-PL port can carry, so `wrappers.py lite`
  generates an AXI4-Lite register file (bit-exact, in `verify_all.sh`). On a ZedBoard
  (xc7z020clg484-1), `zedboard/bd_jtag.tcl` puts it behind a JTAG-to-AXI master at
  70 MHz (6 Oct build: WNS +0.458 ns, so ~72 MHz in context against ~79 MHz out of
  context; 38,752 LUT, 72 DSP, 0.340 W vectorless). `run_jtag.tcl` wrote the 51 input words, started the engine, saw done
  on the first status poll, and read back all 9 outputs **bit-exact against the
  emulator**. Log: `validation/results/board_zedboard_2026-10-06.log`. A sweep then
  ran 50 cases back to back with no reset between them (the 2 fixed cases plus 48
  random draws over the verified domain, seed 2026, not the seed the shifter ranges
  were fitted on; 22 calls, 28 puts): 450/450 sums bit-exact, `range_err` never set,
  132.5 s in all, almost all of it JTAG register traffic (the engine's share is about
  3 ms). Through the host finish step all 500 outputs equal the emulator's, and the
  worst is 0.199 of its error bound; worst price error against the double-precision
  reference 1.5e-5 (`validation/board_report.py`; `results/board_sweep_*_2026-10-06*`).
  The first runs, on 29 Sep, used the bitstream from before put-call parity (19 host
  constants, 56 input words): also 450/450 bit-exact, but worst 0.268 of the bound
  and price error 2.3e-3. Put-call parity plus the refitted shift ranges cost 394 LUT
  (38,358 to 38,752). Also open: the PS design (`bd_lite.tcl`), which needs a C port of the host setup
  and finish.
- **Calls are priced as puts plus put-call parity.** Priced directly, a call's COS
  coefficients carry e^b, which over a wide truncation range grows and then cancels:
  over the 22 calls of the 50-case board sweep, fixed-point price error reached 2.3e-3
  (median 4.8e-5) against the integral reference. The term loop now always computes
  the put, and the finish step adds S0 − K·e^(−rT) and its S0, K, T, r derivatives:
  worst 3.1e-5 (median 5.4e-7), and every output improves. The COS reference prices
  calls the same way (`parity=True`); the FSM engine still prices them directly.
- **Verified input domain**: S0 = 100, K ∈ [60, 150], T ∈ [0.1, 3],
  r ∈ [0, 0.1], v0, θ ∈ [0.005, 0.25], κ ∈ [0.2, 6], ξ ∈ [0.1, 1], ρ ∈ [−0.95, 0.6].
  Outside it, `range_err` reports rather than silently returning wrong values.
- **The truncation range [a, b] is held fixed when differentiating** (standard COS
  convention, same as the software reference).
- **Register sharing across values** (fewer flip-flops) is not implemented. Each
  long-lived value has its own register chain.
