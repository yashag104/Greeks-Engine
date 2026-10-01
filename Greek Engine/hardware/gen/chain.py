"""Strike chain: price + 9 Greeks for M strikes of one expiry in one pass.

The COS grid u_k = k*pi/(b-a) is the same for every strike: the truncation
range [a, b] is centred on c1 = x + c, with x = ln(S0/K) and c independent of
K, and its width b - a = 20*sqrt(c2) does not involve K. Writing the
characteristic function with the payoff's phase folded in,

    Phi_k = phi(u_k) e^{-i u_k a} = exp(C + v0 D + i u_k (x - a)),
    x - a = 10*sqrt(c2) - c,

makes Phi_k, and with [a, b] frozen its derivatives in T, r, v0, kappa,
theta, xi, rho and x, the same for every strike. Each strike j only adds its
payoff coefficient V_jk (one rotation by u_k a_j, a few multiplies) and
multiplies it into the shared sums:

    put_j = e^{-rT} sum_k w_k Re(Phi_k) V_jk,
    d put_j / d p = e^{-rT} sum_k w_k (d Re Phi_k / d p) V_jk.

The reverse sweep is therefore run once per term, seeded with Re(Phi_k)
(seed 1), instead of once per strike. Mathematically each strike's outputs are
those of the single-option engine (heston.py); in fixed point they differ only
by rounding.

    python chain.py   # accuracy against the reference and the one-option engine,
                      # cycles against M -> validation/results/chain_sweep.csv
"""
import math
import os
import sys

import heston as H
import prims as P
from ir import Graph, simplify as ir_simplify

SHARED = ["S0", "T", "r", "v0", "kappa", "theta", "xi", "rho"]


def build_setup(g, M):
    g.part = "setup"
    p = {n: g.inp(n) for n in SHARED}
    S0, T, r, v0, kappa, theta, xi, rho = [p[n] for n in SHARED]
    fl = g.fl
    s = dict(p)
    ekT = P.exp(g, g.neg(g.mul(kappa, T)))
    one = g.const(1)
    c1b = P.div(g, g.sub(one, ekT), g.shl(kappa, 1))
    half_th = g.scale(theta, g.const(-1, 0), fl)
    c = g.add(g.mul(g.sub(r, half_th), T), g.mul(c1b, g.sub(theta, v0)))    # c1 = x + c
    c2 = g.max(g.add(g.mul(v0, T), g.mul(half_th, T)), g.const(2.0 ** -fl))
    sq = P.sqrt(g, c2)
    ten = g.add(g.shl(sq, 3), g.shl(sq, 1))
    bma = g.shl(ten, 1)
    yb, eb = P.recip(g, bma)
    s["pob"] = g.mul(g.const(P.PI_DEC, g.mf), yb, fl, e=eb)
    s["kpi"] = g.mul(bma, g.const(1 / P.PI_DEC, g.mf), fl)
    s["xma"] = g.sub(ten, c)                                               # x - a, every strike
    s["rho_xi"] = g.mul(rho, xi)
    s["xi_sq"] = g.mul(xi, xi)
    s["kappa2"] = g.mul(kappa, kappa)
    s["recip_xi_sq"] = P.recip(g, s["xi_sq"])
    s["kth"] = g.mul(g.mul(kappa, theta), s["recip_xi_sq"][0], fl, e=s["recip_xi_sq"][1])
    s["rT"] = g.mul(r, T)
    s["t1r"] = g.neg(kappa)
    strikes = []
    for j in range(M):
        K = g.inp("K%d" % j)
        is_call = g.inp("is_call%d" % j, frac=0)
        sj = {"K": K, "is_call": g.eq0(g.eq0(is_call)), "recipK": P.recip(g, K)}
        sj["x"] = P.log(g, g.mul(S0, sj["recipK"][0], fl, e=sj["recipK"][1]))
        sj["a"] = g.sub(g.add(sj["x"], c), ten)
        sj["exp_a"] = P.exp(g, sj["a"])
        sj["tkb"] = g.mul(K, yb, fl, e=g.add(eb, g.const(1, 0)))
        strikes.append(sj)
    return s, strikes


