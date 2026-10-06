"""Download NSE F&O daily files ("bhavcopy") and keep the NIFTY rows the hedging
case study needs.

    .venv/bin/python validation/hedging/fetch_nse.py 2025-09-01 2026-09-30
    -> validation/hedging/data/nifty_fo.csv

Source: NSE's public archive, one zip per trading day
(nsearchives.nseindia.com/content/fo/BhavCopy_NSE_FO_0_0_0_YYYYMMDD_F_0000.csv.zip).
Raw zips are cached in validation/hedging/data_raw/ (not committed). Kept rows:
NIFTY index options (IDO) of the monthly expiries with strikes within +-12% of the
underlying, and NIFTY futures (IDF). Days without a file (weekends, holidays) are
skipped.
"""
import csv
import datetime as dt
import io
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "data_raw")
OUT = os.path.join(HERE, "data", "nifty_fo.csv")
URL = "https://nsearchives.nseindia.com/content/fo/BhavCopy_NSE_FO_0_0_0_%s_F_0000.csv.zip"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"
KEEP = ["TradDt", "FinInstrmTp", "XpryDt", "StrkPric", "OptnTp", "ClsPric", "SttlmPric",
        "UndrlygPric", "OpnIntrst", "TtlTradgVol", "NewBrdLotQty"]


def fetch(day):
    path = os.path.join(RAW, day.strftime("%Y%m%d") + ".zip")
    if os.path.exists(path):
        return path if os.path.getsize(path) > 0 else None
    req = urllib.request.Request(URL % day.strftime("%Y%m%d"), headers={"User-Agent": UA})
    try:
        data = urllib.request.urlopen(req, timeout=30).read()
    except urllib.error.HTTPError as e:
        if e.code == 404:                      # no trading that day
            open(path, "wb").close()
            return None
        raise
    open(path, "wb").write(data)
    time.sleep(0.4)                            # be polite to the archive
    return path


def monthly(expiries):
    """the last expiry date of each calendar month"""
    last = {}
    for e in expiries:
        last[e[:7]] = max(last.get(e[:7], e), e)
    return set(last.values())


def main():
    start = dt.date.fromisoformat(sys.argv[1] if len(sys.argv) > 1 else "2025-09-01")
    end = dt.date.fromisoformat(sys.argv[2] if len(sys.argv) > 2 else "2026-09-30")
    os.makedirs(RAW, exist_ok=True)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    rows_out, days = [], 0
    d = start
    while d <= end:
        if d.weekday() < 5:
            path = fetch(d)
            if path:
                z = zipfile.ZipFile(path)
                rows = [r for r in csv.DictReader(io.TextIOWrapper(z.open(z.namelist()[0]), encoding="utf-8"))
                        if r["TckrSymb"] == "NIFTY"]
                months = monthly({r["XpryDt"] for r in rows if r["FinInstrmTp"] == "IDO"})
                for r in rows:
                    if r["FinInstrmTp"] == "IDF":
                        rows_out.append({k: r[k] for k in KEEP})
                    elif r["FinInstrmTp"] == "IDO" and r["XpryDt"] in months:
                        s, k = float(r["UndrlygPric"]), float(r["StrkPric"])
                        if abs(k / s - 1) <= 0.12:
                            rows_out.append({k2: r[k2] for k2 in KEEP})
                days += 1
                print("\r%s  %d trading days, %d rows" % (d, days, len(rows_out)), end="", flush=True)
        d += dt.timedelta(days=1)
    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=KEEP)
        w.writeheader()
        w.writerows(rows_out)
    print("\nwrote %s: %d trading days, %d rows" % (OUT, days, len(rows_out)))


if __name__ == "__main__":
    main()
