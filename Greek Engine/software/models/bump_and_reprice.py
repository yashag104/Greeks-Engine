"""
Bump-and-Reprice Greeks — Finite Difference Baseline.

Computes Greeks by shifting each input parameter by a small amount ε
and re-evaluating the pricing function.  This is the O(n) baseline
that AAD improves upon.

Central differences: ∂V/∂x ≈ (V(x+ε) - V(x-ε)) / (2ε)
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from models.black_scholes import bs_price_scalar
from models.heston_cos import heston_cos_price_scalar


# ======================================================================
# Black-Scholes bump-and-reprice
# ======================================================================

def bs_bump_and_reprice(S, K, T, r, sigma, option_type="call",
                         epsilon=1e-5):
    """
    Compute BS Greeks via central finite differences.

    Parameters
    ----------
    S, K, T, r, sigma : float — Model inputs
    option_type : str — "call" or "put"
    epsilon : float — Bump size for finite differences

    Returns
    -------
    dict with keys: 'price', 'delta', 'gamma', 'vega', 'theta', 'rho'
    """
    price = bs_price_scalar(S, K, T, r, sigma, option_type)

    # Delta: ∂V/∂S (central difference)
    eps_S = epsilon * S  # relative bump for spot
    V_up = bs_price_scalar(S + eps_S, K, T, r, sigma, option_type)
    V_dn = bs_price_scalar(S - eps_S, K, T, r, sigma, option_type)
    delta = (V_up - V_dn) / (2.0 * eps_S)

    # Gamma: ∂²V/∂S² (second-order central difference)
    gamma = (V_up - 2.0 * price + V_dn) / (eps_S ** 2)

    # Vega: ∂V/∂σ
    eps_sig = epsilon
    V_up = bs_price_scalar(S, K, T, r, sigma + eps_sig, option_type)
    V_dn = bs_price_scalar(S, K, T, r, sigma - eps_sig, option_type)
    vega = (V_up - V_dn) / (2.0 * eps_sig)

    # Theta: ∂V/∂T (note: negative of ∂V/∂τ where τ = T - t)
    eps_T = epsilon
    if T - eps_T > 0:
        V_up = bs_price_scalar(S, K, T + eps_T, r, sigma, option_type)
        V_dn = bs_price_scalar(S, K, T - eps_T, r, sigma, option_type)
        theta = (V_up - V_dn) / (2.0 * eps_T)
    else:
        V_up = bs_price_scalar(S, K, T + eps_T, r, sigma, option_type)
        theta = (V_up - price) / eps_T

    # Rho: ∂V/∂r
    eps_r = epsilon
    V_up = bs_price_scalar(S, K, T, r + eps_r, sigma, option_type)
    V_dn = bs_price_scalar(S, K, T, r - eps_r, sigma, option_type)
    rho_greek = (V_up - V_dn) / (2.0 * eps_r)

    return {
        "price": price,
        "delta": delta,
        "gamma": gamma,
        "vega": vega,
        "theta": theta,
        "rho": rho_greek,
    }


# ======================================================================
# Heston bump-and-reprice
# ======================================================================

def heston_bump_and_reprice(S0, K, T, r, v0, kappa, theta, xi, rho,
                             option_type="call", N_terms=256,
                             epsilon=1e-5):
    """
    Compute Heston Greeks via central finite differences.

    Returns sensitivities with respect to all 7 Heston model parameters:
    S0, v0, r, kappa, theta, xi, rho.

    Parameters
    ----------
    S0, K, T, r, v0, kappa, theta, xi, rho : float
    option_type : str
    N_terms : int — COS expansion terms
    epsilon : float — Bump size

    Returns
    -------
    dict with keys: 'price', 'delta', 'vega_v0', 'rho_r', 'kappa_sens',
                    'theta_sens', 'xi_sens', 'rho_corr_sens'
    """
    def _price(**kwargs):
        defaults = dict(S0=S0, K=K, T=T, r=r, v0=v0,
                        kappa=kappa, theta=theta, xi=xi, rho=rho,
                        option_type=option_type, N_terms=N_terms)
        defaults.update(kwargs)
        return heston_cos_price_scalar(**defaults)

    price = _price()

    # Delta: ∂V/∂S0
    eps_S = epsilon * S0
    delta = (_price(S0=S0 + eps_S) - _price(S0=S0 - eps_S)) / (2.0 * eps_S)

    # Vega (w.r.t. v0): ∂V/∂v0
    eps_v = epsilon * max(abs(v0), 0.01)
    vega_v0 = (_price(v0=v0 + eps_v) - _price(v0=v0 - eps_v)) / (2.0 * eps_v)

    # Rho (w.r.t. r): ∂V/∂r
    eps_r = epsilon
    rho_r = (_price(r=r + eps_r) - _price(r=r - eps_r)) / (2.0 * eps_r)

    # Kappa sensitivity: ∂V/∂κ
    eps_k = epsilon * max(abs(kappa), 0.1)
    kappa_sens = (_price(kappa=kappa + eps_k) - _price(kappa=kappa - eps_k)) / (2.0 * eps_k)

    # Theta sensitivity: ∂V/∂θ (long-run variance)
    eps_th = epsilon * max(abs(theta), 0.01)
    theta_sens = (_price(theta=theta + eps_th) - _price(theta=theta - eps_th)) / (2.0 * eps_th)

    # Xi sensitivity: ∂V/∂ξ
    eps_xi = epsilon * max(abs(xi), 0.01)
    xi_sens = (_price(xi=xi + eps_xi) - _price(xi=xi - eps_xi)) / (2.0 * eps_xi)

    # Rho_corr sensitivity: ∂V/∂ρ
    eps_rho = epsilon
    # Clamp rho to [-1, 1]
    rho_up = min(rho + eps_rho, 0.999)
    rho_dn = max(rho - eps_rho, -0.999)
    rho_corr_sens = (_price(rho=rho_up) - _price(rho=rho_dn)) / (rho_up - rho_dn)

    return {
        "price": price,
        "delta": delta,
        "vega_v0": vega_v0,
        "rho_r": rho_r,
        "kappa_sens": kappa_sens,
        "theta_sens": theta_sens,
        "xi_sens": xi_sens,
        "rho_corr_sens": rho_corr_sens,
    }
