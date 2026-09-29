"""Turn a ZedBoard test log into price + Greeks, and judge them.

The board returns the 9 raw COS sums (sum_*). For each case this runs the
host finish step (hardware/gen/host.py, the bit-exact specification of what
the ARM will do) on the board's sums, and compares the 10 outputs with

  - the fixed-point emulator (must be identical: the board already matched
    the sums bit for bit, this confirms it end to end),
  - the double-precision COS reference (the accuracy actually delivered),
  - the first-order error bound (check_accuracy.run; |fixed - float| / bound
    must stay <= 1, the same ratio as fig3 / fig11).

    python board_report.py results/board_zedboard_2026-09-29.log
    python board_report.py <run_sweep.log or vivado.log> [--seed 2026]
    -> results/board_report.csv, and a per-output summary on stdout

Only the last run in the log is used. Needs numpy and scipy (the reference).
"""
import argparse
import csv
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hardware", "gen"))

import board_vectors as BV  # noqa: E402
import check_accuracy as C  # noqa: E402
import heston as H  # noqa: E402
import host  # noqa: E402
from wrappers import CASES  # noqa: E402

A = types.SimpleNamespace(wl=56, fl=28, mults=8, crot=3, cvec=2, pipe_cordic=False,
                          host_setup=True, terms=128, name="heston_aad_z7h")


def parse(log):
    """last run in the log -> [(label, {acc_name: int})]"""
    text = open(log, errors="replace").read()
    starts = [m.start() for m in re.finditer(r"^INFO: base address from", text, re.M)]
    if not starts:
        sys.exit("no run_jtag.tcl run found in %s" % log)
    run = text[starts[-1]:]
    cases, cur = [], None
    for line in run.splitlines():
        m = re.match(r"CASE \d+/\d+ (.*)", line)
        if m:
            cur = (m.group(1).strip(), {})
            cases.append(cur)
            continue
        m = re.match(r"\s*ok sum_(\w+)\s+(-?\d+)", line) or re.match(r"FAIL sum_(\w+)\s+got (-?\d+)", line)
        if m:
            if cur is None:                       # log from before CASE lines existed
                cur = ("single vector", {})
                cases.append(cur)
            cur[1][m.group(1)] = int(m.group(2))
    return cases


def params_for(labels, seed):
    """recover the exact parameters: labels only carry 6 significant digits"""
    if len(labels) == 1:
        return [CASES[0]]
    dp = H.Datapath(A.wl, A.fl)
    cases, _ = BV.sweep_cases(dp, len(labels) - len(CASES), seed)
    for lab, (pv, call) in zip(labels, cases):
        want = "S0=%.6g K=%.6g T=%.6g r=%.6g v0=%.6g kappa=%.6g theta=%.6g xi=%.6g rho=%.6g %s" % (
            tuple(pv) + ("call" if call else "put",))
        if lab != want:
            sys.exit("case mismatch: log has '%s', seed %d gives '%s'" % (lab, seed, want))
    return cases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--out", default=os.path.join(HERE, "results", "board_report.csv"))
    a = ap.parse_args()

    runs = parse(a.log)
    cases = params_for([lab for lab, _ in runs], a.seed)
    dp = H.Datapath(A.wl, A.fl)
    g_out = H.unrolled(A.wl, A.fl)
    rows, incomplete = [], 0
    for i, ((lab, sums), (pv, call)) in enumerate(zip(runs, cases)):
        if len(sums) != len(dp.acc_names):
            incomplete += 1
            continue
        board = host.finish(dp, pv, call, sums)
        emu, _ = C.run(pv, call, A.fl, g_out)
        for o, fx, fl, rv, bound, sigma in emu:
            b = board[o] / 2 ** A.fl
            rows.append(dict(case=i + 1, is_call=int(call), output=o, board=b, emulator=fx, float_alg=fl,
                             ref_cos=rv, err_vs_ref=b - rv, bound=bound, err_over_bound=abs(b - fl) / bound))

    with open(a.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    ncase = len(runs) - incomplete
    exact = sum(1 for r in rows if r["board"] == r["emulator"])
    print("%d case(s) from %s; %d incomplete skipped" % (ncase, os.path.basename(a.log), incomplete))
    print("board == emulator after host finish: %d / %d outputs" % (exact, len(rows)))
    print()
    print("%-12s %14s %14s %14s" % ("output", "max |err|", "max rel. err", "max err/bound"))
    for o in H.OUTPUTS:
        pts = [r for r in rows if r["output"] == o]
        rel = [abs(r["err_vs_ref"]) / max(abs(r["ref_cos"]), 1e-12) for r in pts]
        print("%-12s %14.3e %14.3e %14.3f" % (o, max(abs(r["err_vs_ref"]) for r in pts), max(rel),
                                               max(r["err_over_bound"] for r in pts)))
    worst = max(r["err_over_bound"] for r in rows)
    print()
    print("%s: every output within its error bound (worst %.3f of the bound)" % ("GOOD" if worst <= 1 else "BAD",
                                                                                   worst))
    print("wrote %s" % a.out)


if __name__ == "__main__":
    main()
