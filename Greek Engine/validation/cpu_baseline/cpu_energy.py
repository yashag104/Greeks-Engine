"""CPU energy per evaluation from the HWiNFO session of 29 Oct 2026.

    python validation/cpu_baseline/cpu_energy.py      -> validation/results/cpu_energy.csv

Readings taken by hand: HWiNFO64 "CPU Package Power", average over each run (counters
reset about 5 s after the start), on an idle Intel Core i5-1155G7 laptop on mains, Windows
"Balanced" power plan; MATLAB and other heavy programs closed. Run times are the shell's
`time` (real) for the whole run, input generation included, so energy per evaluation is
slightly overstated. Energy per evaluation = average package power x run time / evaluations,
i.e. power and throughput from the same run. Throughput on this laptop varies by about
+-25% with temperature (it falls as the machine heats up), which is why the throughput used
for energy is the one measured in the same run as the power.
"""
import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "results", "cpu_energy.csv")
IDLE_W = 5.497
#        run                                  command                                    W      real s   evaluations
RUNS = [("scalar analytic, 1 core", "heston_cpu run analytic 3000000", 7.328, 68.367, 3_000_000),
        ("scalar analytic, 8 processes", "8 x heston_cpu run analytic 1000000", 7.867, 55.480, 8_000_000),
        ("vectorised analytic (SoA), 1 core", "heston_cpu_simd run analytic_soa 4000000", 8.338, 55.241, 4_000_000),
        ("vectorised analytic (SoA), 8 processes", "8 x heston_cpu_simd run analytic_soa 1000000", 8.832, 37.022, 8_000_000)]


def main():
    with open(OUT, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["run", "command", "package_W", "real_s", "evaluations", "evals_per_s", "us_per_eval_wall",
                    "uJ_per_eval_package", "uJ_per_eval_above_idle"])
        w.writerow(["idle", "", IDLE_W, "", "", "", "", "", ""])
        for name, cmd, p, t, n in RUNS:
            e = p * t / n * 1e6
            e_dyn = (p - IDLE_W) * t / n * 1e6
            w.writerow([name, cmd, p, t, n, round(n / t), round(t / n * 1e6, 2), round(e, 1), round(e_dyn, 1)])
            print("%-40s %6.0f eval/s  %6.1f uJ/eval (package)  %5.1f uJ/eval (above idle)" % (name, n / t, e, e_dyn))
    print("wrote", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
