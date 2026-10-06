"""Forward-mode (tangent) baselines for the Heston-COS Greeks datapath.

The adjoint datapath (heston.term) gets all Greeks from one reverse sweep per
COS term. A reviewer's fair question is whether a forward-mode datapath, built
from the same primitives and scheduled by the same scheduler, would do as well:
the 1.04x Greeks overhead comes from the reverse sweep filling multiplier slots
that the CORDIC-bound forward pass leaves idle, and a tangent sweep could fill
them too. This module builds the comparison.

Each term propagates one tangent per input direction (T, r, v0, kappa, theta,
xi, rho, x) through the characteristic function, written at the same complex-
arithmetic level as heston.cf_reverse, with the same frozen truncation range,
the same hoisting of per-evaluation constants into setup, and the same finish.

  sparse  derivatives that are structurally zero are skipped and multiplies by
          a seed of 1 are omitted: this is what hand-derived analytic Greeks
          (e.g. Cui et al. 2017; `analytic` in validation/cpu_baseline) amount
          to, i.e. the best a forward method can do.
  dense   every direction is propagated through every node, as a vector
          forward-mode AD tool does; structural zeros are explicit constants.

These graphs are for cost (operation counts, schedule, cycles) and are checked
for correctness in double precision against the adjoint datapath. They have no
fixed-point range normalization of the tangents (the adjoint's adj_shift and
rescaling are not mirrored), so their costs are a lower bound for a working
fixed-point forward engine.

    .venv/bin/python hardware/gen/tangent.py      # check + cost table
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import heston as H                     # noqa: E402
import prims as P                      # noqa: E402
from ir import Graph, simplify as ir_simplify   # noqa: E402

DIRS = ["T", "r", "v0", "kappa", "theta", "xi", "rho", "x"]
ONE = "one"                            # a seed of exactly 1: multiplies by it are wiring
NEG1 = "neg1"                          # a seed of exactly -1


class _T:
    """tangent arithmetic; None is a structural zero (sparse mode only)"""

    def __init__(self, g, dense):
        self.g, self.dense = g, dense
        self.zero = g.const(0) if dense else None
        self._one = None

    def lit(self, x):
        """markers to nodes (for adds); multiplies handle them without a unit"""
        if x is ONE or x is NEG1:
            if self._one is None:
                self._one = self.g.const(1)
            return self._one if x is ONE else self.g.neg(self._one)
        return x

    def z(self, x):
        return self.zero if x is None else self.lit(x)

    # real
    def add(self, *xs):
        xs = [self.lit(x) for x in xs if x is not None] if not self.dense else [self.z(x) for x in xs]
        if not xs:
            return None
        acc = xs[0]
        for x in xs[1:]:
            acc = self.g.add(acc, x)
        return acc

    def neg(self, x):
        if x is ONE or x is NEG1:
            return NEG1 if x is ONE else ONE
        return None if x is None else self.g.neg(x)

    def shl(self, x, n):
        return None if x is None else self.g.shl(x, n)

    def sub(self, a, b):
        return self.add(a, self.neg(self.z(b) if self.dense else b))

    def smul(self, t, x, fout=None, e=None):
        """tangent scalar t (None / ONE / node) times value node x"""
        if self.dense:                   # an AD tool multiplies zero and unit seeds too
            t = self.zero if t is None else (self.g.const(1) if t is ONE else t)
        elif t is None:
            return None
        elif t is ONE:
            return x
        return self.g.mul(t, x, fout, e=e) if e is not None else self.g.mul(t, x)

    def vmul(self, x, t, fout=None, e=None):
        """value node x times tangent node t (None allowed)"""
        if t is None and not self.dense:
            return None
        if t is ONE or t is NEG1:
            v = self.g.scale(x, e, self.g.fl if fout is None else fout) if e is not None else x
            return v if t is ONE else self.g.neg(v)
        t = self.z(t)
        return self.g.mul(x, t, fout, e=e) if e is not None else self.g.mul(x, t)

    # complex: tangent is (re, im) with either part possibly None
    def cnone(self, t):
        return t is None or (t[0] is None and t[1] is None)

    def cadd(self, *ts):
        ts = [t for t in ts if not self.cnone(t)] if not self.dense else ts
        if not ts:
            return None
        return self.add(*[t[0] for t in ts]), self.add(*[t[1] for t in ts])

    def cneg(self, t):
        return None if self.cnone(t) else (self.neg(t[0]), self.neg(t[1]))

    def csub(self, a, b):
        return self.cadd(a, self.cneg(b))

    def cmul(self, c, t, e=None, fout=None):
        """value c (complex nodes) times tangent t; e/fout as in prims.cmul"""
        if self.cnone(t) and not self.dense:
            return None
        g, fl = self.g, (self.g.fl if fout is None else fout)
        t = (self.z(t[0]), self.z(t[1])) if self.dense else t

        def m(a, b):
            if b is None:
                return None
            if b is ONE or b is NEG1:             # a unit seed: wiring (or a shift for e)
                v = g.scale(a, e, fl) if e is not None else a
                return v if b is ONE else g.neg(v)
            return g.mul(a, b, fl, e) if e is not None else g.mul(a, b, fl)
        rr = self.sub(m(c[0], t[0]), m(c[1], t[1]))
        ii = self.add(m(c[0], t[1]), m(c[1], t[0]))
        return rr, ii

    def cinv_mul(self, t, inv):
        """t * inv where inv = prims.cinv(...)"""
        return self.cmul((inv[0], inv[1]), t, e=inv[2])

    def rcmul(self, x, t, fout=None, e=None):
        """real value node x times complex tangent t"""
        if self.cnone(t) and not self.dense:
            return None
        return self.vmul(x, t[0], fout, e), self.vmul(x, t[1], fout, e)

    def scmul(self, t, c):
        """real tangent t times complex value c"""
        return self.smul(t, c[0]), self.smul(t, c[1])


def setup_tangents(g, s):
    """derivatives of the hoisted per-evaluation constants, one dict per direction
    (computed once per evaluation, in the setup part, like the constants)"""
    g.part = "setup"
    fl = g.fl
    kappa, theta, xi, rho, T, r = (s[n] for n in ["kappa", "theta", "xi", "rho", "T", "r"])
    ry, re_ = s["recip_xi_sq"]
    inv_xi = g.mul(xi, ry, fl, e=re_)                                   # 1/xi
    d_ry_xi = g.neg(g.shl(g.mul(inv_xi, ry, fl, e=re_), 1))             # d(1/xi^2)/dxi
    tg = {j: dict(kappa2=None, rho_xi=None, xi_sq=None, ry=None, kth=None, rT=None,
                  kappa=None, v0=None, T=None, x=None) for j in DIRS}
    tg["kappa"].update(kappa=ONE, kappa2=g.shl(kappa, 1), kth=g.mul(theta, ry, fl, e=re_))
    tg["theta"].update(kth=g.mul(kappa, ry, fl, e=re_))
    tg["xi"].update(rho_xi=rho, xi_sq=g.shl(xi, 1), ry=d_ry_xi,
                    kth=g.neg(g.shl(g.mul(s["kth"], inv_xi), 1)))
    tg["rho"].update(rho_xi=xi)
    tg["r"].update(rT=T)
    tg["T"].update(rT=r, T=ONE)
    tg["v0"].update(v0=ONE)
    tg["x"].update(x=ONE)
    return tg


def cf_tangent(t, s, it, dj):
    """tangent of the characteristic-function exponent e = C + D v0 + i u x in one
    direction; dj holds that direction's seeds and setup tangents"""
    g = t.g
    fl = g.fl
    T, v0, kappa = s["T"], s["v0"], s["kappa"]
    ry, re_ = s["recip_xi_sq"]
    u, u2, cf = it["u"], it["u2"], it["cf"]
    d, num, gg, edT, ratio, br_, bi_, nxi2, dratio, D, t1r, t1i = (
        cf[n] for n in ["d", "num", "gg", "edT", "ratio", "br_", "bi_", "nxi2", "dratio", "D", "t1r", "t1i"])
    inv_den, inv_omg, inv_omge = cf["inv_den"], cf["inv_omg"], cf["inv_omge"]

    dt1i = t.smul(dj["rho_xi"], u)
    dus_r = t.add(dj["kappa2"], t.neg(t.vmul(g.shl(t1i, 1), dt1i)), t.smul(dj["xi_sq"], u2))
    # us_i = 2 t1r t1i + xi^2 u with t1r = -kappa
    dus_i = t.add(t.neg(t.shl(t.smul(dj["kappa"], t1i), 1)), t.shl(t.vmul(t1r, dt1i), 1), t.smul(dj["xi_sq"], u))
    dus = (dus_r, dus_i)
    dd = t.cinv_mul(dus, it["inv_2d"])                                  # d sqrt(us) = dus / (2d)
    ddr, ddi = (None, None) if t.cnone(dd) else dd
    dnum = (t.sub(dj["kappa"], ddr), t.sub(t.neg(dt1i), ddi))
    dden = (t.add(dj["kappa"], ddr), t.sub(ddi, dt1i))
    return chain(t, s, it, dj, dnum, dden, dd)


