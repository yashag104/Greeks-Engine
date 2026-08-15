"""
Correctness Validation — Comprehensive validation of all pricing and Greeks computations.

This script runs systematic correctness checks across all components:
1. AAD engine primitives
2. BS pricing + Greeks (AAD vs closed-form)
3. Heston-COS pricing + Greeks (AAD vs bump-and-reprice)
4. Cross-validation: BS as special case of Heston (when xi→0)

Outputs a detailed validation report.
"""

import sys
import os
import math
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "software"))

from aad_engine import AADVariable, tape, reset_tape, aad_sin, aad_cos, aad_exp, aad_log, aad_sqrt
from models.black_scholes import bs_price_aad, bs_price_scalar, bs_greeks_closed_form
from models.heston_cos import heston_cos_price_aad, heston_cos_price_scalar
from models.bump_and_reprice import bs_bump_and_reprice, heston_bump_and_reprice


def main():
    print("=" * 70)
    print("CORRECTNESS VALIDATION REPORT")
    print("=" * 70)
    print(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print()

    results = []

    # ============================================================
    # 1. AAD Engine Primitives
    # ============================================================
    print("1. AAD ENGINE PRIMITIVES")
    print("-" * 70)

    primitives = [
        ("f=x*y+sin(x)", lambda: _test_aad_toy(2.0, 3.0)),
        ("f=x*y+sin(x)", lambda: _test_aad_toy(1.5, 4.0)),
        ("f=x*y+sin(x)", lambda: _test_aad_toy(0.5, 10.0)),
        ("f=exp(log(x))", lambda: _test_identity()),
        ("f=x^3", lambda: _test_power()),
    ]

    for name, test_fn in primitives:
        passed, max_err = test_fn()
        status = "PASS" if passed else "FAIL"
        results.append((f"Primitive: {name}", status, max_err))
        print(f"  [{status}] {name:30s}  max_err={max_err:.2e}")

    # ============================================================
    # 2. Black-Scholes Pricing + Greeks
    # ============================================================
    print("\n2. BLACK-SCHOLES PRICING + GREEKS")
    print("-" * 70)

    bs_scenarios = [
        {"S": 100, "K": 105, "T": 0.5, "r": 0.05, "sigma": 0.2, "type": "call"},
        {"S": 100, "K": 80,  "T": 1.0, "r": 0.05, "sigma": 0.2, "type": "call"},
        {"S": 100, "K": 120, "T": 1.0, "r": 0.05, "sigma": 0.2, "type": "call"},
        {"S": 100, "K": 100, "T": 0.01,"r": 0.05, "sigma": 0.2, "type": "call"},
        {"S": 100, "K": 100, "T": 2.0, "r": 0.05, "sigma": 0.4, "type": "put"},
        {"S": 50,  "K": 60,  "T": 0.5, "r": 0.01, "sigma": 0.15,"type": "put"},
        {"S": 200, "K": 180, "T": 0.25,"r": 0.03, "sigma": 0.3, "type": "call"},
        {"S": 100, "K": 100, "T": 5.0, "r": 0.02, "sigma": 0.25,"type": "put"},
    ]

    tol = 1e-9
    for sc in bs_scenarios:
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
        passed = max_err < tol
        status = "PASS" if passed else "FAIL"

        label = f"BS {sc['type']} S={sc['S']} K={sc['K']} T={sc['T']}"
        results.append((label, status, max_err))
        print(f"  [{status}] {label:40s}  max_err={max_err:.2e}")

    # ============================================================
    # 3. Heston-COS Pricing + Greeks
    # ============================================================
    print("\n3. HESTON-COS PRICING + GREEKS")
    print("-" * 70)

    heston_scenarios = [
        {"S0":100,"K":100,"T":1.0,"r":0.05,"v0":0.04,"kappa":2.0,"theta":0.04,"xi":0.3,"rho":-0.7},
        {"S0":100,"K":120,"T":0.5,"r":0.03,"v0":0.09,"kappa":1.5,"theta":0.09,"xi":0.5,"rho":-0.8},
        {"S0":100,"K":80, "T":2.0,"r":0.04,"v0":0.01,"kappa":3.0,"theta":0.04,"xi":0.4,"rho":-0.6},
        {"S0":50, "K":60, "T":1.0,"r":0.01,"v0":0.16,"kappa":0.5,"theta":0.16,"xi":1.0,"rho":-0.9},
    ]

    heston_tol = 0.02  # 2% relative tolerance (bump-and-reprice has truncation error)
    N_terms = 128

    for sc in heston_scenarios:
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
        for aad_val, ref_val, name in [
            (S0.adjoint, ref["delta"], "delta"),
            (v0.adjoint, ref["vega_v0"], "vega"),
            (r.adjoint, ref["rho_r"], "rho"),
        ]:
            if abs(ref_val) > 1e-10:
                rel_err = abs(aad_val - ref_val) / abs(ref_val)
            else:
                rel_err = abs(aad_val - ref_val)
            max_rel_err = max(max_rel_err, rel_err)

        passed = max_rel_err < heston_tol
        status = "PASS" if passed else "FAIL"

        label = f"Heston S={sc['S0']} K={sc['K']} v0={sc['v0']}"
        results.append((label, status, max_rel_err))
        print(f"  [{status}] {label:40s}  max_rel_err={max_rel_err:.2e}")

    # ============================================================
    # 4. Cross-Validation: Heston→BS limit
    # ============================================================
    print("\n4. CROSS-VALIDATION: HESTON -> BS LIMIT")
    print("-" * 70)

    # When xi→0, rho→0, and v0=theta=sigma^2, Heston should approach BS
    S_val, K_val, T_val, r_val, sigma_val = 100.0, 100.0, 1.0, 0.05, 0.2
    v0_heston = sigma_val ** 2  # = 0.04
    kappa_val = 2.0
    theta_heston = v0_heston  # long-run = initial
    xi_val = 0.001  # nearly zero vol-of-vol
    rho_val = 0.0

    bs_ref = bs_price_scalar(S_val, K_val, T_val, r_val, sigma_val, "call")
    heston_price = heston_cos_price_scalar(
        S_val, K_val, T_val, r_val, v0_heston, kappa_val, theta_heston, xi_val, rho_val,
        N_terms=256
    )

    cross_err = abs(bs_ref - heston_price)
    cross_rel = cross_err / bs_ref if bs_ref > 0 else cross_err
    passed = cross_rel < 0.001  # 0.1% tolerance
    status = "PASS" if passed else "FAIL"
    results.append(("Heston->BS limit", status, cross_rel))
    print(f"  [{status}] BS price = {bs_ref:.6f}, Heston price = {heston_price:.6f}, rel_err = {cross_rel:.2e}")

    # ============================================================
    # Summary
    # ============================================================
    print("\n" + "=" * 70)
    print("VALIDATION SUMMARY")
    print("=" * 70)

    n_pass = sum(1 for _, s, _ in results if s == "PASS")
    n_fail = sum(1 for _, s, _ in results if s == "FAIL")
    print(f"\nTotal: {n_pass} PASSED, {n_fail} FAILED, {n_pass + n_fail} total")

    if n_fail == 0:
        print("\nALL VALIDATION CHECKS PASSED!")
    else:
        print(f"\nWARNING: {n_fail} check(s) FAILED:")
        for name, status, err in results:
            if status == "FAIL":
                print(f"  - {name}: error={err:.2e}")

    return n_fail == 0


# ============================================================
# Helper test functions
# ============================================================

def _test_aad_toy(x_val, y_val):
    reset_tape()
    x = AADVariable(x_val)
    y = AADVariable(y_val)
    f = x * y + aad_sin(x)
    f.backward()

    expected_df_dx = y_val + math.cos(x_val)
    expected_df_dy = x_val

    err_dx = abs(x.adjoint - expected_df_dx)
    err_dy = abs(y.adjoint - expected_df_dy)
    max_err = max(err_dx, err_dy)
    return max_err < 1e-12, max_err


def _test_identity():
    reset_tape()
    x = AADVariable(3.0)
    f = aad_exp(aad_log(x))
    f.backward()
    err = abs(x.adjoint - 1.0)
    return err < 1e-10, err


def _test_power():
    reset_tape()
    x = AADVariable(2.0)
    f = x ** 3
    f.backward()
    err = abs(x.adjoint - 12.0)
    return err < 1e-10, err


if __name__ == "__main__":
    main()
