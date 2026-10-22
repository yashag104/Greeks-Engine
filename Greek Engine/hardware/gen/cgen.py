"""C generator for the host steps of a host-setup design (e.g. heston_aad_z7h).

The FPGA runs the 128-term loop; the host computes the per-evaluation
constants before it (setup) and the discounting and final chain rule after it
(finish). host.py specifies both bit-exactly by evaluating the setup and finish
parts of the operation graph in fixed point. This module turns those parts
into straight-line C with the same integer semantics as Graph.eval_fixed, so
the ARM in the Zynq can run them instead of the PC:

    python cgen.py [--check N]
    -> build/heston_host.h, build/heston_host.c          (the host steps)
       build/heston_host_regs.h                          (AXI4-Lite register map)
       --check N: compiles a test program twice (with the compiler's 128-bit
       integers, and with the portable 64x64->128 multiply the 32-bit ARM
       needs), and compares both with host.py on N random in-domain inputs.

Every product is formed exactly in 128 bits and rounded half up, exactly as
rshift_round; values are int64 (the 56-bit words fit with room to spare).
"""
import argparse
import json
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import heston as H                  # noqa: E402
import host                         # noqa: E402
import ranges as RG                 # noqa: E402
from ir import round_half_up        # noqa: E402
from rtlgen import Gen              # noqa: E402
from sched import Config            # noqa: E402

BUILD = os.path.join(HERE, "build")

PRELUDE = r"""
/* ---- exact 128-bit helpers: the 32-bit ARM has no __int128 ---- */
#if defined(__SIZEOF_INT128__) && !defined(HC_PORTABLE)
typedef __int128 hc_i128;
static inline hc_i128 hc_mul(int64_t a, int64_t b) { return (hc_i128)a * b; }
static inline hc_i128 hc_neg(hc_i128 x) { return -x; }
static inline hc_i128 hc_from64(int64_t a) { return a; }
/* round half up: (x + 2^(s-1)) >> s, or x << -s; the result fits 64 bits */
static inline int64_t hc_rshr(hc_i128 x, int s) {
  if (s > 0) return (int64_t)((x + ((hc_i128)1 << (s - 1))) >> s);
  return (int64_t)(x << (-s));
}
#else
typedef struct { uint64_t lo; int64_t hi; } hc_i128;
static inline hc_i128 hc_from64(int64_t a) { hc_i128 r = { (uint64_t)a, a < 0 ? -1 : 0 }; return r; }
static inline hc_i128 hc_neg(hc_i128 x) {
  hc_i128 r; r.lo = ~x.lo + 1; r.hi = ~x.hi + (r.lo == 0); return r;
}
static inline hc_i128 hc_mul(int64_t a, int64_t b) {
  /* signed 64x64 -> 128 from four 32x32 -> 64 products */
  int neg = (a < 0) != (b < 0);
  uint64_t ua = a < 0 ? (uint64_t)0 - (uint64_t)a : (uint64_t)a;
  uint64_t ub = b < 0 ? (uint64_t)0 - (uint64_t)b : (uint64_t)b;
  uint64_t a0 = (uint32_t)ua, a1 = ua >> 32, b0 = (uint32_t)ub, b1 = ub >> 32;
  uint64_t p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  uint64_t mid = (p00 >> 32) + (uint32_t)p01 + (uint32_t)p10;
  hc_i128 r;
  r.lo = (mid << 32) | (uint32_t)p00;
  r.hi = (int64_t)(p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32));
  return neg ? hc_neg(r) : r;
}
static inline hc_i128 hc_add(hc_i128 x, hc_i128 y) {
  hc_i128 r; r.lo = x.lo + y.lo; r.hi = x.hi + y.hi + (r.lo < x.lo); return r;
}
static inline hc_i128 hc_sar(hc_i128 x, int s) {          /* arithmetic, 0 <= s < 128 */
  hc_i128 r;
  if (s == 0) return x;
  if (s < 64) { r.lo = (x.lo >> s) | ((uint64_t)x.hi << (64 - s)); r.hi = x.hi >> s; }
  else { r.lo = (uint64_t)(x.hi >> (s - 64)); r.hi = x.hi < 0 ? -1 : 0; }
  return r;
}
static inline int64_t hc_rshr(hc_i128 x, int s) {
  if (s > 0) {
    hc_i128 h = s - 1 < 64 ? (hc_i128){ (uint64_t)1 << (s - 1), 0 } : (hc_i128){ 0, (int64_t)1 << (s - 65) };
    return (int64_t)hc_sar(hc_add(x, h), s).lo;
  }
  return (int64_t)(x.lo << (-s));                          /* left shift: fits 64 bits */
}
#endif

static inline int64_t hc_round_shift(int64_t v, int s) {   /* rshift_round on a 64-bit value */
  return hc_rshr(hc_from64(v), s);
}
static inline int64_t hc_bitlen(int64_t x) {               /* x >= 0 */
  int n = 0; while (x) { n++; x >>= 1; } return n;
}
"""


