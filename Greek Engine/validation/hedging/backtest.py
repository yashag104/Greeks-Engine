"""Delta-hedging case study on real NIFTY data.

    .venv/bin/python validation/hedging/backtest.py
    -> validation/hedging/results/trades.csv, summary.csv, figures/*.png

Each month a desk sells NIFTY calls (at the money, about 2-3 months to expiry),
delta-hedges them with NIFTY futures, and buys them back when 0.1 years remain
(the lower end of the engine's verified domain). Profit or loss is everything
left after the premium, the buy-back, the futures gains and losses, every trading
charge, slippage and income tax.

Model. Heston is calibrated each day to that day's NIFTY option settlement
prices (out-of-the-money options of the traded expiry), in double precision. The
hedge ratio comes from the generated engine's bit-accurate emulator, which is
bit-identical to the FPGA: delta at 56 bits (the Zynq-7020 design), and at 48 and
44 bits for the word-length comparison. Dividends: the effective spot is the
same-expiry future discounted at r, S = F e^{-rT}; the engine prices at S = 100
with the strike scaled in proportion (prices scale with the spot level, delta does
not). Futures hedge ratio: dV/dF = delta * e^{-rT}.

All costs are in COSTS below. The defaults are typical published Indian rates for
index options and futures as of 2025; check them against your broker before
quoting results.
"""
import csv
import gzip
import math
import os
import sys
from collections import defaultdict

import numpy as np
from scipy.optimize import least_squares
from scipy.stats import norm

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "hardware", "gen"))
sys.path.insert(0, os.path.join(ROOT, "validation", "reference"))
import heston as H  # noqa: E402
import heston_reference as ref  # noqa: E402

DATA = os.path.join(HERE, "data", "nifty_fo.csv.gz")
RES = os.path.join(HERE, "results")

R = 0.06              # risk-free rate (India 91-day T-bill, approx.)
MIN_VOLUME = 50       # contracts traded that day for a quote to count as a market price
LIQUID = 500          # contracts traded on entry for the sold strike
LOTS = 20             # option lots sold per trade
T_ENTRY = (0.15, 0.30)  # enter the expiry whose remaining life is in this range (years)
T_EXIT = 0.10         # buy back when this much life remains
COSTS = dict(
    brokerage_per_order=20.0,        # Rs, flat, per executed order
    stt_option_sell=0.001,           # 0.1% of premium, sell side
    stt_future_sell=0.0002,          # 0.02% of turnover, sell side
    exch_option=0.0003503,           # NSE transaction charge, % of premium
    exch_future=0.0000173,           # NSE transaction charge, % of turnover
    sebi=10e-7,                      # Rs 10 per crore
    stamp_option_buy=0.00003,        # 0.003% of premium, buy side
    stamp_future_buy=0.00002,        # 0.002% of turnover, buy side
    gst=0.18,                        # on brokerage + exchange + SEBI charges
    slip_future_points=0.5,          # index points lost per futures order
    slip_option_frac=0.005,          # 0.5% of premium lost on entry and exit
    income_tax=0.30,                 # on net profit (business income), if positive
)
DOMAIN = dict(v0=(0.005, 0.25), kappa=(0.2, 6.0), theta=(0.005, 0.25), xi=(0.1, 1.0), rho=(-0.95, 0.6))


# ---------------------------------------------------------------- data
def load():
    days = defaultdict(lambda: {"opt": [], "fut": {}})
    with gzip.open(DATA, "rt") as f:
        for r in csv.DictReader(f):
            d = days[r["TradDt"]]
            if r["FinInstrmTp"] == "IDF":
                d["fut"][r["XpryDt"]] = float(r["SttlmPric"])
            else:
                # real = traded that day at its settlement price; NSE fills untraded contracts
                # with a theoretical settlement at one fixed volatility, which is not a market price
                p, c, vol = float(r["SttlmPric"]), float(r["ClsPric"]), int(r["TtlTradgVol"])
                d["opt"].append(dict(e=r["XpryDt"], k=float(r["StrkPric"]), call=r["OptnTp"] == "CE", p=p,
                                     vol=vol, lot=int(r["NewBrdLotQty"]),
                                     real=vol >= MIN_VOLUME and p > 0.5 and abs(p - c) <= 0.005 * p))
    return dict(sorted(days.items()))


def years(d0, d1):
    from datetime import date
    return (date.fromisoformat(d1) - date.fromisoformat(d0)).days / 365.0