def chain(t, s, it, dj, dnum, dden, dd):
    """from the tangents of num, den and d (and dj's T, kth, rT, ry, v0, x seeds)
    to the tangent of the exponent e"""
    g = t.g
    fl = g.fl
    T, v0 = s["T"], s["v0"]
    ry, re_ = s["recip_xi_sq"]
    u, cf = it["u"], it["cf"]
    d, num, gg, edT, ratio, br_, bi_, nxi2, dratio, D = (
        cf[n] for n in ["d", "num", "gg", "edT", "ratio", "br_", "bi_", "nxi2", "dratio", "D"])
    inv_den, inv_omg, inv_omge = cf["inv_den"], cf["inv_omg"], cf["inv_omge"]
    dgg = t.cinv_mul(t.csub(dnum, t.cmul(gg, dden)), inv_den)
    dnegdT = t.cneg(t.cadd(t.rcmul(T, dd), t.scmul(dj["T"], d)))
    dedT = t.cmul(edT, dnegdT)
    dgedT = t.cadd(t.cmul(edT, dgg), t.cmul(gg, dedT))
    domge, domg = t.cneg(dgedT), t.cneg(dgg)
    dratio_ = t.cinv_mul(t.csub(domge, t.cmul(ratio, domg)), inv_omg)
    dlogr = t.cmul(it["inv_ratio"], dratio_)                            # d log(ratio)
    dnumT = t.cadd(t.rcmul(T, dnum), t.scmul(dj["T"], num))
    dnumT, dlogr = dnumT or (None, None), dlogr or (None, None)
    dbr = t.sub(dnumT[0], t.shl(dlogr[0], 1))
    dbi = t.sub(dnumT[1], t.shl(dlogr[1], 1))
    dC_r = t.add(t.smul(dj["kth"], br_), t.vmul(s["kth"], dbr))
    dC_i = t.add(t.smul(dj["rT"], u), t.smul(dj["kth"], bi_), t.vmul(s["kth"], dbi))
    dnxi2 = t.cadd(t.rcmul(ry, dnum, fl, re_), t.scmul(dj["ry"], num))
    ddratio = t.cinv_mul(t.csub(t.cneg(dedT), t.cmul(dratio, domge)), inv_omge)
    dD = t.cadd(t.cmul(dratio, dnxi2), t.cmul(nxi2, ddratio))
    de = t.cadd((dC_r, dC_i), t.rcmul(v0, dD), t.scmul(dj["v0"], D), (None, t.smul(dj["x"], u)))
    return de


