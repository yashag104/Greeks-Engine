"""Figures for the IEEE paper (docs/paper/greeks_engine_ieee.tex), from validation/results.

    .venv/bin/python docs/paper/make_paper_figures.py      -> docs/paper/figures/*.pdf

IEEE layout: single column 3.5 in, double column 7.16 in, serif text at 8 pt,
vector PDF, and series that stay distinguishable in greyscale (hatching and
markers as well as colour). Every number is read from the CSVs the validation
scripts wrote; nothing is typed in here except the CPU and FPGA latencies, which
come from validation/results/cpu_baseline.csv and the cycle counts.
"""
import csv
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.normpath(os.path.join(HERE, "..", "..", "validation", "results"))
OUT = os.path.join(HERE, "figures")
os.makedirs(OUT, exist_ok=True)

COL1, COL2 = 3.5, 7.16
plt.rcParams.update({
    "font.family": "serif", "font.serif": ["Times New Roman", "Times", "STIXGeneral", "DejaVu Serif"],
    "mathtext.fontset": "stix", "font.size": 8, "axes.labelsize": 8, "axes.titlesize": 8,
    "xtick.labelsize": 7, "ytick.labelsize": 7, "legend.fontsize": 7, "lines.linewidth": 1.0,
    "axes.linewidth": 0.6, "grid.linewidth": 0.4, "grid.alpha": 0.5, "savefig.bbox": "tight",
    "savefig.pad_inches": 0.02, "pdf.fonttype": 42,
})
# colour-blind-safe (Okabe-Ito), each also given a hatch or marker for greyscale print
C_ADJ, C_BUMP, C_PRICE, C_FWD, C_CPU = "#0072B2", "#D55E00", "#999999", "#E69F00", "#555555"
OUTPUTS = ["price", "delta", "strike_sens", "theta_greek", "rho_greek", "vega", "kappa_sens",
           "theta_sens", "xi_sens", "rho_corr"]
LABEL = {"price": r"$V$", "delta": r"$\partial_{S_0}$", "strike_sens": r"$\partial_K$", "theta_greek": r"$\partial_T$",
         "rho_greek": r"$\partial_r$", "vega": r"$\partial_{v_0}$", "kappa_sens": r"$\partial_\kappa$",
         "theta_sens": r"$\partial_\theta$", "xi_sens": r"$\partial_\xi$", "rho_corr": r"$\partial_\rho$"}


def rows(name):
    with open(os.path.join(RES, name)) as f:
        return [r for r in csv.DictReader(line for line in f if not line.startswith("#"))]


def save(fig, name):
    fig.savefig(os.path.join(OUT, name + ".pdf"))
    plt.close(fig)
    print("wrote figures/%s.pdf" % name)


# ---- Fig. cycles: price only / adjoint / bump-and-reprice on the same hardware ----------
def fig_cycles():
    g = {(r["family"], int(r["mults"])): r for r in rows("gen_cycles.csv")}
    cfgs = [(("z7", 8), "56-bit, 8 mult.\n(Zynq-7020)"), (("zu", 32), "64-bit, 32 mult.\n(Zynq US+)")]
    x = np.arange(len(cfgs))
    w = 0.25
    fig, ax = plt.subplots(figsize=(COL1, 1.9))
    series = [("cycles_price", "Price only", C_PRICE, ""), ("cycles_aad", "Price + 9 Greeks, adjoint (this work)", C_ADJ, ""),
              ("cycles_bump", "Price + 9 Greeks, bump-and-reprice", C_BUMP, "////")]
    for i, (key, lab, col, hatch) in enumerate(series):
        vals = [int(g[c][key]) for c, _ in cfgs]
        b = ax.bar(x + (i - 1) * w, vals, w, label=lab, color=col, hatch=hatch, edgecolor="black", linewidth=0.4)
        for rect, v in zip(b, vals):
            ax.text(rect.get_x() + rect.get_width() / 2, v * 1.12, "{:,}".format(v), ha="center", va="bottom", fontsize=6)
    ax.set_yscale("log")
    ax.set_ylim(500, 3e5)
    ax.set_xticks(x)
    ax.set_xticklabels([l for _, l in cfgs])
    ax.set_ylabel("Clock cycles per evaluation")
    ax.grid(axis="y", which="major")
    ax.set_axisbelow(True)
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.0), frameon=False, ncol=1)
    save(fig, "fig_cycles")


