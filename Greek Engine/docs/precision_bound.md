# Fixed-Point Precision of the Heston AAD Engine: Bound and Measurement

This replaces the empirical-only accuracy statement in
`validation/rtl_aad_validation_report.html` (whose numbers predate the fixes
below) and the per-variable budget in `hardware/fixed_point/bit_width_budget.md`
(which describes a BRAM-tape design the RTL does not use).

**Reproduce:** `python validation/run_hw_sweeps.py all && python validation/make_figures.py`
(about 10 minutes on 8 cores). Tables: `validation/figures/tables.md`.

---

## 1. Number format

One uniform format across the whole Heston engine: **Q32.32** (WL = 64,
FL = 32). The truncation range, u_k grid, CORDIC phase, payoff coefficients,
characteristic function, reverse sweep and the accumulators all use it.
Accumulators get 8 more integer bits (AW = WL + 8). `heston_top_level`, `heston_bump_top`
and `heston_axi_top` take WL/FL as parameters; the precision sweep runs
FL = 16…40 with 32 integer bits.

Why 32 integer bits: the largest intermediate magnitudes are |u_k|²ξ² inside
the complex square root (up to ~10⁴–10⁵ at N = 128 for short maturities)
and the payoff coefficients |V_k| (up to ~10³). Range checks: every case in
the accuracy sweep, including T = 0.1 with ξ = 0.8, completes with no
overflow or saturation.

## 2. Defects found and fixed (before → after)

Measured against double precision. ULP = 2^-FL.

| # | Defect | Effect before | After |
|---|--------|---------------|-------|
| 1 | Every constant (ln2, π, 1/K, 1/n!, …) built as `$rtoi(c·2^16) <<< (FL-16)`, i.e. **truncated to 16 fractional bits** even in Q32.32 | φ(0) = 0.999977 instead of 1 | Q4.60 literals from `hardware/tools/gen_constants.py`, rounded per module (`fx_lib.vh`) |
| 2 | `fp_exp`: k = ⌊x/ln2⌋ instead of round, degree-5 series | 8.5e-5 relative (365 774 ULP) at Q32.32 | ≤ 0.6 ULP relative |
| 3 | `fp_log`: 5-term series with \|t\| ≤ 0.414 | 5.2e-4 (2.2M ULP) at Q32.32 | ≤ 1.5 ULP (16-entry LUT + Taylor, \|t\| ≤ 1/33) |
| 4 | CORDIC: Q4.28 atan table, 16-bit π for 2π reduction of angles up to ~200 rad, no guard bits | 580 ULP (Q32.32), 33 ULP (Q16.16) | ≤ 1 ULP (Q60 constants, 6 guard bits, 60-bit n·2π) |
| 5 | Outer COS loop at Q16.16 (only φ at Q32.32); \|V_k\| ~300 amplifies the rounding of cos/sin(u_k·a) and π/(b−a) | **price 0.80 % high** (10.4706 vs 10.3871) | single Q32.32 datapath |
| 6 | `complex_div` formed \|b\|² (loses ~2·log₂(1/\|b\|) bits; divides by ξ⁴ = 0.0081) | dV/dξ error 1.9e-6 relative | Smith's algorithm + guard-bit reciprocal: ≤ 0.6 ULP |
| 7 | `complex_sqrt` took Im = √((\|z\|−Re)/2) (cancels at low frequency) and squared \|z\| unscaled (overflows at short T / high ξ) | cancellation; overflow risk | stable w, a/(2w) form; scaled magnitude |
| 8 | Reverse sweep at high k: \|φ\| ~ 1e-5, so adjoints were a few hundred ULPs and then multiplied by u_k ~ 10² | dV/dρ error 2.7e-5 relative | per-term adjoint normalization: the sweep is linear in the seed, so it runs on seed·2^s and shifts back (exact) |
| 9 | Every product used `>>> FL` (floor): −0.5 ULP bias per op, amplified by V_k and summed over 128 terms | −6.8e-7 absolute price bias | round-to-nearest everywhere (`rshr`), rounding divider and sqrt |
| 10 | `fp_div` waited WL+FL cycles, then used a behavioral `/` | synthesizes a huge combinational divider | real sequential restoring divider (same latency) |
| 11 | `fx_lib` rounding helper sliced a 65-bit temporary | `x` outputs for WL > 65 | 128-bit temporaries |

Unit tests for these primitives (`hardware/sim/unit/check_real_primitives.py`,
`check_complex_primitives.py`); worst
errors over 60 random inputs each, Q32.32: exp 0.61, log 1.48, CORDIC rotation 0.92,
vectoring 0.78, real divide 0.5, complex divide 1.7 (0.6 relative), complex sqrt 0.6,
complex log 3.7, complex exp 1.1 ULP.

## 3. Error bound method

`validation/precision/heston_rtl_model.py` models the RTL **operation by operation**:
`heston_cos_forward.v`, `heston_payoff_coeff.v`, and both the forward and
reverse sweeps of `heston_char_func.v`. It uses the same operation order,
the same branch decisions (Smith swap, guard bits, adjoint normalization
shift, payoff parity) and the same rounding points. Each operation *i* is a
node with its exact value v_i, its local partials, and a local error bound
ε_i (in ULPs), derived in each primitive's header:

| primitive | ε (ULP) |
|---|---|
| rounded multiply, divide, sqrt, right shift, constant | 0.5 |
| `fp_exp(x)` | 3.2·eˣ + 0.5 |
| `fp_log` | 2.7 |
| CORDIC cos/sin | 3.0 |
| CORDIC atan2 | 1 + 1/\|z\| |

If operation *i* produces v_i + e_i with |e_i| ≤ ε_i·2^-FL, then to first order
every output Y satisfies

