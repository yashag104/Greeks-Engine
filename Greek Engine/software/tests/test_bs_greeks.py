"""
Test BS Greeks — AAD Greeks vs. Closed-Form Analytical Greeks.

The Black-Scholes model has exact closed-form expressions for all 5 Greeks.
This test validates that the AAD engine produces the same values to
machine precision (or very close to it).
"""

import sys
import os
import math

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from aad_engine import AADVariable, tape, reset_tape
from models.black_scholes import bs_price_aad, bs_greeks_closed_form


def test_bs_greeks_call():
    """Test BS call Greeks: AAD vs closed-form."""
    # Typical market parameters
    S_val = 100.0
    K_val = 105.0
    T_val = 0.5
    r_val = 0.05
    sigma_val = 0.2

    # Closed-form reference
    ref = bs_greeks_closed_form(S_val, K_val, T_val, r_val, sigma_val, "call")

    # AAD computation
    reset_tape()
    S = AADVariable(S_val, name="S")
    K = AADVariable(K_val, name="K")
    T = AADVariable(T_val, name="T")
    r = AADVariable(r_val, name="r")
    sigma = AADVariable(sigma_val, name="sigma")

    price = bs_price_aad(S, K, T, r, sigma, "call")
    price.backward()

    # Compare
    tol = 1e-10

    print(f"\n  Black-Scholes CALL Greeks (S={S_val}, K={K_val}, T={T_val}, r={r_val}, σ={sigma_val})")
    print(f"  {'Greek':<10} {'AAD':>15} {'Closed-Form':>15} {'Error':>15}")
    print(f"  {'-'*55}")

    # Price
    price_err = abs(price.value - ref["price"])
    print(f"  {'Price':<10} {price.value:>15.10f} {ref['price']:>15.10f} {price_err:>15.2e}")
    assert price_err < tol, f"Price error: {price_err}"

    # Delta = ∂V/∂S
    delta_aad = S.adjoint
    delta_err = abs(delta_aad - ref["delta"])
    print(f"  {'Delta':<10} {delta_aad:>15.10f} {ref['delta']:>15.10f} {delta_err:>15.2e}")
    assert delta_err < tol, f"Delta error: {delta_err}"

    # Vega = ∂V/∂σ
    vega_aad = sigma.adjoint
    vega_err = abs(vega_aad - ref["vega"])
    print(f"  {'Vega':<10} {vega_aad:>15.10f} {ref['vega']:>15.10f} {vega_err:>15.2e}")
    assert vega_err < tol, f"Vega error: {vega_err}"

    # Theta = ∂V/∂T (note: our AAD gives ∂V/∂T directly)
    theta_aad = T.adjoint
    theta_err = abs(theta_aad - ref["theta"])
    print(f"  {'Theta':<10} {theta_aad:>15.10f} {ref['theta']:>15.10f} {theta_err:>15.2e}")
    assert theta_err < tol, f"Theta error: {theta_err}"

    # Rho = ∂V/∂r
    rho_aad = r.adjoint
    rho_err = abs(rho_aad - ref["rho"])
    print(f"  {'Rho':<10} {rho_aad:>15.10f} {ref['rho']:>15.10f} {rho_err:>15.2e}")
    assert rho_err < tol, f"Rho error: {rho_err}"

    # Gamma = ∂²V/∂S² — not directly from AAD (first-order only)
    # but we can verify by computing ∂Delta/∂S via a second AAD pass
    print(f"\n  Note: Gamma (2nd order) requires a second AAD pass or finite diff.")
    # Compute Gamma via finite differences on the AAD delta
    eps = 1e-5
    reset_tape()
    S_up = AADVariable(S_val + eps, name="S")
    price_up = bs_price_aad(S_up, K_val, T_val, r_val, sigma_val, "call")
    price_up.backward()
    delta_up = S_up.adjoint

    reset_tape()
    S_dn = AADVariable(S_val - eps, name="S")
    price_dn = bs_price_aad(S_dn, K_val, T_val, r_val, sigma_val, "call")
    price_dn.backward()
    delta_dn = S_dn.adjoint

    gamma_aad = (delta_up - delta_dn) / (2.0 * eps)
    gamma_err = abs(gamma_aad - ref["gamma"])
    print(f"  {'Gamma':<10} {gamma_aad:>15.10f} {ref['gamma']:>15.10f} {gamma_err:>15.2e}")
    assert gamma_err < 1e-5, f"Gamma error: {gamma_err}"


