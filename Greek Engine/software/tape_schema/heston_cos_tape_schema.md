# Heston-COS Tape Schema

> **Implementation note (added after the RTL AAD pass landed):** the RTL
> (`hardware/verilog/heston_char_func.v`, `heston_cos_forward.v`) does
> *not* implement the ~18,184-entry generic micro-op tape this document
> describes. It reverse-mode-differentiates the characteristic function
> analytically instead: every one of the ~17 named complex steps below
> (`d`, `g`, `exp(-dT)`, `C`, `D`, ...) is complex-holomorphic away from its
> branch cut, so its adjoint reduces to "multiply by the conjugate of its
> own local complex derivative" — one hand-derived macro reverse-step per
> forward step, reusing the *same* `complex_mult`/`complex_div` instances
> the forward pass uses, rather than a separate generic tape-walk over
> every one of the ~72 elementary ops per term. The two are mathematically
> equivalent (composing a holomorphic function's derivative is associative
> regardless of how finely you decompose the chain), and the RTL's reverse
> pass is verified against this project's own `software/aad_engine` tape
> node-by-node (see `Greek Engine/validation/rtl_aad_validation_report.html`,
> §2) — but if you're reading this file expecting to find an 18K-entry
> BRAM tape and a generic reverse sweep in the RTL, you won't; that
> architecture was superseded because a hand-derived analytic adjoint
> needed roughly two orders of magnitude less tape memory and no
> data-dependent addressing, at the cost of being harder to *derive*
> (though no harder to verify) than a fully generic implementation.
>
> The domain-truncation range `[a,b]` and payoff coefficients `V_k`
> described in Step 2 and Step 3c below are treated as constants when
> differentiating in *both* the RTL and `software/models/heston_cos.py`'s
> own `heston_cos_price_aad()` — neither back-propagates through them.
> That's a deliberate, standard COS-method simplification (the price is
> insensitive to the exact truncation choice once N is large enough), not
> a hardware shortcut: it's why software bump-and-reprice and software AAD
> already agreed to ~1e-8 before any RTL existed.

## Overview

Precise, ordered operation list for the Heston-COS pricer. The hardware must replicate these operations for the forward pricing pass, then reverse them for the AAD backward pass.

The COS method sums N terms, each requiring a Heston characteristic function evaluation. The tape length is O(N) — deterministic and fixed at design time.

## Inputs (Leaf Variables)

| Index | Variable | Description | Typical Range |
|-------|----------|-------------|---------------|
| 0 | S₀ | Spot price | 50–200 |
| 1 | K | Strike price | 50–200 |
| 2 | T | Time to maturity | 0.1–2.0 |
| 3 | r | Risk-free rate | 0.01–0.05 |
| 4 | v₀ | Initial variance | 0.01–0.09 |
| 5 | κ | Mean-reversion speed | 0.5–5.0 |
| 6 | θ | Long-run variance | 0.01–0.09 |
| 7 | ξ | Vol-of-vol | 0.1–1.0 |
| 8 | ρ | Correlation | −0.9 to −0.3 |

**Total inputs: 9** (vs. 5 for BS)

## High-Level Algorithm Structure

```
1. x = ln(S₀/K)                          [1 DIV, 1 LOG]
2. Compute truncation range [a, b]        [scalar, not on tape]
3. For k = 0, 1, ..., N-1:               [N iterations]
   a. u_k = kπ/(b-a)                     [scalar constant]
   b. φ(u_k) = heston_char_func(u_k)     [~40 ops per term]
   c. F_k = Re[φ(u_k) · exp(-iu_k·a)]   [2 MUL, 1 SUB]
   d. V_k = payoff_coeff(k)              [scalar constant]
   e. sum += weight · F_k · V_k          [2 MUL, 1 ADD]
4. price = exp(-rT) · sum                [1 MUL, 1 NEG, 1 EXP, 1 MUL]
```

## Per-Term Characteristic Function Operations

For each COS term k (with argument u = u_k), the Heston characteristic function computes:

