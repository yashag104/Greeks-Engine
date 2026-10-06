"""Multiprecision check of the error measurements and of the first-order bound.

    .venv/bin/python validation/run_mp_check.py [n_cases]
    -> validation/results/mp_check.csv

Every error ratio in this project is |fixed - double| / bound, where "double"
is the same algorithm evaluated in double precision and the bound is first
order (products of rounding errors are dropped). This script re-evaluates the
same unrolled graph (same constants, same Newton/CORDIC steps) in 50-digit
arithmetic (mpmath) on a subset of inputs and reports, per output:

  double_err / bound   how far the double-precision reference is from the
                       50-digit value: if this is tiny, measuring against
                       double changes no ratio;
  fixed_err / bound    the hardware's error against the 50-digit value: the
                       quantity the bound is meant to cover, now measured
                       without any double-precision rounding in it.

Inputs are the 2 fixed board cases plus random draws from the verified domain
(seed 20261007, held out from range fitting and all earlier sweeps).
"""
import csv
import math
import os
import random
import sys
import time

import mpmath

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "..", "hardware", "gen")
sys.path.insert(0, GEN)

import heston as H                     # noqa: E402
import ir                              # noqa: E402
import ranges                          # noqa: E402

mpmath.mp.dps = 50
FL = 28                                # the Zynq-7020 engine: 56-bit words, 28 fraction bits


class _MPMath:
    """stands in for the math module inside ir.eval_float"""
    floor = staticmethod(mpmath.floor)
    cos = staticmethod(mpmath.cos)
    sin = staticmethod(mpmath.sin)
    sqrt = staticmethod(mpmath.sqrt)
    hypot = staticmethod(mpmath.hypot)
    atan2 = staticmethod(mpmath.atan2)

    @staticmethod
    def log2(x):
        return mpmath.log(x, 2)


def eval_mp(g, inputs):
    real = ir.math
    ir.math = _MPMath
    try:
        return g.eval_float({k: (mpmath.mpf(v) if isinstance(v, float) else v) for k, v in inputs.items()})
    finally:
        ir.math = real


def cases(n):
    out = [([100, 100, 1, .05, .04, 1.5, .04, .3, -.9], True),
           ([100, 100, 1, 0, .0175, 1.5768, .0398, .5751, -.5711], True)]
    rng = random.Random(20261007)
    while len(out) < n:
        out.append(([rng.uniform(*ranges.DOMAIN[p]) for p in H.PARAMS], rng.random() < 0.5))
    return out


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    g, out = H.unrolled(FL + 28, FL)
    rows = []
    t0 = time.time()
    for i, (p, call) in enumerate(cases(n)):
        q = H.quantize_inputs(p, call, FL)
        g.overflows = []
        fx = g.eval_fixed(q)
        pq = {nm: q[nm] / 2 ** FL for nm in H.PARAMS}
        fv = g.eval_float(dict(pq, is_call=q["is_call"]))
        bounds = g.error_bound(fv, out)
        mv = eval_mp(g, dict(pq, is_call=q["is_call"]))
        for o in H.OUTPUTS:
            b = bounds[o][0]
            m = mv[out[o]]
            fxv = mpmath.mpf(fx[out[o]]) / 2 ** FL
            rows.append(dict(case=i, is_call=int(call), output=o, value=float(m), bound=b,
                             double_err_over_bound=float(abs(fv[out[o]] - m) / b),
                             fixed_err_over_bound=float(abs(fxv - m) / b),
                             fixed_vs_double_over_bound=abs(fx[out[o]] / 2 ** FL - fv[out[o]]) / b))
        print("case %d/%d  %.0f s" % (i + 1, n, time.time() - t0), flush=True)
    path = os.path.join(HERE, "results", "mp_check.csv")
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print("%-12s %18s %18s %18s" % ("output", "max double/bound", "max fixed/bound", "fixed vs double"))
    for o in H.OUTPUTS:
        rs = [r for r in rows if r["output"] == o]
        print("%-12s %18.2e %18.3f %18.3f" % (o, max(r["double_err_over_bound"] for r in rs),
                                            max(r["fixed_err_over_bound"] for r in rs),
                                            max(r["fixed_vs_double_over_bound"] for r in rs)))
    print("wrote", path)


if __name__ == "__main__":
    main()