def test_bs_greeks_put():
    """Test BS put Greeks: AAD vs closed-form."""
    S_val = 100.0
    K_val = 95.0
    T_val = 1.0
    r_val = 0.03
    sigma_val = 0.25

    ref = bs_greeks_closed_form(S_val, K_val, T_val, r_val, sigma_val, "put")

    reset_tape()
    S = AADVariable(S_val, name="S")
    K = AADVariable(K_val, name="K")
    T = AADVariable(T_val, name="T")
    r = AADVariable(r_val, name="r")
    sigma = AADVariable(sigma_val, name="sigma")

    price = bs_price_aad(S, K, T, r, sigma, "put")
    price.backward()

    tol = 1e-10

    print(f"\n  Black-Scholes PUT Greeks (S={S_val}, K={K_val}, T={T_val}, r={r_val}, σ={sigma_val})")
    print(f"  {'Greek':<10} {'AAD':>15} {'Closed-Form':>15} {'Error':>15}")
    print(f"  {'-'*55}")

    comparisons = [
        ("Price", price.value, ref["price"]),
        ("Delta", S.adjoint, ref["delta"]),
        ("Vega", sigma.adjoint, ref["vega"]),
        ("Theta", T.adjoint, ref["theta"]),
        ("Rho", r.adjoint, ref["rho"]),
    ]

    for name, aad_val, ref_val in comparisons:
        err = abs(aad_val - ref_val)
        print(f"  {name:<10} {aad_val:>15.10f} {ref_val:>15.10f} {err:>15.2e}")
        assert err < tol, f"{name} error: {err}"


def test_bs_greeks_multiple_scenarios():
    """Test across multiple parameter sets — ATM, ITM, OTM, near-expiry."""
    scenarios = [
        {"S": 100, "K": 100, "T": 1.0, "r": 0.05, "sigma": 0.2, "type": "call", "label": "ATM Call"},
        {"S": 100, "K": 80,  "T": 1.0, "r": 0.05, "sigma": 0.2, "type": "call", "label": "Deep ITM Call"},
        {"S": 100, "K": 120, "T": 1.0, "r": 0.05, "sigma": 0.2, "type": "call", "label": "Deep OTM Call"},
        {"S": 100, "K": 100, "T": 0.01,"r": 0.05, "sigma": 0.2, "type": "call", "label": "Near-expiry ATM Call"},
        {"S": 100, "K": 100, "T": 2.0, "r": 0.05, "sigma": 0.4, "type": "put",  "label": "High-vol ATM Put"},
        {"S": 50,  "K": 60,  "T": 0.5, "r": 0.01, "sigma": 0.15,"type": "put",  "label": "OTM Put low-vol"},
    ]

    tol = 1e-9
    print(f"\n  Multi-scenario BS Greeks Validation")
    print(f"  {'='*70}")

    for sc in scenarios:
        ref = bs_greeks_closed_form(sc["S"], sc["K"], sc["T"], sc["r"], sc["sigma"], sc["type"])

        reset_tape()
        S = AADVariable(float(sc["S"]))
        sigma = AADVariable(float(sc["sigma"]))
        r = AADVariable(float(sc["r"]))
        T = AADVariable(float(sc["T"]))

        price = bs_price_aad(S, sc["K"], T, r, sigma, sc["type"])
        price.backward()

        errors = {
            "price": abs(price.value - ref["price"]),
            "delta": abs(S.adjoint - ref["delta"]),
            "vega": abs(sigma.adjoint - ref["vega"]),
            "theta": abs(T.adjoint - ref["theta"]),
            "rho": abs(r.adjoint - ref["rho"]),
        }

        max_err = max(errors.values())
        status = "✓" if max_err < tol else "✗"
        print(f"  {status} {sc['label']:<30} max_error={max_err:.2e}")

        for name, err in errors.items():
            assert err < tol, f"{sc['label']} {name} error: {err}"


# ======================================================================
# Run all tests
# ======================================================================

if __name__ == "__main__":
    tests = [
        ("BS Call Greeks (AAD vs Closed-Form)", test_bs_greeks_call),
        ("BS Put Greeks (AAD vs Closed-Form)", test_bs_greeks_put),
        ("BS Greeks Multi-Scenario", test_bs_greeks_multiple_scenarios),
    ]

    print("=" * 60)
    print("BLACK-SCHOLES GREEKS TESTS — AAD vs Closed-Form")
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
