"""Resource-constrained scheduling and binding of the Heston datapath.

Setup and finish run once per evaluation (absolute schedule). The per-term
graph is modulo-scheduled with period II: term k starts at S + k*II, so up
to ceil(L/II) terms are in flight at once. A shared unit may start one new
operation per cycle (pipelined units) or one per Lc cycles (iterative
CORDIC), and in steady state every term uses unit u at the same phase
(t mod II), so the binding is a modulo reservation table.

Storage model (dedicated registers, no sharing yet):
  * a glue node owns its output register, which holds the value for II
    cycles (until the next term overwrites it);
  * a shared unit's output is valid for one cycle and is captured into a
    register if consumed later;
  * a value alive for longer than II cycles needs ceil((life+1)/II)
    registers in a chain.
"""
import math
from dataclasses import dataclass, field

from ir import RESOURCE_OPS

FREE_OPS = {"const", "in", "pick", "shl"}   # shl by a constant is wiring


@dataclass
class Config:
    wl: int = 64
    fl: int = 32
    mults: int = 8            # shared multipliers
    crot: int = 1             # CORDIC rotation units
    cvec: int = 1             # CORDIC vectoring units
    cordic_pipelined: bool = True
    ii: int = 0               # 0 = smallest feasible
    lat_mul: int = 4          # operand mux reg, 2 DSP pipeline regs, rounding shift reg
    lat_glue: int = 1
    host_setup: bool = False  # setup/finish computed by the host CPU
    n_terms: int = 128

    @property
    def lat_cordic(self):
        return self.fl + 4       # load/fold cycle, FL+2 iterations, output rounding


@dataclass
class Schedule:
    cfg: Config
    start: dict = field(default_factory=dict)     # node id -> start cycle (part-relative)
    unit: dict = field(default_factory=dict)      # node id -> (class, index)
    ready: dict = field(default_factory=dict)
    length: dict = field(default_factory=dict)    # part -> cycles
    ii: int = 0
    storage_regs: dict = field(default_factory=dict)   # node id -> registers

    def cycles_per_evaluation(self):
        c = self.cfg
        return self.length["setup"] + (c.n_terms - 1) * self.ii + self.length["term"] + self.length["finish"]


def _lat(cfg, op):
    if op in FREE_OPS:
        return 0
    if op == "mul":
        return cfg.lat_mul
    if op in ("crot", "cvec"):
        return cfg.lat_cordic
    return cfg.lat_glue


def _units(cfg):
    return {"MUL": cfg.mults, "CROT": cfg.crot, "CVEC": cfg.cvec}


def _busy_span(cfg, cls):
    if cls in ("CROT", "CVEC") and not cfg.cordic_pipelined:
        return cfg.lat_cordic
    return 1


def schedule_part(g, cfg, part, modulo, t_offset_ready=None):
    """ASAP schedule of one part. modulo: period (int) or None (absolute)."""
    nodes = [n for n in g.nodes if n.part == part]
    units = _units(cfg)
    occ = {cls: [set() for _ in range(k)] for cls, k in units.items()}
    start, ready, binding = {}, {}, {}
    for n in nodes:
        t = 0
        for a in n.args:
            an = g.nodes[a]
            if an.part == part:
                t = max(t, ready[a])
        if n.op in RESOURCE_OPS:
            cls = RESOURCE_OPS[n.op]
            span = _busy_span(cfg, cls)
            placed = False
            tt = t
            while not placed:
                for u in range(units[cls]):
                    slots = [(tt + d) % modulo if modulo else tt + d for d in range(span)]
                    if not any(s in occ[cls][u] for s in slots):
                        occ[cls][u].update(slots)
                        binding[n.id] = (cls, u)
                        placed = True
                        break
                if not placed:
                    tt += 1
                    if modulo and tt - t > modulo * max(span, 1) + 1:
                        raise RuntimeError("no slot for %s in %s (II=%s)" % (n.op, part, modulo))
            t = tt
        start[n.id] = t
        ready[n.id] = t + _lat(cfg, n.op)
    length = max(ready.values()) + 1 if ready else 0
    return start, ready, binding, length


def schedule(dp, cfg):
    g = dp.g
    units = _units(cfg)
    term_nodes = [n for n in g.nodes if n.part == "term"]
    need = {cls: sum(1 for n in term_nodes if RESOURCE_OPS.get(n.op) == cls) for cls in units}
    lb = max(math.ceil(need[c] * _busy_span(cfg, c) / units[c]) for c in units if need[c])
    ii = cfg.ii or lb
    while True:
        try:
            st, rd, bd, L = schedule_part(g, cfg, "term", ii)
            break
        except RuntimeError:
            ii += 1
    sch = Schedule(cfg=cfg, ii=ii)
    sch.start.update(st)
    sch.ready.update(rd)
    sch.unit.update(bd)
    sch.length["term"] = L
    for part in ("setup", "finish"):
        if cfg.host_setup:
            sch.length[part] = 0
            continue
        s2, r2, b2, L2 = schedule_part(g, cfg, part, None)
        sch.start.update(s2)
        sch.ready.update(r2)
        sch.unit.update(b2)
        sch.length[part] = L2
    # storage for term values
    last_use = {}
    for n in term_nodes:
        for a in n.args:
            if g.nodes[a].part == "term":
                last_use[a] = max(last_use.get(a, -1), sch.start[n.id])
    for n in term_nodes:
        if n.op in ("const", "in") or n.id not in last_use:
            continue
        src = g.nodes[n.args[0]] if n.op == "pick" else n
        life = last_use[n.id] - sch.ready[n.id]
        if n.op == "pick" or src.op in RESOURCE_OPS:
            regs = math.ceil((life + 1) / ii) if life >= 1 else 0
        else:
            regs = math.ceil((life + 1) / ii) - 1
        sch.storage_regs[n.id] = max(regs, 0)
    return sch


