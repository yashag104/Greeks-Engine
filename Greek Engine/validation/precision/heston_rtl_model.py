"""Operation-level model of the Heston AAD RTL, for fixed-point error bounds.

Mirrors hardware/verilog/heston_cos_forward.v, heston_payoff_coeff.v,
heston_char_func.v (forward AND reverse sweep) and the complex_* / fp_*
primitives *operation by operation*: every rounding multiply, divide,
square root, exp, log and CORDIC call in the RTL is one node here, in the
same order, with the same branch decisions (Smith swap, guard bits, adjoint
normalization shift, payoff parity...).

Each node carries
  * its exact real value (double precision),
  * local partial derivatives w.r.t. its parents,
  * a local error bound eps (in ULPs of the RTL format at that node).

First-order error propagation (Linnainmaa 1976; the same adjoint idea the
hardware implements) then gives, for any output Y,

    |Y_rtl - Y_exact|  <=  2^-FL * sum_i |dY/dv_i| * eps_i   + O(2^-2FL)

with all dY/dv_i from ONE reverse sweep over this graph. Because the RTL's
reverse sweep is itself modeled as ordinary nodes, the same machinery bounds
the Greeks, not just the price.

Per-primitive eps (ULP), each derived in the header of the RTL module and
checked against double precision by hardware/sim unit tests:
  rounded multiply / divide / sqrt / arithmetic shift   0.5
  fp_exp(x)        3.2 * exp(x) + 0.5   (k*ln2 rounding, Horner, 2^k shift)
  fp_log(x)        2.7                  (t rounding, Horner, LUT constants)
  CORDIC cos, sin  3.0                  (1/K rounding, guard-bit truncation,
                                         residual angle, output rounding)
  CORDIC atan2     1.0 + 1/|z|
  rounded constant 0.5
Not covered (stated separately): input quantization (inputs are taken as
the Q-format values actually applied), overflow (range is checked
separately), second-order terms.
"""
import math

MUL, DIV, SQRT, SHIFT, CONST = 0.5, 0.5, 0.5, 0.5, 0.5
LOG_EPS, CORDIC_EPS = 2.7, 3.0


