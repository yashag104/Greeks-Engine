"""Operation-graph IR for the shared-multiplier Heston AAD datapath.

One Python description of the datapath drives everything:
  * fixed-point evaluation  -- bit-accurate integer semantics; the generated
                              RTL must match this bit for bit,
  * float evaluation        -- the same algorithm in double precision
                              (reference for hardware error),
  * error bound             -- first-order propagation of every rounding
                              point to every output (one reverse sweep),
  * scheduling / binding    -- MUL and CORDIC nodes are shared resources,
                              everything else is dedicated glue logic.

Values are signed two's-complement integers with a per-node number of
fractional bits `frac`: real value = int * 2^-frac. Node widths are
'W' (WL bits), 'D' (2*WL bits, raw products) or 'B' (1 bit).

Rounding convention everywhere: round half up, `(v + 2^(s-1)) >> s`
with arithmetic (floor) shift -- identical to Verilog `>>>` on signed
values after adding the half.
"""
import math

# ---------------------------------------------------------------------------
# resource classes
MUL = "MUL"
CROT = "CROT"
CVEC = "CVEC"
RESOURCE_OPS = {"mul": MUL, "crot": CROT, "cvec": CVEC}


def rshift_round(v, s):
    if s > 0:
        return (v + (1 << (s - 1))) >> s
    return v << (-s)


class Node:
    __slots__ = ("id", "op", "args", "attrs", "frac", "width", "part", "eps", "name")

    def __init__(self, nid, op, args, attrs, frac, width, part, eps, name):
        self.id, self.op, self.args, self.attrs = nid, op, args, attrs
        self.frac, self.width, self.part, self.eps, self.name = frac, width, part, eps, name


