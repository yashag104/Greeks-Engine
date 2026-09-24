"""Heston-COS price + 9 sensitivities (reverse-mode AAD) as an IR graph.

Three parts:
  setup   once per evaluation: truncation range, grid spacing, payoff
          constants, and every characteristic-function quantity that does
          not depend on u_k (hoisted out of the per-term loop),
  term    one COS term k: payoff coefficient, characteristic function
          forward pass, reverse sweep seeded by this term's contribution,
          adjoint normalization; outputs are accumulated,
  finish  discounting, the r/T discount-chain terms, dV/dS0 and dV/dK.

Same mathematics as hardware/verilog/heston_char_func.v (and
validation/precision/heston_rtl_model.py); divisions are replaced by
reciprocals (prims.cinv/recip) that are computed once and reused, e.g. the
forward pass's 1/den is reused by the reverse pass's g/den and 1/den.
"""
from ir import Graph, simplify as ir_simplify
import prims as P

PARAMS = ["S0", "K", "T", "r", "v0", "kappa", "theta", "xi", "rho"]
ACC = ["price", "T", "r", "v0", "kappa", "theta", "xi", "rho", "x"]
N_TERMS = 128


def build_setup(g):
    g.part = "setup"
    p = {n: g.inp(n) for n in PARAMS}
    is_call = g.inp("is_call", frac=0)
    S0, K, T, r, v0, kappa, theta, xi, rho = [p[n] for n in PARAMS]
    fl = g.fl
    s = dict(p)
    s["is_call"] = g.eq0(g.eq0(is_call))          # to bool
    s["recipK"] = P.recip(g, K)
    s["x"] = P.log(g, g.mul(S0, s["recipK"][0], fl, e=s["recipK"][1]))
    ekT = P.exp(g, g.neg(g.mul(kappa, T)))
    one = g.const(1)
    c1b = P.div(g, g.sub(one, ekT), g.shl(kappa, 1))
    half_th = g.scale(theta, g.const(-1, 0), fl)
    c1 = g.add(g.add(s["x"], g.mul(g.sub(r, half_th), T)), g.mul(c1b, g.sub(theta, v0)))
    c2 = g.max(g.add(g.mul(v0, T), g.mul(half_th, T)), g.const(2.0 ** -fl))
    sq = P.sqrt(g, c2)
    ten = g.add(g.shl(sq, 3), g.shl(sq, 1))
    s["c1"], s["ten_sqrt_c2"] = c1, ten
    s["a"] = g.sub(c1, ten)
    s["b"] = g.add(c1, ten)
    bma = g.shl(ten, 1)
    yb, eb = P.recip(g, bma)
    s["pob"] = g.mul(g.const(P.PI_DEC, g.mf), yb, fl, e=eb)                # pi/(b-a)
    s["tkb"] = g.mul(K, yb, fl, e=g.add(eb, g.const(1, 0)))               # 2K/(b-a)
    s["kpi"] = g.mul(bma, g.const(1 / P.PI_DEC, g.mf), fl)                 # (b-a)/pi
    s["exp_a"] = P.exp(g, s["a"])
    s["exp_b"] = P.exp(g, s["b"])
    # characteristic-function constants
    s["rho_xi"] = g.mul(rho, xi)
    s["xi_sq"] = g.mul(xi, xi)
    s["kappa2"] = g.mul(kappa, kappa)
    s["recip_xi_sq"] = P.recip(g, s["xi_sq"])
    s["kth"] = g.mul(g.mul(kappa, theta), s["recip_xi_sq"][0], fl, e=s["recip_xi_sq"][1])
    s["rT"] = g.mul(r, T)
    s["t1r"] = g.neg(kappa)
    return s