# ---- Fig. modes: adjoint against forward-mode datapaths ---------------------------------
def fig_modes():
    m = [r for r in rows("mode_baselines.csv") if r["family"] == "z7" and r["mults"] == "8"]
    names = {"price only": "Price only", "adjoint": "Adjoint (this work)", "forward factored (analytic)": "Fwd., factored",
             "forward sparse": "Fwd., sparse", "forward dense (AD tool)": "Fwd., dense"}
    cols = {"price only": C_PRICE, "adjoint": C_ADJ}
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(COL1, 1.55), sharey=True)
    y = np.arange(len(m))[::-1]
    for ax, key, xl in ((a1, "mul_per_term", "Multiplies per COS term"), (a2, "cycles", "Cycles, 8 multipliers")):
        vals = [int(r[key]) for r in m]
        for yi, r, v in zip(y, m, vals):
            ax.barh(yi, v, 0.62, color=cols.get(r["datapath"], C_FWD), edgecolor="black", linewidth=0.4,
                    hatch="" if r["datapath"] in cols else "\\\\\\\\")
            ax.text(v + max(vals) * 0.02, yi, "{:,}".format(v), va="center", fontsize=6)
        ax.set_xlabel(xl)
        ax.set_xlim(0, max(vals) * 1.28)
        ax.set_xticks([0, 400, 800] if key == "mul_per_term" else [0, 5000, 10000, 15000])
        ax.grid(axis="x")
        ax.set_axisbelow(True)
    a1.set_yticks(y)
    a1.set_yticklabels([names[r["datapath"]] for r in m])
    fig.subplots_adjust(wspace=0.08)
    save(fig, "fig_modes")


# ---- Fig. design space: cycles against shared multipliers (64-bit) ------------------------
def fig_dse():
    g = [r for r in rows("gen_cycles.csv") if r["family"] == "zu"]
    mu = [int(r["mults"]) for r in g]
    fig, ax = plt.subplots(figsize=(COL1, 1.85))
    ax.plot(mu, [int(r["cycles_bump"]) for r in g], "s--", color=C_BUMP, ms=3.5, label="Bump-and-reprice (19 pricings)")
    ax.plot(mu, [int(r["cycles_aad"]) for r in g], "o-", color=C_ADJ, ms=3.5, label="Adjoint, price + 9 Greeks")
    ax.plot(mu, [int(r["cycles_price"]) for r in g], "^:", color=C_PRICE, ms=3.5, label="Price only")
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_xticks(mu)
    ax.set_xticklabels([str(v) for v in mu])
    ax.set_xlabel("Shared 64-bit multipliers")
    ax.set_ylabel("Clock cycles per evaluation")
    ax.grid(which="major")
    ax.legend(frameon=False, loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=2)
    save(fig, "fig_dse")


# ---- Fig. accuracy: worst relative error and worst error / bound, per output ---------------
def fig_accuracy():
    acc = rows("gen_accuracy.csv")
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(COL2, 1.75), gridspec_kw={"width_ratios": [1.6, 1]})
    x = np.arange(len(OUTPUTS))
    w = 0.38
    for i, (design, lab, col, hatch, mk) in enumerate([("heston_aad_z7", "56-bit (Q28)", C_ADJ, "", "o"),
                                                      ("heston_aad_zu", "64-bit (Q32)", "#56B4E9", "....", "s")]):
        rel, ratio = [], []
        for o in OUTPUTS:
            pts = [r for r in acc if r["design"] == design and r["output"] == o]
            rel.append(max(abs(float(r["fixed"]) - float(r["float_alg"])) / max(abs(float(r["float_alg"])), 1e-12) for r in pts))
            ratio.append(max(abs(float(r["fixed"]) - float(r["float_alg"])) / float(r["bound"]) for r in pts))
        a1.bar(x + (i - 0.5) * w, rel, w, color=col, hatch=hatch, edgecolor="black", linewidth=0.4, label=lab)
        a2.plot(x, ratio, mk, color=col, ms=3.5, label=lab, markeredgecolor="black", markeredgewidth=0.4)
    a1.set_yscale("log")
    a1.set_ylim(top=1e-4)
    a1.set_ylabel("Worst relative error")
    a1.set_xticks(x)
    a1.set_xticklabels([LABEL[o] for o in OUTPUTS])
    a1.grid(axis="y")
    a1.set_axisbelow(True)
    a1.legend(frameon=False, loc="upper left", ncol=2)
    a1.set_title("(a) error against the same algorithm in double precision", loc="left")
    a2.axhline(1.0, color="black", lw=0.8, ls="--")
    a2.text(len(OUTPUTS) - 1, 0.93, "bound", ha="right", va="top", fontsize=6)
    a2.set_ylim(0, 1.05)
    a2.set_ylabel("Worst error / first-order bound")
    a2.set_xticks(x)
    a2.set_xticklabels([LABEL[o] for o in OUTPUTS])
    a2.grid(axis="y")
    a2.set_title("(b) measured error as a fraction of the bound", loc="left")
    a2.legend(frameon=False, loc="center right")
    fig.subplots_adjust(wspace=0.28)
    save(fig, "fig_accuracy")


