"""Vectorised CPU baselines: hand-derived analytic Greeks, SIMD across COS terms.

    .venv/bin/python validation/cpu_baseline/run_simd.py      (on an idle machine)
    -> validation/results/cpu_simd.csv

The plain build (-O3 -march=native, run_baseline.py) leaves the 128-term loop of
the analytic method scalar: the compiler vectorises only its 9-element inner loop
(check with -fopt-info-vec). Two vectorised variants, same mathematics,
built with -Ofast -fopenmp-simd -lmvec (transcendentals from glibc's vector math
library): m_analytic_simd, the single loop made branch-free (it vectorises but spills
its ~100 live complex temporaries, and is slower), and m_analytic_soa, the same work
split into seven short loops over arrays of the 128 terms (structure of arrays),
which vectorise cleanly. The paper's vectorised baseline is the faster of the two. Both builds are timed in the
same session (best of several runs, each the best of 5 passes over 2,000 inputs),
and the SIMD results are checked against forward mode on the same 2,000 inputs.
"""
import csv
import os
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
CODI = os.path.join(HERE, "build", "CoDiPack", "include")
SRC = os.path.join(HERE, "heston_cpu.cpp")
BIN_O3 = os.path.join(HERE, "build", "heston_cpu")
BIN_SIMD = os.path.join(HERE, "build", "heston_cpu_simd")


def build():
    subprocess.run(["g++", "-O3", "-march=native", "-std=c++17", "-I", CODI, SRC, "-o", BIN_O3], check=True)
    rep = subprocess.run(["g++", "-Ofast", "-march=native", "-fopenmp-simd", "-std=c++17", "-I", CODI,
                          "-fopt-info-vec-optimized", SRC, "-o", BIN_SIMD, "-lmvec"],
                         check=True, capture_output=True, text=True).stderr
    src = open(SRC).read().splitlines()
    loop = next(i for i, l in enumerate(src, 1) if "#pragma omp simd" in l)   # gcc reports the pragma's line
    vec = [l for l in rep.splitlines() if (":%d:" % loop in l or ":%d:" % (loop + 1) in l) and "loop vectorized" in l]
    syms = subprocess.run(["nm", "-D", BIN_SIMD], capture_output=True, text=True).stdout
    mvec = sorted({w for w in syms.split() if w.startswith("_ZGV")})
    return vec, mvec


def best_us(binary, method, runs=15, n=2000):
    best = 1e30
    for _ in range(runs):
        out = subprocess.run([binary, "time", str(n)], capture_output=True, text=True, check=True).stdout
        for l in out.splitlines():
            if l.split()[0] == method:
                best = min(best, float(l.split()[1]))
    return best


def throughput(binary, method, procs=8, n=200000):
    """one 8-process run. A laptop's sustained clock falls as it heats, so methods
    timed one after another drift; main() interleaves them (see cpu_energy.py)"""
    t0 = time.perf_counter()
    ps = [subprocess.Popen([binary, "run", method, str(n)], stdout=subprocess.DEVNULL) for _ in range(procs)]
    for p in ps:
        p.wait()
    return procs * n / (time.perf_counter() - t0)


def throughput_interleaved(cases, rounds=3):
    """best of several rounds, the methods taking turns within each round"""
    best = {}
    for _ in range(rounds):
        for key, binary, method in cases:
            best[key] = max(best.get(key, 0.0), throughput(binary, method))
    return best


def main():
    vec, mvec = build()
    print("term loop vectorised:", vec[0].split(": ", 1)[1] if vec else "NO")
    print("libmvec symbols:", " ".join(mvec))
    agree = subprocess.run([BIN_SIMD, "agree", "2000"], capture_output=True, text=True, check=True).stdout
    diff = {l.split()[0]: float(l.split()[1]) for l in agree.splitlines()}
    print("worst difference from forward mode over 2,000 inputs: analytic_simd %.1e, analytic_soa %.1e"
          % (diff["analytic_simd"], diff["analytic_soa"]))
    lat = {k: best_us(b, k) for k, b in (("analytic", BIN_O3), ("analytic_simd", BIN_SIMD), ("analytic_soa", BIN_SIMD))}
    tp = throughput_interleaved([("analytic", BIN_O3, "analytic"), ("analytic_simd", BIN_SIMD, "analytic_simd"),
                                 ("analytic_soa", BIN_SIMD, "analytic_soa")])
    rows = [("analytic, -O3 (scalar term loop)", lat["analytic"], tp["analytic"], "analytic"),
            ("analytic_simd, one loop, -Ofast + libmvec", lat["analytic_simd"], tp["analytic_simd"], "analytic_simd"),
            ("analytic_soa, seven loops, -Ofast + libmvec", lat["analytic_soa"], tp["analytic_soa"], "analytic_soa")]
    for name, us, tp, _ in rows:
        print("%-36s %7.2f us/eval (one core)  %9.0f eval/s (8 processes)" % (name, us, tp))
    out = os.path.join(ROOT, "validation", "results", "cpu_simd.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["method", "us_per_eval_one_core", "evals_per_s_8_processes", "worst_diff_vs_fwdvec_2000_inputs"])
        for name, us, tp, key in rows:
            w.writerow([name, "%.3f" % us, "%.0f" % tp, "%.1e" % diff[key]])
        w.writerow(["vectorised", vec[0].split(": ", 1)[1] if vec else "no", "", ""])
    print("wrote", out)


if __name__ == "__main__":
    main()