def term(g, s, k, greeks=True):
    """one COS term; k is an integer input node. Returns node dict.
    greeks=False: forward pass only (the price-only pricer used by the
    bump-and-reprice baseline)."""
    g.part = "term"
    fl, mf = g.fl, g.mf
    T, r, v0, kappa, theta, xi, rho = (s[n] for n in ["T", "r", "v0", "kappa", "theta", "xi", "rho"])
    one = g.const(1)
    zero = g.const(0)
    ry, re_ = s["recip_xi_sq"]

    # ---- payoff coefficient V_k and seed ----
    u = g.mul(k, s["pob"], fl)                       # k integer: exact
    cu, su = P.cos_sin(g, g.mul(u, s["a"]))
    k0 = g.eq0(k)
    kodd = g.bit0(k)
    u2 = g.mul(u, u)
    yd, ed = P.recip(g, g.add(one, u2))
    usu = g.mul(u, su)
    inv_kp = g.mul(s["kpi"], g.rom("inv_k", k, mf), fl)
    s_ikp = g.mul(inv_kp, su)
    chi_c = g.mul(g.add(g.sub(g.mux(kodd, g.neg(s["exp_b"]), s["exp_b"]), cu), usu), yd, fl, e=ed)
    chi_p = g.mul(g.sub(g.sub(cu, s["exp_a"]), usu), yd, fl, e=ed)
    psi_c = g.mux(k0, s["b"], s_ikp)
    psi_p = g.mux(k0, g.neg(s["a"]), g.neg(s_ikp))
    diff = g.mux(s["is_call"], g.sub(chi_c, psi_c), g.sub(psi_p, chi_p))
    V = g.mul(s["tkb"], diff)
    wV = g.mux(k0, g.scale(V, g.const(-1, 0), fl), V)
    seed = (g.mul(wV, cu), g.mul(wV, su))

    # ---- characteristic function, forward ----
    t1r = s["t1r"]
    t1i = g.mul(s["rho_xi"], u)
    us = (g.add(g.sub(s["kappa2"], g.mul(t1i, t1i)), g.mul(s["xi_sq"], u2)),
          g.add(g.shl(g.mul(t1r, t1i), 1), g.mul(s["xi_sq"], u)))
    d = P.csqrt(g, us)
    num = (g.sub(kappa, d[0]), g.sub(g.neg(t1i), d[1]))
    den = (g.add(kappa, d[0]), g.add(g.neg(t1i), d[1]))
    inv_den = P.cinv(g, den)
    gg = P.cdiv_inv(g, num, inv_den)
    negdT = (g.neg(g.mul(d[0], T)), g.neg(g.mul(d[1], T)))
    edT = P.cexp(g, negdT)
    gedT = P.cmul(g, gg, edT)
    omge = (g.sub(one, gedT[0]), g.neg(gedT[1]))
    omg = (g.sub(one, gg[0]), g.neg(gg[1]))
    inv_omg = P.cinv(g, omg)
    ratio = P.cdiv_inv(g, omge, inv_omg)
    logr = P.clog(g, ratio)
    numT = (g.mul(num[0], T), g.mul(num[1], T))
    br_ = g.sub(numT[0], g.shl(logr[0], 1))
    bi_ = g.sub(numT[1], g.shl(logr[1], 1))
    C_r = g.mul(s["kth"], br_)
    C_i = g.add(g.mul(u, s["rT"]), g.mul(s["kth"], bi_))
    nxi2 = (g.mul(num[0], ry, fl, e=re_), g.mul(num[1], ry, fl, e=re_))
    ome = (g.sub(one, edT[0]), g.neg(edT[1]))
    inv_omge = P.cinv(g, omge)
    dratio = P.cdiv_inv(g, ome, inv_omge)
    D = P.cmul(g, nxi2, dratio)
    e_r = g.add(C_r, g.mul(D[0], v0))
    e_i = g.add(g.add(C_i, g.mul(D[1], v0)), g.mul(u, s["x"]))
    phi = P.cexp(g, (e_r, e_i))

    # price contribution
    F = g.add(g.mul(phi[0], cu), g.mul(phi[1], su))
    contrib = g.mul(F, wV)
    if not greeks:
        return {"price": contrib}

    # ---- reverse sweep (normalized) ----
    wn_r = g.add(g.mul(phi[0], seed[0], raw=True), g.mul(phi[1], seed[1], raw=True))
    wn_i = g.sub(g.mul(phi[0], seed[1], raw=True), g.mul(phi[1], seed[0], raw=True))
    sh = g.adj_shift(wn_r, wn_i, fl)
    ae = (g.scale(wn_r, sh, fl), g.scale(wn_i, sh, fl))
    aC, aDv0, aiux = ae, ae, ae[1]
    aD = (g.mul(aDv0[0], v0), g.mul(aDv0[1], v0))
    adj_v0 = g.add(g.mul(aDv0[0], D[0]), g.mul(aDv0[1], D[1]))
    adj_x = g.mul(aiux, u)
    a_nxi2 = P.cmul(g, P.conj(g, dratio), aD)
    a_Dratio = P.cmul(g, P.conj(g, nxi2), aD)
    a_ome = P.cdiv_inv(g, a_Dratio, P.conj_inv(g, inv_omge))
    q = P.cdiv_inv(g, dratio, inv_omge)
    a_omge = P.cmul(g, (g.neg(q[0]), q[1]), a_Dratio)
    a_edT = (g.neg(a_ome[0]), g.neg(a_ome[1]))
    a_num = (g.mul(a_nxi2[0], ry, fl, e=re_), g.mul(a_nxi2[1], ry, fl, e=re_))
    a_xi_sq = g.neg(g.mul(g.add(g.mul(a_nxi2[0], nxi2[0]), g.mul(a_nxi2[1], nxi2[1])), ry, fl, e=re_))
    a_rut = aC[1]
    a_br = (g.mul(s["kth"], aC[0]), g.mul(s["kth"], aC[1]))
    a_kth = g.add(g.mul(aC[0], br_), g.mul(aC[1], bi_))
    a_logr = (g.neg(g.shl(a_br[0], 1)), g.neg(g.shl(a_br[1], 1)))
    a_num = (g.add(a_num[0], g.mul(a_br[0], T)), g.add(a_num[1], g.mul(a_br[1], T)))
    adj_T = g.add(g.mul(a_br[0], num[0]), g.mul(a_br[1], num[1]))
    ru = g.mul(a_rut, u)
    adj_T = g.add(adj_T, g.mul(ru, r))
    adj_r = g.mul(ru, T)
    a_p = g.mul(a_kth, ry, fl, e=re_)
    a_xi_sq = g.sub(a_xi_sq, g.mul(g.mul(a_kth, s["kth"]), ry, fl, e=re_))
    adj_kappa = g.mul(a_p, theta)
    adj_theta = g.mul(a_p, kappa)
    # 1/ratio = omg/omge
    inv_ratio = P.cdiv_inv(g, omg, inv_omge)
    a_ratio = P.cmul(g, P.conj(g, inv_ratio), a_logr)
    t = P.cdiv_inv(g, a_ratio, P.conj_inv(g, inv_omg))
    a_omge = (g.add(a_omge[0], t[0]), g.add(a_omge[1], t[1]))
    q2 = P.cdiv_inv(g, ratio, inv_omg)
    a_omg = P.cmul(g, (g.neg(q2[0]), q2[1]), a_ratio)
    a_gexp = (g.neg(a_omge[0]), g.neg(a_omge[1]))
    a_g = (g.neg(a_omg[0]), g.neg(a_omg[1]))
    t = P.cmul(g, P.conj(g, edT), a_gexp)
    a_g = (g.add(a_g[0], t[0]), g.add(a_g[1], t[1]))
    t = P.cmul(g, P.conj(g, gg), a_gexp)
    a_edT = (g.add(a_edT[0], t[0]), g.add(a_edT[1], t[1]))
    a_negdT = P.cmul(g, P.conj(g, edT), a_edT)
    a_d = (g.mul(g.neg(a_negdT[0]), T), g.mul(g.neg(a_negdT[1]), T))
    adj_T = g.sub(adj_T, g.add(g.mul(a_negdT[0], d[0]), g.mul(a_negdT[1], d[1])))
    t = P.cdiv_inv(g, a_g, P.conj_inv(g, inv_den))
    a_num = (g.add(a_num[0], t[0]), g.add(a_num[1], t[1]))
    q3 = P.cdiv_inv(g, gg, inv_den)
    a_den = P.cmul(g, (g.neg(q3[0]), q3[1]), a_g)
    adj_kappa = g.add(adj_kappa, g.add(a_num[0], a_den[0]))
    a_t1i = g.neg(g.add(a_num[1], a_den[1]))
    a_d = (g.add(a_d[0], g.sub(a_den[0], a_num[0])), g.add(a_d[1], g.sub(a_den[1], a_num[1])))
    inv_2d = P.cinv(g, (g.shl(d[0], 1), g.shl(d[1], 1)))
    a_us = P.cdiv_inv(g, a_d, P.conj_inv(g, inv_2d))
    a_xi_sq = g.add(a_xi_sq, g.add(g.mul(a_us[0], u2), g.mul(a_us[1], u)))
    t = P.cmul(g, (g.shl(t1r, 1), g.neg(g.shl(t1i, 1))), a_us)
    a_t1i = g.add(a_t1i, t[1])
    adj_kappa = g.sub(adj_kappa, t[0])
    a_rho_xi = g.mul(a_t1i, u)
    adj_xi = g.add(g.mul(a_xi_sq, g.shl(xi, 1)), g.mul(a_rho_xi, rho))
    adj_rho = g.mul(a_rho_xi, xi)

    nsh = g.neg(sh)
    outs = {"price": contrib}
    for name, node in [("T", adj_T), ("r", adj_r), ("v0", adj_v0), ("kappa", adj_kappa),
                       ("theta", adj_theta), ("xi", adj_xi), ("rho", adj_rho), ("x", adj_x)]:
        outs[name] = g.scale(node, nsh, fl)
    return outs


