#!/usr/bin/env python3
"""Real-data backtest of the OrkAD Phase3 PCI/VWAP candidate on XAUUSD M5.

Runs the strategy encoded in AMOS_Phase3_PCI_VWAP_OrkAD_BEST_R2_E008.set on a
user-supplied bar file and executes the four pending validations from
docs/inbox/pci_vwap_orkad_reverification.md.

Data input (--data): parquet or CSV of M5 bars. Accepted layouts:
  - MT5 chart export:  DATE,TIME,OPEN,HIGH,LOW,CLOSE,TICKVOL[,VOL,SPREAD]
  - generic:           time/datetime, open, high, low, close, volume|tickvol
  Timestamps are assumed UTC unless --tz-offset (hours, e.g. 2 for UTC+2
  server time) is given, in which case they are shifted to UTC first.

Modes:
  --mode full       one pass, full period, report PF/WR/DD/monthly
  --mode oos        first half vs second half
  --mode hours      hour-perturbation grid around the chosen h=1,13
  --mode wfo        rolling walk-forward: re-pick hour pair on train, apply
                    on test; reports WFE = OOS return / IS return
  --mode mc         trade-order bootstrap: P(maxDD > 10%), P(ruin)
  --mode all        everything above in sequence

INTERPRETATION NOTES (the .set has no code, so two ambiguous fields are
implemented with the most conservative plausible reading and are flagged in
the output; flip them via CLI if the original BT meant otherwise):
  - partial_profit_pct=0.55 read as +0.55% of EQUITY on the open position
    (sibling fields target_cycle_profit_pct/max_cycle_dd_pct are equity-%).
    Alternative reading (R-multiple 0.55) via --partial-r.
  - entries are evaluated on CLOSED bars; SL/TP fills use bar high/low with
    worst-case ordering (SL before TP when both are inside one bar).
"""

import argparse
import json
import math
import os

import numpy as np
import pandas as pd

CONTRACT = 100.0
CFG = {  # from the .set
    "starting_equity": 100_000.0,
    "risk_pct": 0.0035 * 2.0,        # range_risk_pct * risk_mult
    "spread": 0.28, "slip": 0.04, "commission": 7.0,
    "max_hold_bars": 72,
    "min_bars_after_session_start": 12,
    "max_adx": 30.0,
    "edge_zone_pct": 0.08,
    "sigma_mult": 2.0,
    "sl_atr": 0.7,
    "rr": 1.8,
    "partial_profit_eq_pct": 0.0055,
    "partial_fraction": 0.5,
    "target_cycle_profit_pct": 0.012,
    "max_cycle_dd_pct": 0.03,
    "max_daily_dd_pct": 0.03,
    "hours": (1, 13),
    "weekdays": (0, 1, 2),           # Mon,Tue,Wed (pandas dayofweek)
}


def load_data(path, tz_offset=0.0):
    if path.endswith(".parquet"):
        df = pd.read_parquet(path)
    else:
        df = pd.read_csv(path, sep=None, engine="python")
    df.columns = [str(c).strip().lower().replace("<", "").replace(">", "") for c in df.columns]
    if "date" in df.columns and "time" in df.columns:
        ts = pd.to_datetime(df["date"].astype(str) + " " + df["time"].astype(str))
    else:
        tcol = next(c for c in df.columns if c in ("time", "datetime", "timestamp", "date"))
        ts = pd.to_datetime(df[tcol])
    df = df.assign(ts=ts - pd.Timedelta(hours=tz_offset)).sort_values("ts")
    vol = None
    for c in ("tickvol", "tick_volume", "volume", "vol"):
        if c in df.columns:
            vol = df[c].astype(float).values
            break
    if vol is None:
        vol = np.ones(len(df))
    out = pd.DataFrame({
        "ts": df["ts"].values,
        "open": df["open"].astype(float).values,
        "high": df["high"].astype(float).values,
        "low": df["low"].astype(float).values,
        "close": df["close"].astype(float).values,
        "vol": np.maximum(vol, 1e-9),
    }).reset_index(drop=True)
    # integrity checks - refuse silently broken data
    assert out["ts"].is_monotonic_increasing, "timestamps not sorted"
    assert (out[["open", "high", "low", "close"]] > 0).all().all(), "non-positive prices"
    assert (out["high"] >= out["low"]).all(), "high < low rows present"
    step = out["ts"].diff().dropna().dt.total_seconds().mode().iloc[0]
    print(f"loaded {len(out)} bars  {out['ts'].iloc[0]} .. {out['ts'].iloc[-1]}  "
          f"modal step {step/60:.0f}m")
    return out


