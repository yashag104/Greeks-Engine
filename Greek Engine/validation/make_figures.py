"""Paper figures and tables from validation/results/*.csv.

    python run_hw_sweeps.py all     # RTL simulation data (once, ~20 min)
    python make_figures.py          # -> validation/figures/*.pdf, *.png, tables.md

Figures (each skipped with a message if its data is missing):
  fig1_bump_vs_aad_error   error vs bump size: RTL bump-and-reprice (fixed
                           point) vs double-precision bump vs RTL AAD
  fig2_accuracy_sweep      RTL AAD error over the parameter grid, per output
  fig3_bound_tightness     measured error / first-order bound (all <= 1)
  fig4_precision_vs_fl     error vs fractional bits: measured, bound, 1-sigma
  fig5_cost_vs_greeks      clock cycles vs number of sensitivities
  fig6_resources           LUT/FF/DSP per design and board (needs vivado.csv)
  fig7_energy_latency      latency and energy per Greek set (needs vivado.csv)
"""
import csv
import math
import os
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import LogLocator  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "results")
FIG = os.path.join(HERE, "figures")

# Reference categorical palette (dataviz skill, light mode), fixed order;
# markers/line styles are the secondary encoding for print and CVD.
C1, C2, C3 = "#2a78d6", "#eb6834", "#1baf7a"
INK, INK2, GRID = "#0b0b0b", "#52514e", "#e4e3df"

LABEL = {"price": "Price", "delta": r"Delta $\partial V/\partial S_0$",
         "strike_sens": r"$\partial V/\partial K$", "theta_greek": r"$\partial V/\partial T$",
         "rho_greek": r"Rho $\partial V/\partial r$", "vega": r"$\partial V/\partial v_0$",
         "kappa_sens": r"$\partial V/\partial\kappa$", "theta_sens": r"$\partial V/\partial\theta$",
         "xi_sens": r"$\partial V/\partial\xi$", "rho_corr": r"$\partial V/\partial\rho$"}
SHORT = {"price": "V", "delta": "S0", "strike_sens": "K", "theta_greek": "T", "rho_greek": "r",
         "vega": "v0", "kappa_sens": "κ", "theta_sens": "θ", "xi_sens": "ξ", "rho_corr": "ρ"}
GREEKS = ["delta", "strike_sens", "theta_greek", "rho_greek", "vega",
          "kappa_sens", "theta_sens", "xi_sens", "rho_corr"]
OUTPUTS = ["price"] + GREEKS

plt.rcParams.update({
    "font.size": 8, "axes.titlesize": 8, "axes.labelsize": 8, "legend.fontsize": 7,
    "xtick.labelsize": 7, "ytick.labelsize": 7, "axes.edgecolor": INK2,
    "axes.labelcolor": INK, "xtick.color": INK2, "ytick.color": INK2, "text.color": INK,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
    "axes.spines.top": False, "axes.spines.right": False, "lines.linewidth": 1.5,
    "savefig.bbox": "tight", "savefig.dpi": 300, "pdf.fonttype": 42,
})


def load(name):
    path = os.path.join(RES, name)
    if not os.path.exists(path):
        print("skip: %s not found" % name)
        return None
    with open(path) as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k, v in r.items():
            try:
                r[k] = float(v)
            except (TypeError, ValueError):
                pass
    return rows


def save(fig, name):
    os.makedirs(FIG, exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(FIG, "%s.%s" % (name, ext)))
    plt.close(fig)
    print("wrote figures/%s.pdf" % name)


def rel(err, ref):
    return abs(err) / max(abs(ref), 1e-12)