# ---------------------------------------------------------------------------
def cost_estimate(dp, sch):
    """Rough 7-series style estimate: DSP48E1 (25x18) per multiplier,
    carry-chain LUTs per adder bit, LUT6 muxes, flip-flops per register bit."""
    g, cfg = dp.g, sch.cfg
    wl = cfg.wl
    parts = ("term",) if cfg.host_setup else ("setup", "term", "finish")
    dsp_per_mul = math.ceil(wl / 17) * math.ceil(wl / 24)   # signed partial products
    dsp = cfg.mults * dsp_per_mul
    lut = ff = 0
    width_bits = {"W": wl, "D": 2 * wl, "B": 1, "T": 2 * wl}
    for n in g.nodes:
        if n.part not in parts or n.op in FREE_OPS or n.op in RESOURCE_OPS:
            continue
        w = width_bits.get(n.width, wl)
        ff += w                                   # output register
        if n.op in ("add", "sub", "neg", "abs", "max"):
            lut += w * (2 if n.op in ("abs", "max") else 1)
        elif n.op in ("scale", "refrac"):
            lut += w * (3 if n.op == "scale" else 1)   # barrel (variable) or rounding add
        elif n.op in ("mux",):
            lut += w
        elif n.op in ("norm_e", "adj_shift"):
            lut += w // 2
        elif n.op == "rom":
            lut += w * 2
        else:
            lut += 8
    # storage registers
    ff += sum(sch.storage_regs.values()) * wl
    # multiplier units: 2 operand muxes over the modulo table + rounding barrel shifter
    fan = min(sch.ii, 1 + sum(1 for n in g.nodes if n.part == "term" and n.op == "mul") // max(cfg.mults, 1))
    mux_lut = lambda fanin, bits: bits * max(1, math.ceil((fanin - 1) / 5))
    lut += cfg.mults * (2 * mux_lut(fan, wl) + 7 * 2 * wl // 2)
    ff += cfg.mults * (2 * wl + 2 * wl * 3)
    # CORDIC units: 3 adders (x, y at WL+2+GB; z at WL+1+GB) per stage
    stage_bits = 3 * (wl + 8)
    stages = cfg.lat_cordic if cfg.cordic_pipelined else 1
    for k in (cfg.crot, cfg.cvec):
        lut += k * (stages * stage_bits + (0 if cfg.cordic_pipelined else stage_bits * 2))
        ff += k * stages * stage_bits
    return dict(dsp=dsp, lut=lut, ff=ff)


def report(dp, cfg):
    sch = schedule(dp, cfg)
    c = cost_estimate(dp, sch)
    return dict(mults=cfg.mults, crot=cfg.crot, cvec=cfg.cvec, pipe_cordic=cfg.cordic_pipelined,
                wl=cfg.wl, fl=cfg.fl, host_setup=cfg.host_setup, ii=sch.ii, term_len=sch.length["term"],
                setup_len=sch.length["setup"], finish_len=sch.length["finish"],
                cycles=sch.cycles_per_evaluation(), in_flight=math.ceil(sch.length["term"] / sch.ii),
                storage_regs=sum(sch.storage_regs.values()), **c)


if __name__ == "__main__":
    import heston as H
    rows = []
    for wl, fl in ((64, 32), (56, 28), (48, 24)):
        dp = H.Datapath(wl, fl)
        for mults, pipe, nr, nv, host in ((4, False, 3, 2, True), (4, False, 3, 2, False), (8, False, 3, 2, False),
                                          (8, True, 1, 1, False), (16, True, 1, 1, False), (32, True, 1, 1, False),
                                          (64, True, 1, 1, False), (128, True, 1, 1, False)):
            cfg = Config(wl=wl, fl=fl, mults=mults, cordic_pipelined=pipe, host_setup=host, crot=nr, cvec=nv)
            rows.append(report(dp, cfg))
    keys = ["wl", "fl", "mults", "crot", "cvec", "pipe_cordic", "host_setup", "ii", "term_len", "in_flight",
            "cycles", "dsp", "lut", "ff", "storage_regs"]
    print(" ".join("%8s" % k[:8] for k in keys))
    for r in rows:
        print(" ".join("%8s" % r[k] for k in keys))
