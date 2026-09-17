# Fixed-Point Bit-Width Budget

> **Superseded (Sept 2026).** The Heston engine now runs one uniform Q32.32
> datapath (parameterized WL/FL), and this document's tape/BRAM sizing
> describes a design the RTL does not use (the reverse sweep is computed
> per COS term, with no stored tape). The measured precision, the
> first-order error bound for the price and every Greek, and the list of
> precision defects that were fixed are in **`docs/precision_bound.md`**.
> The per-variable ranges below are kept as design background only.

> **Implementation note:** the per-variable Q-formats below (e.g. Q(1,14,17)
> for S, Q(1,1,30) for r) were the original design target, allocating
> fractional bits per-variable to match each one's expected range. The
> shipped RTL simplifies this to two *uniform* formats instead — Q16.16
> (WL=32, FL=16) for every Black-Scholes signal and every outer
> Heston-COS signal (S0, K, T, r, v0, κ, θ, ξ, ρ, a, b, u_k, V_k, the price
> accumulator, all Greeks), and Q32.32 (WL=64, FL=32) for everything inside
> `heston_char_func`'s complex arithmetic — rather than a different
> fractional-bit count per named variable. This matches the "Design
> Decisions" section below (which already called for 32-bit / 64-bit as the
> two working widths) even where the later per-variable table doesn't; it
> trades a little headroom on variables that would've benefited from more
> fractional bits (T, r) for a much smaller, uniform set of arithmetic
> units to implement, instantiate, and verify. See "Empirical Error
> Validation" at the end of this document for what that simplification
> actually costs in measured accuracy, as a check against the theoretical
> "Error Budget" below.

## Overview

This document specifies the Q-format (fixed-point representation) for every intermediate variable in the BS and Heston-COS pricing pipelines. The format Q(I.F) means I integer bits (including sign) and F fractional bits, for a total word width of I+F bits.

## Design Decisions

1. **Base word width**: 32 bits (Q16.16) for most variables, 48 bits (Q16.32) for accumulations
2. **Extended precision**: 64 bits (Q32.32) for the characteristic function internals (complex arithmetic compounds errors)
3. **Rationale**: 32-bit fixed-point provides ~4.8 decimal digits of precision; 48-bit provides ~9.6 digits. For financial applications, 4-6 digits of accuracy in Greeks is typically sufficient.

## Notation

- **Q(s,I,F)**: s=1 (signed), I integer bits, F fractional bits. Total = 1+I+F.
- **Range**: [−2^I, 2^I − 2^(−F)]
- **Resolution**: 2^(−F)

---

## Black-Scholes Variables

| Variable | Typical Range | Required Precision | Format | Total Bits | Notes |
|----------|--------------|-------------------|--------|-----------|-------|
| S (spot) | 1–10000 | 0.01 | Q(1,14,17) | 32 | Max 16384 |
| K (strike) | 1–10000 | 0.01 | Q(1,14,17) | 32 | Same as S |
| T (time) | 0.001–10 | 0.0001 | Q(1,4,27) | 32 | Years |
| r (rate) | −0.05–0.20 | 0.0001 | Q(1,1,30) | 32 | Small range |
| σ (vol) | 0.01–2.0 | 0.0001 | Q(1,2,29) | 32 | |
| √T | 0.03–3.16 | 0.0001 | Q(1,2,29) | 32 | |
| σ√T | 0.0003–6.32 | 0.0001 | Q(1,3,28) | 32 | |
| S/K | 0.01–100 | 0.001 | Q(1,7,24) | 32 | Moneyness |
| ln(S/K) | −4.6–4.6 | 0.0001 | Q(1,3,28) | 32 | |
| d1 | −10–10 | 0.0001 | Q(1,4,27) | 32 | |
| d2 | −10–10 | 0.0001 | Q(1,4,27) | 32 | |
| N(d1), N(d2) | 0–1 | 0.00001 | Q(1,1,30) | 32 | CDF output |
| n(d1) | 0–0.4 | 0.00001 | Q(1,0,31) | 32 | PDF |
| exp(−rT) | 0.1–1.0 | 0.00001 | Q(1,1,30) | 32 | Discount |
| **V (price)** | 0–10000 | 0.01 | Q(1,14,17) | 32 | Output |

### Adjoint Variables (Backward Pass)

| Variable | Typical Range | Format | Total Bits | Notes |
|----------|--------------|--------|-----------|-------|
| adj(V) | 1.0 (seed) | Q(1,1,30) | 32 | Always 1.0 |
| adj(S) = Δ | −1–1 | Q(1,1,46) | 48 | Delta, accumulates |
| adj(σ) = V | 0–200 | Q(1,8,39) | 48 | Vega, accumulates |
| adj(r) = ρ | −200–200 | Q(1,8,39) | 48 | Rho, accumulates |
| adj(T) = Θ | −500–500 | Q(1,10,37) | 48 | Theta, accumulates |
| adj(K) | −1–0 | Q(1,1,46) | 48 | Strike sens |

