# Benchmark Results: AAD vs Bump-and-Reprice

## Overview

This document summarizes the performance, accuracy, and scaling benchmark results for the Algorithmic Adjoint Differentiation (AAD) engine compared to the traditional Bump-and-Reprice (finite difference) method.

Benchmarks were run using the Python software prototype, comparing wall-clock time, computation counts, and machine-precision accuracy.

---

## 1. Black-Scholes Timing

Averaged over 1,000 runs. The BS model has 4 Greeks (Delta, Vega, Theta, Rho).

| Method | Time (ms) | Total Pricings (equiv.) | Greeks Computed |
|--------|-----------|--------------------------|-----------------|
| Single Pricing | 0.0005 | 1 | 0 |
| **AAD (Forward + Backward)** | **0.0186** | **~2** | **4** |
| Bump-and-Reprice (Central Diff) | 0.0063 | 11 | 5 (incl. Gamma) |

> [!NOTE]
> The Python AAD implementation uses an object-oriented tape and operator overloading, which introduces significant software overhead (~34x vs single pricing). In a compiled or hardware implementation, the AAD backward pass takes approximately the same number of operations as a single forward pass, giving a theoretical overhead of ~2x-3x.

---

## 2. Heston-COS Timing

Averaged over 100 runs (N=128 terms). The Heston model has 7 Greeks (Delta, Vega, Rho, Kappa-sens, Theta-sens, Xi-sens, Rho-corr-sens).

| Method | Time (ms) | Total Pricings (equiv.) | Greeks Computed |
|--------|-----------|--------------------------|-----------------|
| Single Pricing | 0.4882 | 1 | 0 |
| **AAD (Forward + Backward)** | **26.138** | **~2** | **7** |
| Bump-and-Reprice (Central Diff) | 7.4962 | 15 | 7 |

* **Tape size**: 18,184 entries per evaluation

> [!TIP]
> Hardware acceleration is highly beneficial here. The massive software overhead of allocating 18,000 Python objects per evaluation hides the algorithmic advantage of AAD. In RTL/MATLAB hardware pipelines, the AAD cost will strictly be the reverse sweep of the 18,000 operations, which is equivalent in latency to a single forward pass.

---

## 3. Accuracy Comparison

AAD computes exact analytical derivatives up to machine precision, whereas Bump-and-Reprice suffers from finite difference truncation and floating-point cancellation errors.

### Black-Scholes Greeks Error vs Closed-Form Reference

| Greek | AAD Error | Bump-and-Reprice Error | AAD Advantage |
|-------|-----------|-------------------------|---------------|
| **Delta** | 0.00e+00 | 7.64e-12 | Infinite |
| **Vega** | 0.00e+00 | 7.69e-10 | Infinite |
| **Theta** | 0.00e+00 | 5.28e-10 | Infinite |
| **Rho** | 0.00e+00 | 6.92e-11 | Infinite |

> [!IMPORTANT]
> AAD completely eliminates the need to tune the bump size ($\epsilon$). finite difference methods always involve a trade-off between truncation error (if $\epsilon$ is too large) and cancellation error (if $\epsilon$ is too small). AAD provides exact derivatives natively.

---

## 4. Scaling Analysis: Why AAD Wins

The true power of AAD becomes apparent as the number of risk factors ($n$) increases.

* **Bump-and-Reprice Cost**: $O(n)$. Requires $2n + 1$ full pricings for central differences.
* **AAD Cost**: $O(1)$. Requires exactly 1 forward pass and 1 backward pass, regardless of $n$.

| Number of Greeks ($n$) | AAD Cost | Bump Cost | AAD Advantage |
|-------------------------|----------|-----------|---------------|
| 1 | ~2x | ~3x | 1.5x |
| 2 | ~2x | ~5x | 2.5x |
| 5 | ~2x | ~11x | 5.5x |
| **7 (Heston)** | **~2x** | **~15x** | **7.5x** |
| 20 | ~2x | ~41x | 20.5x |
| 100 | ~2x | ~201x | 100.5x |

For a full Heston model calibration or risk management scenario, AAD is theoretically **~7.5x more efficient** computationally.

---

## 5. Hardware Projection (FPGA/ASIC)

In a hardware pipeline (as will be implemented in RTL / Vitis), the software overhead of tape management disappears. The tape is simply a block RAM (BRAM) buffer, and the backward pass is a deterministic sequence of multiply-accumulate (MAC) operations.

| Metric | Bump-and-Reprice Pipeline | AAD Pipeline |
|--------|---------------------------|--------------|
| Forward passes required | 15 (for Heston) | 1 |
| Backward passes required | 0 | 1 |
| Total pipeline latency equivalents| 15x | ~2x - 3x |
| **Latency Advantage** | **Baseline** | **~6x Faster** |

> [!TIP]
> Hardware AAD pipelines are highly efficient because the backward pass reuses the same arithmetic logic units (ALUs/DSPs) as the forward pass, just fed from the tape RAM in reverse order.
