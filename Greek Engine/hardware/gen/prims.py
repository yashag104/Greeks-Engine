"""Arithmetic primitives expressed in the IR (see ir.py).

Every primitive is built only from shared multipliers (MUL), the two CORDIC
units, and glue (add/shift/compare/ROM). There are no dividers and no
bit-serial square roots: reciprocals and inverse square roots are Newton
iterations on a normalized mantissa seeded from an 8-bit ROM, so they cost
multiplier *uses*, which the scheduler shares, instead of dedicated area.

Formats: FL for ordinary values, MF = WL-3 for mantissas in (-4, 4),
0 for integers (exponents, table indices, k).
"""
from decimal import Decimal

from ir import CORDIC_INVK_DEC, PI_DEC

D = Decimal
LN2 = D(2).ln()


def install_tables(g):
    t = g.tables
    # reciprocal seed over m in [1,2): 1/(1 + (i+0.5)/256)
    t["recip_seed"] = [1 / (1 + (D(i) + D("0.5")) / 256) for i in range(256)]
    # inverse sqrt seed over m in [0,4) at 1/64 resolution (entries < 1 unused)
    t["rsqrt_seed"] = [(1 / ((D(i) + D("0.5")) / 64).sqrt()) if i >= 64 else D(0) for i in range(256)]
    # exp: 2^(j/32)
    t["exp2"] = [D(2) ** (D(j) / 32) for j in range(32)]
    # log: c_j = 1 + (2j+1)/128 ; 1/c_j and ln c_j
    t["log_invc"] = [1 / (1 + D(2 * j + 1) / 128) for j in range(64)]
    t["log_lnc"] = [(1 + D(2 * j + 1) / 128).ln() for j in range(64)]
    # 1/k for the COS payoff (k = 0 unused -> 0)
    t["inv_k"] = [D(0)] + [1 / D(k) for k in range(1, 256)]


NEWTON_ITERS = 3


def recip(g, x):
    """1/x = y * 2^e ; returns (y at frac MF with |y| in (0.5, 1], e integer node)"""
    mf = g.mf
    s = g.is_neg(x)
    ax = g.abs(x)
    ex = g.norm_e(ax)
    m = g.scale(ax, g.neg(ex), mf)                       # [1,2)
    y = g.rom("recip_seed", g.idx(m, 8), mf)
    one = g.const(1, mf)
    for _ in range(NEWTON_ITERS):
        t = g.mul(m, y, mf)
        y = g.add(y, g.mul(y, g.sub(one, t), mf))
    y = g.mux(s, g.neg(y), y)
    return y, g.neg(ex)


def rsqrt(g, x):
    """1/sqrt(x) = y * 2^e for x > 0; y at frac MF in (0.5, 1]"""
    mf = g.mf
    ex = g.norm_e(x, even=True)
    m = g.scale(x, g.neg(ex), mf)                        # [1,4)
    y = g.rom("rsqrt_seed", g.idx(m, 8, span4=True), mf)
    three = g.const(3, mf)
    minus_one = g.const(-1, 0)
    for _ in range(NEWTON_ITERS):
        y2 = g.mul(y, y, mf)
        my2 = g.mul(m, y2, mf)
        y = g.mul(y, g.sub(three, my2), mf, e=minus_one)  # y * (3 - m y^2) / 2
    return y, g.neg(g.ishr(ex, 1))                       # ex is even: -ex/2


def div(g, a, x, fout=None):
    """a / x, rounded to fout (default: a's format)"""
    y, e = recip(g, x)
    return g.mul(a, y, g.f(a) if fout is None else fout, e=e)


def sqrt(g, x):
    y, e = rsqrt(g, x)
    return g.mul(x, y, g.f(x), e=e)


def exp(g, x):
    """exp(x), x at frac FL, result at frac FL. Tang's method:
    n = round(32 x / ln2), r = x - n ln2/32, exp(x) = 2^(n>>5) 2^((n&31)/32) P(r)"""
    fl, mf = g.fl, g.mf
    n = g.mul(x, g.const(32 / LN2, mf - 4), 0)                 # integer
    r = g.sub(x, g.mul(n, g.const(LN2 / 32, mf + 2), fl))     # |r| <= ln2/64
    r = g.scale(r, g.const(0, 0), mf)                          # exact widen to MF
    deg = 4 if fl <= 36 else 5
    coef = [D(1)]
    for i in range(1, deg + 1):
        coef.append(coef[-1] / i)
    h = g.const(coef[deg], mf)
    for i in range(deg - 1, -1, -1):
        h = g.add(g.mul(h, r, mf), g.const(coef[i], mf))
    q = g.mul(h, g.rom("exp2", g.iand(n, 31), mf), mf)
    return g.scale(q, g.ishr(n, 5), fl)


