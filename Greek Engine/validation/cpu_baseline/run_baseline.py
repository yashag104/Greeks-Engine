"""CPU baseline for the Greeks Engine: build, check, time.

    .venv/bin/python validation/cpu_baseline/run_baseline.py
    -> validation/results/cpu_baseline.csv and a summary on stdout

1. Builds heston_cpu.cpp with g++ -O3 -march=native against CoDiPack v2.3.2
   (fetched into build/ if missing; not committed).
2. Checks every method's price and 9 Greeks at the base case against the
   project's double-precision reference (heston_reference.cos_price /
   cos_greeks with parity=True, the algorithm the hardware implements), and
   every method against forward mode on 2,000 random in-domain inputs.
3. Times each method on one core (best of 5 passes over 2,000 in-domain
   parameter sets), then measures throughput with 1..N concurrent processes
   (independent processes, so CoDiPack's global tape needs no thread safety).

The FPGA figures it prints for comparison come from the Vivado and board
results already recorded in docs/architecture.md.
"""
import csv
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "validation", "reference"))
import heston_reference as ref  # noqa: E402

BUILD = os.path.join(HERE, "build")
CODI = os.path.join(BUILD, "CoDiPack")
BIN = os.path.join(BUILD, "heston_cpu")
METHODS = ["price", "bump", "bumpopt", "aad", "fwdvec", "analytic"]
NAMES = ["price", "delta", "strike_sens", "theta_greek", "rho_greek", "vega",
         "kappa_sens", "theta_sens", "xi_sens", "rho_corr"]

# FPGA reference points (docs/architecture.md): host-setup design, 4,572 cycles per
# evaluation, one evaluation at a time.
FPGA = {"cycles": 4572, "mhz_board": 70.0, "mhz_fmax": 79.1, "watts_board": 0.341}


def build():
    if not os.path.isdir(CODI):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", "v2.3.2",
                        "https://github.com/SciCompKL/CoDiPack", CODI], check=True)
    subprocess.run(["g++", "-O3", "-march=native", "-std=c++17", "-I", os.path.join(CODI, "include"),
                    os.path.join(HERE, "heston_cpu.cpp"), "-o", BIN], check=True)
    ver = subprocess.run(["g++", "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    cpu = [l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")]
    return ver, cpu[0], len(cpu)


def check():
    base = [100, 100, 1, .05, .04, 1.5, .04, .3, -.9]
    want = [ref.cos_price(base, True)] + list(ref.cos_greeks(base, True))
    out = subprocess.run([BIN, "check"], capture_output=True, text=True, check=True).stdout
    worst = {}
    for line in out.splitlines():
        f = line.split()
        m, vals = f[0], [float(x) for x in f[1:]]
        n = 1 if m == "price" else 10
        worst[m] = max(abs(vals[i] - want[i]) / max(abs(want[i]), 1e-12) for i in range(n))
    return worst


def single_core(n=2000, runs=15):
    """best of several runs, each itself the best of 5 passes: a laptop's other
    work only ever slows a pass down, so the minimum is the cleanest figure"""
    best = {}
    for _ in range(runs):
        out = subprocess.run([BIN, "time", str(n)], capture_output=True, text=True, check=True).stdout
        for l in out.splitlines():
            m, us = l.split()[0], float(l.split()[1])
            best[m] = min(best.get(m, us), us)
    return best


def agree(n=2000):
    out = subprocess.run([BIN, "agree", str(n)], capture_output=True, text=True, check=True).stdout
    return {l.split()[0]: float(l.split()[1]) for l in out.splitlines()}


def throughput(method, procs, n):
    t0 = time.perf_counter()
    ps = [subprocess.Popen([BIN, "run", method, str(n)], stdout=subprocess.DEVNULL) for _ in range(procs)]
    for p in ps:
        p.wait()
    return procs * n / (time.perf_counter() - t0)


def main():
    ver, cpu, ncpu = build()
    print("CPU: %s, %d logical cores; %s -O3 -march=native; CoDiPack v2.3.2" % (cpu, ncpu, ver))
    worst = check()
    print("\nCorrectness at the base case (max relative difference from the Python reference):")
    for m in METHODS:
        print("  %-8s %.1e" % (m, worst[m]))
    agr = agree()
    print("Worst difference from forward mode over 2,000 random in-domain inputs:")
    for m, v in agr.items():
        print("  %-8s %.1e" % (m, v))
    lat = single_core()
    fpga_board = FPGA["cycles"] / FPGA["mhz_board"]
    fpga_fmax = FPGA["cycles"] / FPGA["mhz_fmax"]
    print("\nOne core, microseconds per evaluation (price + 9 Greeks unless noted):")
    for m in METHODS:
        print("  %-8s %8.2f%s" % (m, lat[m], "   (price only)" if m == "price" else ""))
    print("  FPGA    %8.2f   (ZedBoard, 70 MHz)   %.2f at the routed 79.1 MHz" % (fpga_board, fpga_fmax))
    rows = []
    print("\nThroughput, evaluations per second, independent processes:")
    for m in ("aad", "fwdvec", "analytic"):
        n = 4000 if m != "analytic" else 16000
        for procs in sorted({1, 2, 4, ncpu}):
            tp = throughput(m, procs, n)
            rows.append(dict(method=m, processes=procs, evals_per_s=round(tp)))
            print("  %-7s %d proc: %9.0f" % (m, procs, tp))
    print("  FPGA    1 engine: %9.0f (70 MHz)  %9.0f (79.1 MHz)" % (1e6 / fpga_board, 1e6 / fpga_fmax))
    out = os.path.join(ROOT, "validation", "results", "cpu_baseline.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["cpu", cpu]); w.writerow(["compiler", ver]); w.writerow(["logical_cores", ncpu])
        w.writerow([]); w.writerow(["method", "us_per_eval_one_core", "max_rel_diff_vs_reference", "worst_diff_vs_fwdvec_2000_inputs"])
        for m in METHODS:
            w.writerow([m, "%.3f" % lat[m], "%.1e" % worst[m], "%.1e" % agr[m] if m in agr else ""])
        w.writerow(["fpga_70MHz", "%.3f" % fpga_board, ""]); w.writerow(["fpga_79.1MHz", "%.3f" % fpga_fmax, ""])
        w.writerow([]); w.writerow(["method", "processes", "evals_per_s"])
        for r in rows:
            w.writerow([r["method"], r["processes"], r["evals_per_s"]])
    print("\nwrote %s" % out)


if __name__ == "__main__":
    main()
