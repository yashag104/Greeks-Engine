"""
Test Toy AAD Engine — Validates the core AAD mechanism.

Worked example: f(x, y) = x*y + sin(x)

At (x=2, y=3):
    f     = 2*3 + sin(2) = 6 + 0.90929... = 6.90929...
    ∂f/∂x = y + cos(x)   = 3 + cos(2) = 3 + (-0.41615...) = 2.58385...
    ∂f/∂y = x             = 2
"""

import sys
import os
import math

# Add software directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from aad_engine import AADVariable, tape, reset_tape, aad_sin, aad_cos, aad_exp, aad_log, aad_sqrt


def test_toy_example():
    """f(x, y) = x*y + sin(x) — the canonical AAD worked example."""
    reset_tape()

    x = AADVariable(2.0, name="x")
    y = AADVariable(3.0, name="y")

    f = x * y + aad_sin(x)

    # Forward pass check
    expected_value = 2.0 * 3.0 + math.sin(2.0)
    assert abs(f.value - expected_value) < 1e-12, \
        f"Forward value mismatch: {f.value} vs {expected_value}"

    # Backward pass
    f.backward()

    # Check adjoints
    expected_df_dx = 3.0 + math.cos(2.0)  # y + cos(x)
    expected_df_dy = 2.0                    # x

    assert abs(x.adjoint - expected_df_dx) < 1e-12, \
        f"∂f/∂x mismatch: {x.adjoint} vs {expected_df_dx}"
    assert abs(y.adjoint - expected_df_dy) < 1e-12, \
        f"∂f/∂y mismatch: {y.adjoint} vs {expected_df_dy}"

    print(f"  f({2.0}, {3.0}) = {f.value:.10f}  (expected {expected_value:.10f})")
    print(f"  ∂f/∂x = {x.adjoint:.10f}  (expected {expected_df_dx:.10f})")
    print(f"  ∂f/∂y = {y.adjoint:.10f}  (expected {expected_df_dy:.10f})")


def test_toy_different_values():
    """Same function at (x=1.5, y=4.0)."""
    reset_tape()

    x = AADVariable(1.5, name="x")
    y = AADVariable(4.0, name="y")

    f = x * y + aad_sin(x)

    expected_value = 1.5 * 4.0 + math.sin(1.5)
    assert abs(f.value - expected_value) < 1e-12

    f.backward()

    expected_df_dx = 4.0 + math.cos(1.5)
    expected_df_dy = 1.5

    assert abs(x.adjoint - expected_df_dx) < 1e-12
    assert abs(y.adjoint - expected_df_dy) < 1e-12

    print(f"  f({1.5}, {4.0}) = {f.value:.10f}  (expected {expected_value:.10f})")
    print(f"  ∂f/∂x = {x.adjoint:.10f}  (expected {expected_df_dx:.10f})")
    print(f"  ∂f/∂y = {y.adjoint:.10f}  (expected {expected_df_dy:.10f})")


def test_exp_log():
    """f(x) = exp(log(x)) = x.  ∂f/∂x = 1."""
    reset_tape()
    x = AADVariable(3.0)
    f = aad_exp(aad_log(x))

    assert abs(f.value - 3.0) < 1e-12

    f.backward()
    assert abs(x.adjoint - 1.0) < 1e-10, f"Expected 1.0, got {x.adjoint}"

    print(f"  exp(log(3)) = {f.value:.10f}, ∂/∂x = {x.adjoint:.10f}")


def test_sqrt():
    """f(x) = sqrt(x).  ∂f/∂x = 1/(2*sqrt(x))."""
    reset_tape()
    x = AADVariable(9.0)
    f = aad_sqrt(x)

    assert abs(f.value - 3.0) < 1e-12

    f.backward()
    expected = 1.0 / (2.0 * 3.0)
    assert abs(x.adjoint - expected) < 1e-12

    print(f"  sqrt(9) = {f.value:.10f}, ∂/∂x = {x.adjoint:.10f} (expected {expected:.10f})")


def test_division():
    """f(x, y) = x / y.  ∂f/∂x = 1/y, ∂f/∂y = -x/y²."""
    reset_tape()
    x = AADVariable(6.0)
    y = AADVariable(3.0)
    f = x / y

    assert abs(f.value - 2.0) < 1e-12

    f.backward()
    assert abs(x.adjoint - 1.0 / 3.0) < 1e-12
    assert abs(y.adjoint - (-6.0 / 9.0)) < 1e-12

    print(f"  6/3 = {f.value:.10f}, ∂/∂x = {x.adjoint:.10f}, ∂/∂y = {y.adjoint:.10f}")


def test_subtraction():
    """f(x, y) = x - y.  ∂f/∂x = 1, ∂f/∂y = -1."""
    reset_tape()
    x = AADVariable(5.0)
    y = AADVariable(3.0)
    f = x - y

    assert abs(f.value - 2.0) < 1e-12

    f.backward()
    assert abs(x.adjoint - 1.0) < 1e-12
    assert abs(y.adjoint - (-1.0)) < 1e-12

    print(f"  5-3 = {f.value:.10f}, ∂/∂x = {x.adjoint:.10f}, ∂/∂y = {y.adjoint:.10f}")


