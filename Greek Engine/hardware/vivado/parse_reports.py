"""Collect Vivado reports from runs/<part>/<top>/ into validation/results/vivado.csv.

Columns: part, top, lut, ff, dsp, bram, clk_ns, wns_ns, fmax_mhz, power_total_w,
power_dynamic_w. Cycle counts come from simulation (validation/results/*.csv),
and make_figures.py combines them: latency = cycles / fmax, energy per
evaluation = dynamic (or total) power x latency.
"""
import csv
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "validation", "results", "vivado.csv")


def util(path):
    txt = open(path).read()
    def grab(pattern):
        m = re.search(r"\|\s*" + pattern + r"\s*\|\s*([\d.]+)", txt)
        return float(m.group(1)) if m else 0.0
    return dict(lut=grab(r"(?:Slice LUTs|CLB LUTs)\*?"),
                ff=grab(r"(?:Slice Registers|CLB Registers)"),
                dsp=grab(r"DSPs"),
                bram=grab(r"Block RAM Tile"))


def power(path):
    txt = open(path).read()
    tot = re.search(r"Total On-Chip Power \(W\)\s*\|\s*([\d.]+)", txt)
    dyn = re.search(r"Dynamic \(W\)\s*\|\s*([\d.]+)", txt)
    return dict(power_total_w=float(tot.group(1)) if tot else "",
                power_dynamic_w=float(dyn.group(1)) if dyn else "")


rows = []
for d in sorted(glob.glob(os.path.join(HERE, "runs", "*", "*"))):
    s = os.path.join(d, "summary.txt")
    if not os.path.exists(s):
        continue
    kv = dict(line.split(None, 1) for line in open(s).read().split("\n") if line.strip())
    clk, wns = float(kv["clk_ns"]), float(kv["wns_ns"])
    row = dict(part=kv["part"].strip(), top=kv["top"].strip(), clk_ns=clk, wns_ns=wns,
               fmax_mhz=1000.0 / (clk - wns))
    row.update(util(os.path.join(d, "util.rpt")))
    row.update(power(os.path.join(d, "power.rpt")))
    rows.append(row)

if rows:
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print("wrote", os.path.normpath(OUT), len(rows), "rows")
else:
    print("no completed runs under", os.path.join(HERE, "runs"))
