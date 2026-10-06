"""Adjoint vs forward-mode hardware baselines, from the same generator.

    .venv/bin/python validation/run_mode_baselines.py
    -> validation/results/mode_baselines.csv

For each datapath (price only; the adjoint; three forward-mode variants from
hardware/gen/tangent.py) it checks the price and nine Greeks against the
adjoint datapath in double precision on three parameter sets, then reports the
per-term operation counts and the modulo schedule (II, cycles per evaluation)
for the Zynq-7020 and 64-bit configurations at several multiplier counts.
"""
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hardware", "gen"))

import heston as H                                   # noqa: E402
import tangent as TG                                 # noqa: E402
from sched import Config, schedule, cost_estimate    # noqa: E402

FAMILIES = {"z7": dict(wl=56, fl=28, crot=3, cvec=2, pipe=False, mults=(8, 16)),
            "zu": dict(wl=64, fl=32, crot=1, cvec=1, pipe=True, mults=(8, 16, 32, 64))}
CASES = [([100, 100, 1.0, 0.03, 0.04, 1.5, 0.04, 0.5, -0.7], False),
         ([100, 120, 0.5, 0.02, 0.06, 3.0, 0.05, 0.8, -0.3], True),
         ([100, 70, 2.5, 0.05, 0.02, 0.8, 0.03, 0.3, -0.9], False)]


def variants(wl, fl):
    return {"price only": H.Datapath(wl, fl, greeks=False),
            "adjoint": H.Datapath(wl, fl),
            "forward factored (analytic)": TG.TangentDatapath(wl, fl, factored=True),
            "forward sparse": TG.TangentDatapath(wl, fl),
            "forward dense (AD tool)": TG.TangentDatapath(wl, fl, dense=True)}


def check():
    adj = H.Datapath(64, 32)
    for name, dp in variants(64, 32).items():
        if name in ("price only", "adjoint"):
            continue
        worst = 0.0
        for p, call in CASES:
            a, b = TG.emulate_float(adj, p, call), TG.emulate_float(dp, p, call)
            worst = max(worst, max(abs(a[o] - b[o]) / max(1e-6, abs(a[o])) for o in H.OUTPUTS))
        print("%-28s worst relative difference from the adjoint: %.1e" % (name, worst))
        assert worst < 1e-9, name


def main():
    check()
    rows = []
    for fam, c in FAMILIES.items():
        dps = variants(c["wl"], c["fl"])
        for m in c["mults"]:
            cfg = Config(wl=c["wl"], fl=c["fl"], mults=m, crot=c["crot"], cvec=c["cvec"], cordic_pipelined=c["pipe"])
            base = None
            for name, dp in dps.items():
                ops = TG.term_ops(dp)
                s = schedule(dp, cfg)
                cyc = s.cycles_per_evaluation()
                base = cyc if name == "price only" else base
                rows.append(dict(family=fam, wl=c["wl"], mults=m, datapath=name, mul_per_term=ops.get("MUL", 0),
                                 crot=ops.get("CROT", 0), cvec=ops.get("CVEC", 0), ii=s.ii, cycles=cyc,
                                 cost_vs_price=round(cyc / base, 3), lut_est=cost_estimate(dp, s)["lut"]))
                print("%s %3d mults  %-28s MUL/term %4d  II %4d  cycles %6d  %.2fx price" % (
                    fam, m, name, rows[-1]["mul_per_term"], s.ii, cyc, rows[-1]["cost_vs_price"]), flush=True)
    out = os.path.join(HERE, "results", "mode_baselines.csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print("wrote", out)


if __name__ == "__main__":
    main()
