"""Tables and figures for the hedging case study (run backtest.py first).

    .venv/bin/python validation/hedging/analyse.py
    -> validation/hedging/results/summary.csv, figures/*.png

A hedge exists to remove risk, so the headline measure is the spread of a
trade's profit or loss (standard deviation across trades); the mean after all
costs and tax is reported beside it. With about a dozen trades the means are
noisy; the spreads and the delta-error comparison are the robust results.
"""
import csv
import os
import statistics as st
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "results")
FIG = os.path.join(RES, "figures")
AAD, BUMP, INK, MUTED, PLAN = "#1FA97A", "#E8683A", "#16202A", "#56626B", "#7C9CBC"


def lakh(x):
    return x / 1e5


def main():
    trades = list(csv.DictReader(open(os.path.join(RES, "trades.csv"))))
    daily = list(csv.DictReader(open(os.path.join(RES, "daily.csv"))))
    os.makedirs(FIG, exist_ok=True)
    by = defaultdict(list)
    for t in trades:
        key = t["strategy"] + (" / every %s day%s" % (t["rebalance_days"], "" if t["rebalance_days"] == "1" else "s")
                               if t["rebalance_days"] else "")
        by[key].append(t)
    order = list(dict.fromkeys(by))
    summary = []
    for k in order:
        ts = by[k]
        post = [float(t["pnl_after_tax"]) for t in ts]
        pre = [float(t["pnl_before_tax"]) for t in ts]
        summary.append(dict(strategy=k, trades=len(ts),
                            mean_after_tax=round(st.mean(post)), std_after_tax=round(st.pstdev(post)),
                            mean_before_tax=round(st.mean(pre)), std_before_tax=round(st.pstdev(pre)),
                            worst=round(min(post)), best=round(max(post)),
                            mean_costs=round(st.mean(float(t["costs"]) for t in ts)),
                            mean_tax=round(st.mean(float(t["tax"]) for t in ts)),
                            mean_hedge_trades=round(st.mean(float(t["hedge_trades"]) for t in ts), 1),
                            total_after_tax=round(sum(post))))
    with open(os.path.join(RES, "summary.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(summary[0])); w.writeheader(); w.writerows(summary)
    for s in summary:
        print("%-34s n=%2d  mean %+9.0f  std %9.0f  worst %+10.0f  costs %7.0f  hedges %5.1f" % (
            s["strategy"], s["trades"], s["mean_after_tax"], s["std_after_tax"], s["worst"], s["mean_costs"],
            s["mean_hedge_trades"]))

    # 1. risk and return per strategy
    fig, ax = plt.subplots(figsize=(9, 4.2))
    names = [s["strategy"] for s in summary]
    col = [MUTED if n.startswith("unhedged") else BUMP if n.startswith("black") else INK if "min-variance" in n else AAD for n in names]
    ax.bar(range(len(names)), [lakh(s["std_after_tax"]) for s in summary], color=col)
    ax.set_xticks(range(len(names))); ax.set_xticklabels(names, rotation=25, ha="right", fontsize=8)
    ax.set_ylabel("spread of P&L per trade (Rs lakh, std)")
    ax.set_title("Risk left after hedging: lower is better", fontsize=10)
    for i, s in enumerate(summary):
        ax.text(i, lakh(s["std_after_tax"]), "mean %+.2f" % lakh(s["mean_after_tax"]), ha="center", va="bottom", fontsize=7)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "hedge_risk_by_strategy.png"), dpi=200); plt.close(fig)

    # 2. P&L per trade, unhedged vs engine delta daily
    fig, ax = plt.subplots(figsize=(9, 3.8))
    for k, c, m in (("unhedged", MUTED, "o"), ("black-scholes / every 1 day", BUMP, "s"), ("heston 56-bit / every 1 day", AAD, "D"),
                    ("heston min-variance 56-bit / every 1 day", INK, "^")):
        ts = by.get(k, [])
        ax.plot([t["entry"][:7] for t in ts], [lakh(float(t["pnl_after_tax"])) for t in ts], marker=m, color=c, label=k)
    ax.axhline(0, color=INK, lw=0.8)
    ax.set_ylabel("P&L after costs and tax (Rs lakh)"); ax.legend(fontsize=8)
    ax.set_title("Each trade: sell 20 lots of an ATM NIFTY call, hedge with futures", fontsize=10)
    plt.setp(ax.get_xticklabels(), rotation=30, fontsize=8)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "hedge_pnl_per_trade.png"), dpi=200); plt.close(fig)

    # 3. P&L breakdown for the engine-delta daily hedge
    ts = by["heston 56-bit / every 1 day"]
    parts = [("premium received", st.mean(float(t["premium"]) for t in ts)),
             ("buy-back", -st.mean(float(t["buyback"]) for t in ts)),
             ("futures hedge", st.mean(float(t["futures_pnl"]) for t in ts)),
             ("charges and slippage", -st.mean(float(t["costs"]) for t in ts)),
             ("income tax", -st.mean(float(t["tax"]) for t in ts))]
    fig, ax = plt.subplots(figsize=(8, 3.6))
    run = 0.0
    for i, (n, v) in enumerate(parts):
        ax.bar(i, lakh(v), bottom=lakh(run), color=AAD if v >= 0 else BUMP)
        run += v
    ax.bar(len(parts), lakh(run), color=INK)
    ax.set_xticks(range(len(parts) + 1)); ax.set_xticklabels([n for n, _ in parts] + ["net P&L"], fontsize=8, rotation=15)
    ax.axhline(0, color=INK, lw=0.8); ax.set_ylabel("Rs lakh, mean per trade")
    ax.set_title("Where the money goes (Heston delta from the engine, daily hedge)", fontsize=10)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "hedge_pnl_breakdown.png"), dpi=200); plt.close(fig)

    # 4. word length: delta error against the 56-bit engine
    err48 = [abs(float(r["d48"]) - float(r["d56"])) for r in daily]
    err44 = [abs(float(r["d44"]) - float(r["d56"])) for r in daily]
    fig, ax = plt.subplots(figsize=(6, 3.4))
    ax.boxplot([err48, err44], tick_labels=["48-bit", "44-bit"], showfliers=True)
    ax.set_yscale("log"); ax.set_ylabel("|delta - delta at 56 bits|")
    ax.set_title("Hedge-ratio error from fewer bits (every hedging day)", fontsize=10)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "hedge_delta_vs_wordlength.png"), dpi=200); plt.close(fig)
    print("delta error vs 56-bit: 48-bit max %.2e median %.2e; 44-bit max %.2e median %.2e" % (
        max(err48), st.median(err48), max(err44), st.median(err44)))
    print("calibration fit (rms price error, %% of spot): median %.3f, max %.3f" % (
        st.median(float(r["fit_pts"]) for r in daily), max(float(r["fit_pts"]) for r in daily)))
    print("wrote", FIG)


if __name__ == "__main__":
    main()
