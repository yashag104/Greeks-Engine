"""COS truncation (method) error against the independent Fourier integral, as a
separate term from the fixed-point rounding bound.

    .venv/bin/python validation/run_method_error.py
    -> validation/results/method_error.csv

The 50 board cases (2 fixed + 48 random, seed 2026: exactly the cases of
results/board_sweep_report_2026-10-06.csv). For every output:
  method = |COS (N = 128, frozen [a, b], double) - Fourier integral|
  bound  = the first-order rounding bound of the 56-bit engine (from the board report)
Total error of the hardware against the Heston model <= rounding + method, and
only the rounding part is covered by the bound.
"""
import csv
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hardware", "gen"))
sys.path.insert(0, os.path.join(HERE, "reference"))

import heston as H                     # noqa: E402
import heston_reference as ref         # noqa: E402
from board_vectors import sweep_cases  # noqa: E402
from check_accuracy import REF_INDEX   # noqa: E402


def main():
    dp = H.Datapath(56, 28)
    cases, _ = sweep_cases(dp, 48, 2026)
    board = {}
    for r in csv.DictReader(open(os.path.join(HERE, "results", "board_sweep_report_2026-10-06.csv"))):
        board[(int(r["case"]), r["output"])] = r
    rows = []
    t0 = time.time()
    for i, (p, call) in enumerate(cases, 1):
        cg, ig = ref.cos_greeks(p, call), ref.integral_greeks(p, call)
        cosv = {"price": ref.cos_price(p, call)}
        intv = {"price": ref.integral_price(p, call)}
        cosv.update({o: cg[j] for o, j in REF_INDEX.items()})
        intv.update({o: ig[j] for o, j in REF_INDEX.items()})
        for o in H.OUTPUTS:
            b = board[(i, o)]
            rows.append(dict(case=i, is_call=int(call), output=o, cos=cosv[o], integral=intv[o],
                             method_err=abs(cosv[o] - intv[o]), board_err_vs_cos=abs(float(b["err_vs_ref"])),
                             bound=float(b["bound"])))
        print("case %d/%d %.0f s" % (i, len(cases), time.time() - t0), flush=True)
    with open(os.path.join(HERE, "results", "method_error.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print("%-12s %13s %13s %13s %13s" % ("output", "max method", "median method", "max rounding", "max bound"))
    for o in H.OUTPUTS:
        rs = sorted(r["method_err"] for r in rows if r["output"] == o)
        print("%-12s %13.2e %13.2e %13.2e %13.2e" % (o, rs[-1], rs[len(rs) // 2],
              max(r["board_err_vs_cos"] for r in rows if r["output"] == o),
              max(r["bound"] for r in rows if r["output"] == o)))


if __name__ == "__main__":
    main()
