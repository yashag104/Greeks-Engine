"""Large validation sweep of the Zynq-7020 engine (56-bit, FL 28), with hard regimes.

    .venv/bin/python validation/run_domain_sweep.py [n_uniform] [n_per_regime] [n_outside]
    -> validation/results/domain_sweep.csv, domain_sweep_summary.csv
    .venv/bin/python validation/run_domain_sweep.py --reflag
    (recompute range_err for the flagged rows of an existing sweep)
    .venv/bin/python validation/run_domain_sweep.py --heldout [n_uniform] [n_per_regime] [n_outside]
    -> results/domain_sweep_heldout.csv, domain_sweep_heldout_summary.csv: fresh draws
       (seed 20261006) that played no part in fitting or refitting the shift ranges

Every case runs the bit-accurate model of the whole evaluation (the unrolled
graph: fixed-point values identical to the hardware's), the same algorithm in
double precision, the first-order error bound of every output, and the
double-precision COS reference (heston_reference, parity=True). It also checks
whether any variable shift leaves the range the RTL was built for, which is
exactly when the hardware raises range_err.

Cases:
  uniform      uniform over the verified domain (ranges.DOMAIN)
  feller       2 kappa theta < xi^2 (the variance can reach zero)
  rho_edge     rho in [-0.95, -0.85] or [0.5, 0.6]
  deep_strike  K in [60, 70] or [135, 150]
  short_T      T in [0.1, 0.15]
  long_T       T in [2.5, 3]
  high_xi      xi in [0.8, 1]
  low_var      v0 and theta in [0.005, 0.01]
  outside      one input outside the domain (T < 0.1, K beyond [60, 150],
               v0 or theta up to 0.5, kappa up to 10, xi up to 1.5)

The property tested: inside the domain the hardware is never flagged and the
error never exceeds its bound; outside, every result is either flagged by
range_err or still within its bound.
"""
import csv
import multiprocessing as mp
import os
import random
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "..", "hardware", "gen")
sys.path.insert(0, GEN)
sys.path.insert(0, os.path.join(HERE, "reference"))
import heston as H  # noqa: E402
import check_accuracy as C  # noqa: E402
import ranges as RG  # noqa: E402
from board_vectors import BUILD  # noqa: E402

WL, FL = 56, 28
DOM = RG.DOMAIN
REGIMES = ["uniform", "feller", "rho_edge", "deep_strike", "short_T", "long_T", "high_xi", "low_var", "outside"]


def draw(rng, regime):
    p = {n: rng.uniform(*DOM[n]) for n in H.PARAMS}
    if regime == "feller":
        while 2 * p["kappa"] * p["theta"] >= p["xi"] ** 2:
            p = {n: rng.uniform(*DOM[n]) for n in H.PARAMS}
    elif regime == "rho_edge":
        p["rho"] = rng.choice([rng.uniform(-0.95, -0.85), rng.uniform(0.5, 0.6)])
    elif regime == "deep_strike":
        p["K"] = rng.choice([rng.uniform(60, 70), rng.uniform(135, 150)])
    elif regime == "short_T":
        p["T"] = rng.uniform(0.1, 0.15)
    elif regime == "long_T":
        p["T"] = rng.uniform(2.5, 3.0)
    elif regime == "high_xi":
        p["xi"] = rng.uniform(0.8, 1.0)
    elif regime == "low_var":
        p["v0"], p["theta"] = rng.uniform(0.005, 0.01), rng.uniform(0.005, 0.01)
    elif regime == "outside":
        which = rng.choice(["T", "K_lo", "K_hi", "v0", "theta", "kappa", "xi"])
        if which == "T":
            p["T"] = rng.uniform(0.02, 0.1)
        elif which == "K_lo":
            p["K"] = rng.uniform(40, 60)
        elif which == "K_hi":
            p["K"] = rng.uniform(150, 200)
        elif which in ("v0", "theta"):
            p[which] = rng.uniform(0.25, 0.5)
        elif which == "kappa":
            p["kappa"] = rng.uniform(6, 10)
        else:
            p["xi"] = rng.uniform(1.0, 1.5)
        p["_which"] = which
    return p


_state = {}