# ---------------------------------------------------------------- model
def calibrate(opts, S, T, x0=None):
    """Heston on [S scaled to 100]; OTM options, prices relative to spot; params in domain"""
    K = np.array([k for k, _, _ in opts]); P = np.array([p for _, p, _ in opts])
    call = np.array([c for _, _, c in opts])
    names = ["v0", "kappa", "theta", "xi", "rho"]
    lo = [DOMAIN[n][0] for n in names]; hi = [DOMAIN[n][1] for n in names]
    x0 = x0 if x0 is not None else [0.02, 2.0, 0.02, 0.4, -0.5]
    x0 = np.clip(x0, lo, hi)

    def resid(x):
        out = []
        for k, p, c in zip(K, P, call):
            q = [100.0, 100.0 * k / S, T, R] + list(x)
            out.append((ref.cos_price(q, bool(c)) - 100.0 * p / S) / max(100.0 * p / S, 0.05))
        return out
    sol = least_squares(resid, x0, bounds=(lo, hi), x_scale=[0.01, 1, 0.01, 0.1, 0.1], max_nfev=60)
    return sol.x, float(np.sqrt(np.mean(np.square(sol.fun))))


_dp = {}


def engine_greeks(params, S, K, T, wl, fl):
    """the generated engine's delta and variance vega (dV/dv0, at spot 100), from the
    bit-accurate emulator (== RTL) at word length wl"""
    if wl not in _dp:
        _dp[wl] = H.Datapath(wl, fl)
    p = [100.0, 100.0 * K / S, T, R] + list(params)
    q = H.quantize_inputs(p, True, fl)
    out, _ = H.emulate(_dp[wl], q)
    return out["delta"] / 2 ** fl, out["vega"] / 2 ** fl


def bs_delta(S, K, T, vol):
    d1 = (math.log(S / K) + (R + 0.5 * vol * vol) * T) / (vol * math.sqrt(T))
    return norm.cdf(d1)


def implied_vol(S, K, T, price):
    lo, hi = 1e-3, 3.0
    for _ in range(80):
        m = 0.5 * (lo + hi)
        d1 = (math.log(S / K) + (R + 0.5 * m * m) * T) / (m * math.sqrt(T)); d2 = d1 - m * math.sqrt(T)
        v = S * norm.cdf(d1) - K * math.exp(-R * T) * norm.cdf(d2)
        lo, hi = (m, hi) if v < price else (lo, m)
    return 0.5 * (lo + hi)


# ---------------------------------------------------------------- costs
def option_costs(premium_value, side):
    c = COSTS
    exch = c["exch_option"] * premium_value
    sebi = c["sebi"] * premium_value
    cost = c["brokerage_per_order"] + exch + sebi + c["gst"] * (c["brokerage_per_order"] + exch + sebi)
    cost += c["stt_option_sell"] * premium_value if side == "sell" else c["stamp_option_buy"] * premium_value
    return cost + c["slip_option_frac"] * premium_value


def future_costs(turnover, side, units):
    c = COSTS
    exch = c["exch_future"] * turnover
    sebi = c["sebi"] * turnover
    cost = c["brokerage_per_order"] + exch + sebi + c["gst"] * (c["brokerage_per_order"] + exch + sebi)
    cost += c["stt_future_sell"] * turnover if side == "sell" else c["stamp_future_buy"] * turnover
    return cost + c["slip_future_points"] * units


def cos_prices(params, S, K, T, call, N=128):
    """COS prices for many strikes at once (puts, calls by parity), spot scaled to 100.
    Same algorithm as heston_reference.cos_price(parity=True); checked in main()."""
    v0, kappa, theta, xi, rho = params
    K = 100.0 * np.asarray(K, float) / S
    x = np.log(100.0 / K)
    c1 = x + (R - 0.5 * theta) * T + (1.0 - math.exp(-kappa * T)) / (2.0 * kappa) * (theta - v0)
    c2 = max(v0 * T + 0.5 * theta * T, 1e-8)
    a = c1 - 10.0 * math.sqrt(c2); b = c1 + 10.0 * math.sqrt(c2)
    k = np.arange(N)
    u = k[None, :] * math.pi / (b - a)[:, None]                      # strikes x terms
    phi = ref.char_func(u, T, R, v0, kappa, theta, xi, rho, x[:, None])
    F = (phi * np.exp(-1j * u * a[:, None])).real
    with np.errstate(divide="ignore", invalid="ignore"):
        chi = (np.cos(-u * a[:, None]) - np.exp(a)[:, None] + u * np.sin(-u * a[:, None])) / (1 + u * u)
        psi = np.where(k[None, :] == 0, -a[:, None], (b - a)[:, None] / (k[None, :] * math.pi) * np.sin(-u * a[:, None]))
    V = 2.0 / (b - a)[:, None] * K[:, None] * (psi - chi)
    w = np.ones(N); w[0] = 0.5
    put = math.exp(-R * T) * np.sum(w * F * V, axis=1)
    return np.where(call, put + 100.0 - K * math.exp(-R * T), put) * S / 100.0