def indicators(df):
    h, l, c = df["high"].values, df["low"].values, df["close"].values
    n = len(df)
    prev_c = np.concatenate(([c[0]], c[:-1]))
    tr = np.maximum(h - l, np.maximum(np.abs(h - prev_c), np.abs(l - prev_c)))
    atr = pd.Series(tr).ewm(alpha=1 / 14, adjust=False).mean().values
    # Wilder ADX(14)
    up = np.concatenate(([0.0], np.diff(h)))
    dn = np.concatenate(([0.0], -np.diff(l)))
    plus_dm = np.where((up > dn) & (up > 0), up, 0.0)
    minus_dm = np.where((dn > up) & (dn > 0), dn, 0.0)
    a = 1 / 14
    atr_w = pd.Series(tr).ewm(alpha=a, adjust=False).mean().values
    pdi = 100 * pd.Series(plus_dm).ewm(alpha=a, adjust=False).mean().values / np.maximum(atr_w, 1e-9)
    mdi = 100 * pd.Series(minus_dm).ewm(alpha=a, adjust=False).mean().values / np.maximum(atr_w, 1e-9)
    dx = 100 * np.abs(pdi - mdi) / np.maximum(pdi + mdi, 1e-9)
    adx = pd.Series(dx).ewm(alpha=a, adjust=False).mean().values
    # session (UTC-day) anchored VWAP + rolling sigma of deviation
    day = pd.to_datetime(df["ts"]).dt.floor("D")
    day_change = day.ne(day.shift()).values
    vwap = np.empty(n)
    sess_start = np.empty(n, dtype=int)
    cum_pv = cum_v = 0.0
    s0 = 0
    tp = (h + l + c) / 3.0
    for i in range(n):
        if day_change[i]:
            cum_pv = cum_v = 0.0
            s0 = i
        cum_pv += tp[i] * df["vol"].iloc[i]
        cum_v += df["vol"].iloc[i]
        vwap[i] = cum_pv / cum_v
        sess_start[i] = s0
    dev = c - vwap
    sigma = pd.Series(dev).rolling(96, min_periods=24).std().values
    return atr, adx, vwap, sigma, sess_start