# ---- Fig. bound over the held-out sweep: distribution of error / bound ---------------------
def fig_bound_sweep():
    d = rows("domain_sweep_heldout.csv")
    fig, ax = plt.subplots(figsize=(COL1, 1.75))
    for regime_set, lab, col, ls in ((lambda r: r["regime"] != "outside", "In domain (9,500 inputs)", C_ADJ, "-"),
                                     (lambda r: r["regime"] == "outside", "One input outside (1,000)", C_BUMP, "--")):
        vals = []
        for r in d:
            if not regime_set(r) or r["flagged"] == "1" or r["error"]:
                continue
            ratios = [float(r["ratio_" + o]) for o in OUTPUTS if r.get("ratio_" + o) not in ("", None)]
            if ratios:
                vals.append(max(ratios))
        v = np.sort(vals)
        ax.plot(v, np.arange(1, len(v) + 1) / len(v), ls, color=col, label="%s, worst %.3f" % (lab, v[-1]))
    ax.axvline(1.0, color="black", lw=0.8, ls=":")
    ax.text(0.985, 0.08, "bound", rotation=90, ha="right", fontsize=6)
    ax.set_xlim(0, 1.02)
    ax.set_ylim(0, 1.01)
    ax.set_xlabel("Worst error / bound over the 10 outputs of an input")
    ax.set_ylabel("Fraction of inputs")
    ax.grid()
    ax.legend(frameon=False, loc="center right")
    save(fig, "fig_bound_sweep")


# ---- Fig. bump-and-reprice error against bump size, with the adjoint ------------------------
def fig_bump():
    b = [r for r in rows("gen_bump.csv") if r["family"] == "z7"]
    show = ["delta", "vega", "kappa_sens", "rho_corr"]
    fig, axs = plt.subplots(1, 4, figsize=(COL2, 1.45), sharey=False)
    for ax, o in zip(axs, show):
        pts = sorted((float(r["rel_h"]), r) for r in b if r["output"] == o)
        h = [p[0] for p in pts]
        ref = [float(p[1]["ref_cos"]) for p in pts]
        eb = [abs(float(p[1]["bump"]) - rf) / abs(rf) for p, rf in zip(pts, ref)]
        ea = [abs(float(p[1]["aad"]) - rf) / abs(rf) for p, rf in zip(pts, ref)]
        ax.loglog(h, eb, "s--", color=C_BUMP, ms=3, label="Bump-and-reprice")
        ax.loglog(h, ea, "-", color=C_ADJ, lw=1.4, label="Adjoint (this work)")
        ax.set_title(LABEL[o], loc="center")
        ax.set_xlabel("Relative bump size $h$")
        ax.grid(which="major")
        ax.set_xticks([1e-8, 1e-6, 1e-4, 1e-2])
    axs[0].set_ylabel("Relative error")
    axs[0].legend(frameon=False, loc="lower left", fontsize=6)
    fig.subplots_adjust(wspace=0.32)
    save(fig, "fig_bump")


# ---- Fig. latency against the CPU, same algorithm -----------------------------------------
def fig_latency():
    cpu = {}
    with open(os.path.join(RES, "cpu_baseline.csv")) as f:
        for line in f:
            p = line.strip().split(",")
            if len(p) >= 2 and p[0] in ("price", "bump", "bumpopt", "aad", "fwdvec", "analytic"):
                try:
                    cpu.setdefault(p[0], float(p[1]))
                except ValueError:
                    pass
    gc = {(r["family"], int(r["mults"])): r for r in rows("gen_cycles.csv")}
    zu_us = int(gc[("zu", 32)]["cycles_aad"]) / 100.0       # 100 MHz on the ZCU102
    zed_us = 4572 / 70.0                                    # host-setup loop, 70 MHz on the ZedBoard
    bars = [("CPU, bump-and-reprice", cpu["bump"], C_CPU, "////"), ("CPU, AAD (CoDiPack)", cpu["aad"], C_CPU, "...."),
            ("CPU, forward mode", cpu["fwdvec"], C_CPU, "\\\\\\\\"), ("CPU, analytic Greeks", cpu["analytic"], C_CPU, ""),
            ("FPGA, Zynq-7020 (loop)", zed_us, C_ADJ, "...."), ("FPGA, Zynq US+ (whole)", zu_us, C_ADJ, "")]
    fig, ax = plt.subplots(figsize=(COL1, 1.75))
    y = np.arange(len(bars))[::-1]
    for yi, (lab, v, col, hatch) in zip(y, bars):
        ax.barh(yi, v, 0.62, color=col, hatch=hatch, edgecolor="black", linewidth=0.4)
        ax.text(v * 1.06, yi, "%.1f" % v, va="center", fontsize=6)
    ax.set_xscale("log")
    ax.set_xlim(8, 600)
    ax.set_yticks(y)
    ax.set_yticklabels([b[0] for b in bars])
    ax.set_xlabel(r"Latency, price + 9 Greeks ($\mu$s, one core / one engine)")
    ax.grid(axis="x", which="major")
    ax.set_axisbelow(True)
    save(fig, "fig_latency")


if __name__ == "__main__":
    fig_cycles()
    fig_modes()
    fig_dse()
    fig_accuracy()
    fig_bound_sweep()
    fig_bump()
    fig_latency()
