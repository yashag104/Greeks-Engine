"""
Benchmark Comparison — AAD vs Bump-and-Reprice Performance Analysis.

Compares:
1. Computation count: AAD (1 forward + 1 backward) vs Bump-and-Reprice (n+1 pricings)
2. Wall-clock time: Python software implementation
3. Accuracy: AAD machine-precision vs finite-difference truncation error
4. Scaling: How the advantage grows with the number of Greeks

Generates results for the benchmark_results.md report.
"""

import sys
import os
import math
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "software"))

from aad_engine import AADVariable, tape, reset_tape
from models.black_scholes import bs_price_aad, bs_price_scalar, bs_greeks_closed_form
from models.heston_cos import heston_cos_price_aad, heston_cos_price_scalar
from models.bump_and_reprice import bs_bump_and_reprice, heston_bump_and_reprice


def main():
    print("=" * 70)
    print("BENCHMARK COMPARISON: AAD vs BUMP-AND-REPRICE")
    print("=" * 70)
    print(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print()

    # ============================================================
    # 1. Black-Scholes Timing Comparison
    # ============================================================
    print("1. BLACK-SCHOLES TIMING")
    print("-" * 70)

    S, K, T, r, sigma = 100.0, 105.0, 0.5, 0.05, 0.2
    n_runs = 1000

    # AAD timing
    t0 = time.perf_counter()
    for _ in range(n_runs):
        reset_tape()
        S_v = AADVariable(S)
        sigma_v = AADVariable(sigma)
        r_v = AADVariable(r)
        T_v = AADVariable(T)
        price = bs_price_aad(S_v, K, T_v, r_v, sigma_v, "call")
        price.backward()
    t_aad = (time.perf_counter() - t0) / n_runs * 1000  # ms

    # Bump-and-reprice timing
    t0 = time.perf_counter()
    for _ in range(n_runs):
        bs_bump_and_reprice(S, K, T, r, sigma, "call")
    t_bump = (time.perf_counter() - t0) / n_runs * 1000  # ms

    # Direct pricing timing
    t0 = time.perf_counter()
    for _ in range(n_runs):
        bs_price_scalar(S, K, T, r, sigma, "call")
    t_price = (time.perf_counter() - t0) / n_runs * 1000  # ms

    print(f"  Averaged over {n_runs} runs:")
    print(f"  {'Method':<25} {'Time (ms)':>10} {'Pricings':>10} {'Greeks':>8}")
    print(f"  {'-'*53}")
    print(f"  {'Single pricing':<25} {t_price:>10.4f} {'1':>10} {'0':>8}")
    print(f"  {'AAD (forward+backward)':<25} {t_aad:>10.4f} {'1':>10} {'4':>8}")
    print(f"  {'Bump-and-reprice':<25} {t_bump:>10.4f} {'11':>10} {'5':>8}")

    aad_overhead = t_aad / t_price
    bump_overhead = t_bump / t_price
    print(f"\n  AAD overhead vs single pricing: {aad_overhead:.1f}x")
    print(f"  Bump overhead vs single pricing: {bump_overhead:.1f}x")
    print(f"  AAD speedup vs bump-and-reprice: {t_bump/t_aad:.1f}x")

    # ============================================================
    # 2. Heston-COS Timing Comparison
    # ============================================================
    print("\n\n2. HESTON-COS TIMING")
    print("-" * 70)

    S0, K_h, T_h, r_h = 100.0, 100.0, 1.0, 0.05
    v0, kappa, theta, xi, rho = 0.04, 2.0, 0.04, 0.3, -0.7
    N_terms = 128
    n_runs_h = 100

    # AAD timing
    t0 = time.perf_counter()
    for _ in range(n_runs_h):
        reset_tape()
        s = AADVariable(S0)
        v = AADVariable(v0)
        rv = AADVariable(r_h)
        ka = AADVariable(kappa)
        th = AADVariable(theta)
        xv = AADVariable(xi)
        rv2 = AADVariable(rho)
        p = heston_cos_price_aad(s, K_h, T_h, rv, v, ka, th, xv, rv2, N_terms=N_terms)
        p.backward()
    t_aad_h = (time.perf_counter() - t0) / n_runs_h * 1000

    # Bump-and-reprice timing
    t0 = time.perf_counter()
    for _ in range(n_runs_h):
        heston_bump_and_reprice(S0, K_h, T_h, r_h, v0, kappa, theta, xi, rho, N_terms=N_terms)
    t_bump_h = (time.perf_counter() - t0) / n_runs_h * 1000

    # Direct pricing timing
    t0 = time.perf_counter()
    for _ in range(n_runs_h):
        heston_cos_price_scalar(S0, K_h, T_h, r_h, v0, kappa, theta, xi, rho, N_terms=N_terms)
    t_price_h = (time.perf_counter() - t0) / n_runs_h * 1000

    n_greeks = 7  # Heston has 7 Greeks
    n_pricings_bump = 2 * n_greeks + 1  # Central diff = 2 per Greek + 1 base

    print(f"  Averaged over {n_runs_h} runs (N={N_terms}):")
    print(f"  {'Method':<25} {'Time (ms)':>10} {'Pricings':>10} {'Greeks':>8}")
    print(f"  {'-'*53}")
    print(f"  {'Single pricing':<25} {t_price_h:>10.4f} {'1':>10} {'0':>8}")
    print(f"  {'AAD (forward+backward)':<25} {t_aad_h:>10.4f} {'1':>10} {str(n_greeks):>8}")
    print(f"  {'Bump-and-reprice':<25} {t_bump_h:>10.4f} {str(n_pricings_bump):>10} {str(n_greeks):>8}")

    aad_oh = t_aad_h / t_price_h
    bump_oh = t_bump_h / t_price_h
    print(f"\n  AAD overhead: {aad_oh:.1f}x single pricing")
    print(f"  Bump overhead: {bump_oh:.1f}x single pricing")
    print(f"  AAD speedup vs bump: {t_bump_h/t_aad_h:.1f}x")
    print(f"  Tape size: {len(tape)} entries")

    # ============================================================
    # 3. Accuracy Comparison
    # ============================================================
    print("\n\n3. ACCURACY COMPARISON")
    print("-" * 70)

    ref = bs_greeks_closed_form(S, K, T, r, sigma, "call")
    bump = bs_bump_and_reprice(S, K, T, r, sigma, "call")

    reset_tape()
    S_v = AADVariable(S)
    sigma_v = AADVariable(sigma)
    r_v = AADVariable(r)
    T_v = AADVariable(T)
    price = bs_price_aad(S_v, K, T_v, r_v, sigma_v, "call")
    price.backward()

    print(f"  BS Greeks — Error vs Closed-Form:")
    print(f"  {'Greek':<10} {'AAD Error':>15} {'Bump Error':>15} {'AAD Advantage':>15}")
    print(f"  {'-'*55}")

    greeks = [
        ("Delta", S_v.adjoint, bump["delta"], ref["delta"]),
        ("Vega", sigma_v.adjoint, bump["vega"], ref["vega"]),
        ("Theta", T_v.adjoint, bump["theta"], ref["theta"]),
        ("Rho", r_v.adjoint, bump["rho"], ref["rho"]),
    ]

    for name, aad_val, bump_val, ref_val in greeks:
        aad_err = abs(aad_val - ref_val)
        bump_err = abs(bump_val - ref_val)
        advantage = bump_err / aad_err if aad_err > 0 else float("inf")
        print(f"  {name:<10} {aad_err:>15.2e} {bump_err:>15.2e} {advantage:>15.0f}x")

    # ============================================================
    # 4. Scaling Analysis
    # ============================================================
    print("\n\n4. SCALING ANALYSIS (Why AAD Wins)")
    print("-" * 70)

    print(f"""
  Number of Greeks (n) vs Computation Cost:

  {'n':>5} {'AAD Cost':>15} {'Bump Cost':>15} {'AAD Advantage':>15}
  {'-'*50}""")

    for n in [1, 2, 5, 7, 10, 20, 50, 100]:
        aad_cost = 2  # 1 forward + 1 backward (constant)
        bump_cost = 2 * n + 1  # Central differences
        advantage = bump_cost / aad_cost
        print(f"  {n:>5} {'~2x':>15} {f'~{bump_cost}x':>15} {f'{advantage:.0f}x':>15}")

    print(f"""
  Key insight: AAD cost is O(1) with respect to number of Greeks.
  Bump-and-reprice cost is O(n).
  For Heston (n=7), AAD is ~7.5x more efficient in theory.
  For large portfolios with many risk factors, the advantage is massive.
""")

    # ============================================================
    # 5. Hardware Projection
    # ============================================================
    print("\n5. HARDWARE PROJECTION")
    print("-" * 70)

    print(f"""
  Estimated FPGA performance (based on Weiss et al. reference):

  {'Metric':<30} {'Bump-and-Reprice':>20} {'AAD Pipeline':>20}
  {'-'*70}
  {'Forward pricings needed':<30} {f'{2*n_greeks+1}':>20} {'1':>20}
  {'Backward passes needed':<30} {'0':>20} {'1':>20}
  {'Total pipeline passes':<30} {f'{2*n_greeks+1}':>20} {'2':>20}
  {'Relative latency':<30} {f'{2*n_greeks+1}x':>20} {'~2-3x':>20}
  {'Latency advantage':<30} {'baseline':>20} {f'~{(2*n_greeks+1)/2.5:.0f}x faster':>20}

  Note: The AAD backward pass has similar complexity to the forward pass
  (same number of operations, but in reverse with accumulation).
  The 2-3x estimate accounts for forward + backward + tape storage overhead.
""")


if __name__ == "__main__":
    main()