def day_quotes(day):
    """traded out-of-the-money quotes of every expiry with 0.03-0.6 years left, grouped by expiry"""
    groups = []
    for e, F in day["fut"].items():
        T = years(day["date"], e)
        if not 0.03 <= T <= 0.6:
            continue
        S = F * math.exp(-R * T)
        q = [(o["k"], o["p"], o["call"]) for o in day["opt"] if o["e"] == e and o["real"]
             and (o["k"] >= S) == o["call"] and abs(o["k"] / S - 1) <= 0.10]
        if len(q) >= 4:
            groups.append((S, T, q))
    return groups


def calibrate_fast(groups, x0=None):
    """Heston fitted to all expiries at once (one expiry cannot separate v0 from kappa)"""
    names = ["v0", "kappa", "theta", "xi", "rho"]
    lo = [DOMAIN[n][0] for n in names]; hi = [DOMAIN[n][1] for n in names]
    x0 = np.clip(x0 if x0 is not None else [0.015, 2.0, 0.02, 0.4, -0.5], lo, hi)
    arr = [(S, T, np.array([q[0] for q in g]), np.array([q[1] for q in g]), np.array([q[2] for q in g]))
           for S, T, g in groups]

    def resid(x):
        return np.concatenate([(cos_prices(x, S, K, T, C) - P) / S * 100 for S, T, K, P, C in arr])
    sol = least_squares(resid, x0, bounds=(lo, hi), x_scale=[0.01, 1, 0.01, 0.1, 0.1], max_nfev=300)
    n = sum(len(a[2]) for a in arr)
    return sol.x, float(np.sqrt(np.sum(np.square(sol.fun)) / n)), n


STRATS = [("unhedged", None, 0), ("black-scholes", 1, 0), ("black-scholes", 5, 0),
          ("heston 56-bit", 1, 56), ("heston 56-bit", 2, 56), ("heston 56-bit", 5, 56),
          ("heston 48-bit", 1, 48), ("heston 44-bit", 1, 44), ("heston min-variance 56-bit", 1, 56)]
FL = {56: 28, 48: 20, 44: 16}


def plan_trades(days):
    """one trade per month: the expiry with 0.15-0.30 years left, its liquid call nearest
    the money, exit on the first day with <= 0.1 years left on which that call traded"""
    dates = list(days)
    trades, seen = [], set()
    for d in dates:
        if d[:7] in seen:
            continue
        exps = sorted({o["e"] for o in days[d]["opt"]} & set(days[d]["fut"]))
        ok = [e for e in exps if T_ENTRY[0] <= years(d, e) <= T_ENTRY[1]]
        if not ok:
            continue
        e = min(ok, key=lambda e: abs(years(d, e) - 0.22))
        S = days[d]["fut"][e] * math.exp(-R * years(d, e))
        liquid = [o for o in days[d]["opt"] if o["e"] == e and o["call"] and o["real"] and o["vol"] >= LIQUID]
        if not liquid:
            continue
        seen.add(d[:7])
        K = min(liquid, key=lambda o: abs(o["k"] - S))["k"]
        exit_d = next((x for x in dates if x > d and years(x, e) <= T_EXIT and e in days[x]["fut"]
                       and any(o["e"] == e and o["k"] == K and o["call"] and o["real"] for o in days[x]["opt"])), None)
        if exit_d:
            trades.append((d, e, K, exit_d))
    return trades


