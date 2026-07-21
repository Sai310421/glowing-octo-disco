#!/usr/bin/env python3
"""Answer to "トレンド方向のみに進めばいいのでは?" on real XAUUSD data.

Two trend-direction-only architectures, same 2026-01..07 1m series and the
same cost model as every previous experiment (spread $0.28 + slip $0.04,
CB $15/lot where noted):

A) One-sided CB grid: the CB Survivor rotation engine, but positions exist
   ONLY in the H1 EMA20/50 trend direction - nanpin into pullbacks, basket
   TP $1 rotation, flatten on trend flip. No counter-trend side, so no
   stuck-position conveyor.

B) Trend Rider SAR (the video mechanism, v1.31 close-confirmed core) on M5:
   ATR pitch pyramid with the trend, chandelier ATR trail, flip on close,
   ER regime (range => widen + halt). Fixed 0.01 lot per level.

Both report monthly PnL, max DD, volume and CB impact so they are directly
comparable with the counter-trend results (all of which lost ~$1,700/mo and
blew the $10k account on this period).
"""

import json
import os
import numpy as np
import pandas as pd

CONTRACT = 100.0
START_EQ = 10_000.0
SPREAD = 0.28
SLIP = 0.04
HALF = (SPREAD / 2 + SLIP) * CONTRACT   # $ per lot per side


def load(path):
    df = pd.read_csv(path, skiprows=1)
    df["time"] = pd.to_datetime(df["time"]).dt.tz_localize(None)
    ohlc = df[["open", "high", "low", "close"]]
    df["high"] = ohlc.max(axis=1)
    df["low"] = ohlc.min(axis=1)
    return df.reset_index(drop=True)


def h1_trend(df):
    s = df.set_index("time")["close"].resample("1h").last().dropna()
    e20 = s.ewm(span=20, adjust=False).mean()
    e50 = s.ewm(span=50, adjust=False).mean()
    # left-labeled resample puts the hour's END close on its START label;
    # shift(1) so minute rows only ever see the last COMPLETED hour
    d = ((e20 > e50).astype(int) * 2 - 1).shift(1)
    return d.reindex(df.set_index("time").index, method="ffill").fillna(0).values


def sim_one_sided_grid(df, nanpin=2.5, tp=1.0, max_pos=25, lot=0.01):
    """A) trend-side-only rotation grid."""
    c = df["close"].values
    trend = h1_trend(df)
    eq, peak, max_dd = START_EQ, START_EQ, 0.0
    pos = []          # [lot, entry]; all in 'cur' direction
    cur = 0
    vol = 0.0
    trades = flips = 0
    max_float = 0.0
    for i in range(len(c)):
        px = c[i]
        d = int(trend[i])
        f = sum(cur * (px - e) * l * CONTRACT for l, e in pos)
        eqty = eq + f
        peak = max(peak, eqty)
        max_dd = max(max_dd, (peak - eqty) / peak)
        max_float = max(max_float, -f)
        if eqty <= 0:
            return dict(blown=True, eq=eqty, vol=vol, max_dd=max_dd,
                        max_float=max_float, trades=trades, flips=flips)
        if d == 0:
            continue
        if d != cur:                       # trend flip: flatten, restart
            for l, e in pos:
                eq += cur * (px - e) * l * CONTRACT - HALF * l
                vol += l; trades += 1
            pos = []
            cur = d
            flips += 1
        # basket rotation TP
        f = sum(cur * (px - e) * l * CONTRACT - HALF * l for l, e in pos)
        if pos and f >= tp:
            for l, e in pos:
                eq += cur * (px - e) * l * CONTRACT - HALF * l
                vol += l; trades += 1
            pos = []
        # seed / pullback nanpin (WITH the trend only)
        if not pos:
            pos.append((lot, px + cur * (SPREAD / 2 + SLIP)))
        elif len(pos) < max_pos:
            adverse = cur * (pos[-1][1] - px)
            if adverse >= nanpin:
                pos.append((lot, px + cur * (SPREAD / 2 + SLIP)))
    px = c[-1]
    for l, e in pos:
        eq += cur * (px - e) * l * CONTRACT - HALF * l
        vol += l
    return dict(blown=False, eq=eq, vol=vol, max_dd=max_dd,
                max_float=max_float, trades=trades, flips=flips)