### Step 1: Build intermediate complex values
```
ρξ = ρ · ξ                              [1 MUL]
term1_real = -κ                          [1 NEG]
term1_imag = ρξ · u                      [1 MUL] (scalar u)
```

### Step 2: term1² (complex squaring)
```
t1_sq_real = term1_real² - term1_imag²   [2 MUL, 1 SUB]
t1_sq_imag = 2 · term1_real · term1_imag [2 MUL]
```

### Step 3: ξ²(iu + u²)
```
ξ² = ξ · ξ                              [1 MUL]
term2_real = ξ² · u²                     [1 MUL] (scalar u²)
term2_imag = ξ² · u                      [1 MUL] (scalar u)
```

### Step 4: under_sqrt = term1² + term2
```
us_real = t1_sq_real + term2_real        [1 ADD]
us_imag = t1_sq_imag + term2_imag        [1 ADD]
```

### Step 5: d = complex_sqrt(under_sqrt)
```
mag_sq = us_real² + us_imag²             [2 MUL, 1 ADD]
mag = sqrt(mag_sq)                       [1 SQRT]
sqrt_mag = sqrt(mag)                     [1 SQRT]
angle = atan2(us_imag, us_real)          [1 ATAN2]
half_angle = angle / 2                   [1 MUL]
d_real = sqrt_mag · cos(half_angle)      [1 COS, 1 MUL]
d_imag = sqrt_mag · sin(half_angle)      [1 SIN, 1 MUL]
```

### Step 6: numerator = (κ - d_real, -ρξu - d_imag)
```
num_real = κ - d_real                    [1 SUB]
neg_rho_xi_u = -(ρξ · u)                [1 NEG] (or reuse)
num_imag = neg_rho_xi_u - d_imag         [1 SUB]
```

### Step 7: denominator = (κ + d_real, -ρξu + d_imag)
```
den_real = κ + d_real                    [1 ADD]
den_imag = neg_rho_xi_u + d_imag         [1 ADD]
```

### Step 8: g = num / den (complex division)
```
den_mag_sq = den_real² + den_imag²       [2 MUL, 1 ADD]
g_real = (num_real·den_real + num_imag·den_imag) / den_mag_sq   [2 MUL, 1 ADD, 1 DIV]
g_imag = (num_imag·den_real - num_real·den_imag) / den_mag_sq   [2 MUL, 1 SUB, 1 DIV]
```

### Step 9: exp(-dT) (complex exponential)
```
neg_dT_real = -d_real · T                [1 MUL, 1 NEG]
neg_dT_imag = -d_imag · T               [1 MUL, 1 NEG]
exp_a = exp(neg_dT_real)                 [1 EXP]
exp_neg_dT_real = exp_a · cos(neg_dT_imag)  [1 COS, 1 MUL]
exp_neg_dT_imag = exp_a · sin(neg_dT_imag)  [1 SIN, 1 MUL]
```

### Step 10: g · exp(-dT) (complex multiply)
```
g_exp_real = g_real·exp_neg_dT_real - g_imag·exp_neg_dT_imag  [2 MUL, 1 SUB]
g_exp_imag = g_real·exp_neg_dT_imag + g_imag·exp_neg_dT_real  [2 MUL, 1 ADD]
```

### Step 11: (1 - g·exp(-dT)) and (1 - g)
```
omge_real = 1 - g_exp_real               [1 SUB]
omge_imag = -g_exp_imag                  [1 NEG]
omg_real = 1 - g_real                    [1 SUB]
omg_imag = -g_imag                       [1 NEG]
```

### Step 12: ratio = (1-g·exp(-dT)) / (1-g) (complex division)
```
[Same pattern as Step 8: 2 MUL + 1 ADD + 1 DIV for each component]
```

### Step 13: log(ratio) (complex logarithm)
```
ratio_mag_sq = ratio_real² + ratio_imag²  [2 MUL, 1 ADD]
log_ratio_real = 0.5 · log(ratio_mag_sq)  [1 LOG, 1 MUL]
log_ratio_imag = atan2(ratio_imag, ratio_real) [1 ATAN2]
```

