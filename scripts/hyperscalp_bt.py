#!/usr/bin/env python3
"""HyperScalp v1.21/v1.30 mechanical core backtest on real XAUUSD 1m.

Replicates the EA's firing path (Claude gate excluded - in the Strategy
Tester it is bypassed anyway, so this IS the tester-equivalent run):

  new M1 bar, flat, no pendings ->
    RangeEntryScore = avg(scoreBB, scoreADX, scoreATR) using
      BB(20,2) width percentile vs 150 bars (squeeze),
      ADX(14) last-5-bars-below-20 fraction,
      ATR(14) percentile vs 150 bars
    score >= 0.58 -> range = hi/lo of the last 16 completed M1 bars
    ICT bias (M15 EMA20/50, PDH/PDL sweep, 20-bar MSS, EA's precedence)
    bias BUY  and price breaks below range_low  -> 12 BUY  limits every
      150pt ($1.50) below the trigger, SL = range_low - $2, TP = range_high
    bias SELL and price breaks above range_high -> mirrored
  basket managed by: per-order SL/TP + Giveback trailing (peak >= $10,
  close all when profit <= peak * (1 - 40%)), limits cancelled only on
  the giveback close (as coded in the EA).

Two SL variants are run because of a defect found while porting:
  A) as-coded: SL = range_low - SlBuffer($2). Any BUY limit deeper than
     $2 below the range violates SL<price and is REJECTED by the EA's own
     guard -> with default step $1.50 only limit #1 survives (11/12 die).
  B) intended cluster: SL = deepest limit - $2 (all 12 valid).

Costs: same model as every prior experiment (spread $0.28 + slip $0.04
per side per lot, contract 100). Fixed 0.01 lot. Conservative intrabar
ordering: SL before TP within the same bar.
"""

import json
import os
import numpy as np
import pandas as pd

CONTRACT = 100.0
START_EQ = 10_000.0
SPREAD = 0.28
SLIP = 0.04
HALF = (SPREAD / 2 + SLIP) * CONTRACT      # $ per 1.0 lot per side
LOT = 0.01

# EA defaults
BB_P, BB_DEV = 20, 2.0
ATR_P, ADX_P = 14, 14
LOOKBACK = 150
SCORE_MIN = 0.58
BB_SQ_PCT, ATR_LOW_PCT, ADX_MAX, ADX_LB = 15.0, 25.0, 20.0, 5
RANGE_BARS = 16
STEP = 1.50            # PyramidStepPoints 150 * point 0.01
N_ORDERS = 12
GIVEBACK = 0.40
GB_ARM = 10.0          # peak >= $10 arms the giveback
SL_BUF = 2.0
SWING_LB = 20


def load(path):
    df = pd.read_csv(path, skiprows=1)
    df["time"] = pd.to_datetime(df["time"]).dt.tz_localize(None)
    ohlc = df[["open", "high", "low", "close"]]
    df["high"] = ohlc.max(axis=1)
    df["low"] = ohlc.min(axis=1)
    return df.reset_index(drop=True)


def wilder_adx(h, l, c, p):
    up = np.diff(h, prepend=h[0])
    dn = -np.diff(l, prepend=l[0])
    plus_dm = np.where((up > dn) & (up > 0), up, 0.0)
    minus_dm = np.where((dn > up) & (dn > 0), dn, 0.0)
    prev = np.concatenate(([c[0]], c[:-1]))
    tr = np.maximum(h - l, np.maximum(np.abs(h - prev), np.abs(l - prev)))
    a = 1.0 / p
    atr = pd.Series(tr).ewm(alpha=a, adjust=False).mean().values
    pdi = 100 * pd.Series(plus_dm).ewm(alpha=a, adjust=False).mean().values / np.maximum(atr, 1e-9)
    mdi = 100 * pd.Series(minus_dm).ewm(alpha=a, adjust=False).mean().values / np.maximum(atr, 1e-9)
    dx = 100 * np.abs(pdi - mdi) / np.maximum(pdi + mdi, 1e-9)
    return pd.Series(dx).ewm(alpha=a, adjust=False).mean().values, atr