class Graph:
    """Datapath description. Build with the op methods, evaluate with
    eval_fixed / eval_float, bound with error_bound."""

    def __init__(self, wl=64, fl=32, gb=6):
        self.wl, self.fl, self.gb = wl, fl, gb
        self.mf = wl - 3                  # mantissa fraction: values in (-4, 4)
        self.nodes = []
        self.part = "setup"
        self.tables = {}                  # name -> list of exact values
        self.cordic_iters = fl + 2

    # ---------------------------------------------------------------- core
    def _add(self, op, args=(), attrs=None, frac=0, width="W", eps=0.0, name=None):
        n = Node(len(self.nodes), op, tuple(args), attrs or {}, frac, width, self.part, eps, name)
        self.nodes.append(n)
        return n.id

    def f(self, i):
        return self.nodes[i].frac

    # ---------------------------------------------------------------- leaves
    def inp(self, name, frac=None):
        """External input (model parameter, k, accumulated sums)."""
        return self._add("in", attrs={"name": name}, frac=self.fl if frac is None else frac, name=name)

    def const(self, value, frac=None):
        frac = self.fl if frac is None else frac
        return self._add("const", attrs={"value": value}, frac=frac)

    def rom(self, table, idx, frac):
        return self._add("rom", (idx,), {"table": table}, frac=frac)

    # ---------------------------------------------------------------- glue
    def add(self, a, b):
        assert self.f(a) == self.f(b), (self.nodes[a].op, self.nodes[b].op, self.f(a), self.f(b))
        return self._add("add", (a, b), frac=self.f(a), width=self._w(a, b))

    def sub(self, a, b):
        assert self.f(a) == self.f(b), (self.f(a), self.f(b))
        return self._add("sub", (a, b), frac=self.f(a), width=self._w(a, b))

    def neg(self, a):
        return self._add("neg", (a,), frac=self.f(a), width=self.nodes[a].width)

    def shl(self, a, n):
        """exact multiply by 2^n (n >= 0), same format"""
        return self._add("shl", (a,), {"n": n}, frac=self.f(a), width=self.nodes[a].width)

    def refrac(self, a, fout, width="W"):
        """change format; rounds when dropping fraction bits"""
        eps = 0.5 * 2.0 ** -fout if fout < self.f(a) else 0.0
        return self._add("refrac", (a,), {"fout": fout}, frac=fout, width=width, eps=eps)

    def scale(self, a, e, fout, width="W"):
        """a * 2^e (e: integer node), rounded to fout"""
        return self._add("scale", (a, e), frac=fout, width=width, eps=0.5 * 2.0 ** -fout)

    def abs(self, a):
        return self._add("abs", (a,), frac=self.f(a), width=self.nodes[a].width)

    def max(self, a, b):
        assert self.f(a) == self.f(b)
        return self._add("max", (a, b), frac=self.f(a))

    def mux(self, c, a, b):
        """c ? a : b"""
        assert self.f(a) == self.f(b), (self.f(a), self.f(b))
        return self._add("mux", (c, a, b), frac=self.f(a), width=self._w(a, b))

    def is_neg(self, a):
        return self._add("is_neg", (a,), width="B")

    def eq0(self, a):
        return self._add("eq0", (a,), width="B")

    def bit0(self, a):
        return self._add("bit0", (a,), width="B")

    def ishr(self, a, n):
        """integer floor shift (frac 0 nodes)"""
        assert self.f(a) == 0
        return self._add("ishr", (a,), {"n": n}, frac=0)

    def iand(self, a, mask):
        assert self.f(a) == 0
        return self._add("iand", (a,), {"mask": mask}, frac=0)

    def ineg(self, a):
        return self.neg(a)

    def norm_e(self, a, even=False):
        """integer e with |a| = m * 2^e, m in [1,2) (even: e even, m in [1,4))"""
        return self._add("norm_e", (a,), {"even": even}, frac=0)

    def idx(self, m, nbits, span4=False):
        """table index from a mantissa (frac mf): [1,2) -> top nbits of the
        fraction; span4: [0,4) -> top nbits of m"""
        return self._add("idx", (m,), {"nbits": nbits, "span4": span4}, frac=0)

    def adj_shift(self, wr, wi, fl_target):
        """normalization exponent s >= 0 for a raw (2*FL) adjoint pair so that
        max(|wr|,|wi|) * 2^s lies in [1, 2), clipped to [0, fl_target]"""
        return self._add("adj_shift", (wr, wi), {"cap": fl_target}, frac=0)

    def pick(self, a, i):
        n = self.nodes[a]
        fr = n.attrs["out_frac"][i]
        eps = n.attrs["out_eps"][i]
        return self._add("pick", (a,), {"i": i}, frac=fr, eps=eps)

    # ---------------------------------------------------------------- shared
    def mul(self, a, b, fout=None, e=None, raw=False):
        """a * b * 2^e, rounded to fout (default FL). raw: full 2*WL product"""
        if raw:
            return self._add("mul", (a, b), {"raw": True}, frac=self.f(a) + self.f(b), width="D")
        fout = self.fl if fout is None else fout
        args = (a, b) if e is None else (a, b, e)
        return self._add("mul", args, {"raw": False}, frac=fout, eps=0.5 * 2.0 ** -fout)

    def crot(self, z):
        """CORDIC rotation of angle z (frac FL, reduced to [-pi-eps, pi+eps])
        -> (cos z, sin z) at frac FL"""
        return self._add("crot", (z,), {"out_frac": (self.fl, self.fl), "out_eps": (2.0 * 2.0 ** -self.fl,) * 2},
                         frac=None, width="T")

    def cvec(self, x, y):
        """CORDIC vectoring -> (K*|z|, atan2(y, x)) at frac FL"""
        return self._add("cvec", (x, y), {"out_frac": (self.fl, self.fl), "out_eps": (2.0 * 2.0 ** -self.fl,) * 2},
                         frac=None, width="T")

    def _w(self, a, b):
        return "D" if "D" in (self.nodes[a].width, self.nodes[b].width) else "W"

    # ================================================================ fixed
    def eval_fixed(self, inputs, values=None, part=None, check_overflow=True):
        """Integer evaluation. inputs: name -> int (already in the node's
        format). Returns list of node values (ints, bools or tuples)."""
        v = values if values is not None else [None] * len(self.nodes)
        wl = self.wl
        lim = {"W": 1 << (wl - 1), "D": 1 << (2 * wl - 1)}
        self.overflows = getattr(self, "overflows", [])
        for n in self.nodes:
            if part is not None and n.part != part:
                continue
            if v[n.id] is not None and n.op == "in":
                continue
            a = [v[x] for x in n.args]
            op = n.op
            if op == "in":
                r = inputs[n.attrs["name"]]
            elif op == "const":
                r = int(round_half_up(n.attrs["value"], n.frac))
            elif op == "rom":
                r = int(round_half_up(self.tables[n.attrs["table"]][a[0]], n.frac))
            elif op == "add":
                r = a[0] + a[1]
            elif op == "sub":
                r = a[0] - a[1]
            elif op == "neg":
                r = -a[0]
            elif op == "shl":
                r = a[0] << n.attrs["n"]
            elif op == "refrac":
                r = rshift_round(a[0], self.f(n.args[0]) - n.frac)
            elif op == "scale":
                r = rshift_round(a[0], self.f(n.args[0]) - n.frac - a[1])
            elif op == "abs":
                r = -a[0] if a[0] < 0 else a[0]
            elif op == "max":
                r = a[0] if a[0] >= a[1] else a[1]
            elif op == "mux":
                r = a[1] if a[0] else a[2]
            elif op == "is_neg":
                r = a[0] < 0
            elif op == "eq0":
                r = a[0] == 0
            elif op == "bit0":
                r = bool(a[0] & 1)
            elif op == "ishr":
                r = a[0] >> n.attrs["n"]
            elif op == "iand":
                r = a[0] & n.attrs["mask"]
            elif op == "norm_e":
                x = -a[0] if a[0] < 0 else a[0]
                pos = x.bit_length() - 1 if x else 0
                e = pos - self.f(n.args[0])
                if n.attrs["even"]:
                    e -= e % 2
                r = e
            elif op == "idx":
                m, nb = a[0], n.attrs["nbits"]
                if n.attrs["span4"]:
                    r = (m >> (self.mf + 2 - nb)) & ((1 << nb) - 1)
                else:
                    r = (m >> (self.mf - nb)) & ((1 << nb) - 1)
            elif op == "adj_shift":
                x = max(abs(a[0]), abs(a[1]))
                fr = self.f(n.args[0])
                pos = x.bit_length() - 1 if x else -(10 ** 9)
                r = min(max(fr - pos, 0), n.attrs["cap"])
            elif op == "mul":
                p = a[0] * a[1]
                if n.attrs["raw"]:
                    r = p
                else:
                    e = a[2] if len(a) == 3 else 0
                    if n.attrs.get("negate"):
                        p = -p
                    r = rshift_round(p, self.f(n.args[0]) + self.f(n.args[1]) - n.frac - e)
            elif op == "crot":
                r = cordic_rot_fixed(a[0], self.fl, self.gb, self.cordic_iters)
            elif op == "cvec":
                r = cordic_vec_fixed(a[0], a[1], self.fl, self.gb, self.cordic_iters)
            elif op == "pick":
                r = a[0][n.attrs["i"]]
            else:
                raise ValueError(op)
            if check_overflow and n.width in lim and isinstance(r, int) and not isinstance(r, bool):
                if not (-lim[n.width] <= r < lim[n.width]):
                    self.overflows.append((n.id, op, n.name))
            v[n.id] = r
        return v

    # ================================================================ float
    def eval_float(self, inputs, values=None, part=None):
        v = values if values is not None else [None] * len(self.nodes)
        for n in self.nodes:
            if part is not None and n.part != part:
                continue
            if v[n.id] is not None and n.op == "in":
                continue
            a = [v[x] for x in n.args]
            op = n.op
            if op == "in":
                r = inputs[n.attrs["name"]]
            elif op == "const":
                r = round_half_up(n.attrs["value"], n.frac) * 2.0 ** -n.frac
            elif op == "rom":
                r = round_half_up(self.tables[n.attrs["table"]][int(a[0])], n.frac) * 2.0 ** -n.frac
            elif op == "add":
                r = a[0] + a[1]
            elif op == "sub":
                r = a[0] - a[1]
            elif op == "neg":
                r = -a[0]
            elif op == "shl":
                r = a[0] * 2.0 ** n.attrs["n"]
            elif op in ("refrac",):
                r = a[0]
            elif op == "scale":
                r = a[0] * 2.0 ** a[1]
            elif op == "abs":
                r = abs(a[0])
            elif op == "max":
                r = max(a[0], a[1])
            elif op == "mux":
                r = a[1] if a[0] else a[2]
            elif op == "is_neg":
                r = a[0] < 0
            elif op == "eq0":
                r = a[0] == 0
            elif op == "bit0":
                r = bool(int(a[0]) & 1)
            elif op == "ishr":
                r = int(a[0]) >> n.attrs["n"]
            elif op == "iand":
                r = int(a[0]) & n.attrs["mask"]
            elif op == "norm_e":
                x = abs(a[0])
                e = math.floor(math.log2(x)) if x > 0 else -self.f(n.args[0])
                if n.attrs["even"]:
                    e -= e % 2
                r = e
            elif op == "idx":
                m, nb = a[0], n.attrs["nbits"]
                if n.attrs["span4"]:
                    r = min(int(math.floor(m * 2 ** (nb - 2))), (1 << nb) - 1)
                else:
                    r = min(int(math.floor((m - 1.0) * 2 ** nb)), (1 << nb) - 1)
                r = max(r, 0)
            elif op == "adj_shift":
                x = max(abs(a[0]), abs(a[1]))
                pos = math.floor(math.log2(x)) if x > 0 else -(10 ** 9)
                r = min(max(-pos, 0), n.attrs["cap"])
            elif op == "mul":
                r = a[0] * a[1] * (2.0 ** a[2] if len(a) == 3 else 1.0)
                if n.attrs.get("negate"):
                    r = -r
            elif op == "crot":
                r = (math.cos(a[0]), math.sin(a[0]))
            elif op == "cvec":
                r = (CORDIC_K * math.hypot(a[0], a[1]), math.atan2(a[1], a[0]))
            elif op == "pick":
                r = a[0][n.attrs["i"]]
            else:
                raise ValueError(op)
            if n.frac == 0 and op in ("mul", "scale", "refrac"):
                r = math.floor(r + 0.5)          # integer-valued node: rounds in hardware too
            v[n.id] = r
        return v

    # ================================================================ bound
    def error_bound(self, fvals, outputs):
        """First-order bound and 1-sigma estimate of |fixed - float| for each
        output node, from local rounding errors eps (one reverse sweep per
        output over the linearized graph around the float values)."""
        N = len(self.nodes)
        # local partials
        par = [()] * N
        for n in self.nodes:
            a = [fvals[x] for x in n.args]
            op, g = n.op, n.args
            if n.frac == 0:
                continue                          # integer nodes: piecewise constant
            if op in ("add",):
                par[n.id] = ((g[0], 1.0), (g[1], 1.0))
            elif op == "sub":
                par[n.id] = ((g[0], 1.0), (g[1], -1.0))
            elif op == "neg":
                par[n.id] = ((g[0], -1.0),)
            elif op == "shl":
                par[n.id] = ((g[0], 2.0 ** n.attrs["n"]),)
            elif op == "refrac":
                par[n.id] = ((g[0], 1.0),)
            elif op == "scale":
                par[n.id] = ((g[0], 2.0 ** a[1]),)
            elif op == "abs":
                par[n.id] = ((g[0], 1.0 if a[0] >= 0 else -1.0),)
            elif op == "max":
                par[n.id] = ((g[0], 1.0),) if a[0] >= a[1] else ((g[1], 1.0),)
            elif op == "mux":
                par[n.id] = ((g[1], 1.0),) if a[0] else ((g[2], 1.0),)
            elif op == "mul":
                s = 2.0 ** a[2] if len(a) == 3 else 1.0
                if n.attrs.get("negate"):
                    s = -s
                par[n.id] = ((g[0], a[1] * s), (g[1], a[0] * s))
            elif op == "pick":
                src = self.nodes[g[0]]
                i = n.attrs["i"]
                sa = [fvals[x] for x in src.args]
                if src.op == "crot":
                    z = sa[0]
                    d = -math.sin(z) if i == 0 else math.cos(z)
                    par[n.id] = ((src.args[0], d),)
                else:  # cvec
                    x, y = sa
                    r2 = x * x + y * y
                    if i == 0:
                        r = math.sqrt(r2)
                        par[n.id] = ((src.args[0], CORDIC_K * x / r), (src.args[1], CORDIC_K * y / r))
                    else:
                        par[n.id] = ((src.args[0], -y / r2), (src.args[1], x / r2))
        eps = [0.0 if n.frac == 0 else n.eps for n in self.nodes]
        res = {}
        for name, out in outputs.items():
            adj = [0.0] * N
            adj[out] = 1.0
            for i in range(out, -1, -1):
                ai = adj[i]
                if ai == 0.0:
                    continue
                for p, d in par[i]:
                    adj[p] += ai * d
            worst = sq = 0.0
            for ai, e in zip(adj, eps):
                if e:
                    t = abs(ai) * e
                    worst += t
                    sq += t * t
            res[name] = (worst, math.sqrt(sq / 3.0))
        return res