def _c_int(v):
    v = int(v)
    if v == -(1 << 63):
        return "INT64_MIN"
    return "INT64_C(%d)" % v


def emit_part(g, part, keep, fin_inputs=None):
    """C statements for one part; keep: node ids whose values the caller needs"""
    lines = []
    tables = {}
    for n in g.nodes:
        if n.part != part:
            continue
        a = ["v%d" % x for x in n.args]
        fa = [g.nodes[x].frac for x in n.args]
        op = n.op
        if op == "in":
            name = n.attrs["name"]
            e = fin_inputs[name] if fin_inputs and name in fin_inputs else "in_%s" % name
        elif op == "const":
            e = _c_int(round_half_up(n.attrs["value"], n.frac))
        elif op == "rom":
            key = (n.attrs["table"], n.frac)
            if key not in tables:
                tables[key] = [round_half_up(x, n.frac) for x in g.tables[n.attrs["table"]]]
            e = "T_%s_%d[%s]" % (key[0], key[1], a[0])
        elif op == "add":
            e = "%s + %s" % (a[0], a[1])
        elif op == "sub":
            e = "%s - %s" % (a[0], a[1])
        elif op == "neg":
            e = "-%s" % a[0]
        elif op == "shl":
            e = "%s * (INT64_C(1) << %d)" % (a[0], n.attrs["n"])
        elif op == "refrac":
            e = "hc_round_shift(%s, %d)" % (a[0], fa[0] - n.frac)
        elif op == "scale":
            e = "hc_round_shift(%s, %d - (int)%s)" % (a[0], fa[0] - n.frac, a[1])
        elif op == "abs":
            e = "(%s < 0 ? -%s : %s)" % (a[0], a[0], a[0])
        elif op == "max":
            e = "(%s >= %s ? %s : %s)" % (a[0], a[1], a[0], a[1])
        elif op == "mux":
            e = "(%s ? %s : %s)" % (a[0], a[1], a[2])
        elif op == "is_neg":
            e = "(%s < 0)" % a[0]
        elif op == "eq0":
            e = "(%s == 0)" % a[0]
        elif op == "bit0":
            e = "(%s & 1)" % a[0]
        elif op == "ishr":
            e = "(%s >> %d)" % (a[0], n.attrs["n"])          # arithmetic shift (gcc, clang)
        elif op == "iand":
            e = "(%s & %s)" % (a[0], _c_int(n.attrs["mask"]))
        elif op == "norm_e":
            ev = n.attrs["even"]
            e = "hc_norm_e(%s, %d, %d)" % (a[0], fa[0], 1 if ev else 0)
        elif op == "idx":
            nb, mf = n.attrs["nbits"], g.mf
            sh = (mf + 2 - nb) if n.attrs["span4"] else (mf - nb)
            e = "((%s >> %d) & %d)" % (a[0], sh, (1 << nb) - 1)
        elif op == "mul":
            if n.attrs.get("raw"):
                raise ValueError("raw product in a host part")
            p = "hc_mul(%s, %s)" % (a[0], a[1])
            if n.attrs.get("negate"):
                p = "hc_neg(%s)" % p
            sh = "%d" % (fa[0] + fa[1] - n.frac)
            if len(a) == 3:
                sh = "%s - (int)%s" % (sh, a[2])
            e = "hc_rshr(%s, %s)" % (p, sh)
        else:
            raise ValueError("op %s not supported on the host" % op)
        lines.append("  const int64_t v%d = %s;" % (n.id, e))
    return lines, tables


