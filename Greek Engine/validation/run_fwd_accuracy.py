"""Fixed-point accuracy of the adjoint and the factored forward-mode datapaths.

    .venv/bin/python validation/run_fwd_accuracy.py
    -> validation/results/fwd_accuracy.csv

Both datapaths are scheduled graphs from the same generator (hardware/gen/heston.py,
tangent.py) at the Zynq-7020 word length (56 bits, 28 fraction bits). For each of
the 21 grid cases (run_hw_sweeps.accuracy_cases) the bit-accurate model of the
scheduled graph -- what the generated RTL computes -- is compared with the same
graph in double precision. The forward datapath carries its tangents without the
per-term rescaling the adjoint applies to its adjoints, which is why it loses
accuracy at the same word length.
"""
import csv
import os
import sys
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hardware", "gen"))
sys.path.insert(0, HERE)

import heston as H                               # noqa: E402
import tangent as TG                             # noqa: E402
from run_hw_sweeps import accuracy_cases         # noqa: E402

DESIGNS = {"adjoint": lambda: H.Datapath(56, 28),
           "forward factored": lambda: TG.TangentDatapath(56, 28, factored=True)}


def one(args):
    name, case = args
    dp = DESIGNS[name]()
    p = [case[k] for k in H.PARAMS]
    q = H.quantize_inputs(p, bool(case["is_call"]), 28)
    fx, _ = H.emulate(dp, q)
    pq = [q[k] / 2 ** 28 for k in H.PARAMS]
    fl = TG.emulate_float(dp, pq, bool(case["is_call"]))
    return [(name, case["name"], o, fx[o] / 2 ** 28, fl[o]) for o in H.OUTPUTS], len(dp.g.overflows)


def main():
    jobs = [(n, c) for n in DESIGNS for c in accuracy_cases()]
    with Pool(max(1, (os.cpu_count() or 2) - 2)) as pool:
        res = pool.map(one, jobs)
    rows = [r for rs, _ in res for r in rs]
    ovf = sum(o for _, o in res)
    out = os.path.join(HERE, "results", "fwd_accuracy.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["datapath", "case", "output", "fixed", "float_alg"])
        w.writerows(rows)
    for name in DESIGNS:
        worst = {}
        for d, _, o, fx, fl in rows:
            if d == name:
                worst[o] = max(worst.get(o, 0.0), abs(fx - fl) / max(abs(fl), 1e-12))
        print("%-17s worst relative error over 21 cases: %.2e (worst output %s)" %
              (name, max(worst.values()), max(worst, key=worst.get)))
    print("overflows:", ovf)
    print("wrote", out)


if __name__ == "__main__":
    main()
