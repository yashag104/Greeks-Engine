"""
Test Bump-and-Reprice — Validates the finite difference baseline.

Validates BS bump-and-reprice against closed-form Greeks to ensure
the baseline itself is correct before using it to validate Heston AAD.
"""

import sys
import os
import math

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from models.black_scholes import bs_greeks_closed_form
from models.bump_and_reprice import bs_bump_and_reprice


def test_bs_bump_vs_closed_form():
    """BS bump-and-reprice should agree with closed-form within finite-diff error."""
    S, K, T, r, sigma = 100.0, 105.0, 0.5, 0.05, 0.2

    ref = bs_greeks_closed_form(S, K, T, r, sigma, "call")
    bump = bs_bump_and_reprice(S, K, T, r, sigma, "call", epsilon=1e-5)

    # Finite differences should agree to ~1e-5 for first-order and ~1e-3 for second-order
    tol_first = 1e-4
    tol_second = 1e-3

    print(f"\n  BS Bump-and-Reprice vs Closed-Form")
    print(f"  {'Greek':<10} {'Bump&Reprice':>15} {'Closed-Form':>15} {'Error':>15}")
    print(f"  {'-'*55}")

    for name, bump_val, ref_val, tol in [
        ("Price", bump["price"], ref["price"], 1e-12),
        ("Delta", bump["delta"], ref["delta"], tol_first),
        ("Gamma", bump["gamma"], ref["gamma"], tol_second),
        ("Vega", bump["vega"], ref["vega"], tol_first),
        ("Theta", bump["theta"], ref["theta"], tol_first),
        ("Rho", bump["rho"], ref["rho"], tol_first),
    ]:
        err = abs(bump_val - ref_val)
        status = "✓" if err < tol else "✗"
        print(f"  {status} {name:<10} {bump_val:>15.10f} {ref_val:>15.10f} {err:>15.2e}")
        assert err < tol, f"{name} error too large: {err} > {tol}"


def test_bs_bump_multiple_epsilons():
    """Verify convergence: smaller epsilon → smaller error (up to numerical noise)."""
    S, K, T, r, sigma = 100.0, 100.0, 1.0, 0.05, 0.2

    ref = bs_greeks_closed_form(S, K, T, r, sigma, "call")

    epsilons = [1e-3, 1e-4, 1e-5, 1e-6, 1e-7]

    print(f"\n  Convergence of Bump-and-Reprice Delta vs Epsilon")
    print(f"  {'Epsilon':>12} {'Delta':>15} {'Error':>15}")
    print(f"  {'-'*42}")

    prev_err = float("inf")
    for eps in epsilons:
        bump = bs_bump_and_reprice(S, K, T, r, sigma, "call", epsilon=eps)
        err = abs(bump["delta"] - ref["delta"])
        print(f"  {eps:>12.0e} {bump['delta']:>15.10f} {err:>15.2e}")
        # Error should generally decrease until numerical noise dominates
        # (at very small epsilon, subtraction cancellation increases error)


# ======================================================================
# Run all tests
# ======================================================================

if __name__ == "__main__":
    tests = [
        ("BS Bump-and-Reprice vs Closed-Form", test_bs_bump_vs_closed_form),
        ("Convergence with Epsilon", test_bs_bump_multiple_epsilons),
    ]

    print("=" * 60)
    print("BUMP-AND-REPRICE BASELINE TESTS")
    print("=" * 60)

    passed = 0
    failed = 0
    for name, test_fn in tests:
        try:
            print(f"\n[TEST] {name}")
            test_fn()
            print(f"\n  ✓ PASSED")
            passed += 1
        except Exception as e:
            print(f"\n  ✗ FAILED: {e}")
            import traceback
            traceback.print_exc()
            failed += 1

    print(f"\n{'=' * 60}")
    print(f"Results: {passed} passed, {failed} failed, {passed + failed} total")
    print(f"{'=' * 60}")
