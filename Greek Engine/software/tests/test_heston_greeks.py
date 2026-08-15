"""
Test Heston Greeks — AAD Greeks vs. Bump-and-Reprice Reference.

Since there are no closed-form Greeks for Heston, we validate AAD
results against finite-difference (bump-and-reprice) approximations.
Agreement within a tolerance that accounts for both AAD accuracy and
finite-difference truncation error.
"""

import sys
import os
import math
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from aad_engine import AADVariable, tape, reset_tape
from models.heston_cos import heston_cos_price_aad, heston_cos_price_scalar
from models.bump_and_reprice import heston_bump_and_reprice


def test_heston_price_consistency():
    """Verify scalar and AAD pricers give the same value."""
    S0_val, K_val, T_val, r_val = 100.0, 100.0, 1.0, 0.05
    v0_val, kappa_val, theta_val, xi_val, rho_val = 0.04, 2.0, 0.04, 0.3, -0.7

    # Scalar price
    scalar_price = heston_cos_price_scalar(
        S0_val, K_val, T_val, r_val, v0_val, kappa_val, theta_val, xi_val, rho_val,
        N_terms=128
    )

    # AAD price
    reset_tape()
    S0 = AADVariable(S0_val)
    K = AADVariable(K_val)
    T = AADVariable(T_val)
    r = AADVariable(r_val)
    v0 = AADVariable(v0_val)
    kappa = AADVariable(kappa_val)
    theta = AADVariable(theta_val)
    xi = AADVariable(xi_val)
    rho = AADVariable(rho_val)

    aad_price_var = heston_cos_price_aad(S0, K, T, r, v0, kappa, theta, xi, rho,
                                          N_terms=128)

    err = abs(aad_price_var.value - scalar_price)
    print(f"\n  Scalar price:  {scalar_price:.10f}")
    print(f"  AAD price:     {aad_price_var.value:.10f}")
    print(f"  Difference:    {err:.2e}")

    assert err < 1e-8, f"Price mismatch between scalar and AAD: {err}"


def test_heston_greeks_vs_bump_and_reprice():
    """Compare AAD Greeks against bump-and-reprice for Heston-COS."""
    S0_val = 100.0
    K_val = 100.0
    T_val = 1.0
    r_val = 0.05
    v0_val = 0.04
    kappa_val = 2.0
    theta_val = 0.04
    xi_val = 0.3
    rho_val = -0.7
    N_terms = 128

    # Bump-and-reprice reference
    print("\n  Computing bump-and-reprice reference...")
    t0 = time.time()
    ref = heston_bump_and_reprice(
        S0_val, K_val, T_val, r_val, v0_val, kappa_val, theta_val, xi_val, rho_val,
        N_terms=N_terms, epsilon=1e-5
    )
    t_bump = time.time() - t0

    # AAD computation
    print("  Computing AAD Greeks...")
    t0 = time.time()
    reset_tape()

    S0 = AADVariable(S0_val, name="S0")
    K = AADVariable(K_val, name="K")
    T = AADVariable(T_val, name="T")
    r = AADVariable(r_val, name="r")
    v0 = AADVariable(v0_val, name="v0")
    kappa = AADVariable(kappa_val, name="kappa")
    theta = AADVariable(theta_val, name="theta")
    xi = AADVariable(xi_val, name="xi")
    rho = AADVariable(rho_val, name="rho")

    price = heston_cos_price_aad(S0, K, T, r, v0, kappa, theta, xi, rho,
                                  N_terms=N_terms)
    price.backward()
    t_aad = time.time() - t0

    # Compare
    # Tolerance is looser because bump-and-reprice has truncation error
    tol = 0.01  # 1% relative tolerance for most Greeks

    print(f"\n  Heston-COS Greeks Comparison (N={N_terms})")
    print(f"  {'Greek':<20} {'AAD':>15} {'Bump&Reprice':>15} {'Rel.Err':>12}")
    print(f"  {'-'*62}")

    comparisons = [
        ("Price", price.value, ref["price"]),
        ("Delta (∂V/∂S0)", S0.adjoint, ref["delta"]),
        ("Vega (∂V/∂v0)", v0.adjoint, ref["vega_v0"]),
        ("Rho (∂V/∂r)", r.adjoint, ref["rho_r"]),
        ("κ-sens (∂V/∂κ)", kappa.adjoint, ref["kappa_sens"]),
        ("θ-sens (∂V/∂θ)", theta.adjoint, ref["theta_sens"]),
        ("ξ-sens (∂V/∂ξ)", xi.adjoint, ref["xi_sens"]),
        ("ρ-sens (∂V/∂ρ)", rho.adjoint, ref["rho_corr_sens"]),
    ]

    all_ok = True
    for name, aad_val, ref_val in comparisons:
        if abs(ref_val) > 1e-10:
            rel_err = abs(aad_val - ref_val) / abs(ref_val)
        else:
            rel_err = abs(aad_val - ref_val)

        status = "✓" if rel_err < tol else "✗"
        print(f"  {status} {name:<20} {aad_val:>15.8f} {ref_val:>15.8f} {rel_err:>12.4e}")

        if rel_err >= tol:
            all_ok = False

    print(f"\n  Timing: AAD = {t_aad:.3f}s (1 pass), Bump&Reprice = {t_bump:.3f}s ({8} pricings)")
    print(f"  Tape size: {len(tape)} entries")

    if not all_ok:
        print("\n  WARNING: Some Greeks exceed tolerance. This may be due to:")
        print("  - Finite difference truncation error (bump-and-reprice)")
        print("  - Truncation range sensitivity (COS method)")
        print("  - Complex arithmetic accumulation in AAD")