```
|Y_rtl − Y_exact|  ≤  2^-FL · Σ_i |∂Y/∂v_i| · ε_i          (worst case)
σ_Y               ≈  2^-FL · sqrt( Σ_i (|∂Y/∂v_i| · ε_i)² / 3 )   (typical, independent uniform errors)
```

All ∂Y/∂v_i come from **one reverse-mode sweep over the model graph**
(Linnainmaa, 1976, introduced reverse-mode AD for exactly this purpose). The
model includes the RTL's reverse sweep as ordinary operations, so the same
bound covers **each Greek**, not only the price. "Bits lost" for Y is
log₂(Σ|∂Y/∂v_i|ε_i).

Scope, stated explicitly:
- **First order.** Products of errors are O(2^-2FL). At FL ≥ 20 all bounds
  are ≪ 1, so these terms are negligible.
- **Input quantization excluded.** Inputs are taken as the Q-format values
  actually applied. At Q32.32, representing r = 0.05 adds ~1e-8 to rho·Δr.
- **Overflow excluded.** Range is checked separately (§1).
- **Hardware error only.** The bound covers the RTL relative to the
  double-precision COS algorithm it implements. COS truncation (method)
  error is reported separately.

## 4. Results

### 4.1 Bound holds, and the 1σ estimate predicts the measured error

Base case (S0 = K = 100, T = 1, r = 5 %, v0 = θ = 0.04, κ = 1.5, ξ = 0.3, ρ = −0.9), Q32.32:

| output | RTL error | 1σ estimate | worst-case bound | bits lost |
|---|---|---|---|---|
| price | 3.3e-7 | 3.5e-7 | 5.2e-6 | 14.5 |
| ∂V/∂S0 | 6.2e-10 | 7.3e-9 | 1.4e-7 | 9.2 |
| ∂V/∂K | 3.0e-9 | 7.3e-9 | 1.7e-7 | 9.5 |
| ∂V/∂T | 5.0e-8 | 7.0e-8 | 2.0e-6 | 13.1 |
| ∂V/∂r | 3.4e-7 | 6.0e-7 | 1.6e-5 | 16.1 |
| ∂V/∂v0 | 8.3e-7 | 8.3e-7 | 2.1e-5 | 16.4 |
| ∂V/∂κ | 9.7e-8 | 1.3e-7 | 2.0e-6 | 13.1 |
| ∂V/∂θ | 3.4e-7 | 3.8e-6 | 5.2e-5 | 17.8 |
| ∂V/∂ξ | 4.5e-8 | 1.0e-6 | 1.5e-5 | 16.0 |
| ∂V/∂ρ | 8.0e-8 | 7.0e-8 | 1.9e-6 | 13.0 |

Over the 21-case grid (moneyness 80–120, T 0.1–2, ξ 0.2–1, ρ −0.9…0.5, calls and
puts, the Fang–Oosterlee 2008 test set): **measured error / bound ≤ 0.21 for all 210
(case, output) pairs** (`fig3_bound_tightness`). Relative errors: median 1e-8,
worst 5e-5 (∂V/∂ρ at T = 0.1, where the value itself is small). See `fig2_accuracy_sweep` and `tables.md`.

Statement for the paper: *at Q32.32 the first-order bound shows at most 16.5 bits
lost on the price over the test grid (14.5 at the base point: bound 5.2e-6, measured
3.3e-7) and at most 21 bits on any Greek, leaving ≥ 11 correct fractional bits. The
bound is computed per parameter set in 0.1 s by the same adjoint machinery the
hardware implements.*

### 4.2 Precision vs fractional bits

`fig4_precision_vs_fl`: FL = 16…40, three parameter sets. Error falls by 2^-FL, as the
bound predicts. Measured points sit on or below the 1σ line and always below the bound.

### 4.3 AAD vs bump-and-reprice in the same fixed-point hardware

`fig1_bump_vs_aad_error`: `heston_bump_top.v` uses the *same* pricing core in
price-only mode (19 pricings, central differences), with the bump size swept from
1e-8 to 1e-1 (relative). With double precision, bump-and-reprice reaches ~1e-9
at its optimal h. In Q32.32 hardware the cancellation error ULP/h pushes the
optimum up to h ≈ 1e-2…1e-4, and the best achievable error becomes
5e-7…5.5e-5, depending on the Greek. **AAD in the same format: 9e-10…1.6e-6.**
Compared with the best bump size chosen in hindsight *per Greek*, AAD is more
accurate by 5.6× (∂V/∂κ) to 690× (∂V/∂K), median ~220×, with no bump size to
tune. At a single bump size shared by all Greeks, the gap is larger.

## 5. Cost

Simulated clock cycles per evaluation (same core, Q32.32):
price only 200 562; **AAD, price + 9 sensitivities: 433 779 (2.16× a
pricing)**; bump-and-reprice, price + 9 sensitivities: 3 811 647 (8.8× AAD).
Wall-clock latency, area and energy need implementation runs
(`hardware/vivado/`). See §6.

## 6. Open items

- **Resource sharing.** Every `*` in every FSM state infers its own multiplier.
  The engine is time-multiplexed in *control* but not in *datapath*, so the DSP
  count is far above what the cycle count suggests. Fix this (a shared
  multiplier or a real pipeline) before quoting area. Check it on the
  Zynq-7000 part first.
- **Black-Scholes core still at Q16.16.** Its Greeks are within ~1e-4
  relative, but its price error is ~5e-4, because S ≈ 100 × 1 ULP. Moving it
  to the parameterized library at Q32.32 would give the same precision as
  Heston.
- **Truncation-range sensitivity.** [a, b] depends on the parameters but is
  held fixed when differentiating, in both RTL and reference. This is the COS
  method's standard convention; its effect is included in the "method error"
  series of `fig2_accuracy_sweep`.