def run(df, hours, weekdays, cfg=CFG, partial_r=False, collect_curve=False):
    atr, adx, vwap, sigma, sess_start = indicators(df)
    ts = pd.to_datetime(df["ts"])
    hour = ts.dt.hour.values
    wd = ts.dt.dayofweek.values
    day = ts.dt.floor("D").values
    o, h, l, c = (df[k].values for k in ("open", "high", "low", "close"))
    n = len(df)

    eq = cfg["starting_equity"]
    peak, max_dd = eq, 0.0
    day_start_eq, cur_day = eq, day[0]
    max_daily_loss = 0.0
    halt_today = False
    pos = 0
    entry = sl = tp = 0.0
    lots = 0.0
    bars_held = 0
    partial_done = False
    wins = losses = 0
    gw = gl = 0.0
    curve = []
    trades = []
    cost_half = (cfg["spread"] / 2 + cfg["slip"]) * CONTRACT  # per lot per side

    def book(pnl, i, tag):
        nonlocal eq, wins, losses, gw, gl
        eq += pnl
        if pnl >= 0:
            wins += 1; gw += pnl
        else:
            losses += 1; gl -= pnl
        trades.append({"i": int(i), "ts": str(df['ts'].iloc[i]), "pnl": float(pnl), "tag": tag})

    for i in range(1, n):
        if day[i] != cur_day:
            cur_day = day[i]
            day_start_eq = eq
            halt_today = False
        cur = eq if pos == 0 else eq + pos * (c[i] - entry) * lots * CONTRACT
        peak = max(peak, cur)
        max_dd = max(max_dd, (peak - cur) / peak)
        dl = (day_start_eq - cur) / day_start_eq
        max_daily_loss = max(max_daily_loss, dl)
        if collect_curve:
            curve.append(cur)
        if dl >= cfg["max_daily_dd_pct"]:
            halt_today = True
            if pos != 0:  # flatten at close price
                pnl = pos * (c[i] - entry) * lots * CONTRACT - cost_half * lots - cfg["commission"] * lots / 2
                book(pnl, i, "daily_dd_flat")
                pos = 0

        if pos != 0:
            bars_held += 1
            # partial take: +0.55% equity (default) or +0.55R
            if not partial_done:
                gain = pos * (c[i] - entry) * lots * CONTRACT
                trigger = (gain >= cfg["partial_profit_eq_pct"] * eq) if not partial_r \
                    else (pos * (c[i] - entry) >= 0.55 * abs(entry - sl))
                if trigger:
                    part = lots * cfg["partial_fraction"]
                    pnl = pos * (c[i] - entry) * part * CONTRACT - cost_half * part - cfg["commission"] * part / 2
                    book(pnl, i, "partial")
                    lots -= part
                    partial_done = True
            # worst-case intrabar ordering: SL first
            hit_sl = (pos > 0 and l[i] <= sl) or (pos < 0 and h[i] >= sl)
            hit_tp = (pos > 0 and h[i] >= tp) or (pos < 0 and l[i] <= tp)
            px = None
            tag = ""
            if hit_sl:
                px, tag = sl, "sl"
            elif hit_tp:
                px, tag = tp, "tp"
            elif bars_held >= cfg["max_hold_bars"]:
                px, tag = c[i], "time"
            if px is not None:
                pnl = pos * (px - entry) * lots * CONTRACT - cost_half * lots - cfg["commission"] * lots / 2
                book(pnl, i, tag)
                pos = 0
            continue

        # flat: gates
        if halt_today or hour[i] not in hours or wd[i] not in weekdays:
            continue
        if i - sess_start[i] < cfg["min_bars_after_session_start"]:
            continue
        if not np.isfinite(sigma[i]) or sigma[i] <= 0 or adx[i] >= cfg["max_adx"]:
            continue
        band = cfg["sigma_mult"] * sigma[i]
        edge = cfg["edge_zone_pct"] * band
        z = c[i] - vwap[i]
        direction = 0
        if cfg.get("strict_zone"):
            # strict reading: fade only INSIDE the zone [band-edge, band+edge];
            # beyond it is breakout territory (enable_breakout=false => no trade)
            if band - edge <= z <= band + edge:
                direction = -1
            elif -band - edge <= z <= -band + edge:
                direction = +1
        else:
            if z >= band - edge:
                direction = -1
            elif z <= -band + edge:
                direction = +1
        if direction == 0:
            continue
        slN = cfg["sl_atr"] * atr[i]
        if slN <= 0:
            continue
        lots = max(0.01, round(eq * cfg["risk_pct"] / (slN * CONTRACT), 2))
        entry = c[i] + direction * (cfg["spread"] / 2 + cfg["slip"])
        sl = entry - direction * slN
        tp = entry + direction * cfg["rr"] * slN
        pos = direction
        bars_held = 0
        partial_done = False
        # entry-side spread/slip is already inside the adverse entry price;
        # only the commission half is charged here
        eq -= cfg["commission"] * lots / 2

    months = max((ts.iloc[-1] - ts.iloc[0]).days / 30.4, 1e-9)
    total_ret = eq / cfg["starting_equity"] - 1.0
    res = {
        "trades": wins + losses,
        "win_rate": wins / max(wins + losses, 1),
        "pf": (gw / gl) if gl > 0 else float("inf"),
        "total_return": total_ret,
        "monthly_return": (1 + total_ret) ** (1 / months) - 1 if total_ret > -1 else -1.0,
        "max_dd": max_dd,
        "max_daily_loss": max_daily_loss,
        "months": months,
    }
    return (res, trades, curve) if collect_curve else (res, trades, None)