def build_finish(g, s, greeks=True):
    g.part = "finish"
    fl = g.fl
    if not greeks:
        acc_price = g.inp("acc_price")
        return {"price": g.mul(P.exp(g, g.neg(s["rT"])), acc_price)}
    acc = {n: g.inp("acc_" + n) for n in ACC}
    r, T, S0 = s["r"], s["T"], s["S0"]
    disc = P.exp(g, g.neg(s["rT"]))
    out = {"price": g.mul(disc, acc["price"])}
    for name, a in [("vega", "v0"), ("kappa_sens", "kappa"), ("theta_sens", "theta"),
                    ("xi_sens", "xi"), ("rho_corr", "rho")]:
        out[name] = g.mul(disc, acc[a])
    adjx = g.mul(disc, acc["x"])
    out["theta_greek"] = g.add(g.mul(disc, acc["T"]), g.mul(g.mul(g.neg(r), disc), acc["price"]))
    out["rho_greek"] = g.add(g.mul(disc, acc["r"]), g.mul(g.mul(g.neg(T), disc), acc["price"]))
    yS, eS = P.recip(g, S0)
    out["delta"] = g.mul(adjx, yS, fl, e=eS)
    out["strike_sens"] = g.mul(g.sub(out["price"], adjx), s["recipK"][0], fl, e=s["recipK"][1])
    return out