**Key insight**: Adjoint accumulation requires extra fractional bits to maintain precision through many additions.

---

## Heston-COS Variables

### Model Parameters
| Variable | Typical Range | Format | Total Bits |
|----------|--------------|--------|-----------|
| v₀ | 0.001–0.25 | Q(1,0,31) | 32 |
| κ | 0.1–10 | Q(1,4,27) | 32 |
| θ | 0.001–0.25 | Q(1,0,31) | 32 |
| ξ | 0.01–2.0 | Q(1,2,29) | 32 |
| ρ | −1–1 | Q(1,1,30) | 32 |

### COS Method Variables
| Variable | Typical Range | Format | Total Bits | Notes |
|----------|--------------|--------|-----------|-------|
| x = ln(S₀/K) | −5–5 | Q(1,3,28) | 32 | Log-moneyness |
| u_k | 0–~400 | Q(1,9,22) | 32 | kπ/(b−a), k≤128 |
| bma = b−a | 1–20 | Q(1,5,26) | 32 | Truncation width |

### Characteristic Function Internals (Complex)

**These require extended precision (64-bit) due to error accumulation in complex arithmetic:**

| Variable | Typical Range | Format | Total Bits | Notes |
|----------|--------------|--------|-----------|-------|
| ρξ | −2–2 | Q(1,2,61) | 64 | |
| term1 (real) | −10–10 | Q(1,4,59) | 64 | |
| term1 (imag) | −800–800 | Q(1,10,53) | 64 | ρξu, large for high k |
| d (complex) | ±1000 | Q(1,10,53) | 64 | sqrt result |
| g (complex) | −2–2 | Q(1,2,61) | 64 | Ratio |
| exp(−dT) | −1–1 | Q(1,1,62) | 64 | Complex exp |
| C (complex) | ±100 | Q(1,7,56) | 64 | |
| D (complex) | ±50 | Q(1,6,57) | 64 | |
| φ (complex) | −2–2 | Q(1,2,61) | 64 | Char func output |
| F_k | −2–2 | Q(1,2,29) | 32 | Re[φ·phase], back to 32-bit |

### COS Summation
| Variable | Typical Range | Format | Total Bits | Notes |
|----------|--------------|--------|-----------|-------|
| V_k (payoff coeff) | ±10000 | Q(1,14,17) | 32 | Scalar |
| F_k · V_k | ±20000 | Q(1,15,32) | 48 | Product |
| sum (accumulator) | ±100000 | Q(1,17,30) | 48 | N terms accumulated |
| price | 0–10000 | Q(1,14,17) | 32 | Final output |

### Adjoint Variables (Heston)
| Variable | Format | Total Bits | Notes |
|----------|--------|-----------|-------|
| All 9 input adjoints | Q(1,16,47) | 64 | Extended for accumulation |
| Intermediate adjoints | Q(1,10,53) | 64 | Match char func precision |

---

## Resource Estimates

### BRAM Usage (Tape Storage)

| Component | Entries | Bits/Entry | Total Bits | 36Kb BRAMs |
|-----------|---------|------------|-----------|------------|
| BS forward values | 25 | 32 | 800 | <1 |
| BS forward partials | 25×2 | 32 | 1,600 | <1 |
| BS backward adjoints | 25 | 48 | 1,200 | <1 |
| Heston forward values | ~18,000 | 64 | ~1.15M | ~32 |
| Heston forward partials | ~18,000×2 | 64 | ~2.30M | ~64 |
| Heston backward adjoints | ~18,000 | 64 | ~1.15M | ~32 |
| **Heston Total** | | | **~4.6M** | **~128** |

### DSP Usage

| Operation | DSPs (32-bit) | DSPs (64-bit) |
|-----------|--------------|--------------|
| Fixed-point MUL | 2 | 8 |
| Fixed-point ADD | 0 (LUT) | 0 (LUT) |
| Complex MUL | 6 | 24 |

---

## Overflow Protection

1. **Saturation arithmetic**: All operations use saturating addition/subtraction to prevent wrap-around
2. **Guard bits**: 2 extra MSBs allocated in accumulator paths
3. **Scaling**: Characteristic function terms scaled to keep intermediate values in representable range
4. **Monitoring**: Python analysis script `fixed_point_analysis.m` validates no overflow for representative parameter sets

## Error Budget

| Source | Estimated Error (bits) | Notes |
|--------|----------------------|-------|
| Fixed-point quantization | 1–2 ULP per op | Rounding |
| Accumulation (N terms) | ~log₂(N) = 7 bits | N=128 |
| Complex arithmetic chain | ~10 bits | ~20 ops deep |
| **Total worst case** | ~19 bits lost | |
| **Available precision** | 32 fractional bits (64-bit) | |
| **Remaining precision** | ~13 bits (~4 decimal digits) | Acceptable |
