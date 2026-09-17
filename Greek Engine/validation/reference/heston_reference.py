"""Floating-point references for validating the Heston RTL.

Two references, answering two different questions:

1. ``cos_price`` / ``cos_greeks`` -- the *algorithm the RTL implements*, in
   double precision: COS method, N=128 terms, cumulant truncation range
   [a, b] = c1 -+ 10 sqrt(c2), with [a, b] held fixed when differentiating
   (the convention of both the RTL and software/models/heston_cos.py).
   Greeks by 4th-order Richardson-extrapolated central differences, which
   are accurate to ~1e-10 relative here -- far below any fixed-point error
   we want to resolve. The difference RTL - this is *hardware error*.

2. ``integral_price`` / ``integral_greeks`` -- the Heston model itself,
   priced by adaptive quadrature of the Fourier integral (Albrecher et al.
   "little trap" characteristic function) and differentiated by
   Richardson central differences. The difference between this and (1) is
   *method error* (COS truncation + finite N), independent of hardware.

Parameters are always the 9-tuple order PARAMS.
"""
import cmath
import math

import numpy as np
from scipy.integrate import quad

PARAMS = ["S0", "K", "T", "r", "v0", "kappa", "theta", "xi", "rho"]
L_TRUNC = 10.0


def char_func(u, T, r, v0, kappa, theta, xi, rho, x):
    """phi(u) of ln(S_T/K) (numpy, u array). phi(0) = 1."""
    u = np.asarray(u, dtype=complex)
    iu = 1j * u
    b = kappa - rho * xi * iu
    d = np.sqrt(b * b + xi * xi * (iu + u * u))
    g = (b - d) / (b + d)
    e = np.exp(-d * T)
    C = r * iu * T + kappa * theta / xi**2 * ((b - d) * T - 2.0 * np.log((1 - g * e) / (1 - g)))
    D = (b - d) / xi**2 * (1 - e) / (1 - g * e)
    return np.exp(C + D * v0 + iu * x)


def truncation_range(S0, K, T, r, v0, kappa, theta, xi, rho):
    x = math.log(S0 / K)
    c1 = x + (r - 0.5 * theta) * T + (1.0 - math.exp(-kappa * T)) / (2.0 * kappa) * (theta - v0)
    c2 = max(v0 * T + 0.5 * theta * T, 1e-8)
    return c1 - L_TRUNC * math.sqrt(c2), c1 + L_TRUNC * math.sqrt(c2)


def cos_price(p, is_call=True, N=128, ab=None):
    S0, K, T, r, v0, kappa, theta, xi, rho = p
    a, b = ab if ab is not None else truncation_range(*p)
    x = math.log(S0 / K)
    k = np.arange(N)
    u = k * math.pi / (b - a)
    F = (char_func(u, T, r, v0, kappa, theta, xi, rho, x) * np.exp(-1j * u * a)).real
    with np.errstate(divide="ignore", invalid="ignore"):
        if is_call:   # payoff support [0, b]
            chi = (np.exp(b) * np.cos(k * math.pi) - np.cos(-u * a) + u * (np.exp(b) * np.sin(k * math.pi) - np.sin(-u * a))) / (1 + u * u)
            psi = np.where(k == 0, b, (b - a) / (k * math.pi) * (np.sin(k * math.pi) - np.sin(-u * a)))
            V = 2.0 / (b - a) * K * (chi - psi)
        else:         # payoff support [a, 0]
            chi = (np.cos(-u * a) - np.exp(a) + u * np.sin(-u * a)) / (1 + u * u)
            psi = np.where(k == 0, -a, (b - a) / (k * math.pi) * np.sin(-u * a))
            V = 2.0 / (b - a) * K * (psi - chi)
    w = np.ones(N)
    w[0] = 0.5
    return math.exp(-r * T) * float(np.sum(w * F * V))


def _richardson(f, p, i, h):
    def cd(hh):
        pp, pm = list(p), list(p)
        pp[i] += hh
        pm[i] -= hh
        return (f(pp) - f(pm)) / (2 * hh)
    return (4 * cd(h / 2) - cd(h)) / 3


def _step(p, i):
    return 1e-3 * max(abs(p[i]), 1e-2)


def cos_greeks(p, is_call=True, N=128):
    """dV/dp for all 9 parameters with [a, b] frozen at the base point."""
    ab = truncation_range(*p)
    f = lambda q: cos_price(q, is_call, N, ab)
    return [_richardson(f, p, i, _step(p, i)) for i in range(9)]


def integral_price(p, is_call=True):
    S0, K, T, r, v0, kappa, theta, xi, rho = p
    lk, fwd = math.log(K), S0 * math.exp(r * T)
    x0 = math.log(S0)

    def cf(u):  # char. function of ln S_T
        return char_func(np.array([u]), T, r, v0, kappa, theta, xi, rho, 0.0)[0] * cmath.exp(1j * u * x0)

    f1 = lambda u: (cmath.exp(-1j * u * lk) * cf(u - 1j) / (1j * u * fwd)).real
    f2 = lambda u: (cmath.exp(-1j * u * lk) * cf(u) / (1j * u)).real
    opts = dict(limit=2000, epsabs=1e-14, epsrel=1e-13)
    P1 = 0.5 + quad(f1, 1e-12, 500, **opts)[0] / math.pi
    P2 = 0.5 + quad(f2, 1e-12, 500, **opts)[0] / math.pi
    call = S0 * P1 - K * math.exp(-r * T) * P2
    return call if is_call else call - S0 + K * math.exp(-r * T)


def integral_greeks(p, is_call=True):
    f = lambda q: integral_price(q, is_call)
    return [_richardson(f, p, i, 10 * _step(p, i)) for i in range(9)]


if __name__ == "__main__":
    base = [100.0, 100.0, 1.0, 0.05, 0.04, 1.5, 0.04, 0.3, -0.9]
    print("COS price      %.12f" % cos_price(base))
    print("integral price %.12f" % integral_price(base))
    for n, g1, g2 in zip(PARAMS, cos_greeks(base), integral_greeks(base)):
        print("%-6s COS %+.10f  integral %+.10f" % (n, g1, g2))