def generate(name="heston_aad_z7h"):
    cfg = Config(wl=56, fl=28, mults=8, crot=3, cvec=2, cordic_pipelined=False, host_setup=True)
    dp = H.Datapath(56, 28)
    gen = Gen(dp, cfg, name)
    gen.emit()
    g = dp.g
    fin_from_setup = sorted({a for n in g.nodes if n.part == "finish" for a in n.args
                             if g.nodes[a].part == "setup"})
    s_lines, s_tab = emit_part(g, "setup", None)
    f_lines, f_tab = emit_part(g, "finish", None, {"acc_" + a: "sums[%d]" % i for i, a in enumerate(dp.acc_names)})
    ports = sorted(gen.host_inputs.items(), key=lambda kv: kv[1])
    tables = {**s_tab, **f_tab}

    h = ["/* Generated by hardware/gen/cgen.py from the operation graph -- do not edit. */",
         "#ifndef HESTON_HOST_H", "#define HESTON_HOST_H", "#include <stdint.h>", "",
         "/* fixed point: %d-bit words, %d fraction bits (Q%d.%d) */" % (g.wl, g.fl, g.wl - g.fl, g.fl),
         "#define HC_WL %d" % g.wl, "#define HC_FL %d" % g.fl,
         "#define HC_NPORTS %d       /* host constants written to the FPGA */" % len(ports),
         "#define HC_NSUMS %d        /* sums read back from the FPGA */" % len(dp.acc_names),
         "#define HC_NOUT %d         /* price + 9 Greeks */" % len(dp.outputs),
         "/* parameter order: %s, is_call (0/1) */" % ", ".join(H.PARAMS),
         "/* host constants, in port order: %s */" % " ".join(p for _, p in ports),
         "/* sums, in order: %s */" % " ".join(dp.acc_names),
         "/* outputs, in order: %s */" % " ".join(dp.outputs),
         "typedef struct { int64_t s[%d]; } hc_ctx;   /* setup values that finish needs */" % len(fin_from_setup), "",
         "/* params[9] are the inputs already quantised: round(x * 2^HC_FL) */",
         "void hc_setup(const int64_t params[9], int is_call, hc_ctx *ctx, int64_t ports[HC_NPORTS]);",
         "void hc_finish(const hc_ctx *ctx, const int64_t sums[HC_NSUMS], int64_t out[HC_NOUT]);",
         "#endif", ""]
    c = ["/* Generated by hardware/gen/cgen.py from the operation graph -- do not edit.",
         " * Bit-exact with hardware/gen/host.py (setup_ports, finish). */",
         "#include <stdint.h>", '#include "heston_host.h"', PRELUDE,
         "static inline int64_t hc_norm_e(int64_t x, int frac, int even) {",
         "  int64_t ax = x < 0 ? -x : x;",
         "  int64_t e = (ax ? hc_bitlen(ax) - 1 : 0) - frac;",
         "  if (even) e -= ((e % 2) + 2) % 2;                     /* Python's e % 2 is never negative */",
         "  return e;", "}", ""]
    for (tname, frac), vals in sorted(tables.items()):
        c.append("static const int64_t T_%s_%d[%d] = {" % (tname, frac, len(vals)))
        for i in range(0, len(vals), 4):
            c.append("  " + ", ".join(_c_int(v) for v in vals[i:i + 4]) + ",")
        c.append("};")
    c += ["", "void hc_setup(const int64_t params[9], int is_call, hc_ctx *ctx, int64_t ports[HC_NPORTS]) {"]
    c += ["  const int64_t in_%s = params[%d];" % (p, i) for i, p in enumerate(H.PARAMS)]
    c += ["  const int64_t in_is_call = is_call ? 1 : 0;"]
    c += s_lines
    c += ["  ports[%d] = v%d;   /* %s */" % (i, nid, p) for i, (nid, p) in enumerate(ports)]
    c += ["  ctx->s[%d] = v%d;" % (i, nid) for i, nid in enumerate(fin_from_setup)]
    c += ["}", "", "void hc_finish(const hc_ctx *ctx, const int64_t sums[HC_NSUMS], int64_t out[HC_NOUT]) {"]
    c += ["  const int64_t v%d = ctx->s[%d];" % (nid, i) for i, nid in enumerate(fin_from_setup)]
    c += f_lines
    c += ["  out[%d] = v%d;   /* %s */" % (i, dp.finish[o], o) for i, o in enumerate(dp.outputs)]
    c += ["}", ""]
    # unused-variable warnings are expected for setup values only feeding ports
    os.makedirs(BUILD, exist_ok=True)
    open(os.path.join(BUILD, "heston_host.h"), "w").write("\n".join(h))
    open(os.path.join(BUILD, "heston_host.c"), "w").write("\n".join(c))
    regs = json.load(open(os.path.join(BUILD, name + "_lite_regs.json")))
    r = ["/* AXI4-Lite register map of %s_lite (byte offsets). Generated by cgen.py. */" % name,
         "#ifndef HESTON_HOST_REGS_H", "#define HESTON_HOST_REGS_H"]
    for k, v in sorted(regs.items(), key=lambda kv: kv[1]["offset"]):
        r.append("#define HC_REG_%s 0x%03x   /* %d word(s), %s */" % (k.upper(), v["offset"], v["words"], v["dir"]))
    r += ["static const unsigned hc_param_regs[9] = { %s };" % ", ".join("HC_REG_%s" % p.upper() for p in H.PARAMS),
          "static const unsigned hc_port_regs[HC_NPORTS_REGS] = { %s };" % ", ".join(
              "HC_REG_%s" % p.upper() for _, p in ports),
          "static const unsigned hc_sum_regs[%d] = { %s };" % (len(dp.acc_names), ", ".join(
              "HC_REG_SUM_%s" % a.upper() for a in dp.acc_names)), "#endif", ""]
    r = [x.replace("HC_NPORTS_REGS", str(len(ports))) for x in r]
    open(os.path.join(BUILD, "heston_host_regs.h"), "w").write("\n".join(r))
    return dp, gen