def log(g, x):
    """ln(x), x > 0 at any frac, result at frac FL"""
    fl, mf = g.fl, g.mf
    e = g.norm_e(x)
    m = g.scale(x, g.neg(e), mf)                               # [1,2)
    j = g.idx(m, 6)
    t = g.sub(g.mul(m, g.rom("log_invc", j, mf), mf), g.const(1, mf))
    deg = 4 if fl <= 36 else 5
    h = g.const(D((-1) ** (deg + 1)) / deg, mf)
    for i in range(deg - 1, 0, -1):
        h = g.add(g.mul(h, t, mf), g.const(D((-1) ** (i + 1)) / i, mf))
    l1p = g.mul(h, t, mf)
    small = g.refrac(g.add(g.rom("log_lnc", j, mf), l1p), fl)    # ln(c_j) + ln(1+t)
    return g.add(g.mul(e, g.const(LN2, mf), fl), small)


def cos_sin(g, z):
    """(cos z, sin z) for any z at frac FL: reduce by round(z/2pi)*2pi, then CORDIC"""
    fl, mf = g.fl, g.mf
    n = g.mul(z, g.const(1 / (2 * PI_DEC), mf), 0)
    zr = g.sub(z, g.mul(n, g.const(2 * PI_DEC, mf - 1), fl))
    c = g.crot(zr)
    return g.pick(c, 0), g.pick(c, 1)


# ---------------------------------------------------------------- complex
def cmul(g, a, b, e=None, fout=None):
    fout = g.fl if fout is None else fout
    rr = g.sub(g.mul(a[0], b[0], fout, e), g.mul(a[1], b[1], fout, e))
    ii = g.add(g.mul(a[0], b[1], fout, e), g.mul(a[1], b[0], fout, e))
    return rr, ii


def conj(g, a):
    return a[0], g.neg(a[1])


def cinv(g, b):
    """1/b as (cr, ci, e) with 1/b = (cr + i ci) * 2^e, cr/ci at frac MF.
    b is scaled by 2^-p so max(|br|,|bi|) in [0.5, 1) before |b|^2 is formed:
    no bits are lost to squaring, no overflow."""
    mf = g.mf
    big = g.max(g.abs(b[0]), g.abs(b[1]))
    p = g.add(g.norm_e(big), g.const(1, 0))
    br = g.scale(b[0], g.neg(p), mf)
    bi = g.scale(b[1], g.neg(p), mf)
    n2 = g.add(g.mul(br, br, mf), g.mul(bi, bi, mf))            # [0.25, 2)
    y, e = recip(g, n2)
    cr = g.mul(br, y, mf)
    ci = g.neg(g.mul(bi, y, mf))
    return cr, ci, g.sub(e, p)


def cdiv_inv(g, a, inv, fout=None):
    """a * inv where inv = cinv(...)"""
    return cmul(g, a, (inv[0], inv[1]), e=inv[2], fout=fout)


def conj_inv(g, inv):
    return inv[0], g.neg(inv[1]), inv[2]


def cexp(g, z):
    e = exp(g, z[0])
    c, s = cos_sin(g, z[1])
    return g.mul(e, c), g.mul(e, s)


def clog(g, z):
    """(ln|z|, arg z): CORDIC vectoring gives K|z| without squaring"""
    v = g.cvec(z[0], z[1])
    mag_k, ang = g.pick(v, 0), g.pick(v, 1)
    lnk = g.const(-(1 / CORDIC_INVK_DEC).ln(), g.fl)            # -ln K
    return g.add(log(g, mag_k), lnk), ang


def csqrt(g, z):
    """principal sqrt: |z| from CORDIC vectoring, w = sqrt((|z| + |zr|)/2),
    other part = zi / (2w) via the same inverse square root (no divide)"""
    fl = g.fl
    v = g.cvec(z[0], z[1])
    mag = g.mul(g.pick(v, 0), g.const(CORDIC_INVK_DEC, g.mf), fl)
    yv = g.scale(g.add(mag, g.abs(z[0])), g.const(-1, 0), fl)    # (|z|+|zr|)/2
    ys, e = rsqrt(g, yv)
    w = g.mul(yv, ys, fl, e=e)
    other = g.mul(z[1], ys, fl, e=g.sub(e, g.const(1, 0)))       # zi/(2w)
    pos = g.is_neg(z[0])
    re = g.mux(pos, g.abs(other), w)
    im = g.mux(pos, g.mux(g.is_neg(z[1]), g.neg(w), w), other)
    return re, im