class Graph:
    def __init__(self, fl):
        self.fl = fl
        self.val = []
        self.par = []      # list of tuples ((parent, partial), ...)
        self.eps = []      # local error bound in *true units* (already * 2^-FL * scale)
        self.escale = 1.0  # error scale for the adjoint-normalized reverse sweep

    # ---- node creation ------------------------------------------------
    def node(self, v, parents=(), eps_ulp=0.0):
        self.val.append(float(v))
        self.par.append(tuple(parents))
        self.eps.append(eps_ulp * self.escale * 2.0 ** -self.fl)
        return len(self.val) - 1

    def inp(self, v):
        return self.node(v)

    def const(self, v, rounded=True):
        return self.node(v, (), CONST if rounded else 0.0)

    def v(self, i):
        return self.val[i]

    # ---- real primitives (value, partials, eps) ------------------------
    def add(self, a, b):
        return self.node(self.v(a) + self.v(b), ((a, 1.0), (b, 1.0)))

    def sub(self, a, b):
        return self.node(self.v(a) - self.v(b), ((a, 1.0), (b, -1.0)))

    def neg(self, a):
        return self.node(-self.v(a), ((a, -1.0),))

    def scale(self, a, c, eps=0.0):
        """exact (shift-left / small-integer) or rounding (right-shift) scaling"""
        return self.node(c * self.v(a), ((a, c),), eps)

    def mul(self, a, b, eps=MUL):
        return self.node(self.v(a) * self.v(b), ((a, self.v(b)), (b, self.v(a))), eps)

    def mulw(self, a, b):
        """wide (not yet rounded) product"""
        return self.mul(a, b, 0.0)

    def rnd(self, a, eps=MUL):
        """round a wide value back to FL bits"""
        return self.node(self.v(a), ((a, 1.0),), eps)

    def div(self, a, b, eps=DIV):
        q = self.v(a) / self.v(b)
        return self.node(q, ((a, 1.0 / self.v(b)), (b, -q / self.v(b))), eps)

    def sqrt(self, a):
        s = math.sqrt(self.v(a))
        return self.node(s, ((a, 0.5 / s if s > 0 else 0.0),), SQRT)

    def exp(self, a):
        e = math.exp(self.v(a))
        return self.node(e, ((a, e),), 3.2 * e + 0.5)

    def log(self, a):
        return self.node(math.log(self.v(a)), ((a, 1.0 / self.v(a)),), LOG_EPS)

    def cos_sin(self, a):
        x = self.v(a)
        c = self.node(math.cos(x), ((a, -math.sin(x)),), CORDIC_EPS)
        s = self.node(math.sin(x), ((a, math.cos(x)),), CORDIC_EPS)
        return c, s

    def atan2(self, y, x):
        yv, xv = self.v(y), self.v(x)
        r2 = xv * xv + yv * yv
        return self.node(math.atan2(yv, xv), ((y, xv / r2), (x, -yv / r2)), 1.0 + 1.0 / math.sqrt(r2))

    # ---- complex primitives (pairs of node ids) ------------------------
    def cmul(self, a, b):
        ar, ai = a
        br, bi = b
        rr = self.sub(self.mulw(ar, br), self.mulw(ai, bi))
        ii = self.add(self.mulw(ar, bi), self.mulw(ai, br))
        return self.rnd(rr), self.rnd(ii)

    def cdiv(self, a, b):
        """complex_div.v: Smith's algorithm with a guard-bit inverse"""
        ar, ai = a
        br, bi = b
        swap = abs(self.v(bi)) > abs(self.v(br))
        if swap:
            t = self.div(br, bi)
            den = self.add(bi, self.mul(br, t))
            nr = self.add(self.mul(ar, t), ai)
            ni = self.sub(self.mul(ai, t), ar)
        else:
            t = self.div(bi, br) if self.v(bi) != 0 else self.const(0.0, rounded=False)
            den = self.add(br, self.mul(bi, t))
            nr = self.add(ar, self.mul(ai, t))
            ni = self.sub(ai, self.mul(ar, t))
        il = 32
        dv = abs(self.v(den))
        pos = math.floor(math.log2(dv * 2.0 ** self.fl)) if dv > 0 else 0
        guard = max(0, min(il - 2, pos - self.fl + il - 3))
        one = self.const(1.0, rounded=False)
        inv = self.div(one, den, eps=DIV * 2.0 ** -guard)
        return self.mul(nr, inv), self.mul(ni, inv)

    def csqrt(self, a):
        """complex_sqrt.v: w = sqrt((|z|+|ar|)/2), other part = a_other/(2w)"""
        ar, ai = a
        m2 = self.rnd(self.add(self.mulw(ar, ar), self.mulw(ai, ai)))
        mag = self.sqrt(m2)
        sgn = 1.0 if self.v(ar) >= 0 else -1.0
        absr = self.scale(ar, sgn)
        w = self.sqrt(self.scale(self.add(mag, absr), 0.5, SHIFT))
        two_w = self.scale(w, 2.0)
        if self.v(ar) >= 0:
            return w, self.div(ai, two_w)
        si = 1.0 if self.v(ai) >= 0 else -1.0
        return self.div(self.scale(ai, si), two_w), self.scale(w, si)

    def cexp(self, a):
        ar, ai = a
        e = self.exp(ar)
        c, s = self.cos_sin(ai)
        return self.mul(e, c), self.mul(e, s)

    def clog(self, a):
        ar, ai = a
        m2 = self.rnd(self.add(self.mulw(ar, ar), self.mulw(ai, ai)))
        return self.scale(self.log(m2), 0.5, SHIFT), self.atan2(ai, ar)

    def conj(self, z):
        return z[0], self.neg(z[1])

    # ---- reverse sweep over this graph ---------------------------------
    def sensitivities(self, out):
        adj = [0.0] * len(self.val)
        adj[out] = 1.0
        for i in range(out, -1, -1):
            a = adj[i]
            if a == 0.0:
                continue
            for p, d in self.par[i]:
                adj[p] += a * d
        return adj

    def bound(self, out):
        """(worst-case first-order bound, 1-sigma estimate).

        The estimate treats each local error as independent and uniform on
        [-eps_i, eps_i] (std eps_i/sqrt(3)); it describes the *typical*
        error, the bound the worst case."""
        adj = self.sensitivities(out)
        worst = sq = 0.0
        for a, e in zip(adj, self.eps):
            if e:
                t = abs(a) * e
                worst += t
                sq += t * t
        return worst, math.sqrt(sq / 3.0)


