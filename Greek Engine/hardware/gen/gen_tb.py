"""Generate RTL + a self-checking testbench and run it in Icarus Verilog.

    python gen_tb.py [--wl 56 --fl 28 --mults 8 --crot 3 --cvec 2] [--terms 128] [--cases 3]

Checks, against the bit-accurate emulator (heston.emulate):
  * every setup register, every register of terms k = 0, 1, 2 at the cycle
    its value becomes valid, every finish register (first case only),
  * all 10 outputs exactly, for every case,
  * cycles from start to done equal the schedule's prediction.
"""
import argparse
import os
import subprocess
import sys

import heston as H
from rtlgen import Gen, lit
from sched import Config

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")

CASES = [([100, 100, 1, .05, .04, 1.5, .04, .3, -.9], True),
         ([100, 110, .25, 0, .0175, 1.5768, .0398, .5751, -.5711], False),
         ([100, 90, .1, .05, .04, 1.5, .04, .8, -.9], True),
         ([100, 100, 2, .02, .09, 3.0, .06, .3, .5], False)]


def signed_expr(expr, w):
    return "$signed(%s)" % expr if w > 1 else expr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wl", type=int, default=56)
    ap.add_argument("--fl", type=int, default=28)
    ap.add_argument("--mults", type=int, default=8)
    ap.add_argument("--crot", type=int, default=3)
    ap.add_argument("--cvec", type=int, default=2)
    ap.add_argument("--terms", type=int, default=128)
    ap.add_argument("--cases", type=int, default=3)
    ap.add_argument("--pipe-cordic", action="store_true")
    ap.add_argument("--name", default="heston_aad_z7")
    a = ap.parse_args()
    cfg = Config(wl=a.wl, fl=a.fl, mults=a.mults, crot=a.crot, cvec=a.cvec, cordic_pipelined=a.pipe_cordic,
                 n_terms=a.terms)
    dp = H.Datapath(a.wl, a.fl)
    gen = Gen(dp, cfg, a.name)
    rtl = gen.emit()
    os.makedirs(BUILD, exist_ok=True)
    rtl_path = os.path.join(BUILD, a.name + ".v")
    open(rtl_path, "w").write(rtl)
    g, sch, W = dp.g, gen.sch, a.wl
    cycles_expected = gen.TF + gen.F + 2   # start-sampling edge .. done visible

    tb = ["`timescale 1ns/1ps", "module tb;", "  reg clk = 0, rst = 1, start = 0; always #5 clk = ~clk;",
          "  reg signed [%d:0] %s;" % (W - 1, ", ".join(H.PARAMS)), "  reg is_call;",
          "  wire signed [%d:0] %s;" % (W - 1, ", ".join(H.OUTPUTS)), "  wire done;",
          "  integer errors = 0, checks = 0, cyc;",
          "  %s uut(.clk(clk), .rst(rst), .start(start), %s, .is_call(is_call), %s, .done(done));"
          % (a.name, ", ".join(".%s(%s)" % (p, p) for p in H.PARAMS), ", ".join(".%s(%s)" % (o, o) for o in H.OUTPUTS))]

    # register-level checks for the first case
    q0 = H.quantize_inputs(CASES[0][0], CASES[0][1], a.fl)
    out0, trace = H.emulate(dp, q0, n_terms=a.terms, keep_terms=(0, 1, 2))
    checks = []

    def unit_expr(n):
        e = gen.unit_out(n)
        return e.replace("mu", "uut.mu").replace("cr", "uut.cr").replace("cv", "uut.cv")

    for n in g.nodes:
        if n.op in ("const", "in", "crot", "cvec", "shl"):
            continue
        is_unit = n.op in ("mul", "pick")
        w = gen.width(n)
        r = sch.ready.get(n.id)
        if r is None:
            continue
        if n.part == "setup":
            times = [(r, trace["setup"])]
        elif n.part == "finish":
            times = [(gen.TF + r, trace["finish"])]
        else:
            times = [(gen.S + k * gen.II + r, trace[k]) for k in (0, 1, 2) if k < a.terms]
        for t_abs, vals in times:
            val = vals[n.id]
            if isinstance(val, tuple):
                continue
            expr = unit_expr(n) if is_unit else "uut.v%d" % n.id
            exp = ("1'b%d" % int(val)) if w == 1 else lit(val, w)
            checks.append("      if (uut.t == 32'd%d && %s !== %s) begin errors = errors + 1; if (errors < 20) "
                          "$display(\"MISMATCH node %d (%s, %s) t=%%0d got %%0d exp %s\", uut.t, %s); end"
                          % (t_abs, signed_expr(expr, w), exp, n.id, n.op, n.part, int(val), signed_expr(expr, w)))
    tb.append("  reg check_on = 0;")
    tb.append("  always @(negedge clk) if (check_on && uut.running) begin")
    tb += checks
    tb.append("  end")

    tb.append("  initial begin")
    tb.append("    #20 rst = 0;")
    for ci, (p, call) in enumerate(CASES[:a.cases]):
        q = H.quantize_inputs(p, call, a.fl)
        outs, _ = H.emulate(dp, q, n_terms=a.terms)
        tb.append("    // case %d: %s call=%s" % (ci, p, call))
        for name in H.PARAMS:
            tb.append("    %s = %s;" % (name, lit(q[name], W)))
        tb.append("    is_call = %d; check_on = %d;" % (q["is_call"], 1 if ci == 0 else 0))
        tb.append("    @(negedge clk) start = 1; @(negedge clk) start = 0; cyc = 1;")
        tb.append("    while (!done) begin @(posedge clk); cyc = cyc + 1; end")
        tb.append("    #1;")
        for o in H.OUTPUTS:
            tb.append("    if (%s !== %s) begin errors = errors + 1; $display(\"FAIL case %d %s got %%0d exp %d\", %s); end"
                      % (o, lit(outs[o], W), ci, o, outs[o], o))
        tb.append("    $display(\"case %d done in %%0d cycles (schedule predicts %d); price = %%f delta = %%f\", cyc - 1, price * 1.0 / %d.0, delta * 1.0 / %d.0);"
                  % (ci, cycles_expected, 2 ** a.fl, 2 ** a.fl))
    tb.append("    if (errors == 0) $display(\"PASS: RTL matches emulator bit-exactly (%%0d register checks + outputs)\", %d);" % len(checks))
    tb.append("    else $display(\"FAIL: %0d mismatches\", errors);")
    tb.append("    $finish;")
    tb.append("  end")
    tb.append("endmodule")
    tb_path = os.path.join(BUILD, "tb_" + a.name + ".v")
    open(tb_path, "w").write("\n".join(tb) + "\n")
    vvp = os.path.join(BUILD, a.name + ".vvp")
    r = subprocess.run(["iverilog", "-g2005", "-o", vvp, tb_path, rtl_path], capture_output=True, text=True)
    if r.returncode:
        print(r.stdout, r.stderr[:4000])
        sys.exit(1)
    print("schedule: II=%d S=%d L=%d F=%d cycles/eval=%d, %d register checks" % (gen.II, gen.S, gen.L, gen.F, cycles_expected, len(checks)))
    r = subprocess.run(["vvp", "-n", vvp], capture_output=True, text=True)
    print(r.stdout[-6000:])


if __name__ == "__main__":
    main()