def term_tangent(g, s, k, tg, dense):
    it = {}
    out = H.term(g, s, k, greeks=False, internals=it)
    t = _T(g, dense)
    cf = it["cf"]
    d = cf["d"]
    it["inv_2d"] = P.cinv(g, (g.shl(d[0], 1), g.shl(d[1], 1)))
    it["inv_ratio"] = P.cdiv_inv(g, cf["omg"], cf["inv_omge"])
    # d contrib = wV Re(dphi (cu - i su)), dphi = phi de: with w = wV phi (cu - i su),
    # d contrib = w_r de_r - w_i de_i
    phi = cf["phi"]
    w0 = P.cmul(g, phi, (it["cu"], g.neg(it["su"])))
    w = (g.mul(it["wV"], w0[0]), g.mul(it["wV"], w0[1]))
    for j in DIRS:
        de = cf_tangent(t, s, it, tg[j])
        if t.cnone(de):
            out[j] = g.const(0)
            continue
        out[j] = t.sub(t.vmul(w[0], de[0]), t.vmul(w[1], de[1]))
    return out


class TangentDatapath:
    """setup + one tangent term + the adjoint's finish (same accumulators)"""

    def __init__(self, wl=64, fl=32, dense=False, simplify=True, factored=False):
        self.g = Graph(wl, fl)
        self.acc_names = H.ACC
        self.outputs = H.OUTPUTS
        P.install_tables(self.g)
        self.setup = H.build_setup(self.g)
        tg = setup_tangents(self.g, self.setup)
        self.g.part = "term"
        self.k = self.g.inp("k", frac=0)
        self.term = (term_factored(self.g, self.setup, self.k, tg) if factored
                     else term_tangent(self.g, self.setup, self.k, tg, dense))
        self.finish = H.build_finish(self.g, self.setup)
        if simplify:
            roots = list(self.term.values()) + list(self.finish.values())
            m = ir_simplify(self.g, roots)
            self.term = {k: m[v] for k, v in self.term.items()}
            self.finish = {k: m[v] for k, v in self.finish.items()}
            self.k = m.get(self.k, -1)