def precompute(df):
    c = df["close"].values
    h = df["high"].values
    l = df["low"].values
    n = len(c)

    ma = pd.Series(c).rolling(BB_P).mean()
    sd = pd.Series(c).rolling(BB_P).std(ddof=0)
    width = (2 * BB_DEV * sd).values
    adx, atr = wilder_adx(h, l, c, ATR_P)

    # fraction of window (t-LOOKBACK..t-1) strictly below x[t]
    def frac_below(x):
        import bisect
        out = np.full(n, np.nan)
        window = []
        for t in range(n):
            if t >= LOOKBACK:
                out[t] = bisect.bisect_left(window, x[t]) / LOOKBACK
            bisect.insort(window, x[t])
            if len(window) > LOOKBACK:
                window.pop(bisect.bisect_left(window, x[t - LOOKBACK]))
        return out

    bb_pct = frac_below(np.nan_to_num(width)) * 100.0
    atr_pct = frac_below(atr) * 100.0

    score_bb = np.where(bb_pct <= BB_SQ_PCT, 1.0,
                        np.maximum(0.0, 1.0 - (bb_pct - BB_SQ_PCT) / (100.0 - BB_SQ_PCT)))
    adx_below = pd.Series((adx < ADX_MAX).astype(float)).rolling(ADX_LB).mean().values
    score_atr = np.where(atr_pct <= ATR_LOW_PCT, 1.0,
                         np.maximum(0.0, 1.0 - (atr_pct - ATR_LOW_PCT) / (100.0 - ATR_LOW_PCT)))
    score = (score_bb + adx_below + score_atr) / 3.0

    # M15 EMA bias, ffilled to M1
    s = df.set_index("time")["close"].resample("15min").last().dropna()
    e20 = s.ewm(span=20, adjust=False).mean()
    e50 = s.ewm(span=50, adjust=False).mean()
    d = (e20 > e50).astype(int) * 2 - 1
    ema_bias = d.reindex(df.set_index("time").index, method="ffill").fillna(0).values

    # previous-day high/low
    day = df.set_index("time")
    dh = day["high"].resample("1D").max().shift(1)
    dl = day["low"].resample("1D").min().shift(1)
    pdh = dh.reindex(day.index, method="ffill").values
    pdl = dl.reindex(day.index, method="ffill").values

    # 20-bar swing (completed bars 1..20)
    swing_hi = pd.Series(h).shift(1).rolling(SWING_LB).max().values
    swing_lo = pd.Series(l).shift(1).rolling(SWING_LB).min().values

    rng_hi = pd.Series(h).shift(1).rolling(RANGE_BARS).max().values
    rng_lo = pd.Series(l).shift(1).rolling(RANGE_BARS).min().values

    return dict(c=c, h=h, l=l, score=score, ema=ema_bias, pdh=pdh, pdl=pdl,
                swhi=swing_hi, swlo=swing_lo, rhi=rng_hi, rlo=rng_lo, n=n)


def ict_bias(P, t):
    ema = int(P["ema"][t])
    c0, h0, l0 = P["c"][t], P["h"][t], P["l"][t]
    sweep = 0
    if not np.isnan(P["pdl"][t]):
        if l0 < P["pdl"][t] and c0 > P["pdl"][t]:
            sweep = 1
        if h0 > P["pdh"][t] and c0 < P["pdh"][t]:
            sweep = -1
    mss = 0
    if not np.isnan(P["swhi"][t]):
        if c0 > P["swhi"][t]:
            mss = 1
        if c0 < P["swlo"][t]:
            mss = -1
    if sweep != 0 and mss != 0 and sweep == mss:
        return sweep
    if mss != 0 and mss == ema:
        return mss
    return ema


