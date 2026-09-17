"""Fixed-point emulation of the shared-multiplier datapath vs the double
precision COS reference, plus the first-order error bound.

    python check_accuracy.py [FL]
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "validation", "reference"))
import heston_reference as ref  # noqa: E402
import heston as H  # noqa: E402

REF_INDEX = {"delta": 0, "strike_sens": 1, "theta_greek": 2, "rho_greek": 3, "vega": 4,
             "kappa_sens": 5, "theta_sens": 6, "xi_sens": 7, "rho_corr": 8}


def run(params, is_call=True, fl=32, g_out=None):
    g, out = g_out or H.unrolled(fl + 32, fl)
    q = H.quantize_inputs(params, is_call, fl)
    g.overflows = []
    fx = g.eval_fixed(q)
    pq = [q[n] / 2 ** fl for n in H.PARAMS]
    fv = g.eval_float(dict({n: pq[i] for i, n in enumerate(H.PARAMS)}, is_call=q["is_call"]))
    bounds = g.error_bound(fv, out)
    cg = ref.cos_greeks(pq, is_call)
    rv = {"price": ref.cos_price(pq, is_call)}
    rv.update({o: cg[i] for o, i in REF_INDEX.items()})
    rows = []
    for o in H.OUTPUTS:
        rows.append((o, fx[out[o]] / 2 ** fl, fv[out[o]], rv[o], bounds[o][0], bounds[o][1]))
    return rows, len(g.overflows)


if __name__ == "__main__":
    fl = int(sys.argv[1]) if len(sys.argv) > 1 else 32
    t0 = time.time()
    g_out = H.unrolled(fl + 32, fl)
    g = g_out[0]
    muls = sum(1 for n in g.nodes if n.op == "mul" and n.part == "term") // H.N_TERMS
    print("graph: %d nodes (%.1fs), %d multiplies per term" % (len(g.nodes), time.time() - t0, muls))
    cases = [([100, 100, 1, .05, .04, 1.5, .04, .3, -.9], True, "base"),
             ([100, 100, 1, 0, .0175, 1.5768, .0398, .5751, -.5711], True, "FO2008"),
             ([100, 90, .1, 0, .0175, 1.5768, .0398, .5751, -.5711], False, "FO put K=90 T=0.1"),
             ([100, 100, .1, .05, .04, 1.5, .04, .8, -.9], True, "short T high xi")]
    for p, call, name in cases:
        t0 = time.time()
        rows, novf = run(p, call, fl, g_out)
        print("\n== %s (%.1fs, overflows %d)" % (name, time.time() - t0, novf))
        print("%-12s %16s %11s %11s %11s %9s" % ("output", "fixed", "err vs ref", "float-ref", "bound", "err/bound"))
        for o, fxv, flv, rv, b, sg in rows:
            print("%-12s %+16.10f %11.2e %11.2e %11.2e %9.3f" % (o, fxv, fxv - rv, flv - rv, b, abs(fxv - flv) / b))