def emulate_float(dp, params, is_call, n_terms=H.N_TERMS):
    """double-precision run of a scheduled datapath (setup, term per k, finish)"""
    g = dp.g
    q = {n: params[i] for i, n in enumerate(H.PARAMS)}
    q["is_call"] = 1 if is_call else 0
    vals = g.eval_float(q, part="setup")
    acc = {n: 0.0 for n in dp.acc_names}
    for k in range(n_terms):
        tv = list(vals)
        tv[dp.k] = k
        g.eval_float(dict(q, k=k), values=tv, part="term")
        for n in dp.acc_names:
            acc[n] += tv[dp.term[n]]
    fin = list(vals)
    g.eval_float(dict(q, **{"acc_" + n: acc[n] for n in dp.acc_names}), values=fin, part="finish")
    return {o: fin[dp.finish[o]] for o in dp.outputs}


def term_ops(dp):
    from collections import Counter
    from ir import RESOURCE_OPS
    c = Counter(RESOURCE_OPS.get(n.op) for n in dp.g.nodes if n.part == "term")
    c.pop(None, None)
    return c


def term_factored(g, s, k, tg):
    """hand-derived analytic Greeks, factored as a careful derivation would be:
    e depends on the inputs only through m = kappa - i t1i and d = sqrt(us) (both
    complex, entering num = m - d and den = m + d), T, kth, rT, 1/xi^2, v0 and x.
    The complex partials de/dm, de/dd, de/dT are formed once per term (forward,
    holomorphic), then each Greek is a short combination of them."""
    it = {}
    out = H.term(g, s, k, greeks=False, internals=it)
    t = _T(g, False)
    fl = g.fl
    cf = it["cf"]
    d, num, D, br_, bi_, dratio, t1r, t1i = (cf[n] for n in ["d", "num", "D", "br_", "bi_", "dratio", "t1r", "t1i"])
    u, u2, v0 = it["u"], it["u2"], s["v0"]
    it["inv_2d"] = P.cinv(g, (g.shl(d[0], 1), g.shl(d[1], 1)))
    it["inv_ratio"] = P.cdiv_inv(g, cf["omg"], cf["inv_omge"])
    none = {k_: None for k_ in ("T", "kth", "rT", "ry", "v0", "x")}
    E_m = chain(t, s, it, none, (ONE, None), (ONE, None), None)
    E_d = chain(t, s, it, none, (NEG1, None), (ONE, None), (ONE, None))
    E_T = chain(t, s, it, dict(none, T=ONE), None, None, None)
    F = t.cinv_mul(E_d, it["inv_2d"])                       # de/dus = de/dd / (2d)
    # d us / d t1i = -2 t1i + 2 i t1r, and d m / d t1i = -i:  de/dt1i = G
    Fq = P.cmul(g, F, (g.neg(g.shl(t1i, 1)), g.shl(t1r, 1)))
    G = (g.add(Fq[0], E_m[1]), g.sub(Fq[1], E_m[0]))
    b = (br_, bi_)
    nd = P.cmul(g, num, dratio)                              # de/d(1/xi^2) = num dratio v0
    tgk, tgx, tgt = tg["kappa"], tg["xi"], tg["theta"]
    de = {}
    # kappa: dm = 1, dus = (2 kappa, -2 t1i) since us_i = 2 t1r t1i with t1r = -kappa; dkth
    de["kappa"] = t.cadd(E_m, P.cmul(g, F, (tgk["kappa2"], g.neg(g.shl(t1i, 1)))), t.scmul(tgk["kth"], b))
    # rho: dt1i = xi u
    de["rho"] = t.rcmul(g.mul(s["xi"], u), G)
    # xi: dt1i = rho u; dus += 2 xi (u^2 + i u); dkth; d(1/xi^2)
    xs = g.shl(s["xi"], 1)
    de["xi"] = t.cadd(t.rcmul(g.mul(s["rho"], u), G),
                      t.cmul(F, (g.mul(xs, u2), g.mul(xs, u))),
                      t.scmul(tgx["kth"], b), t.rcmul(g.mul(tgx["ry"], v0), nd))
    de["T"] = t.cadd(E_T, (None, g.mul(u, s["r"])))
    de["theta"] = t.scmul(tgt["kth"], b)
    de["r"] = (None, g.mul(u, s["T"]))
    de["v0"] = D
    de["x"] = (None, u)
    phi = cf["phi"]
    w0 = P.cmul(g, phi, (it["cu"], g.neg(it["su"])))
    w = (g.mul(it["wV"], w0[0]), g.mul(it["wV"], w0[1]))
    for j in DIRS:
        out[j] = t.sub(t.vmul(w[0], de[j][0]), t.vmul(w[1], de[j][1]))
    return out