# ======================================================================
# heston_char_func.v
# ======================================================================
def char_func(g, u, T, r, v0, kappa, theta, xi, rho, x, seed):
    one = g.const(1.0, rounded=False)
    # ---- forward ----
    rho_xi = g.mul(rho, xi)
    xi_sq = g.mul(xi, xi)
    t1r = g.neg(kappa)
    t1i = g.mul(rho_xi, u)
    wp1, wp2, wp3 = g.mulw(t1r, t1r), g.mulw(t1i, t1i), g.mulw(t1r, t1i)
    wp4 = g.mulw(xi_sq, u)
    xi2u2 = g.mulw(g.rnd(wp4), u)
    us_r = g.add(g.rnd(g.sub(wp1, wp2)), g.rnd(xi2u2))
    us_i = g.add(g.scale(g.rnd(wp3), 2.0), g.rnd(wp4))
    d = g.csqrt((us_r, us_i))
    num = (g.sub(kappa, d[0]), g.sub(g.neg(t1i), d[1]))
    den = (g.add(kappa, d[0]), g.add(g.neg(t1i), d[1]))
    gg = g.cdiv(num, den)
    negdT = (g.mul(g.neg(d[0]), T), g.mul(g.neg(d[1]), T))
    edT = g.cexp(negdT)
    gedT = g.cmul(gg, edT)
    omge = (g.sub(one, gedT[0]), g.neg(gedT[1]))
    omg = (g.sub(one, gg[0]), g.neg(gg[1]))
    ratio = g.cdiv(omge, omg)
    logr = g.clog(ratio)
    kt = g.mul(kappa, theta)
    kth = g.div(kt, xi_sq)
    numT = (g.mul(num[0], T), g.mul(num[1], T))
    rut = g.mul(g.rnd(g.mulw(r, u)), T)
    br_ = g.sub(numT[0], g.scale(logr[0], 2.0))
    bi_ = g.sub(numT[1], g.scale(logr[1], 2.0))
    C_r = g.mul(kth, br_)
    C_i = g.add(rut, g.mul(kth, bi_))
    zero = g.const(0.0, rounded=False)
    nxi2 = g.cdiv(num, (xi_sq, zero))
    ome = (g.sub(one, edT[0]), g.neg(edT[1]))
    dr = g.cdiv(ome, omge)
    D = g.cmul(nxi2, dr)
    e_r = g.add(C_r, g.mul(D[0], v0))
    e_i = g.add(g.add(C_i, g.mul(D[1], v0)), g.mul(u, x))
    phi = g.cexp((e_r, e_i))

    # ---- reverse (heston_char_func.v R_* states) ----
    inv_xi_sq = g.div(one, xi_sq)
    wn_r = g.add(g.mulw(phi[0], seed[0]), g.mulw(phi[1], seed[1]))
    wn_i = g.sub(g.mulw(phi[0], seed[1]), g.mulw(phi[1], seed[0]))
    mag = max(abs(g.v(wn_r)), abs(g.v(wn_i)))
    fl = g.fl
    if mag > 0:
        npos = math.floor(math.log2(mag * 2.0 ** (2 * fl)))
        shift = 0 if npos >= 2 * fl else (2 * fl - npos if npos >= fl else fl)
    else:
        shift = fl
    saved = g.escale
    g.escale = 2.0 ** -shift           # reverse-sweep rounding is 2^-shift smaller
    ae = (g.rnd(wn_r), g.rnd(wn_i))
    aC, aDv0, aiux = ae, ae, ae[1]
    aD = (g.mul(aDv0[0], v0), g.mul(aDv0[1], v0))
    adj_v0 = g.add(g.mul(aDv0[0], D[0]), g.mul(aDv0[1], D[1]))
    adj_x = g.mul(aiux, u)
    a_nxi2 = g.cmul(g.conj(dr), aD)
    a_Dratio = g.cmul(g.conj(nxi2), aD)
    inv_omge = g.cdiv((one, zero), omge)
    a_ome = g.cmul(g.conj(inv_omge), a_Dratio)
    q = g.cdiv(dr, omge)
    a_omge = g.cmul((g.neg(q[0]), q[1]), a_Dratio)
    a_edT = (g.neg(a_ome[0]), g.neg(a_ome[1]))
    a_num = (g.mul(a_nxi2[0], inv_xi_sq), g.mul(a_nxi2[1], inv_xi_sq))
    a_xi_sq = g.neg(g.mul(g.add(g.mul(a_nxi2[0], nxi2[0]), g.mul(a_nxi2[1], nxi2[1])), inv_xi_sq))
    a_rut = aC[1]
    a_br = (g.mul(kth, aC[0]), g.mul(kth, aC[1]))
    a_kth = g.add(g.mul(aC[0], br_), g.mul(aC[1], bi_))
    a_numT = a_br
    a_logr = (g.scale(a_br[0], -2.0), g.scale(a_br[1], -2.0))
    a_num = (g.add(a_num[0], g.mul(a_numT[0], T)), g.add(a_num[1], g.mul(a_numT[1], T)))
    adj_T = g.add(g.mul(a_numT[0], num[0]), g.mul(a_numT[1], num[1]))
    adj_T = g.add(adj_T, g.mul(g.mul(a_rut, u), r))
    adj_r = g.mul(g.mul(a_rut, u), T)
    a_p = g.mul(a_kth, inv_xi_sq)
    a_xi_sq = g.sub(a_xi_sq, g.mul(g.mul(a_kth, kth), inv_xi_sq))
    adj_kappa = g.mul(a_p, theta)
    adj_theta = g.mul(a_p, kappa)
    inv_ratio = g.cdiv((one, zero), ratio)
    a_ratio = g.cmul(g.conj(inv_ratio), a_logr)
    inv_omg = g.cdiv((one, zero), omg)
    t = g.cmul(g.conj(inv_omg), a_ratio)
    a_omge = (g.add(a_omge[0], t[0]), g.add(a_omge[1], t[1]))
    q2 = g.cdiv(ratio, omg)
    a_omg = g.cmul((g.neg(q2[0]), q2[1]), a_ratio)
    a_gexp = (g.neg(a_omge[0]), g.neg(a_omge[1]))
    a_g = (g.neg(a_omg[0]), g.neg(a_omg[1]))
    t = g.cmul(g.conj(edT), a_gexp)
    a_g = (g.add(a_g[0], t[0]), g.add(a_g[1], t[1]))
    t = g.cmul(g.conj(gg), a_gexp)
    a_edT = (g.add(a_edT[0], t[0]), g.add(a_edT[1], t[1]))
    a_negdT = g.cmul(g.conj(edT), a_edT)
    a_d = (g.mul(g.neg(a_negdT[0]), T), g.mul(g.neg(a_negdT[1]), T))
    adj_T = g.add(adj_T, g.add(g.mul(g.neg(a_negdT[0]), d[0]), g.mul(g.neg(a_negdT[1]), d[1])))
    inv_den = g.cdiv((one, zero), den)
    t = g.cmul(g.conj(inv_den), a_g)
    a_num = (g.add(a_num[0], t[0]), g.add(a_num[1], t[1]))
    q3 = g.cdiv(gg, den)
    a_den = g.cmul((g.neg(q3[0]), q3[1]), a_g)
    adj_kappa = g.add(adj_kappa, g.add(a_num[0], a_den[0]))
    a_t1i = g.neg(g.add(a_num[1], a_den[1]))
    a_d = (g.add(a_d[0], g.sub(a_den[0], a_num[0])), g.add(a_d[1], g.sub(a_den[1], a_num[1])))
    inv_2d = g.cdiv((one, zero), (g.scale(d[0], 2.0), g.scale(d[1], 2.0)))
    a_us = g.cmul(g.conj(inv_2d), a_d)
    a_xi_sq = g.add(a_xi_sq, g.add(g.mul(a_us[0], g.mul(u, u)), g.mul(a_us[1], u)))
    t = g.cmul((g.scale(t1r, 2.0), g.scale(t1i, -2.0)), a_us)
    a_t1r = t[0]
    a_t1i = g.add(a_t1i, t[1])
    adj_kappa = g.sub(adj_kappa, a_t1r)
    a_rho_xi = g.mul(a_t1i, u)
    adj_xi = g.mul(a_xi_sq, g.scale(xi, 2.0))
    adj_rho = g.mul(a_rho_xi, xi)
    adj_xi = g.add(adj_xi, g.mul(a_rho_xi, rho))
    g.escale = saved
    # values are kept in true units throughout; only the rounding of the
    # final >>> shift (in true units) remains to be accounted for
    outs = [adj_T, adj_r, adj_v0, adj_kappa, adj_theta, adj_xi, adj_rho, adj_x]
    outs = [g.rnd(o, SHIFT if shift else 0.0) for o in outs]
    return phi, dict(zip(["T", "r", "v0", "kappa", "theta", "xi", "rho", "x"], outs))


