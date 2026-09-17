"""Shift-amount range analysis for the generated datapath.

Every variable shift in the datapath (`scale` nodes, and multiplies with a
data-dependent exponent e) has shift amount sh = fixed part - e. The RTL
barrel shifter only needs to cover the values sh actually takes, which is a
few bits' worth instead of a full 16-bit amount over a 2*WL-bit word -- the
dominant LUT cost otherwise. Ranges are measured with the bit-accurate
emulator over random parameter sets drawn from DOMAIN, widened by MARGIN on
each side; the generated RTL raises a sticky `range_err` output if any shift
ever falls outside its range, so an out-of-domain input is detected rather
than silently mis-computed.
"""
import json
import os
import random

import heston as H

DOMAIN = dict(S0=(100.0, 100.0), K=(60.0, 150.0), T=(0.1, 3.0), r=(0.0, 0.1), v0=(0.005, 0.25),
              kappa=(0.2, 6.0), theta=(0.005, 0.25), xi=(0.1, 1.0), rho=(-0.95, 0.6))
MARGIN = 3
N_SAMPLES = 150


def fixed_shift(g, n):
    """constant part of the shift amount (sh = const - e)"""
    if n.op == "scale":
        return g.f(n.args[0]) - n.frac
    return g.f(n.args[0]) + g.f(n.args[1]) - n.frac


def variable_nodes(g):
    return [n for n in g.nodes if n.op == "scale" or (n.op == "mul" and len(n.args) == 3)]


def measure(dp, n_samples=N_SAMPLES, seed=11):
    g = dp.g
    var = variable_nodes(g)
    lo = {n.id: 10 ** 9 for n in var}
    hi = {n.id: -10 ** 9 for n in var}
    rng = random.Random(seed)
    cases = [([100, 100, 1, .05, .04, 1.5, .04, .3, -.9], True)]
    for _ in range(n_samples):
        cases.append(([rng.uniform(*DOMAIN[p]) for p in H.PARAMS], rng.random() < 0.5))

    def note(vals, part):
        for n in var:
            if n.part == part:
                sh = fixed_shift(g, n) - vals[n.args[-1] if n.op == "mul" else n.args[1]]
                lo[n.id] = min(lo[n.id], sh)
                hi[n.id] = max(hi[n.id], sh)

    for p, call in cases:
        q = H.quantize_inputs(p, call, g.fl)
        vals = g.eval_fixed(q, part="setup")
        note(vals, "setup")
        acc = {a: 0 for a in dp.acc_names}
        for k in range(H.N_TERMS):
            tv = list(vals)
            tv[dp.k] = k
            g.eval_fixed(dict(q, k=k), values=tv, part="term")
            note(tv, "term")
            for a in dp.acc_names:
                acc[a] += tv[dp.term[a]]
        fin = list(vals)
        g.eval_fixed(dict(q, **{"acc_" + a: acc[a] for a in dp.acc_names}), values=fin, part="finish")
        note(fin, "finish")
    return {i: (lo[i] - MARGIN, hi[i] + MARGIN) for i in lo}


def get(dp, cache_dir):
    key = "ranges_wl%d_fl%d_%s.json" % (dp.g.wl, dp.g.fl, "aad" if dp.greeks else "price")
    path = os.path.join(cache_dir, key)
    if os.path.exists(path):
        data = json.load(open(path))
        if data.get("nodes") == len(dp.g.nodes):
            return {int(k): tuple(v) for k, v in data["ranges"].items()}
    r = measure(dp)
    os.makedirs(cache_dir, exist_ok=True)
    json.dump({"nodes": len(dp.g.nodes), "domain": DOMAIN, "margin": MARGIN, "samples": N_SAMPLES,
               "ranges": {str(k): v for k, v in r.items()}}, open(path, "w"), indent=1)
    return r


if __name__ == "__main__":
    import collections
    dp = H.Datapath(56, 28)
    r = measure(dp, n_samples=40)
    widths = collections.Counter(max(1, (hi - lo).bit_length()) for lo, hi in r.values())
    print("variable shifts:", len(r), "amount bits needed (count by bits):", dict(sorted(widths.items())))
    print("widest:", sorted(((hi - lo), dp.g.nodes[i].op, dp.g.nodes[i].part) for i, (lo, hi) in r.items())[-5:])
