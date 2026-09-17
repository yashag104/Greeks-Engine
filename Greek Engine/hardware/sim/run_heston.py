"""Run the Heston RTL (AAD engine or bump-and-reprice baseline) in Icarus Verilog.

    from run_heston import run_cases
    rows = run_cases(cases, engine="aad", fl=32)

Each case is a dict of float model parameters (S0, K, T, r, v0, kappa, theta,
xi, rho, is_call) plus, for engine="bump", absolute bump sizes h_<param>.
Cases are split across worker processes (one vvp per chunk). Every returned
row holds the dequantized inputs actually simulated (inputs are rounded to
the Q format), the clock-cycle count from start to done, and the outputs as
floats.

Command line (smoke test):  python run_heston.py [--engine aad|bump] [--fl 32]
"""
import argparse
import os
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
VERILOG = os.path.normpath(os.path.join(HERE, "..", "verilog"))
BUILD = os.path.join(HERE, "build")

PARAMS = ["S0", "K", "T", "r", "v0", "kappa", "theta", "xi", "rho"]
OUTPUTS = ["price", "delta", "strike_sens", "theta_greek", "rho_greek", "vega",
           "kappa_sens", "theta_sens", "xi_sens", "rho_corr"]
# RTL output name -> derivative w.r.t. which parameter
SENS_PARAM = {"delta": "S0", "strike_sens": "K", "theta_greek": "T", "rho_greek": "r",
              "vega": "v0", "kappa_sens": "kappa", "theta_sens": "theta",
              "xi_sens": "xi", "rho_corr": "rho"}

SOURCES = ["heston_top_level.v", "heston_bump_top.v", "heston_cos_forward.v",
           "heston_char_func.v", "heston_payoff_coeff.v", "complex_add_sub.v",
           "complex_div.v", "complex_exp.v", "complex_log.v", "complex_mult.v",
           "complex_sqrt.v", "cordic.v", "fp_div.v", "fp_exp.v", "fp_log.v",
           "fp_sqrt.v"]


def word_length(fl):
    """Integer part is fixed at 32 bits (headroom analysis: |u_k|^2 * xi^2 and
    the COS accumulators need ~20 integer bits); only the fraction varies."""
    return fl + 32


def build(engine="aad", fl=32):
    os.makedirs(BUILD, exist_ok=True)
    out = os.path.join(BUILD, "heston_%s_fl%d.vvp" % (engine, fl))
    srcs = [os.path.join(VERILOG, s) for s in SOURCES]
    tb = os.path.join(VERILOG, "tb", "heston_run_tb.v")
    newest = max(os.path.getmtime(p) for p in srcs + [tb, os.path.join(VERILOG, "fx_lib.vh")])
    if os.path.exists(out) and os.path.getmtime(out) > newest:
        return out
    # the case file is opened relative to vvp's working directory
    cmd = ["iverilog", "-g2005", "-I", VERILOG, "-o", out, "-DCASEFILE=\"cases.txt\"",
           "-Pheston_run_tb.WL=%d" % word_length(fl), "-Pheston_run_tb.FL=%d" % fl]
    if engine == "bump":
        cmd.append("-DBUMP")
    cmd += [tb] + srcs
    subprocess.run(cmd, check=True)
    return out


def _q(v, fl):
    return int(round(v * (1 << fl)))


def _run_chunk(vvp, chunk, fl):
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "cases.txt"), "w") as f:
            for i, c in chunk:
                vals = [i] + [_q(c[p], fl) for p in PARAMS] + [1 if c.get("is_call", 1) else 0]
                vals += [_q(c.get("h_" + p, 0.0), fl) for p in PARAMS]
                f.write(" ".join(str(v) for v in vals) + "\n")
        res = subprocess.run(["vvp", "-n", vvp], cwd=d, capture_output=True, text=True, check=True)
    rows = {}
    scale = float(1 << fl)
    for line in res.stdout.splitlines():
        p = line.split()
        if not p or p[0] != "RES":
            continue
        idx, cycles = int(p[1]), int(p[2])
        # an 'x'/'z' output means the RTL produced undefined bits: keep it
        # visible as NaN rather than aborting the whole sweep
        rows[idx] = dict(cycles=cycles, **{name: (int(v) / scale if v.lstrip("-").isdigit() else float("nan"))
                                            for name, v in zip(OUTPUTS, p[3:])})
    return rows


def run_cases(cases, engine="aad", fl=32, workers=None):
    vvp = build(engine, fl)
    workers = workers or os.cpu_count() or 4
    indexed = list(enumerate(cases))
    chunks = [indexed[k::workers] for k in range(workers)]
    chunks = [c for c in chunks if c]
    out = {}
    with ThreadPoolExecutor(len(chunks)) as ex:
        for part in ex.map(lambda c: _run_chunk(vvp, c, fl), chunks):
            out.update(part)
    rows = []
    scale = float(1 << fl)
    for i, c in indexed:
        if i not in out:
            raise RuntimeError("case %d produced no result" % i)
        row = {"id": i, "engine": engine, "fl": fl, "is_call": c.get("is_call", 1)}
        row.update({p: _q(c[p], fl) / scale for p in PARAMS})           # simulated inputs
        row.update({"h_" + p: _q(c.get("h_" + p, 0.0), fl) / scale for p in PARAMS})
        row.update(out[i])
        rows.append(row)
    return rows


BASE_CASE = dict(S0=100.0, K=100.0, T=1.0, r=0.05, v0=0.04, kappa=1.5,
                 theta=0.04, xi=0.3, rho=-0.9, is_call=1)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="aad", choices=["aad", "bump"])
    ap.add_argument("--fl", type=int, default=32)
    a = ap.parse_args()
    case = dict(BASE_CASE)
    for p in PARAMS:
        case["h_" + p] = 1e-3 * max(abs(case[p]), 1e-2)
    for row in run_cases([case], a.engine, a.fl, workers=1):
        for k, v in row.items():
            print("%-12s %s" % (k, v))