def rtl_checks(dp, rmap, cfg):
    """the shift checks the generated RTL performs (rtlgen.emit_scale and the
    multiplier units): a scale node is flagged below its fitted range, or above
    it only if that range ends below the word width (beyond it the shifter
    clamps and the rounded result is exactly 0); a multiplier unit checks the
    union of the ranges of every operation bound to it, likewise.
    Returns {node id: (lo, hi or None)}."""
    import sched as S
    g = dp.g
    sch = S.schedule(dp, cfg)
    width = {"W": g.wl, "D": 2 * g.wl}
    checks, units = {}, {}
    for n in RG.variable_nodes(g):
        if n.op == "scale":
            lo, hi = rmap[n.id]
            cap = width.get(g.nodes[n.args[0]].width, g.wl) + 1
            checks[n.id] = (lo, hi if hi < cap else None)
        elif n.id in sch.unit:                   # (host-setup designs: setup/finish not on the FPGA)
            units.setdefault(sch.unit[n.id], []).append(n)
    for u, ops in units.items():
        # every non-raw multiply on the unit contributes; fixed-shift ones a point
        allops = [m for m in g.nodes if m.op == "mul" and sch.unit.get(m.id) == u and not m.attrs.get("raw")]
        rs = [rmap[m.id] if len(m.args) == 3 else (RG.fixed_shift(g, m),) * 2 for m in allops]
        ulo, uhi = min(r[0] for r in rs), max(r[1] for r in rs)
        for n in ops:
            checks[n.id] = (ulo, uhi if uhi < 2 * g.wl + 1 else None)
    return checks


def flagged_by_range(dp, checks, pv, call):
    """True if the fully on-chip RTL would raise range_err for these inputs"""
    g = dp.g
    var = [n for n in RG.variable_nodes(g)]
    q = H.quantize_inputs(pv, call, g.fl)

    def out_of_range(vals, part):
        for n in var:
            if n.part == part:
                sh = RG.fixed_shift(g, n) - vals[n.args[-1] if n.op == "mul" else n.args[1]]
                lo, hi = checks[n.id]
                if sh < lo or (hi is not None and sh > hi):
                    return True
        return False

    vals = g.eval_fixed(q, part="setup", check_overflow=False)
    if out_of_range(vals, "setup"):
        return True
    acc = {a: 0 for a in dp.acc_names}
    for k in range(H.N_TERMS):
        tv = list(vals)
        tv[dp.k] = k
        g.eval_fixed(dict(q, k=k), values=tv, part="term", check_overflow=False)
        if out_of_range(tv, "term"):
            return True
        for a in dp.acc_names:
            acc[a] += tv[dp.term[a]]
    fin = list(vals)
    g.eval_fixed(dict(q, **{"acc_" + a: acc[a] for a in dp.acc_names}), values=fin, part="finish",
                 check_overflow=False)
    return out_of_range(fin, "finish")


def _init():
    _state["g_out"] = H.unrolled(WL, FL)
    _state["dp"] = H.Datapath(WL, FL)
    import sched as S
    cfg = S.Config(wl=WL, fl=FL, mults=8, crot=3, cvec=2, cordic_pipelined=False)   # heston_aad_z7
    _state["checks"] = rtl_checks(_state["dp"], RG.get(_state["dp"], BUILD), cfg)


def run_case(args):
    i, regime, p, call = args
    pv = [p[n] for n in H.PARAMS]
    try:
        flagged = flagged_by_range(_state["dp"], _state["checks"], pv, call)
        rows, novf = C.run(pv, call, FL, _state["g_out"])
    except Exception as e:                       # e.g. a math domain error outside the domain
        return dict(case=i, regime=regime, which=p.get("_which", ""), is_call=int(call), flagged=-1,
                    overflows=-1, error=repr(e)[:80], **{n: p[n] for n in H.PARAMS})
    out = dict(case=i, regime=regime, which=p.get("_which", ""), is_call=int(call), flagged=int(flagged),
               overflows=novf, error="", **{n: p[n] for n in H.PARAMS})
    for o, fx, flv, rv, b, sg in rows:
        out["err_" + o] = fx - rv                # against the COS reference
        out["ref_" + o] = rv                     # for relative errors (significant figures)
        out["ratio_" + o] = abs(fx - flv) / b    # against the bound (same algorithm in double)
    return out


def _reflag(r):
    pv = [float(r[n]) for n in H.PARAMS]
    return r["case"], int(flagged_by_range(_state["dp"], _state["checks"], pv, r["is_call"] == "1"))