OUTPUTS = ["price", "delta", "strike_sens", "theta_greek", "rho_greek", "vega",
           "kappa_sens", "theta_sens", "xi_sens", "rho_corr"]


# ======================================================================
class Datapath:
    """setup graph + one term graph + finish graph (for scheduling / RTL)"""

    def __init__(self, wl=64, fl=32, simplify=True, greeks=True):
        self.g = Graph(wl, fl)
        self.greeks = greeks
        self.acc_names = ACC if greeks else ["price"]
        self.outputs = OUTPUTS if greeks else ["price"]
        P.install_tables(self.g)
        self.setup = build_setup(self.g)
        self.g.part = "term"
        self.k = self.g.inp("k", frac=0)
        self.term = term(self.g, self.setup, self.k, greeks)
        self.finish = build_finish(self.g, self.setup, greeks)
        if simplify:
            roots = list(self.term.values()) + list(self.finish.values())
            m = ir_simplify(self.g, roots)
            self.term = {k: m[v] for k, v in self.term.items()}
            self.finish = {k: m[v] for k, v in self.finish.items()}
            self.setup = {k: (tuple(m.get(x, -1) for x in v) if isinstance(v, tuple) else m.get(v, -1))
                          for k, v in self.setup.items()}
            self.k = m.get(self.k, -1)