def term(g, s, strikes, k):
    """shared characteristic function and its adjoint, then each strike's payoff
    coefficient and its ten contributions. Returns {(j, name): node}."""
    g.part = "term"
    fl, mf = g.fl, g.mf
    one = g.const(1)
    u = g.mul(k, s["pob"], fl)
    k0 = g.eq0(k)
    u2 = g.mul(u, u)
    yd, ed = P.recip(g, g.add(one, u2))
    inv_kp = g.mul(s["kpi"], g.rom("inv_k", k, mf), fl)

    cf = H.cf_forward(g, s, u, u2, s["xma"], one)
    phi = cf["phi"]
    # seed 1 on Re(Phi): the raw adjoint of the exponent is conj(Phi)
    adj, sh = H.cf_reverse(g, s, u, u2, cf, phi[0], g.neg(phi[1]))
    nsh = g.neg(sh)

    outs = {}
    for j, sj in enumerate(strikes):
        cu, su = P.cos_sin(g, g.mul(u, sj["a"]))
        usu = g.mul(u, su)
        s_ikp = g.mul(inv_kp, su)
        chi_p = g.mul(g.sub(g.sub(cu, sj["exp_a"]), usu), yd, fl, e=ed)
        psi_p = g.mux(k0, g.neg(sj["a"]), g.neg(s_ikp))
        V = g.mul(sj["tkb"], g.sub(psi_p, chi_p))
        wV = g.mux(k0, g.scale(V, g.const(-1, 0), fl), V)
        outs[(j, "price")] = g.mul(phi[0], wV)
        # Descaling wV once instead of each product saves ~10% LUT (estimate) but
        # doubled the error of vega, theta_sens and rho_corr on the 8-strike check.
        for name, node in adj.items():
            outs[(j, name)] = g.scale(g.mul(node, wV), nsh, fl)
    return outs


def build_finish(g, s, strikes, acc):
    """acc[(j, name)] -> outputs[(j, output)]; as heston.build_finish_from, with
    the discount factor and 1/S0 formed once for all strikes"""
    g.part = "finish"
    fl = g.fl
    r, T, S0 = s["r"], s["T"], s["S0"]
    disc = P.exp(g, g.neg(s["rT"]))
    yS, eS = P.recip(g, S0)
    mrd, mTd = g.mul(g.neg(r), disc), g.mul(g.neg(T), disc)
    res = {}
    for j, sj in enumerate(strikes):
        a = {n: acc[(j, n)] for n in H.ACC}
        out = {"price": g.mul(disc, a["price"])}
        for name, n in [("vega", "v0"), ("kappa_sens", "kappa"), ("theta_sens", "theta"),
                        ("xi_sens", "xi"), ("rho_corr", "rho")]:
            out[name] = g.mul(disc, a[n])
        adjx = g.mul(disc, a["x"])
        out["theta_greek"] = g.add(g.mul(disc, a["T"]), g.mul(mrd, a["price"]))
        out["rho_greek"] = g.add(g.mul(disc, a["r"]), g.mul(mTd, a["price"]))
        out["delta"] = g.mul(adjx, yS, fl, e=eS)
        out["strike_sens"] = g.mul(g.sub(out["price"], adjx), sj["recipK"][0], fl, e=sj["recipK"][1])
        sp = dict(s, K=sj["K"], is_call=sj["is_call"])
        for o, v in H.parity(g, sp, disc, out).items():
            res[(j, o)] = v
    return res


class ChainDatapath:
    """setup + one term graph + finish for an M-strike chain (for scheduling and
    bit-accurate emulation; same interface as heston.Datapath where sched.py
    needs it)"""

    def __init__(self, M, wl=56, fl=28):
        self.M = M
        self.g = Graph(wl, fl)
        P.install_tables(self.g)
        self.setup, self.strikes = build_setup(self.g, M)
        self.g.part = "term"
        self.k = self.g.inp("k", frac=0)
        self.term = term(self.g, self.setup, self.strikes, self.k)
        self.g.part = "finish"
        acc_in = {key: self.g.inp("acc_%d_%s" % key) for key in self.term}
        self.finish = build_finish(self.g, self.setup, self.strikes, acc_in)
        roots = list(self.term.values()) + list(self.finish.values())
        m = ir_simplify(self.g, roots)
        self.term = {key: m[v] for key, v in self.term.items()}
        self.finish = {key: m[v] for key, v in self.finish.items()}
        self.k = m.get(self.k, -1)
        self.acc_names = list(self.term)


def quantize(shared, strikes, fl):
    """shared: dict of SHARED values; strikes: list of (K, is_call)"""
    q = {n: int(round(shared[n] * 2 ** fl)) for n in SHARED}
    for j, (K, call) in enumerate(strikes):
        q["K%d" % j] = int(round(K * 2 ** fl))
        q["is_call%d" % j] = 1 if call else 0
    return q


def emulate(dp, q, n_terms=H.N_TERMS):
    """bit-accurate run of the scheduled computation: setup, the term graph for
    k = 0..n_terms-1 with outputs accumulated, finish"""
    g = dp.g
    g.overflows = []
    vals = g.eval_fixed(q, part="setup")
    acc = {key: 0 for key in dp.acc_names}
    for k in range(n_terms):
        tv = list(vals)
        tv[dp.k] = k
        g.eval_fixed(dict(q, k=k), values=tv, part="term")
        for key in dp.acc_names:
            acc[key] += tv[dp.term[key]]
    fin = list(vals)
    g.eval_fixed(dict(q, **{"acc_%d_%s" % key: v for key, v in acc.items()}), values=fin, part="finish")
    return {key: fin[node] / 2 ** g.fl for key, node in dp.finish.items()}