def reflag():
    """recompute range_err for the rows of an existing domain_sweep.csv that were
    flagged (a row the check passed stays passed: the RTL is no stricter)"""
    path = os.path.join(HERE, "results", "domain_sweep.csv")
    res = list(csv.DictReader(open(path)))
    todo = [r for r in res if r["flagged"] == "1"]
    with mp.Pool(max(1, (os.cpu_count() or 2) - 2), initializer=_init) as pool:
        new = dict(pool.map(_reflag, todo, chunksize=4))
    for r in res:
        if r["case"] in new:
            r["flagged"] = str(new[r["case"]])
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(res[0]))
        w.writeheader()
        w.writerows(res)
    for r in res:
        for k in r:
            if k.startswith(("err_", "ratio_")) and r[k] != "":
                r[k] = float(r[k])
        r["flagged"], r["overflows"] = int(r["flagged"]), int(r["overflows"])
    print("re-flagged %d rows: %d still flagged" % (len(todo), sum(new.values())))
    summarise(res)


def main():
    if sys.argv[1:] == ["--reflag"]:
        return reflag()
    # The ranges were refitted after the 20261001 sweep flagged inputs, so that sweep
    # no longer tests them independently; --heldout draws a fresh set.
    heldout = "--heldout" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--heldout"]
    n_uniform = int(args[0]) if len(args) > 0 else 6000
    n_regime = int(args[1]) if len(args) > 1 else 500
    n_out = int(args[2]) if len(args) > 2 else 1000
    tag = "domain_sweep_heldout" if heldout else "domain_sweep"
    rng = random.Random(20261006 if heldout else 20261001)
    jobs = []
    for regime in REGIMES:
        n = n_uniform if regime == "uniform" else n_out if regime == "outside" else n_regime
        for _ in range(n):
            jobs.append((len(jobs), regime, draw(rng, regime), rng.random() < 0.5))
    procs = max(1, (os.cpu_count() or 2) - 2)
    t0 = time.time()
    res = []
    with mp.Pool(procs, initializer=_init) as pool:
        for r in pool.imap_unordered(run_case, jobs, chunksize=8):
            res.append(r)
            if len(res) % 200 == 0:
                print("%d/%d cases, %.0f s" % (len(res), len(jobs), time.time() - t0), flush=True)
    res.sort(key=lambda r: r["case"])
    keys = list(dict.fromkeys(k for r in res for k in r))
    out = os.path.join(HERE, "results", tag + ".csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(res)
    print("wrote", out, "in %.0f s" % (time.time() - t0))
    summarise(res, tag)


def summarise(res, tag="domain_sweep"):
    rows = []
    for regime in REGIMES:
        rs = [r for r in res if r["regime"] == regime]
        if not rs:
            continue
        ok = [r for r in rs if not r["error"]]
        unflagged = [r for r in ok if not r["flagged"]]
        row = dict(regime=regime, cases=len(rs), flagged=sum(r["flagged"] for r in rs),
                   failed_to_compute=len(rs) - len(ok), overflows=sum(1 for r in ok if r["overflows"] > 0))
        row["worst_ratio_unflagged"] = max((max(r["ratio_" + o] for o in H.OUTPUTS) for r in unflagged), default=0)
        row["unflagged_over_bound"] = sum(1 for r in unflagged if max(r["ratio_" + o] for o in H.OUTPUTS) > 1)
        for o in H.OUTPUTS:
            row["worst_abs_err_" + o] = max((abs(r["err_" + o]) for r in unflagged), default=0)
        rows.append(row)
    out = os.path.join(HERE, "results", tag + "_summary.csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print("%-12s %6s %7s %5s %4s %9s %6s %9s %9s" % ("regime", "cases", "flagged", "fail", "ovf", "worst e/b",
                                                    ">bound", "price err", "max Greek"))
    for r in rows:
        print("%-12s %6d %7d %5d %4d %9.3f %6d %9.1e %9.1e" % (
            r["regime"], r["cases"], r["flagged"], r["failed_to_compute"], r["overflows"], r["worst_ratio_unflagged"],
            r["unflagged_over_bound"], r["worst_abs_err_price"],
            max(r["worst_abs_err_" + o] for o in H.OUTPUTS if o != "price")))
    print("wrote", out)


if __name__ == "__main__":
    main()