def unrolled(wl=64, fl=32, n_terms=N_TERMS):
    """One graph with all terms instantiated and the sums formed explicitly:
    used for float/fixed evaluation and the error bound of the whole
    evaluation. Returns (graph, output node ids)."""
    g = Graph(wl, fl)
    P.install_tables(g)
    s = build_setup(g)
    sums = None
    for k in range(n_terms):
        g.part = "term"
        kn = g.const(k, 0)
        o = term(g, s, kn)
        sums = o if sums is None else {n: g.add(sums[n], o[n]) for n in ACC}
    g.part = "finish"
    # finish, wired to the sums instead of accumulator inputs
    fin = build_finish_from(g, s, sums)
    m = ir_simplify(g, list(fin.values()))
    return g, {k: m[v] for k, v in fin.items()}


def build_finish_from(g, s, acc):
    fl = g.fl
    r, T, S0 = s["r"], s["T"], s["S0"]
    disc = P.exp(g, g.neg(s["rT"]))
    out = {"price": g.mul(disc, acc["price"])}
    for name, a in [("vega", "v0"), ("kappa_sens", "kappa"), ("theta_sens", "theta"),
                    ("xi_sens", "xi"), ("rho_corr", "rho")]:
        out[name] = g.mul(disc, acc[a])
    adjx = g.mul(disc, acc["x"])
    out["theta_greek"] = g.add(g.mul(disc, acc["T"]), g.mul(g.mul(g.neg(r), disc), acc["price"]))
    out["rho_greek"] = g.add(g.mul(disc, acc["r"]), g.mul(g.mul(g.neg(T), disc), acc["price"]))
    yS, eS = P.recip(g, S0)
    out["delta"] = g.mul(adjx, yS, fl, e=eS)
    out["strike_sens"] = g.mul(g.sub(out["price"], adjx), s["recipK"][0], fl, e=s["recipK"][1])
    return out


def quantize_inputs(params, is_call, fl):
    d = {n: int(round(params[i] * 2 ** fl)) for i, n in enumerate(PARAMS)}
    d["is_call"] = 1 if is_call else 0
    return d


def emulate(dp, q, n_terms=N_TERMS, keep_terms=()):
    """Bit-accurate run of the *scheduled* graph (setup once, the term graph
    once per k with its outputs accumulated, finish once) -- exactly the
    computation the generated RTL performs. Returns (outputs, trace) where
    trace holds full node-value lists for setup, finish and terms in
    keep_terms, for register-level RTL checks."""
    g = dp.g
    g.overflows = []
    vals = g.eval_fixed(q, part="setup")
    trace = {"setup": list(vals)}
    acc = {n: 0 for n in dp.acc_names}
    for k in range(n_terms):
        tv = list(vals)
        tv[dp.k] = k
        g.eval_fixed(dict(q, k=k), values=tv, part="term")
        for n in dp.acc_names:
            acc[n] += tv[dp.term[n]]
        if k in keep_terms:
            trace[k] = tv
    fin = list(vals)
    g.eval_fixed(dict(q, **{"acc_" + n: acc[n] for n in dp.acc_names}), values=fin, part="finish")
    trace["finish"] = fin
    trace["acc"] = acc
    return {o: fin[dp.finish[o]] for o in dp.outputs}, trace