def check(dp, gen, n):
    """compile twice (native 128-bit, portable 64x64) and compare with host.py"""
    rng = random.Random(20261021)
    cases = [(p, c) for p, c in [([100, 100, 1, .05, .04, 1.5, .04, .3, -.9], True),
                                 ([100, 110, .25, 0, .0175, 1.5768, .0398, .5751, -.5711], False)]]
    while len(cases) < n:
        cases.append(([rng.uniform(*RG.DOMAIN[p]) for p in H.PARAMS], rng.random() < 0.5))
    lines = []
    for p, call in cases:
        q = H.quantize_inputs(p, call, dp.g.fl)
        ports = host.setup_ports(dp, gen, p, call)
        # sums: any integers exercise finish; random ones of realistic size, plus the
        # real loop sums for the two fixed cases (emulated)
        if len(lines) < 2:
            _, tr = H.emulate(dp, q)
            sums = [tr["acc"][a] for a in dp.acc_names]
        else:
            sums = [rng.randrange(-(1 << 40), 1 << 40) for _ in dp.acc_names]
        out = host.finish(dp, p, call, dict(zip(dp.acc_names, sums)))
        row = [q[nm] for nm in H.PARAMS] + [q["is_call"]] + [ports[pt] for _, pt in sorted(
            gen.host_inputs.items(), key=lambda kv: kv[1])] + sums + [out[o] for o in dp.outputs]
        lines.append(" ".join(str(int(x)) for x in row))
    vec = os.path.join(BUILD, "heston_host_vectors.txt")
    open(vec, "w").write("%d\n" % len(lines) + "\n".join(lines) + "\n")
    test = os.path.join(BUILD, "heston_host_test.c")
    open(test, "w").write(r"""
#include <stdio.h>
#include <inttypes.h>
#include "heston_host.h"
int main(int argc, char **argv) {
  FILE *f = fopen(argv[1], "r"); int n, bad = 0;
  if (!f || fscanf(f, "%d", &n) != 1) return 2;
  for (int c = 0; c < n; c++) {
    int64_t p[9], call, ports[HC_NPORTS], sums[HC_NSUMS], want_p[HC_NPORTS], want_o[HC_NOUT], out[HC_NOUT];
    hc_ctx ctx;
    for (int i = 0; i < 9; i++) (void)!fscanf(f, "%" SCNd64, &p[i]);
    (void)!fscanf(f, "%" SCNd64, &call);
    for (int i = 0; i < HC_NPORTS; i++) (void)!fscanf(f, "%" SCNd64, &want_p[i]);
    for (int i = 0; i < HC_NSUMS; i++) (void)!fscanf(f, "%" SCNd64, &sums[i]);
    for (int i = 0; i < HC_NOUT; i++) (void)!fscanf(f, "%" SCNd64, &want_o[i]);
    hc_setup(p, (int)call, &ctx, ports);
    hc_finish(&ctx, sums, out);
    for (int i = 0; i < HC_NPORTS; i++) if (ports[i] != want_p[i]) { bad++; printf("case %d port %d: %" PRId64 " want %" PRId64 "\n", c, i, ports[i], want_p[i]); }
    for (int i = 0; i < HC_NOUT; i++) if (out[i] != want_o[i]) { bad++; printf("case %d out %d: %" PRId64 " want %" PRId64 "\n", c, i, out[i], want_o[i]); }
  }
  printf("%s: %d cases, %d mismatches\n", bad ? "FAIL" : "PASS", n, bad);
  return bad != 0;
}
""")
    ok = True
    for label, flags in (("native 128-bit", []), ("portable 64x64->128 (as on the 32-bit ARM)", ["-DHC_PORTABLE"])):
        exe = os.path.join(BUILD, "heston_host_test" + ("_portable" if flags else ""))
        subprocess.run(["gcc", "-O2", "-std=c99", "-Wall", "-Wno-unused-variable", "-I", BUILD] + flags +
                       [os.path.join(BUILD, "heston_host.c"), test, "-o", exe], check=True)
        r = subprocess.run([exe, vec], capture_output=True, text=True)
        print("%-44s %s" % (label, r.stdout.strip().splitlines()[-1]))
        ok &= r.returncode == 0
    return ok