# ---------------------------------------------------------------------------
def fig_bump(rows):
    by = defaultdict(list)
    for r in rows:
        by[r["output"]].append(r)
    fig, axes = plt.subplots(3, 3, figsize=(7.0, 6.0), sharex=True)
    for ax, o in zip(axes.flat, GREEKS):
        pts = sorted(by[o], key=lambda r: r["rel_h"])
        h = [r["rel_h"] for r in pts]
        e_rtl = [max(rel(r["rtl_bump"] - r["ref_cos"], r["ref_cos"]), 1e-16) for r in pts]
        e_flt = [max(rel(r["float_bump"] - r["ref_cos"], r["ref_cos"]), 1e-16) for r in pts]
        e_aad = max(rel(pts[0]["rtl_aad"] - pts[0]["ref_cos"], pts[0]["ref_cos"]), 1e-16)
        ax.loglog(h, e_rtl, color=C2, marker="o", ms=4, label="Bump-and-reprice, RTL Q32.32")
        ax.loglog(h, e_flt, color=C1, marker="s", ms=3.5, ls="--", label="Bump-and-reprice, double")
        ax.axhline(e_aad, color=C3, lw=2, label="AAD, RTL Q32.32 (no bump size)")
        ax.set_title(LABEL[o])
        ax.yaxis.set_major_locator(LogLocator(numticks=5))
    for ax in axes[-1]:
        ax.set_xlabel("relative bump size h")
    for ax in axes[:, 0]:
        ax.set_ylabel("relative error")
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=3, frameon=False, bbox_to_anchor=(0.5, 1.02))
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    save(fig, "fig1_bump_vs_aad_error")


def fig_accuracy(rows):
    fig, ax = plt.subplots(figsize=(7.0, 2.6))
    for j, o in enumerate(OUTPUTS):
        pts = [r for r in rows if r["output"] == o]
        errs = [max(rel(r["rtl"] - r["ref_cos"], r["ref_cos"]), 1e-13) for r in pts]
        meth = [max(rel(r["ref_cos"] - r["ref_model"], r["ref_model"]), 1e-13) for r in pts]
        xs = [j - 0.15 + 0.3 * (i / max(len(pts) - 1, 1)) for i in range(len(pts))]
        ax.scatter(xs, errs, s=9, color=C1, marker="o", lw=0, label="RTL AAD vs double-precision COS" if j == 0 else None)
        ax.scatter([x + 0.02 for x in xs], meth, s=9, color=C2, marker="^", lw=0,
                   label="COS method vs Fourier integral (not hardware)" if j == 0 else None)
    ax.set_yscale("log")
    ax.set_xticks(range(len(OUTPUTS)))
    ax.set_xticklabels([LABEL[o] for o in OUTPUTS], rotation=30, ha="right")
    ax.set_ylabel("relative error")
    ax.grid(axis="x", visible=False)
    n = len({r["case"] for r in rows})
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.0), frameon=False, ncol=2,
              title="Heston AAD engine, %d parameter sets (Q32.32 RTL simulation)" % n)
    save(fig, "fig2_accuracy_sweep")


def fig_tightness(rows):
    fig, ax = plt.subplots(figsize=(7.0, 2.4))
    for j, o in enumerate(OUTPUTS):
        pts = [r for r in rows if r["output"] == o]
        ratio = [max(abs(r["rtl"] - r["model_value"]) / r["bound"], 1e-6) for r in pts]
        xs = [j - 0.15 + 0.3 * (i / max(len(pts) - 1, 1)) for i in range(len(pts))]
        ax.scatter(xs, ratio, s=9, color=C1, lw=0)
    ax.axhline(1.0, color=INK, lw=1)
    ax.text(len(OUTPUTS) - 0.5, 1.15, "bound", ha="right", va="bottom", color=INK2)
    ax.set_yscale("log")
    ax.set_xticks(range(len(OUTPUTS)))
    ax.set_xticklabels([LABEL[o] for o in OUTPUTS], rotation=30, ha="right")
    ax.set_ylabel("|measured error| / bound")
    ax.grid(axis="x", visible=False)
    ax.set_title("First-order error bound vs measured RTL error (every point must lie below 1)")
    save(fig, "fig3_bound_tightness")