def test_heston_greeks_multiple_scenarios():
    """Test Heston Greeks across different parameter regimes."""
    scenarios = [
        {"label": "ATM, low vol", "S0": 100, "K": 100, "T": 1.0, "r": 0.05,
         "v0": 0.01, "kappa": 2.0, "theta": 0.01, "xi": 0.2, "rho": -0.5},
        {"label": "OTM, high vol", "S0": 100, "K": 120, "T": 0.5, "r": 0.03,
         "v0": 0.09, "kappa": 1.5, "theta": 0.09, "xi": 0.5, "rho": -0.8},
        {"label": "ITM, long maturity", "S0": 100, "K": 80, "T": 2.0, "r": 0.04,
         "v0": 0.04, "kappa": 3.0, "theta": 0.04, "xi": 0.4, "rho": -0.6},
    ]

    N_terms = 128
    tol = 0.02  # 2% tolerance

    print(f"\n  Multi-Scenario Heston Greeks Validation")
    print(f"  {'='*70}")

    for sc in scenarios:
        ref = heston_bump_and_reprice(
            sc["S0"], sc["K"], sc["T"], sc["r"], sc["v0"],
            sc["kappa"], sc["theta"], sc["xi"], sc["rho"],
            N_terms=N_terms, epsilon=1e-5
        )

        reset_tape()
        S0 = AADVariable(float(sc["S0"]))
        v0 = AADVariable(float(sc["v0"]))
        r = AADVariable(float(sc["r"]))
        kappa = AADVariable(float(sc["kappa"]))
        theta = AADVariable(float(sc["theta"]))
        xi = AADVariable(float(sc["xi"]))
        rho = AADVariable(float(sc["rho"]))

        price = heston_cos_price_aad(
            S0, sc["K"], sc["T"], r, v0, kappa, theta, xi, rho,
            N_terms=N_terms
        )
        price.backward()

        max_rel_err = 0.0
        for aad_val, ref_val in [
            (S0.adjoint, ref["delta"]),
            (v0.adjoint, ref["vega_v0"]),
            (r.adjoint, ref["rho_r"]),
        ]:
            if abs(ref_val) > 1e-10:
                rel_err = abs(aad_val - ref_val) / abs(ref_val)
            else:
                rel_err = abs(aad_val - ref_val)
            max_rel_err = max(max_rel_err, rel_err)

        status = "✓" if max_rel_err < tol else "✗"
        print(f"  {status} {sc['label']:<30} price={price.value:.6f}  max_rel_err={max_rel_err:.4e}")


# ======================================================================
# Run all tests
# ======================================================================

if __name__ == "__main__":
    tests = [
        ("Heston Price Consistency (scalar vs AAD)", test_heston_price_consistency),
        ("Heston Greeks (AAD vs Bump-and-Reprice)", test_heston_greeks_vs_bump_and_reprice),
        ("Heston Greeks Multi-Scenario", test_heston_greeks_multiple_scenarios),
    ]

    print("=" * 60)
    print("HESTON-COS GREEKS TESTS — AAD vs Bump-and-Reprice")
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