def run_trade(days, entry, expiry, K, exit_d, cal_cache):
    dates = [d for d in days if entry <= d <= exit_d and expiry in days[d]["fut"]]
    lot = next(o["lot"] for o in days[entry]["opt"] if o["e"] == expiry)
    units = LOTS * lot
    state = {s: dict(pos=0, cash=0.0, costs=0.0, trades=0) for s in STRATS}
    prev_F, x0, rows, vol = None, None, [], None
    for i, d in enumerate(dates):
        F = days[d]["fut"][expiry]; T = years(d, expiry); S = F * math.exp(-R * T)
        mine = next((o for o in days[d]["opt"] if o["e"] == expiry and o["k"] == K and o["call"]), None)
        if mine and mine["real"]:
            vol = implied_vol(S, K, T, mine["p"])
        last = d == dates[-1]
        deltas = {}
        if not last:
            if d not in cal_cache:
                days[d]["date"] = d
                cal_cache[d] = calibrate_fast(day_quotes(days[d]), cal_cache.get("_x0"))
                cal_cache["_x0"] = cal_cache[d][0]
            params, fit, nq = cal_cache[d]
            g = {w: engine_greeks(params, S, K, T, w, FL[w]) for w in (56, 48, 44)}
            deltas = {w: g[w][0] for w in g}
            deltas["bs"] = bs_delta(S, K, T, vol)
            # minimum-variance delta: dV/dS + (rho xi / S) dV/dv, since spot and variance
            # move together under Heston (both Greeks come from the same engine pass; at
            # spot 100 the correction is rho*xi*vega/100)
            deltas["mv"] = g[56][0] + params[4] * params[3] * g[56][1] / 100.0
        for s in STRATS:
            name, freq, wl = s
            st = state[s]
            if prev_F is not None:
                st["cash"] += st["pos"] * (F - prev_F)                      # futures mark-to-market
            if name != "unhedged" and (i % freq == 0 or last):
                dl = 0 if last else (deltas["bs"] if name == "black-scholes" else
                                     deltas["mv"] if name.startswith("heston min-variance") else deltas[wl])
                target = 0 if last else lot * round(units * dl * math.exp(-R * T) / lot)
                trade = target - st["pos"]
                if trade:
                    st["costs"] += future_costs(abs(trade) * F, "buy" if trade > 0 else "sell", abs(trade))
                    st["trades"] += 1
                    st["pos"] = target
        if not last:
            rows.append(dict(date=d, F=F, T=round(T, 4), option=mine["p"] if mine else "", option_real=bool(mine and mine["real"]),
                             fit_pts=round(fit, 4), quotes=nq, d56=deltas[56], d48=deltas[48], d44=deltas[44], dbs=deltas["bs"], dmv=deltas["mv"],
                             **{n: round(float(v), 5) for n, v in zip(["v0", "kappa", "theta", "xi", "rho"], params)}))
        prev_F = F
    entry_p = next(o["p"] for o in days[entry]["opt"] if o["e"] == expiry and o["k"] == K and o["call"])
    exit_p = next(o["p"] for o in days[exit_d]["opt"] if o["e"] == expiry and o["k"] == K and o["call"])
    premium_in, buyback = entry_p * units, exit_p * units
    out = []
    for s in STRATS:
        st = state[s]
        costs = st["costs"] + option_costs(premium_in, "sell") + option_costs(buyback, "buy")
        pre_tax = premium_in - buyback + st["cash"] - costs
        tax = COSTS["income_tax"] * pre_tax if pre_tax > 0 else 0.0
        out.append(dict(entry=entry, expiry=expiry, exit=exit_d, strike=K, days=len(dates), strategy=s[0],
                        rebalance_days=s[1] or "", premium=round(premium_in), buyback=round(buyback),
                        futures_pnl=round(st["cash"]), costs=round(costs), hedge_trades=st["trades"],
                        pnl_before_tax=round(pre_tax), tax=round(tax), pnl_after_tax=round(pre_tax - tax)))
    return out, rows


def main():
    # the vectorised pricer must agree with the project reference
    p = [0.02, 2.0, 0.03, 0.5, -0.6]
    for k, c in ((22000, False), (25000, True), (27000, True)):
        a = cos_prices(p, 24500.0, [k], 0.2, [c])[0]
        b = ref.cos_price([100.0, 100.0 * k / 24500.0, 0.2, R] + p, c) * 24500.0 / 100.0
        assert abs(a - b) < 1e-8 * max(1, abs(b)), (k, a, b)
    days = load()
    trades = plan_trades(days)
    print("%d trading days, %d trades" % (len(days), len(trades)))
    os.makedirs(RES, exist_ok=True)
    allrows, cache, daily = [], {}, []
    for entry, expiry, K, exit_d in trades:
        out, rows = run_trade(days, entry, expiry, K, exit_d, cache)
        allrows += out
        daily += [dict(r, entry=entry, expiry=expiry) for r in rows]
        print("%s -> %s  exp %s  K %.0f  %d days  heston56/1d %+10.0f  unhedged %+10.0f" % (
            entry, exit_d, expiry, out[0]["strike"], out[0]["days"],
            next(o["pnl_after_tax"] for o in out if o["strategy"] == "heston 56-bit" and o["rebalance_days"] == 1),
            next(o["pnl_after_tax"] for o in out if o["strategy"] == "unhedged")))
    for name, rows in (("trades.csv", allrows), ("daily.csv", daily)):
        with open(os.path.join(RES, name), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    print("wrote", RES)


if __name__ == "__main__":
    main()