def run(P, sl_mode):
    """sl_mode: 'as_coded' (A) or 'deep' (B)."""
    n = P["n"]
    eq, peak_eq, max_dd = START_EQ, START_EQ, 0.0
    pos = []          # dicts: dir, entry, sl, tp
    pend = []         # dicts: dir, price, sl, tp
    gb_peak = 0.0
    vol = trades = setups = rejected = 0
    max_float = 0.0

    t = LOOKBACK + RANGE_BARS + 5
    while t < n:
        c0, h0, l0 = P["c"][t], P["h"][t], P["l"][t]

        # --- fills of pending limits (limit price touched) ---
        still = []
        for o in pend:
            if (o["dir"] > 0 and l0 <= o["price"]) or (o["dir"] < 0 and h0 >= o["price"]):
                pos.append(dict(dir=o["dir"], entry=o["price"], sl=o["sl"], tp=o["tp"]))
                eq -= HALF * LOT
                vol += LOT
                trades += 1
            else:
                still.append(o)
        pend = still

        # --- SL/TP exits (SL first = conservative) ---
        alive = []
        for p in pos:
            if p["dir"] > 0:
                if l0 <= p["sl"]:
                    eq += (p["sl"] - p["entry"]) * LOT * CONTRACT - HALF * LOT
                elif h0 >= p["tp"]:
                    eq += (p["tp"] - p["entry"]) * LOT * CONTRACT - HALF * LOT
                else:
                    alive.append(p)
            else:
                if h0 >= p["sl"]:
                    eq += (p["entry"] - p["sl"]) * LOT * CONTRACT - HALF * LOT
                elif l0 >= 0 and l0 <= p["tp"]:
                    eq += (p["entry"] - p["tp"]) * LOT * CONTRACT - HALF * LOT
                else:
                    alive.append(p)
        pos = alive

        # --- giveback trailing on basket close-profit ---
        if pos:
            prof = sum(pp["dir"] * (c0 - pp["entry"]) * LOT * CONTRACT for pp in pos)
            gb_peak = max(gb_peak, prof)
            if gb_peak >= GB_ARM and prof <= gb_peak * (1.0 - GIVEBACK):
                for pp in pos:
                    eq += pp["dir"] * (c0 - pp["entry"]) * LOT * CONTRACT - HALF * LOT
                pos = []
                pend = []          # CancelAllLimits happens on this path only
                gb_peak = 0.0
        else:
            if not pend:
                gb_peak = 0.0

        # --- equity tracking ---
        f = sum(pp["dir"] * (c0 - pp["entry"]) * LOT * CONTRACT for pp in pos)
        eqty = eq + f
        peak_eq = max(peak_eq, eqty)
        max_dd = max(max_dd, (peak_eq - eqty) / peak_eq)
        max_float = max(max_float, -f)
        if eqty <= 0:
            return dict(blown=True, eq=eqty, vol=vol, max_dd=max_dd, trades=trades,
                        setups=setups, rejected=rejected, max_float=max_float)

        # --- new setup only when totally flat (EA: BlockNewOrder) ---
        if not pos and not pend:
            sc = P["score"][t]
            if not np.isnan(sc) and sc >= SCORE_MIN and not np.isnan(P["rlo"][t]):
                rlo, rhi = P["rlo"][t], P["rhi"][t]
                bias = ict_bias(P, t)
                fired = 0
                if bias == 1 and l0 < rlo:
                    trigger = rlo
                    sl_a = rlo - SL_BUF
                    sl_b = trigger - N_ORDERS * STEP - SL_BUF
                    for i in range(N_ORDERS):
                        px = trigger - (i + 1) * STEP
                        sl = sl_a if sl_mode == "as_coded" else sl_b
                        if sl >= px:      # the EA's own SL-inversion guard
                            rejected += 1
                            continue
                        pend.append(dict(dir=1, price=px, sl=sl, tp=rhi))
                        fired += 1
                elif bias == -1 and h0 > rhi:
                    trigger = rhi
                    sl_a = rhi + SL_BUF
                    sl_b = trigger + N_ORDERS * STEP + SL_BUF
                    for i in range(N_ORDERS):
                        px = trigger + (i + 1) * STEP
                        sl = sl_a if sl_mode == "as_coded" else sl_b
                        if sl <= px:
                            rejected += 1
                            continue
                        pend.append(dict(dir=-1, price=px, sl=sl, tp=rlo))
                        fired += 1
                if fired:
                    setups += 1
        t += 1

    # liquidate
    c0 = P["c"][n - 1]
    for pp in pos:
        eq += pp["dir"] * (c0 - pp["entry"]) * LOT * CONTRACT - HALF * LOT
    return dict(blown=False, eq=eq, vol=vol, max_dd=max_dd, trades=trades,
                setups=setups, rejected=rejected, max_float=max_float)


def main():
    path = os.environ.get("CB_DATA",
        "/tmp/claude-0/-home-user-glowing-octo-disco/74058501-f7f7-5fe1-b123-2e20f42fe8bd/scratchpad/uploads/wfo_data/XAUUSD_1m_20260104_20260703_orkad.csv")
    df = load(path)
    months = (df["time"].iloc[-1] - df["time"].iloc[0]).days / 30.4
    P = precompute(df)
    out = {}
    for mode, label in [("as_coded", "A) SL=range-2$ (v1.21 as coded)"),
                        ("deep",     "B) SL=deepest-2$ (intended cluster)")]:
        r = run(P, mode)
        net = r["eq"] - START_EQ
        cb = r["vol"] * 15.0
        print(f"{label}: blown={r['blown']} net={net:+9.2f} ({net/months:+7.2f}/mo) "
              f"vol={r['vol']:.2f} lot  CB@15={cb/months:+6.2f}/mo  net+CB={(net+cb)/months:+7.2f}/mo  "
              f"maxDD={r['max_dd']*100:5.1f}%  maxFloat={r['max_float']:.0f}  "
              f"setups={r['setups']} trades={r['trades']} rejectedOrders={r['rejected']}")
        out[mode] = {**r, "net": net}
    with open(os.path.join(os.path.dirname(__file__), "..", "reports",
                           "hyperscalp_bt.json"), "w") as f:
        json.dump(out, f, indent=1, default=float)


if __name__ == "__main__":
    main()