def fig_fl(rows):
    shown = ["price", "delta", "vega", "rho_corr"]
    fig, axes = plt.subplots(1, 4, figsize=(7.0, 2.2), sharex=True)
    for ax, o in zip(axes, shown):
        pts = [r for r in rows if r["output"] == o]
        fls = sorted({r["fl"] for r in pts})
        for case, mk in zip(sorted({r["case"] for r in pts}), ("o", "s", "D")):
            cp = sorted([r for r in pts if r["case"] == case], key=lambda r: r["fl"])
            ax.semilogy([r["fl"] for r in cp], [max(abs(r["rtl"] - r["ref_cos"]), 1e-15) for r in cp],
                        ls="none", marker=mk, ms=3.5, color=C1, label="measured (%s)" % case)
        worst = [max(r["bound"] for r in pts if r["fl"] == f) for f in fls]
        sig = [max(r["sigma"] for r in pts if r["fl"] == f) for f in fls]
        ax.semilogy(fls, worst, color=C2, label="worst-case bound")
        ax.semilogy(fls, sig, color=C3, ls="--", label="1-sigma estimate")
        ax.semilogy(fls, [2.0 ** -f for f in fls], color=INK2, lw=0.8, ls=":", label="1 ULP")
        ax.set_title(LABEL[o])
        ax.set_xlabel("fractional bits FL")
    axes[0].set_ylabel("absolute error")
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=3, frameon=False, bbox_to_anchor=(0.5, 1.12))
    fig.tight_layout()
    save(fig, "fig4_precision_vs_fl")


def fig_cost(acc_rows, bump_rows):
    aad = acc_rows[0]["cycles"]
    fwd = cycles_forward_only()
    bump9 = bump_rows[0]["cycles_bump"] if bump_rows else None
    n = list(range(1, 21))
    # bump: 1 base + 2 pricings per sensitivity, plus one divide each
    div = (bump9 - 19 * fwd) / 9.0 if (bump9 and fwd) else 0.0
    fig, ax = plt.subplots(figsize=(3.4, 2.4))
    if fwd:
        ax.plot(n, [((2 * k + 1) * fwd + k * div) / 1e6 for k in n], color=C2, marker="o", ms=2.5,
                label="bump-and-reprice (central)")
    ax.plot(n, [aad / 1e6] * len(n), color=C3, lw=2, label="AAD (forward + reverse)")
    if bump9:
        ax.plot([9], [bump9 / 1e6], ls="none", marker="o", ms=7, mfc="none", mec=INK, label="measured, 9 sensitivities")
        ax.plot([9], [aad / 1e6], ls="none", marker="o", ms=7, mfc="none", mec=INK)
    ax.set_xlabel("number of sensitivities")
    ax.set_xticks([1, 5, 9, 13, 17, 20])
    ax.set_ylabel("clock cycles per evaluation (millions)")
    ax.legend(frameon=False, loc="upper left")
    save(fig, "fig5_cost_vs_greeks")


def cycles_forward_only():
    path = os.path.join(RES, "forward_only_cycles.txt")
    return float(open(path).read()) if os.path.exists(path) else None


