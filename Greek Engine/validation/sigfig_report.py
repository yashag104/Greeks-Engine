"""Significant figures delivered by the 56-bit engine, from a domain sweep.

    .venv/bin/python validation/sigfig_report.py [results/domain_sweep_heldout.csv]
    -> validation/results/sigfig_summary.csv

For every output: the relative error of the hardware against the COS reference
(err / |ref|) over unflagged in-domain inputs, as a median, 99th percentile and
worst, and the significant figures these give (-log10 of the relative error).
Relative error is meaningless where a Greek passes through zero, so inputs where
|ref| is below 1% of that output's median magnitude are counted and excluded.
"""
import csv
import math
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hardware", "gen"))
import heston as H  # noqa: E402


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results", "domain_sweep_heldout.csv")
    rows = [r for r in csv.DictReader(open(path))
            if r["regime"] != "outside" and r["error"] == "" and r["flagged"] == "0"]
    out = []
    print("%d unflagged in-domain inputs from %s" % (len(rows), os.path.basename(path)))
    print("%-12s %9s %10s %10s %10s %9s %9s %9s" % ("output", "excluded", "median", "p99", "worst",
                                                   "fig.med", "fig.p99", "fig.worst"))
    for o in H.OUTPUTS:
        refs = [abs(float(r["ref_" + o])) for r in rows]
        floor = 0.01 * statistics.median(refs)
        rel = sorted(abs(float(r["err_" + o])) / abs(float(r["ref_" + o]))
                     for r in rows if abs(float(r["ref_" + o])) >= floor)
        excl = len(rows) - len(rel)
        med, p99, worst = rel[len(rel) // 2], rel[int(0.99 * (len(rel) - 1))], rel[-1]
        fig = [(-math.log10(x) if x > 0 else 16.0) for x in (med, p99, worst)]
        out.append(dict(output=o, inputs=len(rel), excluded_near_zero=excl, rel_median=med, rel_p99=p99,
                        rel_worst=worst, sigfig_median=round(fig[0], 1), sigfig_p99=round(fig[1], 1),
                        sigfig_worst=round(fig[2], 1)))
        print("%-12s %9d %10.1e %10.1e %10.1e %9.1f %9.1f %9.1f" % (o, excl, med, p99, worst, *fig))
    dest = os.path.join(HERE, "results", "sigfig_summary.csv")
    with open(dest, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0]))
        w.writeheader()
        w.writerows(out)
    print("wrote", dest)


if __name__ == "__main__":
    main()