def sim_trend_rider(df, c_atr=2.0, k_trail=2.0, er_n=20, er_lo=0.30,
                    er_hi=0.45, w_range=2.0, n_max=7, lot=0.01):
    """B) video SAR mechanism (v1.31 close-confirmed core) on M5."""
    m5 = df.set_index("time").resample("5min").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last"}).dropna().reset_index()
    c = m5["close"].values
    h, l = m5["high"].values, m5["low"].values
    prev = np.concatenate(([c[0]], c[:-1]))
    tr = np.maximum(h - l, np.maximum(np.abs(h - prev), np.abs(l - prev)))
    atr = pd.Series(tr).ewm(alpha=1 / 14, adjust=False).mean().values
    dif = np.abs(np.diff(c, prepend=c[0]))
    csum = np.cumsum(dif)
    n = len(c)

    eq, peak, max_dd = START_EQ, START_EQ, 0.0
    dirn = 0
    entries = []
    last_add = leg_ext = trail_lv = 0.0
    flat_hi = flat_lo = 0.0
    rng_mode = False
    vol = 0.0
    trades = flips = 0

    for i in range(30, n):
        px = c[i]
        den = csum[i] - csum[i - er_n]
        er = abs(c[i] - c[i - er_n]) / den if den > 0 else 1.0
        if er < er_lo: rng_mode = True
        elif er >= er_hi: rng_mode = False
        pitch = max(c_atr * atr[i], 4 * SPREAD) * (w_range if rng_mode else 1.0)
        tdist = max(k_trail * atr[i], 4 * SPREAD)

        f = sum(dirn * (px - e) * lot * CONTRACT for e in entries)
        eqty = eq + f
        peak = max(peak, eqty)
        max_dd = max(max_dd, (peak - eqty) / peak)
        if eqty <= 0:
            return dict(blown=True, eq=eqty, vol=vol, max_dd=max_dd,
                        trades=trades, flips=flips)

        if dirn == 0:
            if flat_lo > 0 and px >= flat_lo + pitch:
                dirn, entries = +1, [px + SPREAD / 2 + SLIP]
            elif flat_hi > 0 and px <= flat_hi - pitch:
                dirn, entries = -1, [px - SPREAD / 2 - SLIP]
            else:
                flat_hi = px if flat_hi <= 0 else max(flat_hi, px)
                flat_lo = px if flat_lo <= 0 else min(flat_lo, px)
                continue
            last_add = leg_ext = px
            trail_lv = 0.0
            trades += 1
            continue

        if (dirn > 0 and px > leg_ext) or (dirn < 0 and px < leg_ext):
            leg_ext = px
        if not rng_mode and len(entries) < n_max and \
           ((dirn > 0 and px >= last_add + pitch) or (dirn < 0 and px <= last_add - pitch)):
            entries.append(px + dirn * (SPREAD / 2 + SLIP))
            last_add = px
            trades += 1
        t_new = leg_ext - tdist if dirn > 0 else leg_ext + tdist
        trail_lv = t_new if trail_lv == 0.0 else \
            (max(trail_lv, t_new) if dirn > 0 else min(trail_lv, t_new))
        if (dirn > 0 and px <= trail_lv) or (dirn < 0 and px >= trail_lv):
            for e in entries:
                eq += dirn * (px - e) * lot * CONTRACT - HALF * lot
                vol += lot
            flips += 1
            trades += 1
            dirn = -dirn
            entries = [px + dirn * (SPREAD / 2 + SLIP)]
            last_add = leg_ext = px
            trail_lv = 0.0
    px = c[-1]
    for e in entries:
        eq += dirn * (px - e) * lot * CONTRACT - HALF * lot
        vol += lot
    return dict(blown=False, eq=eq, vol=vol, max_dd=max_dd,
                trades=trades, flips=flips)


def main():
    path = os.environ.get("CB_DATA",
        "/tmp/claude-0/-home-user-glowing-octo-disco/74058501-f7f7-5fe1-b123-2e20f42fe8bd/scratchpad/uploads/wfo_data/XAUUSD_1m_20260104_20260703_orkad.csv")
    df = load(path)
    months = (df["time"].iloc[-1] - df["time"].iloc[0]).days / 30.4
    out = {}

    a = sim_one_sided_grid(df)
    neta = a["eq"] - START_EQ
    cba = a["vol"] * 15.0
    print(f"A) one-sided trend grid : blown={a['blown']} net(noCB)={neta:+9.2f} "
          f"({neta/months:+7.2f}/mo)  vol={a['vol']:.2f} lot  CB@15={cba/months:+6.2f}/mo  "
          f"net+CB={(neta+cba)/months:+7.2f}/mo  maxDD={a['max_dd']*100:5.1f}%  "
          f"maxFloat={a['max_float']:.0f}  trades={a['trades']} flips={a['flips']}")
    out["one_sided_grid"] = {**a, "net_no_cb": neta}

    b = sim_trend_rider(df)
    netb = b["eq"] - START_EQ
    cbb = b["vol"] * 15.0
    print(f"B) Trend Rider SAR (M5) : blown={b['blown']} net(noCB)={netb:+9.2f} "
          f"({netb/months:+7.2f}/mo)  vol={b['vol']:.2f} lot  CB@15={cbb/months:+6.2f}/mo  "
          f"net+CB={(netb+cbb)/months:+7.2f}/mo  maxDD={b['max_dd']*100:5.1f}%  "
          f"trades={b['trades']} flips={b['flips']}")
    out["trend_rider_sar"] = {**b, "net_no_cb": netb}

    with open(os.path.join(os.path.dirname(__file__), "..", "reports",
                           "trend_direction_bt.json"), "w") as f:
        json.dump(out, f, indent=1, default=float)


if __name__ == "__main__":
    main()
