"""Generate every hardware dataset used by validation/make_figures.py.

All hardware numbers come from cycle-accurate RTL simulation (Icarus
Verilog) of hardware/verilog, driven through hardware/sim/run_heston.py.

    python run_hw_sweeps.py accuracy   # RTL AAD @Q32.32 over a parameter grid
    python run_hw_sweeps.py fl         # RTL AAD over fractional bits 16..40
    python run_hw_sweeps.py bump       # RTL bump-and-reprice over bump sizes
    python run_hw_sweeps.py all

Outputs (validation/results/*.csv), one row per (case, output):
    accuracy.csv  case, is_call, params..., output, rtl, ref_cos, ref_model,
                  bound, sigma, cycles
    fl_sweep.csv  case, fl, output, rtl, ref_cos, bound, sigma, cycles
    bump.csv      rel_h, output, rtl_bump, ref_cos, rtl_aad, cycles_bump,
                  cycles_aad, float_bump
"""
import csv
import math
import os
import sys
import time
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hardware", "sim"))
sys.path.insert(0, os.path.join(HERE, "reference"))
sys.path.insert(0, os.path.join(HERE, "precision"))

import heston_reference as ref            # noqa: E402
import heston_rtl_model as model          # noqa: E402
from run_heston import PARAMS, SENS_PARAM, run_cases  # noqa: E402

RESULTS = os.path.join(HERE, "results")
OUTPUTS = ["price", "delta", "strike_sens", "theta_greek", "rho_greek", "vega",
           "kappa_sens", "theta_sens", "xi_sens", "rho_corr"]
# output -> index into the 9-parameter gradient
GRAD_INDEX = {o: PARAMS.index(p) for o, p in SENS_PARAM.items()}

# Fang & Oosterlee (2008) Heston test set, Section 5.2, plus the project's
# original base point; the grid varies moneyness, maturity, vol-of-vol,
# correlation and payoff around them.
FO = dict(S0=100.0, K=100.0, T=1.0, r=0.0, v0=0.0175, kappa=1.5768,
          theta=0.0398, xi=0.5751, rho=-0.5711)
BASE = dict(S0=100.0, K=100.0, T=1.0, r=0.05, v0=0.04, kappa=1.5,
            theta=0.04, xi=0.3, rho=-0.9)


def accuracy_cases():
    cases = [dict(BASE, is_call=1, name="base"), dict(FO, is_call=1, name="FO2008")]
    for K in (80.0, 90.0, 110.0, 120.0):
        cases.append(dict(FO, K=K, is_call=1, name="FO K=%g" % K))
    for T in (0.1, 0.25, 0.5, 2.0):
        cases.append(dict(FO, T=T, is_call=1, name="FO T=%g" % T))
    for xi in (0.2, 1.0):
        cases.append(dict(FO, xi=xi, is_call=1, name="FO xi=%g" % xi))
    for rho in (-0.9, 0.0, 0.5):
        cases.append(dict(FO, rho=rho, is_call=1, name="FO rho=%g" % rho))
    cases.append(dict(BASE, r=0.02, v0=0.09, theta=0.06, kappa=3.0, is_call=1, name="high vol"))
    cases.append(dict(BASE, T=0.1, xi=0.8, is_call=1, name="short T, high xi"))
    for K in (90.0, 100.0, 110.0):
        cases.append(dict(FO, K=K, is_call=0, name="FO put K=%g" % K))
    cases.append(dict(BASE, is_call=0, name="base put"))
    return cases


def _pvec(c):
    return [c[p] for p in PARAMS]


def _refs(c, with_model=True):
    p, call = _pvec(c), bool(c["is_call"])
    cos_g = ref.cos_greeks(p, call)
    cos_v = {"price": ref.cos_price(p, call)}
    cos_v.update({o: cos_g[i] for o, i in GRAD_INDEX.items()})
    mod_v = {}
    if with_model:
        mg = ref.integral_greeks(p, call)
        mod_v = {"price": ref.integral_price(p, call)}
        mod_v.update({o: mg[i] for o, i in GRAD_INDEX.items()})
    return cos_v, mod_v