def fmt(r):
    return (f"trades={r['trades']:4d} WR={r['win_rate']*100:5.1f}% PF={r['pf']:5.2f} "
            f"ret={r['total_return']*100:7.2f}% (mo {r['monthly_return']*100:5.2f}%) "
            f"maxDD={r['max_dd']*100:5.2f}% dayDD={r['max_daily_loss']*100:4.2f}%")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--tz-offset", type=float, default=0.0,
                    help="hours to SUBTRACT to convert timestamps to UTC")
    ap.add_argument("--mode", default="all",
                    choices=["full", "oos", "hours", "wfo", "mc", "all"])
    ap.add_argument("--partial-r", action="store_true",
                    help="read partial_profit as 0.55R instead of 0.55% equity")
    ap.add_argument("--strict-zone", action="store_true",
                    help="fade only inside [band-edge, band+edge]; beyond band = no trade")
    args = ap.parse_args()
    if args.strict_zone:
        CFG["strict_zone"] = True

    df = load_data(args.data, args.tz_offset)
    out = {}
    modes = [args.mode] if args.mode != "all" else ["full", "oos", "hours", "wfo", "mc"]

    if "full" in modes:
        r, tr, _ = run(df, CFG["hours"], CFG["weekdays"], partial_r=args.partial_r)
        print("[full]  ", fmt(r))
        print("         claimed: trades= 100 WR= 83.0% PF= 2.83 mo 2.18% maxDD 2.99%")
        out["full"] = r

    if "oos" in modes:
        half = len(df) // 2
        for name, part in (("IS(1st half)", df.iloc[:half]), ("OOS(2nd half)", df.iloc[half:])):
            r, _, _ = run(part.reset_index(drop=True), CFG["hours"], CFG["weekdays"],
                          partial_r=args.partial_r)
            print(f"[oos]    {name:14s}", fmt(r))
            out.setdefault("oos", {})[name] = r

    if "hours" in modes:
        print("[hours] perturbation around h=(1,13): a cliff = curve-fit hours")
        for hh in [(0, 12), (0, 13), (1, 12), (1, 13), (1, 14), (2, 13), (2, 14), (0, 14)]:
            r, _, _ = run(df, hh, CFG["weekdays"], partial_r=args.partial_r)
            print(f"         h={hh}: ", fmt(r))
            out.setdefault("hours", {})[str(hh)] = r

    if "wfo" in modes:
        ts = pd.to_datetime(df["ts"])
        t0, t1 = ts.iloc[0], ts.iloc[-1]
        cur = t0
        is_rets, oos_rets = [], []
        print("[wfo]   rolling 8w train -> 4w test, hour pair re-picked each window")
        while cur + pd.Timedelta(weeks=12) <= t1:
            tr_df = df[(ts >= cur) & (ts < cur + pd.Timedelta(weeks=8))].reset_index(drop=True)
            te_df = df[(ts >= cur + pd.Timedelta(weeks=8)) & (ts < cur + pd.Timedelta(weeks=12))].reset_index(drop=True)
            best, best_ret = None, -9e9
            for h1 in range(0, 24, 2):
                for h2 in range(h1, 24, 2):
                    r, _, _ = run(tr_df, (h1, h2), CFG["weekdays"], partial_r=args.partial_r)
                    if r["trades"] >= 10 and r["total_return"] > best_ret:
                        best, best_ret = (h1, h2), r["total_return"]
            if best:
                rt, _, _ = run(te_df, best, CFG["weekdays"], partial_r=args.partial_r)
                is_rets.append(best_ret)
                oos_rets.append(rt["total_return"])
                print(f"         {cur.date()} train h={best} IS={best_ret*100:6.2f}% -> OOS={rt['total_return']*100:6.2f}%")
            cur += pd.Timedelta(weeks=4)
        if is_rets:
            wfe = (np.mean(oos_rets) / np.mean(is_rets)) if np.mean(is_rets) > 0 else float("nan")
            print(f"         WFE = {wfe:.2f}  (factory bar: >= 0.50)")
            out["wfo"] = {"is": is_rets, "oos": oos_rets, "wfe": float(wfe)}

    if "mc" in modes:
        _, trades, _ = run(df, CFG["hours"], CFG["weekdays"], partial_r=args.partial_r)
        pnl = np.array([t["pnl"] for t in trades])
        if len(pnl) >= 10:
            rng = np.random.default_rng(1)
            fails = dd10 = 0
            for _ in range(2000):
                path = CFG["starting_equity"] + np.cumsum(rng.permutation(pnl))
                peak = np.maximum.accumulate(np.concatenate(([CFG["starting_equity"]], path)))
                dd = ((peak[1:] - path) / peak[1:]).max()
                if dd >= 0.10:
                    dd10 += 1
                if path.min() <= CFG["starting_equity"] * 0.5:
                    fails += 1
            print(f"[mc]    bootstrap x2000: P(maxDD>=10%)={dd10/20:.1f}%  P(-50% ruin)={fails/20:.1f}%")
            out["mc"] = {"p_dd10": dd10 / 2000, "p_ruin50": fails / 2000}

    path = os.path.join(os.path.dirname(__file__), "..", "reports", "pci_vwap_bt_result.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=1, default=float)
    print("saved:", os.path.normpath(path))


if __name__ == "__main__":
    main()
