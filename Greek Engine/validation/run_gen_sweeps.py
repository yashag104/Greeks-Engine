"""Datasets for the generated shared-multiplier architecture (hardware/gen).

    python run_gen_sweeps.py            # -> results/gen_cycles.csv, results/gen_bump.csv

gen_cycles.csv  cycles per evaluation vs number of shared multipliers, for the
                AAD engine (price + 9 sensitivities) and the bump-and-reprice
                baseline on the same architecture. Cycle counts come from the
                modulo scheduler; the generated RTL reproduced the scheduler's
                prediction exactly for every configuration simulated
                (hardware/gen/gen_tb.py, wrappers.py), and the bump wrapper's
                measured count is 19 * (pricer + 3) + 11.
gen_bump.csv    bump-and-reprice error vs bump size on the generated pricer
                (bit-accurate emulator == RTL), against AAD on the same config.
"""
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hardware", "gen"))
sys.path.insert(0, os.path.join(HERE, "reference"))

import heston as H  # noqa: E402
import heston_reference as ref  # noqa: E402
from sched import Config, cost_estimate, schedule  # noqa: E402
from wrappers import SENS, bump_emulate  # noqa: E402

RES = os.path.join(HERE, "results")
CONFIGS = {"z7": dict(wl=56, fl=28, crot=3, cvec=2, pipe=False, mults=8),
           "zu": dict(wl=64, fl=32, crot=1, cvec=1, pipe=True, mults=32)}


def bump_cycles(pricer_cycles):
    return 19 * (pricer_cycles + 3) + 11


def write(name, rows):
    os.makedirs(RES, exist_ok=True)
    with open(os.path.join(RES, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print("wrote results/%s (%d rows)" % (name, len(rows)))


def cycles_sweep():
    rows = []
    for fam, c in CONFIGS.items():
        dp_aad = H.Datapath(c["wl"], c["fl"])
        dp_prc = H.Datapath(c["wl"], c["fl"], greeks=False)
        mlist = (2, 4, 8, 16) if not c["pipe"] else (1, 2, 4, 8, 16, 32, 64, 128)
        for m in mlist:
            cfg = Config(wl=c["wl"], fl=c["fl"], mults=m, crot=c["crot"], cvec=c["cvec"], cordic_pipelined=c["pipe"])
            sa, sp = schedule(dp_aad, cfg), schedule(dp_prc, cfg)
            ca, cp = sa.cycles_per_evaluation() + 2, sp.cycles_per_evaluation() + 2   # RTL: start edge .. done visible
            est = cost_estimate(dp_aad, sa)
            rows.append(dict(family=fam, wl=c["wl"], fl=c["fl"], mults=m, ii_aad=sa.ii, ii_price=sp.ii,
                             cycles_aad=ca, cycles_price=cp, cycles_bump=bump_cycles(cp),
                             bump_over_aad=round(bump_cycles(cp) / ca, 2), dsp_est=est["dsp"]))
            print(rows[-1])
    write("gen_cycles.csv", rows)


def bump_sweep(rel_hs=(1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1)):
    base = [100.0, 100.0, 1.0, 0.05, 0.04, 1.5, 0.04, 0.3, -0.9]
    rows = []
    for fam, c in CONFIGS.items():
        fl = c["fl"]
        q = H.quantize_inputs(base, True, fl)
        pq = [q[n] / 2 ** fl for n in H.PARAMS]
        cg = ref.cos_greeks(pq, True)
        refv = {o: cg[H.PARAMS.index(p)] for o, p in SENS}
        aad, _ = H.emulate(H.Datapath(c["wl"], fl), q)
        dp_prc = H.Datapath(c["wl"], fl, greeks=False)
        for rh in rel_hs:
            hq = {n: max(1, int(round(rh * max(abs(base[i]), 1e-2) * 2 ** fl))) for i, n in enumerate(H.PARAMS)}
            iq = {n: int(round(2 ** fl / (2 * hq[n] / 2 ** fl))) for n in H.PARAMS}
            b = bump_emulate(dp_prc, q, hq, iq)
            for o, _ in SENS:
                rows.append(dict(family=fam, wl=c["wl"], fl=fl, rel_h=rh, output=o, ref_cos=refv[o],
                                 bump=b[o] / 2 ** fl, aad=aad[o] / 2 ** fl))
            print(fam, rh, "delta bump %.3e aad %.3e" % (abs(b["delta"] / 2 ** fl - refv["delta"]), abs(aad["delta"] / 2 ** fl - refv["delta"])))
    write("gen_bump.csv", rows)


if __name__ == "__main__":
    cycles_sweep()
    bump_sweep()