def _refs_job(args):
    c, with_model = args
    return _refs(c, with_model)


def write_csv(name, rows):
    os.makedirs(RESULTS, exist_ok=True)
    path = os.path.join(RESULTS, name)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print("wrote %s (%d rows)" % (path, len(rows)))


def sweep_accuracy():
    cases = accuracy_cases()
    t0 = time.time()
    rtl = run_cases(cases, "aad", 32)
    print("RTL accuracy sweep: %d cases in %.0fs" % (len(cases), time.time() - t0))
    with Pool(os.cpu_count()) as pool:
        refs = pool.map(_refs_job, [(r, True) for r in rtl])   # refs at the *simulated* (quantized) inputs
    rows = []
    for c, r, (cos_v, mod_v) in zip(cases, rtl, refs):
        bounds = model.error_bounds(_pvec(r), bool(c["is_call"]), 32)
        for o in OUTPUTS:
            rows.append(dict(case=c["name"], is_call=c["is_call"], **{p: r[p] for p in PARAMS},
                             output=o, rtl=r[o], ref_cos=cos_v[o], ref_model=mod_v[o],
                             model_value=bounds[o][0], bound=bounds[o][1], sigma=bounds[o][2],
                             cycles=r["cycles"]))
    write_csv("accuracy.csv", rows)


def sweep_fl(fls=(16, 20, 24, 28, 32, 36, 40)):
    cases = [dict(BASE, is_call=1, name="base"), dict(FO, is_call=1, name="FO2008"),
             dict(FO, K=110.0, T=0.25, is_call=1, name="FO K=110 T=0.25")]
    rows = []
    for fl in fls:
        t0 = time.time()
        rtl = run_cases(cases, "aad", fl)
        print("FL=%d: %.0fs" % (fl, time.time() - t0))
        for c, r in zip(cases, rtl):
            cos_v, _ = _refs(r, with_model=False)
            bounds = model.error_bounds(_pvec(r), True, fl)
            for o in OUTPUTS:
                rows.append(dict(case=c["name"], fl=fl, output=o, rtl=r[o], ref_cos=cos_v[o],
                                 bound=bounds[o][1], sigma=bounds[o][2], cycles=r["cycles"]))
        write_csv("fl_sweep.csv", rows)   # checkpoint after every FL


def sweep_bump(rel_hs=(1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1)):
    base = dict(BASE, is_call=1)
    cases = []
    for rh in rel_hs:
        c = dict(base)
        for p in PARAMS:
            c["h_" + p] = rh * max(abs(base[p]), 1e-2)
        cases.append(c)
    t0 = time.time()
    aad = run_cases([base], "aad", 32, workers=1)[0]
    bump = run_cases(cases, "bump", 32)
    print("bump sweep: %d bump sizes in %.0fs" % (len(cases), time.time() - t0))
    cos_v, _ = _refs(aad, with_model=False)
    p0 = _pvec(aad)
    ab = ref.truncation_range(*p0)
    rows = []
    for rh, b in zip(rel_hs, bump):
        for o in OUTPUTS:
            if o == "price":
                fb = ref.cos_price(p0, True)
            else:  # double-precision central difference, same h, same frozen [a,b]
                i = GRAD_INDEX[o]
                h = b["h_" + PARAMS[i]]
                pp, pm = list(p0), list(p0)
                pp[i] += h
                pm[i] -= h
                fb = (ref.cos_price(pp, True, 128, ab) - ref.cos_price(pm, True, 128, ab)) / (2 * h)
            rows.append(dict(rel_h=rh, output=o, rtl_bump=b[o], ref_cos=cos_v[o], rtl_aad=aad[o],
                             cycles_bump=b["cycles"], cycles_aad=aad["cycles"], float_bump=fb))
    write_csv("bump.csv", rows)


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("accuracy", "all"):
        sweep_accuracy()
    if what in ("fl", "all"):
        sweep_fl()
    if what in ("bump", "all"):
        sweep_bump()