# ======================================================================
# heston_cos_forward.v + heston_payoff_coeff.v
# ======================================================================
def heston_engine(params, is_call=True, fl=32, n_terms=128):
    """Build the full graph. Returns (graph, dict of output node ids)."""
    g = Graph(fl)
    S0, K, T, r, v0, kappa, theta, xi, rho = [g.inp(p) for p in params]
    one = g.const(1.0, rounded=False)
    x = g.log(g.div(S0, K))
    exp_nkT = g.exp(g.neg(g.mul(kappa, T)))
    c1b = g.div(g.sub(one, exp_nkT), g.scale(kappa, 2.0))
    half_theta = g.scale(theta, 0.5, SHIFT)
    c1 = g.add(g.add(x, g.mul(g.sub(r, half_theta), T)), g.mul(c1b, g.sub(theta, v0)))
    c2 = g.add(g.mul(v0, T), g.mul(half_theta, T))
    ten = g.scale(g.sqrt(c2), 10.0)
    a = g.sub(c1, ten)
    b = g.add(c1, ten)
    inv_bma = g.div(one, g.scale(ten, 2.0))
    pi_c = g.const(math.pi)
    pob = g.mul(pi_c, inv_bma)
    tkb = g.mul(g.scale(K, 2.0), inv_bma)
    exp_a, exp_b = g.exp(a), g.exp(b)

    acc = g.const(0.0, rounded=False)
    names = ["T", "r", "v0", "kappa", "theta", "xi", "rho", "x"]
    accs = {n: g.const(0.0, rounded=False) for n in names}
    for k in range(n_terms):
        u = g.scale(pob, float(k))
        cu, su = g.cos_sin(g.mul(u, a))
        if k == 0:
            if is_call:
                chi, psi = g.sub(exp_b, one), b
            else:
                chi, psi = g.sub(one, exp_a), g.neg(a)
        else:
            inv_den = g.div(one, g.add(one, g.mul(u, u)))
            inv_kp = g.div(one, u)
            if is_call:
                sign = -1.0 if k % 2 else 1.0
                chi = g.mul(inv_den, g.add(g.sub(g.scale(exp_b, sign), cu), g.mul(u, su)))
                psi = g.mul(inv_kp, su)
            else:
                chi = g.mul(inv_den, g.sub(g.sub(cu, exp_a), g.mul(u, su)))
                psi = g.neg(g.mul(inv_kp, su))
        V = g.mul(tkb, g.sub(chi, psi) if is_call else g.sub(psi, chi))
        wV = g.scale(V, 0.5, SHIFT) if k == 0 else V
        seed = (g.mul(wV, cu), g.mul(wV, su))
        phi, adj = char_func(g, u, T, r, v0, kappa, theta, xi, rho, x, seed)
        F = g.add(g.mul(phi[0], cu), g.mul(phi[1], su))
        acc = g.add(acc, g.mul(F, wV))
        for n in names:
            accs[n] = g.add(accs[n], adj[n])

    disc = g.exp(g.neg(g.mul(r, T)))
    out = {"price": g.mul(disc, acc)}
    for n, o in [("vega", "v0"), ("kappa_sens", "kappa"), ("theta_sens", "theta"),
                 ("xi_sens", "xi"), ("rho_corr", "rho")]:
        out[n] = g.mul(disc, accs[o])
    adjx = g.mul(disc, accs["x"])
    out["theta_greek"] = g.add(g.mul(disc, accs["T"]), g.mul(g.mul(g.neg(r), disc), acc))
    out["rho_greek"] = g.add(g.mul(disc, accs["r"]), g.mul(g.mul(g.neg(T), disc), acc))
    out["delta"] = g.mul(adjx, g.div(one, S0))
    out["strike_sens"] = g.mul(g.sub(out["price"], adjx), g.div(one, K))
    return g, out


OUTPUTS = ["price", "delta", "strike_sens", "theta_greek", "rho_greek", "vega",
           "kappa_sens", "theta_sens", "xi_sens", "rho_corr"]


def error_bounds(params, is_call=True, fl=32):
    """{output: (exact value of the modelled algorithm, worst-case bound, 1-sigma estimate)}"""
    g, out = heston_engine(params, is_call, fl)
    res = {}
    for n in OUTPUTS:
        worst, sigma = g.bound(out[n])
        res[n] = (g.v(out[n]), worst, sigma)
    return res


if __name__ == "__main__":
    import time
    t0 = time.time()
    base = [100.0, 100.0, 1.0, 0.05, 0.04, 1.5, 0.04, 0.3, -0.9]
    res = error_bounds(base, True, 32)
    print("graph built + 10 sweeps in %.1fs" % (time.time() - t0))
    for n in OUTPUTS:
        v, b, s = res[n]
        print("%-12s value %+.10f  bound %.3e  (%.1f bits lost)  1-sigma %.3e" % (n, v, b, math.log2(b / 2.0 ** -32), s))