def test_power():
    """f(x) = x^3.  ∂f/∂x = 3x²."""
    reset_tape()
    x = AADVariable(2.0)
    f = x ** 3

    assert abs(f.value - 8.0) < 1e-12

    f.backward()
    expected = 3.0 * 4.0  # 3*x² = 12
    assert abs(x.adjoint - expected) < 1e-10

    print(f"  2^3 = {f.value:.10f}, ∂/∂x = {x.adjoint:.10f} (expected {expected})")


def test_complex_expression():
    """f(x, y) = exp(x*y) + x² - cos(y).

    ∂f/∂x = y*exp(x*y) + 2x
    ∂f/∂y = x*exp(x*y) + sin(y)
    """
    reset_tape()
    x = AADVariable(1.0)
    y = AADVariable(2.0)

    f = aad_exp(x * y) + x ** 2 - aad_cos(y)

    expected_value = math.exp(2.0) + 1.0 - math.cos(2.0)
    assert abs(f.value - expected_value) < 1e-10

    f.backward()

    expected_df_dx = 2.0 * math.exp(2.0) + 2.0
    expected_df_dy = 1.0 * math.exp(2.0) + math.sin(2.0)

    assert abs(x.adjoint - expected_df_dx) < 1e-10, \
        f"∂f/∂x: {x.adjoint} vs {expected_df_dx}"
    assert abs(y.adjoint - expected_df_dy) < 1e-10, \
        f"∂f/∂y: {y.adjoint} vs {expected_df_dy}"

    print(f"  f(1,2) = {f.value:.10f}")
    print(f"  ∂f/∂x = {x.adjoint:.10f} (expected {expected_df_dx:.10f})")
    print(f"  ∂f/∂y = {y.adjoint:.10f} (expected {expected_df_dy:.10f})")


def test_scalar_operations():
    """Test operations with mixed AADVariable and scalar operands."""
    reset_tape()
    x = AADVariable(3.0)

    # 2 * x + 1
    f = 2.0 * x + 1.0

    assert abs(f.value - 7.0) < 1e-12

    f.backward()
    assert abs(x.adjoint - 2.0) < 1e-12

    print(f"  2*3+1 = {f.value:.10f}, ∂/∂x = {x.adjoint:.10f}")


def test_rsub():
    """Test reverse subtraction: f(x) = 5 - x. ∂f/∂x = -1."""
    reset_tape()
    x = AADVariable(3.0)
    f = 5.0 - x

    assert abs(f.value - 2.0) < 1e-12

    f.backward()
    assert abs(x.adjoint - (-1.0)) < 1e-12

    print(f"  5-3 = {f.value:.10f}, ∂/∂x = {x.adjoint:.10f}")


def test_rdiv():
    """Test reverse division: f(x) = 6 / x. ∂f/∂x = -6/x²."""
    reset_tape()
    x = AADVariable(3.0)
    f = 6.0 / x

    assert abs(f.value - 2.0) < 1e-12

    f.backward()
    expected = -6.0 / 9.0
    assert abs(x.adjoint - expected) < 1e-12

    print(f"  6/3 = {f.value:.10f}, ∂/∂x = {x.adjoint:.10f} (expected {expected:.10f})")


def test_negation():
    """Test negation: f(x) = -x. ∂f/∂x = -1."""
    reset_tape()
    x = AADVariable(5.0)
    f = -x

    assert abs(f.value - (-5.0)) < 1e-12

    f.backward()
    assert abs(x.adjoint - (-1.0)) < 1e-12

    print(f"  -5 = {f.value:.10f}, ∂/∂x = {x.adjoint:.10f}")


# ======================================================================
# Run all tests
# ======================================================================

if __name__ == "__main__":
    tests = [
        ("Toy example (x=2, y=3)", test_toy_example),
        ("Toy different values (x=1.5, y=4)", test_toy_different_values),
        ("exp(log(x)) identity", test_exp_log),
        ("sqrt(x)", test_sqrt),
        ("Division x/y", test_division),
        ("Subtraction x-y", test_subtraction),
        ("Power x^3", test_power),
        ("Complex expression", test_complex_expression),
        ("Scalar operations", test_scalar_operations),
        ("Reverse subtraction", test_rsub),
        ("Reverse division", test_rdiv),
        ("Negation", test_negation),
    ]

    print("=" * 60)
    print("TOY AAD ENGINE TESTS")
    print("=" * 60)

    passed = 0
    failed = 0
    for name, test_fn in tests:
        try:
            print(f"\n[TEST] {name}")
            test_fn()
            print(f"  ✓ PASSED")
            passed += 1
        except Exception as e:
            print(f"  ✗ FAILED: {e}")
            failed += 1

    print(f"\n{'=' * 60}")
    print(f"Results: {passed} passed, {failed} failed, {passed + failed} total")
    print(f"{'=' * 60}")