def fig_vivado(viv, acc_rows, bump_rows):
    tops = [("heston_cos_forward", "price only"), ("heston_top_level", "AAD, 9 sens."),
            ("heston_bump_top", "bump, 9 sens.")]
    parts = sorted({r["part"] for r in viv})
    fig, axes = plt.subplots(1, 3, figsize=(7.0, 2.2))
    for ax, key, title in zip(axes, ("lut", "ff", "dsp"), ("LUTs", "Flip-flops", "DSP blocks")):
        width = 0.8 / max(len(parts), 1)
        for i, part in enumerate(parts):
            vals = [next((r[key] for r in viv if r["part"] == part and r["top"] == t), 0) for t, _ in tops]
            ax.bar([j + i * width for j in range(len(tops))], vals, width=width - 0.02,
                   color=(C1, C2, C3)[i % 3], label=part)
        ax.set_xticks([j + 0.4 - width / 2 for j in range(len(tops))])
        ax.set_xticklabels([lbl for _, lbl in tops], rotation=20, ha="right")
        ax.set_title(title)
        ax.grid(axis="x", visible=False)
    axes[0].legend(frameon=False)
    save(fig, "fig6_resources")

    cyc = {"heston_top_level": acc_rows[0]["cycles"],
           "heston_bump_top": bump_rows[0]["cycles_bump"] if bump_rows else None}
    fig, axes = plt.subplots(1, 2, figsize=(7.0, 2.2))
    for i, part in enumerate(parts):
        for j, (top, lbl) in enumerate(tops[1:]):
            r = next((r for r in viv if r["part"] == part and r["top"] == top), None)
            if not r or not cyc[top]:
                continue
            latency_ms = cyc[top] / (r["fmax_mhz"] * 1e6) * 1e3
            energy_mj = r["power_total_w"] * latency_ms
            x = i + 0.2 * (j - 0.5)
            axes[0].bar(x, latency_ms, width=0.38, color=(C3, C2)[j], label=lbl if i == 0 else None)
            axes[1].bar(x, energy_mj, width=0.38, color=(C3, C2)[j], label=lbl if i == 0 else None)
    for ax, t in zip(axes, ("latency per evaluation (ms)", "energy per evaluation (mJ)")):
        ax.set_xticks(range(len(parts)))
        ax.set_xticklabels(parts)
        ax.set_title(t)
        ax.grid(axis="x", visible=False)
    axes[0].legend(frameon=False)
    save(fig, "fig7_energy_latency")


# ---------------------------------------------------------------------------
def tables(acc, fl_rows, bump):
    out = []
    if acc:
        out.append("## Accuracy of the Heston AAD RTL (Q32.32), %d parameter sets\n" % len({r["case"] for r in acc}))
        out.append("| output | max rel. error vs double | median rel. error | max error / bound | bits lost (worst case, bound) |")
        out.append("|---|---|---|---|---|")
        for o in OUTPUTS:
            pts = [r for r in acc if r["output"] == o]
            errs = sorted(rel(r["rtl"] - r["ref_cos"], r["ref_cos"]) for r in pts)
            ratio = max(abs(r["rtl"] - r["model_value"]) / r["bound"] for r in pts)
            bits = max(math.log2(r["bound"] / 2.0 ** -32) for r in pts)
            out.append("| %s | %.2e | %.2e | %.3f | %.1f |" % (o, errs[-1], errs[len(errs) // 2], ratio, bits))
        out.append("\nCycles per AAD evaluation: %d\n" % acc[0]["cycles"])
    if bump:
        out.append("## Bump-and-reprice (RTL, Q32.32) vs AAD, base case\n")
        out.append("| output | AAD rel. error | best bump rel. error | at relative h | worst bump rel. error |")
        out.append("|---|---|---|---|---|")
        for o in GREEKS:
            pts = [r for r in bump if r["output"] == o]
            e = [(rel(r["rtl_bump"] - r["ref_cos"], r["ref_cos"]), r["rel_h"]) for r in pts]
            best, worst = min(e), max(e)
            out.append("| %s | %.2e | %.2e | %g | %.2e |" % (o, rel(pts[0]["rtl_aad"] - pts[0]["ref_cos"], pts[0]["ref_cos"]),
                                                         best[0], best[1], worst[0]))
        out.append("\nCycles: AAD %d, bump-and-reprice %d (%.1fx)\n" % (
            bump[0]["cycles_aad"], bump[0]["cycles_bump"], bump[0]["cycles_bump"] / bump[0]["cycles_aad"]))
    if out:
        path = os.path.join(FIG, "tables.md")
        os.makedirs(FIG, exist_ok=True)
        open(path, "w").write("\n".join(out) + "\n")
        print("wrote figures/tables.md")


if __name__ == "__main__":
    acc, fl_rows, bump, viv = load("accuracy.csv"), load("fl_sweep.csv"), load("bump.csv"), load("vivado.csv")
    if bump:
        fig_bump(bump)
    if acc:
        fig_accuracy(acc)
        fig_tightness(acc)
    if fl_rows:
        fig_fl(fl_rows)
    if acc:
        fig_cost(acc, bump)
    if viv and acc:
        fig_vivado(viv, acc, bump)
    tables(acc, fl_rows, bump)