def term_ops(dp):
    from ir import RESOURCE_OPS
    n = {}
    for node in dp.g.nodes:
        if node.part == "term" and node.op in RESOURCE_OPS:
            n[RESOURCE_OPS[node.op]] = n.get(RESOURCE_OPS[node.op], 0) + 1
    return n


# ---------------------------------------------------------------- checks
def accuracy(M=8, wl=56, fl=28, shared=None, Ks=None):
    """each strike's outputs against the double-precision reference and against
    the single-option engine's bit-accurate model"""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "validation", "reference"))
    import heston_reference as ref
    shared = shared or dict(S0=100, T=1, r=.05, v0=.04, kappa=1.5, theta=.04, xi=.3, rho=-.9)
    Ks = Ks or [80 + 40 * j / max(M - 1, 1) for j in range(M)]
    strikes = [(K, K >= 100) for K in Ks]                 # OTM calls above spot, puts below
    dp = ChainDatapath(M, wl, fl)
    q = quantize(shared, strikes, fl)
    out = emulate(dp, q)
    single = H.Datapath(wl, fl)
    rows = []
    for j, (K, call) in enumerate(strikes):
        p = [q[n] / 2 ** fl if n in SHARED else q["K%d" % j] / 2 ** fl for n in H.PARAMS]
        want = [ref.cos_price(p, call)] + list(ref.cos_greeks(p, call))
        so, _ = H.emulate(single, H.quantize_inputs(p, call, fl))
        for i, o in enumerate(H.OUTPUTS):
            rows.append((K, call, o, out[(j, o)], want[i], so[o] / 2 ** fl))
    return rows, len(dp.g.overflows)


def sweep(Ms=(1, 2, 4, 8, 16, 32)):
    """cycles for M strikes on the two reference configurations. Zynq-7020 style:
    56-bit, 8 multipliers, iterative CORDIC, with as many rotators as keep the
    multipliers the bound (one extra rotation per strike per term) and also with
    today's 3. UltraScale+ style: 64-bit, 32 multipliers, pipelined CORDIC."""
    import sched as S
    rows = []
    for M in Ms:
        for wl, fl in ((56, 28), (64, 32)):
            dp = ChainDatapath(M, wl, fl)
            ops = term_ops(dp)
            if wl == 56:
                need = max(3, math.ceil(ops["CROT"] * (fl + 4) / math.ceil(ops["MUL"] / 8)))
                cfgs = [S.Config(wl=56, fl=28, mults=8, crot=n, cvec=2, cordic_pipelined=False)
                        for n in sorted({3, min(need, ops["CROT"])})]
            else:
                cfgs = [S.Config(wl=64, fl=32, mults=32, crot=1, cvec=1, cordic_pipelined=True)]
            for cfg in cfgs:
                r = S.report(dp, cfg)
                rows.append(dict(strikes=M, wl=wl, mults=cfg.mults, crot=cfg.crot, cvec=cfg.cvec,
                                 pipe_cordic=int(cfg.cordic_pipelined), mul_per_term=ops["MUL"],
                                 rot_per_term=ops["CROT"], ii=r["ii"], cycles=r["cycles"],
                                 cycles_per_strike=round(r["cycles"] / M), lut_est=r["lut"], dsp=r["dsp"]))
    return rows


if __name__ == "__main__":
    import csv
    import random
    rng = random.Random(7)
    cases = [None] + [dict(S0=100, T=rng.uniform(.1, 3), r=rng.uniform(0, .1), v0=rng.uniform(.005, .25),
                           kappa=rng.uniform(.2, 6), theta=rng.uniform(.005, .25), xi=rng.uniform(.1, 1),
                           rho=rng.uniform(-.95, .6)) for _ in range(4)]
    worst = {}
    for shared in cases:
        rows, novf = accuracy(8, shared=shared)
        assert novf == 0
        for K, call, o, got, want, single in rows:
            w = worst.setdefault(o, [0.0, 0.0])
            w[0] = max(w[0], abs(got - want))
            w[1] = max(w[1], abs(single - want))
    print("8-strike chains (K = 80..120), 56-bit, base case + 4 random parameter sets: worst absolute error")
    print("%-12s %12s %12s" % ("output", "chain", "one option"))
    for o in H.OUTPUTS:
        print("%-12s %12.2e %12.2e" % (o, worst[o][0], worst[o][1]))
    rows = sweep()
    print()
    keys = list(rows[0])
    print(" ".join("%9s" % k[:9] for k in keys))
    for r in rows:
        print(" ".join("%9s" % r[k] for k in keys))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "validation", "results", "chain_sweep.csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)
        f.write("\n# accuracy, 8 strikes, 56-bit, 5 parameter sets: output,chain_worst_abs_err,one_option_worst_abs_err\n")
        for o in H.OUTPUTS:
            f.write("# %s,%.2e,%.2e\n" % (o, worst[o][0], worst[o][1]))
    print("wrote", os.path.normpath(out))