### Step 14: C function
```
κθ_over_ξ² = κ · θ / ξ²                 [2 MUL, 1 DIV]
numT_real = num_real · T                 [1 MUL]
numT_imag = num_imag · T                 [1 MUL]
bracket_real = numT_real - 2·log_ratio_real  [1 MUL, 1 SUB]
bracket_imag = numT_imag - 2·log_ratio_imag  [1 MUL, 1 SUB]
C_part_real = κθ_over_ξ² · bracket_real  [1 MUL]
C_part_imag = κθ_over_ξ² · bracket_imag  [1 MUL]
r_u_T = r · u · T                       [2 MUL]
C_real = C_part_real                     [pass-through]
C_imag = r_u_T + C_part_imag            [1 ADD]
```

### Step 15: D function
```
num_over_ξ²_real = num_real / ξ²         [1 DIV]
num_over_ξ²_imag = num_imag / ξ²         [1 DIV]
one_minus_exp_real = 1 - exp_neg_dT_real  [1 SUB]
one_minus_exp_imag = -exp_neg_dT_imag     [1 NEG]
D_ratio = complex_div(one_minus_exp, omge)  [~7 ops]
D = complex_mul(num_over_ξ², D_ratio)     [4 MUL, 1 ADD, 1 SUB]
```

### Step 16: Exponent = C + D·v₀ + iu·x
```
Dv0_real = D_real · v₀                   [1 MUL]
Dv0_imag = D_imag · v₀                   [1 MUL]
iu_x_imag = u · x                        [1 MUL]
exp_real = C_real + Dv0_real             [1 ADD]
exp_imag = C_imag + Dv0_imag + iu_x_imag [2 ADD]
```

### Step 17: φ = exp(exponent) (complex exponential)
```
phi_mag = exp(exp_real)                   [1 EXP]
phi_real = phi_mag · cos(exp_imag)        [1 COS, 1 MUL]
phi_imag = phi_mag · sin(exp_imag)        [1 SIN, 1 MUL]
```

## Per-Term Operation Summary

| Operation | Count per term |
|-----------|---------------|
| ADD/SUB | ~20 |
| MUL | ~35 |
| DIV | ~6 |
| SQRT | 2 |
| EXP | 2 |
| LOG | 1 |
| SIN | 2 |
| COS | 2 |
| ATAN2 | 2 |
| **Total** | **~72** |

## Full Tape Size

For N = 128 COS terms:
- Input variables: 9
- x = ln(S₀/K): ~3 ops
- Per-term: ~72 ops × 128 terms = ~9,216 ops
- Accumulation: ~3 ops × 128 = ~384 ops
- Final discounting: ~4 ops
- **Total tape entries: ~9,616**

Measured from Python implementation: **18,184 entries** (includes intermediate AADVariable creations from operator overloading).

## Pipeline Design Implications

1. **Per-term independence**: Each COS term k is independent → fully parallelizable
2. **Fixed iteration count**: N is a compile-time constant → fixed pipeline depth
3. **Dominant operations**: MUL and ADD dominate → DSP-friendly
4. **Transcendentals**: Need efficient sin/cos/exp/log/sqrt/atan2 implementations
5. **Complex arithmetic**: All complex ops decompose into real arithmetic
6. **Tape storage**: Need ~18K entries × (value + partial) → manageable in BRAM
7. **Backward pass**: Same tape length, reverse order, adjoint accumulation only

## Hardware Architecture Sketch

```
┌─────────────────────────────────────────────────────┐
│                   FORWARD PIPELINE                   │
│                                                      │
│  x = ln(S/K)  →  For each k:                       │
│                    char_func(u_k) → F_k → sum       │
│                   End for                            │
│                   price = exp(-rT) × sum             │
│                                                      │
│  Values stored in BRAM tape                         │
├─────────────────────────────────────────────────────┤
│                   BACKWARD PIPELINE                  │
│                                                      │
│  Read tape in reverse                               │
│  For each entry:                                    │
│    adj[parent] += adj[output] × local_partial       │
│  End for                                            │
│                                                      │
│  Output: adj[0..8] = all 9 Greeks                   │
└─────────────────────────────────────────────────────┘
```
