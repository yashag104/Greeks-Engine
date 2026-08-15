"""
Black-Scholes Option Pricing — AAD and Closed-Form Implementations.

Provides:
1. bs_price_aad()          — Price via AAD (records on tape, enables adjoint Greeks)
2. bs_price_scalar()       — Plain float pricing (no tape, for bump-and-reprice)
3. bs_greeks_closed_form() — Analytical Greeks from the standard BS formulas

All functions handle European calls and puts.
"""

import math
import sys
import os

# Add parent directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from aad_engine.tape import tape, reset_tape
from aad_engine.aad_variable import AADVariable
from aad_engine.operations import (
    aad_exp, aad_log, aad_sqrt, aad_norm_cdf, aad_norm_pdf,
)


# ======================================================================
# AAD-enabled Black-Scholes pricer
# ======================================================================

def bs_price_aad(S, K, T, r, sigma, option_type="call"):
    """
    Black-Scholes European option price using AAD variables.

    All inputs can be AADVariable objects (for computing Greeks via adjoint)
    or plain floats (in which case the function still works but no gradients
    are available).

    Parameters
    ----------
    S : AADVariable or float — Spot price
    K : AADVariable or float — Strike price
    T : AADVariable or float — Time to maturity (years)
    r : AADVariable or float — Risk-free interest rate
    sigma : AADVariable or float — Volatility (annualized)
    option_type : str — "call" or "put"

    Returns
    -------
    AADVariable — The option price (on the tape, ready for backward())
    """
    # Ensure all inputs are AADVariables
    if not isinstance(S, AADVariable):
        S = AADVariable(float(S))
    if not isinstance(K, AADVariable):
        K = AADVariable(float(K))
    if not isinstance(T, AADVariable):
        T = AADVariable(float(T))
    if not isinstance(r, AADVariable):
        r = AADVariable(float(r))
    if not isinstance(sigma, AADVariable):
        sigma = AADVariable(float(sigma))

    # Compute d1, d2
    sqrt_T = aad_sqrt(T)
    sigma_sqrt_T = sigma * sqrt_T

    log_S_K = aad_log(S / K)
    d1 = (log_S_K + (r + sigma * sigma * 0.5) * T) / sigma_sqrt_T
    d2 = d1 - sigma_sqrt_T

    # Discount factor
    discount = aad_exp(-r * T)

    if option_type == "call":
        # V_call = S * N(d1) - K * exp(-rT) * N(d2)
        price = S * aad_norm_cdf(d1) - K * discount * aad_norm_cdf(d2)
    elif option_type == "put":
        # V_put = K * exp(-rT) * N(-d2) - S * N(-d1)
        price = K * discount * aad_norm_cdf(-d2) - S * aad_norm_cdf(-d1)
    else:
        raise ValueError(f"option_type must be 'call' or 'put', got '{option_type}'")

    return price


# ======================================================================
# Plain scalar Black-Scholes pricer (no AAD, for bump-and-reprice)
# ======================================================================

def bs_price_scalar(S, K, T, r, sigma, option_type="call"):
    """
    Black-Scholes European option price — plain float computation.

    Used as the baseline for bump-and-reprice Greeks computation.
    """
    S, K, T, r, sigma = float(S), float(K), float(T), float(r), float(sigma)

    sqrt_T = math.sqrt(T)
    sigma_sqrt_T = sigma * sqrt_T

    d1 = (math.log(S / K) + (r + 0.5 * sigma ** 2) * T) / sigma_sqrt_T
    d2 = d1 - sigma_sqrt_T

    N = _norm_cdf
    discount = math.exp(-r * T)

    if option_type == "call":
        return S * N(d1) - K * discount * N(d2)
    elif option_type == "put":
        return K * discount * N(-d2) - S * N(-d1)
    else:
        raise ValueError(f"option_type must be 'call' or 'put', got '{option_type}'")


# ======================================================================
# Closed-form Greeks (analytical derivatives of the BS formula)
# ======================================================================

def bs_greeks_closed_form(S, K, T, r, sigma, option_type="call"):
    """
    Compute all 5 BS Greeks analytically.

    Parameters
    ----------
    S, K, T, r, sigma : float
    option_type : str — "call" or "put"

    Returns
    -------
    dict with keys: 'price', 'delta', 'gamma', 'vega', 'theta', 'rho'
    """
    S, K, T, r, sigma = float(S), float(K), float(T), float(r), float(sigma)

    sqrt_T = math.sqrt(T)
    sigma_sqrt_T = sigma * sqrt_T

    d1 = (math.log(S / K) + (r + 0.5 * sigma ** 2) * T) / sigma_sqrt_T
    d2 = d1 - sigma_sqrt_T

    N = _norm_cdf
    n = _norm_pdf
    discount = math.exp(-r * T)

    n_d1 = n(d1)
    N_d1 = N(d1)
    N_d2 = N(d2)

    if option_type == "call":
        price = S * N_d1 - K * discount * N_d2
        delta = N_d1
        # Theta as ∂V/∂T (time-to-maturity), matching AAD convention.
        # Traditional ∂V/∂t = -(S*n(d1)*σ)/(2√T) - r*K*e^{-rT}*N(d2)
        # Since T = maturity - t, ∂V/∂T = -∂V/∂t
        theta = ((S * n_d1 * sigma) / (2.0 * sqrt_T)
                 + r * K * discount * N_d2)
        rho_greek = K * T * discount * N_d2
    elif option_type == "put":
        N_neg_d1 = N(-d1)
        N_neg_d2 = N(-d2)
        price = K * discount * N_neg_d2 - S * N_neg_d1
        delta = N_d1 - 1.0
        # Theta as ∂V/∂T (time-to-maturity): negate traditional formula
        theta = ((S * n_d1 * sigma) / (2.0 * sqrt_T)
                 - r * K * discount * N_neg_d2)
        rho_greek = -K * T * discount * N_neg_d2
    else:
        raise ValueError(f"option_type must be 'call' or 'put', got '{option_type}'")

    # Gamma and Vega are the same for calls and puts
    gamma = n_d1 / (S * sigma_sqrt_T)
    vega = S * n_d1 * sqrt_T

    return {
        "price": price,
        "delta": delta,
        "gamma": gamma,
        "vega": vega,
        "theta": theta,
        "rho": rho_greek,
    }


# ======================================================================
# Helper: plain-float normal distribution functions
# ======================================================================

_SQRT_2PI = math.sqrt(2.0 * math.pi)
_SQRT_2 = math.sqrt(2.0)


def _norm_pdf(x):
    return math.exp(-0.5 * x * x) / _SQRT_2PI


def _norm_cdf(x):
    return 0.5 * (1.0 + math.erf(x / _SQRT_2))