# ---------------------------------------------------------------------------
def round_half_up(value, frac):
    """exact rounding of a Decimal/float/int constant to an integer at frac"""
    from decimal import Decimal, ROUND_FLOOR
    d = Decimal(value) if not isinstance(value, Decimal) else value
    return int((d * (Decimal(2) ** frac) + Decimal("0.5")).to_integral_value(rounding=ROUND_FLOOR))


# ---------------------------------------------------------------------------
# CORDIC units: exact integer models of the RTL units (rtl/cordic_rot_pipe.v,
# rtl/cordic_vec_pipe.v). Angles and x/y carry GB guard bits internally.
from decimal import Decimal, getcontext  # noqa: E402

getcontext().prec = 80


def _atan_dec(x):
    # atan for |x| <= 1 by argument halving + series
    if x > Decimal("0.1"):
        return 2 * _atan_dec(x / (1 + (1 + x * x).sqrt()))
    s, t, n = Decimal(0), x, 1
    while abs(t) > Decimal(10) ** -70:
        s += t / n if (n // 2) % 2 == 0 else -t / n
        t *= x * x
        n += 2
    return s


PI_DEC = 4 * _atan_dec(Decimal(1))
ATAN_DEC = [_atan_dec(Decimal(2) ** -i) for i in range(64)]
_k = Decimal(1)
for _i in range(64):
    _k *= 1 / (1 + Decimal(4) ** -_i).sqrt()
CORDIC_INVK_DEC = _k                       # 1/K = 0.60725...
CORDIC_K = float(1 / _k)                   # K = 1.64676...


def cordic_rot_fixed(z, fl, gb, nit):
    f = fl + gb
    pi = round_half_up(PI_DEC, f)
    half = round_half_up(PI_DEC / 2, f)
    zz = z << gb
    flip = False
    if zz > half:
        zz -= pi
        flip = True
    elif zz < -half:
        zz += pi
        flip = True
    x = round_half_up(CORDIC_INVK_DEC, f)
    y = 0
    for i in range(nit):
        at = round_half_up(ATAN_DEC[i], f)
        if zz < 0:
            x, y, zz = x + (y >> i), y - (x >> i), zz + at
        else:
            x, y, zz = x - (y >> i), y + (x >> i), zz - at
    c, s = rshift_round(x, gb), rshift_round(y, gb)
    return (-c, -s) if flip else (c, s)


def cordic_vec_fixed(x0, y0, fl, gb, nit):
    f = fl + gb
    pi = round_half_up(PI_DEC, f)
    x, y = x0 << gb, y0 << gb
    add_pi = 0
    if x < 0:
        x, y = -x, -y
        add_pi = -1 if y0 < 0 else 1       # original y sign selects -pi / +pi
    z = 0
    for i in range(nit):
        at = round_half_up(ATAN_DEC[i], f)
        if y >= 0:
            x, y, z = x + (y >> i), y - (x >> i), z + at
        else:
            x, y, z = x - (y >> i), y + (x >> i), z - at
    z += add_pi * pi
    return rshift_round(x, gb), rshift_round(z, gb)


# ---------------------------------------------------------------------------
# graph simplification (exact: integer add/sub/neg identities only, so the
# fixed-point semantics -- and hence emulator/RTL agreement -- are unchanged)
def simplify(g, roots):
    """Fold negations into add/sub and drop dead nodes. `roots` is a list of
    node ids that must survive. Returns old->new id map."""
    nodes = g.nodes
    repl = {}                                   # id -> replacement id

    def r(i):
        while i in repl:
            i = repl[i]
        return i

    changed = True
    while changed:
        changed = False
        for n in nodes:
            if n.id in repl:
                continue
            n.args = tuple(r(a) for a in n.args)
            op = n.op
            if op == "neg":
                a = nodes[n.args[0]]
                if a.op == "neg":
                    repl[n.id] = a.args[0]; changed = True
                elif a.op == "sub":
                    n.op, n.args = "sub", (a.args[1], a.args[0]); changed = True
            elif op == "add":
                x, y = nodes[n.args[0]], nodes[n.args[1]]
                if y.op == "neg":
                    n.op, n.args = "sub", (x.id, y.args[0]); changed = True
                elif x.op == "neg":
                    n.op, n.args = "sub", (y.id, x.args[0]); changed = True
            elif op == "sub":
                y = nodes[n.args[1]]
                if y.op == "neg":
                    n.op, n.args = "add", (n.args[0], y.args[0]); changed = True
            elif op == "mul" and not n.attrs.get("raw"):
                # (-x) * y == -(x * y) exactly before rounding: fold into the unit
                for j in (0, 1):
                    if nodes[n.args[j]].op == "neg":
                        args = list(n.args)
                        args[j] = nodes[n.args[j]].args[0]
                        n.args = tuple(args)
                        n.attrs = dict(n.attrs, negate=not n.attrs.get("negate", False))
                        changed = True
    roots = [r(i) for i in roots]
    live = set()
    stack = list(roots)
    while stack:
        i = stack.pop()
        if i in live:
            continue
        live.add(i)
        stack.extend(nodes[i].args)
    new_nodes, remap = [], {}
    for n in nodes:
        if n.id in live:
            remap[n.id] = len(new_nodes)
            new_nodes.append(n)
    for n in new_nodes:
        n.args = tuple(remap[a] for a in n.args)
        n.id = remap[n.id]
    g.nodes = new_nodes
    full = {}
    for old in range(len(nodes)):
        rr = r(old)
        if rr in remap:
            full[old] = remap[rr]
    return full