def cases_header(dp, nifty_csv):
    """the ARM test's cases: the 50-case board sweep (seed 2026) and the 50 real
    NIFTY days, with the emulator's 10 outputs (host + FPGA == on-chip, host.py)"""
    from board_vectors import csv_cases, sweep_cases
    cases = sweep_cases(dp, 48, 2026)[0] + csv_cases(nifty_csv)
    rows = []
    for i, (p, call) in enumerate(cases):
        q = H.quantize_inputs(p, call, dp.g.fl)
        out, tr = H.emulate(dp, q)
        rows.append("  {{%s}, %d, {%s}, {%s}},   /* %s */" % (
            ", ".join(_c_int(q[nm]) for nm in H.PARAMS), q["is_call"],
            ", ".join(_c_int(tr["acc"][a]) for a in dp.acc_names),
            ", ".join(_c_int(out[o]) for o in dp.outputs),
            "board sweep %d" % (i + 1) if i < 50 else "NIFTY day %d" % (i - 49)))
        print("case %d/%d" % (i + 1, len(cases)), flush=True)
    h = ["/* Generated by hardware/gen/cgen.py --cases: inputs and the emulator's outputs. */",
         "#ifndef HESTON_HOST_CASES_H", "#define HESTON_HOST_CASES_H", "#include <stdint.h>",
         "/* sums: the FPGA loop's 9 sums (for the PC test only); want: the 10 outputs */",
         "typedef struct { int64_t p[9]; int is_call; int64_t sums[%d]; int64_t want[%d]; } hc_case;" % (
             len(dp.acc_names), len(dp.outputs)),
         "#define HC_NCASES %d   /* 1-50: board sweep (seed 2026); 51-100: real NIFTY days */" % len(rows),
         "static const hc_case hc_cases[HC_NCASES] = {"] + rows + ["};", "#endif", ""]
    open(os.path.join(BUILD, "heston_host_cases.h"), "w").write("\n".join(h))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", type=int, default=0)
    ap.add_argument("--cases", help="also write build/heston_host_cases.h from the board sweep and this NIFTY csv")
    a = ap.parse_args()
    dp, gen = generate()
    print("wrote build/heston_host.h, heston_host.c, heston_host_regs.h")
    if a.cases:
        cases_header(dp, a.cases)
    if a.check:
        sys.exit(0 if check(dp, gen, a.check) else 1)
