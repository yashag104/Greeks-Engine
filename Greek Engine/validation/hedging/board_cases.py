"""Real-market inputs for the board: the hedging study's daily NIFTY calibrations.

    .venv/bin/python validation/hedging/board_cases.py [n]
    -> validation/hedging/results/board_cases.csv

Each row of results/daily.csv is one trading day of one hedged trade: the
futures level F, the option's time to expiry T and the Heston parameters
calibrated that day to real NIFTY option quotes. The engine's inputs are those
values with the spot scaled to 100 and the strike in proportion, exactly as the
backtest priced them (backtest.py: q = [100, 100 K / S, T, R] + params), at the
backtest's rate R. The option is the short at-the-money call of that trade.

n trading days are picked evenly over the year (default 50), so the board sees
real parameter sets from every month, including the days where the calibration
sits at a domain edge (kappa = 6).
"""
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from backtest import R  # noqa: E402  (the backtest's risk-free rate)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 50
    daily = list(csv.DictReader(open(os.path.join(HERE, "results", "daily.csv"))))
    strike = {}
    for t in csv.DictReader(open(os.path.join(HERE, "results", "trades.csv"))):
        strike[(t["entry"], t["expiry"])] = float(t["strike"])
    pick = [daily[round(i * (len(daily) - 1) / (n - 1))] for i in range(n)]
    rows = []
    for d in pick:
        K = strike[(d["entry"], d["expiry"])]
        F = float(d["F"])
        rows.append(dict(date=d["date"], futures=F, strike=K, S0=100.0, K=round(100.0 * K / F, 6),
                         T=float(d["T"]), r=R, v0=float(d["v0"]), kappa=float(d["kappa"]),
                         theta=float(d["theta"]), xi=float(d["xi"]), rho=float(d["rho"]), is_call=1))
    out = os.path.join(HERE, "results", "board_cases.csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print("wrote %s: %d trading days, %s to %s" % (out, len(rows), rows[0]["date"], rows[-1]["date"]))


if __name__ == "__main__":
    main()
