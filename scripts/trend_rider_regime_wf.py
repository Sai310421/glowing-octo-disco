#!/usr/bin/env python3
"""Walk-forward test of a causal regime gate on the Trend Rider SAR.

Question (user): can a regime filter keep the SAR flat through the weak
half (2026 Apr-Jul, -$50/mo pre-CB) without giving back the strong half
(Jan-Mar, +$160/mo)?

Gate: Kaufman ER over a LONG window N on M5 closes (the entry-level ER(20)
inside the sim stays as-is; this is a higher-level on/off switch).
Hysteresis thresholds are set from the TRAIN window's ER quantiles only
(q_on / q_off), then applied causally to the TEST month:
  ER >= quantile(train, q_on)  -> trading ON
  ER <  quantile(train, q_off) -> trading OFF (close all, sit flat)

Walk-forward: train 2 months -> test 1 month, rolling monthly. The config
(N, q_on, q_off) with the best train net+CB is applied to each test month.
Baseline = ungated SAR on the same test months. An in-sample "oracle"
(best single config over the full period) is reported only as the
hindsight ceiling, clearly labeled.

Costs: corrected model (adverse entry embeds the entry side; HALF charged
on exit only). Same data and defaults as scripts/trend_direction_bt.py.
"""

import json
import os
import numpy as np
import pandas as pd

CONTRACT = 100.0
START_EQ = 10_000.0
SPREAD = 0.28
SLIP = 0.04
HALF = (SPREAD / 2 + SLIP) * CONTRACT
LOT = 0.01

ER_WINDOWS = (100, 250, 500)
Q_ON = (0.40, 0.50, 0.60, 0.70)
Q_OFF_GAP = 0.20


def load(path):
    df = pd.read_csv(path, skiprows=1)
    df["time"] = pd.to_datetime(df["time"]).dt.tz_localize(None)
    ohlc = df[["open", "high", "low", "close"]]
    df["high"] = ohlc.max(axis=1)
    df["low"] = ohlc.min(axis=1)
    return df.reset_index(drop=True)


def make_m5(df):
    m5 = df.set_index("time").resample("5min").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last"}).dropna().reset_index()
    c = m5["close"].values
    h, l = m5["high"].values, m5["low"].values
    prev = np.concatenate(([c[0]], c[:-1]))
    tr = np.maximum(h - l, np.maximum(np.abs(h - prev), np.abs(l - prev)))
    atr = pd.Series(tr).ewm(alpha=1 / 14, adjust=False).mean().values
    dif = np.abs(np.diff(c, prepend=c[0]))
    csum = np.cumsum(dif)
    return m5["time"].values, c, h, l, atr, csum


def er_series(c, csum, n_er):
    n = len(c)
    er = np.full(n, np.nan)
    for i in range(n_er, n):
        den = csum[i] - csum[i - n_er]
        er[i] = abs(c[i] - c[i - n_er]) / den if den > 0 else 1.0
    return er


def sim(c, atr, csum, gate, i0, i1,
        c_atr=2.0, k_trail=2.0, er_n=20, er_lo=0.30, er_hi=0.45,
        w_range=2.0, n_max=7):
    """SAR core (corrected costs) over bars [i0, i1); gate=None -> ungated."""
    eq = 0.0                       # PnL only; DD tracked on START_EQ + PnL
    peak, max_dd = START_EQ, 0.0
    dirn = 0
    entries = []
    last_add = leg_ext = trail_lv = 0.0
    flat_hi = flat_lo = 0.0
    rng_mode = False
    vol = 0.0
    flips = 0
    off_bars = 0

    for i in range(i0, i1):
        px = c[i]
        allowed = True if gate is None else bool(gate[i])

        if not allowed:
            off_bars += 1
            if dirn != 0:          # close everything, sit flat
                for e in entries:
                    eq += dirn * (px - e) * LOT * CONTRACT - HALF * LOT
                    vol += LOT
                dirn = 0
                entries = []
            flat_hi = flat_lo = px # keep breakout anchors fresh
            trail_lv = 0.0
            continue

        den = csum[i] - csum[i - er_n]
        er = abs(c[i] - c[i - er_n]) / den if den > 0 else 1.0
        if er < er_lo: rng_mode = True
        elif er >= er_hi: rng_mode = False
        pitch = max(c_atr * atr[i], 4 * SPREAD) * (w_range if rng_mode else 1.0)
        tdist = max(k_trail * atr[i], 4 * SPREAD)

        f = sum(dirn * (px - e) * LOT * CONTRACT for e in entries)
        eqty = START_EQ + eq + f
        peak = max(peak, eqty)
        max_dd = max(max_dd, (peak - eqty) / peak)

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
            continue

        if (dirn > 0 and px > leg_ext) or (dirn < 0 and px < leg_ext):
            leg_ext = px
        if not rng_mode and len(entries) < n_max and \
           ((dirn > 0 and px >= last_add + pitch) or (dirn < 0 and px <= last_add - pitch)):
            entries.append(px + dirn * (SPREAD / 2 + SLIP))
            last_add = px
        t_new = leg_ext - tdist if dirn > 0 else leg_ext + tdist
        trail_lv = t_new if trail_lv == 0.0 else \
            (max(trail_lv, t_new) if dirn > 0 else min(trail_lv, t_new))
        if (dirn > 0 and px <= trail_lv) or (dirn < 0 and px >= trail_lv):
            for e in entries:
                eq += dirn * (px - e) * LOT * CONTRACT - HALF * LOT
                vol += LOT
            flips += 1
            dirn = -dirn
            entries = [px + dirn * (SPREAD / 2 + SLIP)]
            last_add = leg_ext = px
            trail_lv = 0.0

    px = c[i1 - 1]
    for e in entries:
        eq += dirn * (px - e) * LOT * CONTRACT - HALF * LOT
        vol += LOT
    return dict(net=eq, vol=vol, max_dd=max_dd, flips=flips,
                off_frac=off_bars / max(i1 - i0, 1))


def build_gate(er, thr_on, thr_off, i0, i1):
    """Hysteresis gate over [i0, i1); starts ON if er[i0] >= thr_on."""
    n = len(er)
    g = np.zeros(n, dtype=bool)
    state = bool(er[i0] >= thr_on) if not np.isnan(er[i0]) else False
    for i in range(i0, i1):
        e = er[i]
        if not np.isnan(e):
            if e >= thr_on: state = True
            elif e < thr_off: state = False
        g[i] = state
    return g


def month_slices(times):
    ts = pd.Series(pd.to_datetime(times))
    key = ts.dt.to_period("M")
    out = []
    for p in key.unique():
        idx = np.where(key == p)[0]
        out.append((str(p), int(idx[0]), int(idx[-1]) + 1))
    return out


def main():
    path = os.environ.get("CB_DATA",
        "/tmp/claude-0/-home-user-glowing-octo-disco/74058501-f7f7-5fe1-b123-2e20f42fe8bd/scratchpad/uploads/wfo_data/XAUUSD_1m_20260104_20260703_orkad.csv")
    times, c, h, l, atr, csum = make_m5(load(path))
    ers = {n: er_series(c, csum, n) for n in ER_WINDOWS}
    months = month_slices(times)
    print("months:", [m[0] for m in months])

    warm = max(ER_WINDOWS) + 30

    def run_cfg(n_er, q_on, i_tr0, i_tr1, i_te0, i_te1):
        er = ers[n_er]
        tr_vals = er[max(i_tr0, n_er):i_tr1]
        tr_vals = tr_vals[~np.isnan(tr_vals)]
        thr_on = np.quantile(tr_vals, q_on)
        thr_off = np.quantile(tr_vals, max(q_on - Q_OFF_GAP, 0.0))
        g_tr = build_gate(er, thr_on, thr_off, i_tr0, i_tr1)
        g_te = build_gate(er, thr_on, thr_off, i_te0, i_te1)
        r_tr = sim(c, atr, csum, g_tr, i_tr0, i_tr1)
        r_te = sim(c, atr, csum, g_te, i_te0, i_te1)
        return r_tr, r_te

    # --- walk-forward: train = 2 preceding months, test = next month ---
    wf_rows = []
    for k in range(2, len(months)):
        tr0 = max(months[k - 2][1], warm)
        tr1 = months[k - 1][2]
        te0, te1 = months[k][1], months[k][2]
        mdays = (pd.to_datetime(times[te1 - 1]) - pd.to_datetime(times[te0])).days / 30.4
        best = None
        for n_er in ER_WINDOWS:
            for q_on in Q_ON:
                r_tr, r_te = run_cfg(n_er, q_on, tr0, tr1, te0, te1)
                score = r_tr["net"] + r_tr["vol"] * 15.0
                if best is None or score > best[0]:
                    best = (score, n_er, q_on, r_te)
        base = sim(c, atr, csum, None, te0, te1)
        _, n_er, q_on, r_te = best
        wf_rows.append(dict(month=months[k][0], n_er=n_er, q_on=q_on,
                            gated=r_te, base=base, mdays=mdays))
        print(f"{months[k][0]}: pick N={n_er} q_on={q_on:.2f} | "
              f"gated net={r_te['net']/mdays:+7.2f}/mo (+CB {(r_te['net']+r_te['vol']*15)/mdays:+7.2f}) "
              f"off={r_te['off_frac']*100:4.1f}% DD={r_te['max_dd']*100:4.1f}% | "
              f"base net={base['net']/mdays:+7.2f}/mo (+CB {(base['net']+base['vol']*15)/mdays:+7.2f}) "
              f"DD={base['max_dd']*100:4.1f}%")

    tot_m = sum(r["mdays"] for r in wf_rows)
    g_net = sum(r["gated"]["net"] for r in wf_rows)
    g_cb = sum(r["gated"]["vol"] for r in wf_rows) * 15.0
    b_net = sum(r["base"]["net"] for r in wf_rows)
    b_cb = sum(r["base"]["vol"] for r in wf_rows) * 15.0
    print(f"\nWF total ({tot_m:.1f}mo, test months only):")
    print(f"  gated : net={g_net/tot_m:+7.2f}/mo  +CB={(g_net+g_cb)/tot_m:+7.2f}/mo  "
          f"maxDD(worst month)={max(r['gated']['max_dd'] for r in wf_rows)*100:.1f}%")
    print(f"  base  : net={b_net/tot_m:+7.2f}/mo  +CB={(b_net+b_cb)/tot_m:+7.2f}/mo  "
          f"maxDD(worst month)={max(r['base']['max_dd'] for r in wf_rows)*100:.1f}%")

    # --- hindsight ceiling: best single config over the full period ---
    i0, i1 = warm, len(c)
    full_m = (pd.to_datetime(times[i1 - 1]) - pd.to_datetime(times[i0])).days / 30.4
    best = None
    for n_er in ER_WINDOWS:
        for q_on in Q_ON:
            er = ers[n_er]
            vals = er[n_er:i1]
            vals = vals[~np.isnan(vals)]
            thr_on = np.quantile(vals, q_on)
            thr_off = np.quantile(vals, max(q_on - Q_OFF_GAP, 0.0))
            g = build_gate(er, thr_on, thr_off, i0, i1)
            r = sim(c, atr, csum, g, i0, i1)
            score = r["net"] + r["vol"] * 15.0
            if best is None or score > best[0]:
                best = (score, n_er, q_on, r)
    _, n_er, q_on, r = best
    print(f"\nOracle (full-period best, HINDSIGHT ONLY): N={n_er} q_on={q_on:.2f} "
          f"net={r['net']/full_m:+7.2f}/mo +CB={(r['net']+r['vol']*15)/full_m:+7.2f}/mo "
          f"off={r['off_frac']*100:.1f}% DD={r['max_dd']*100:.1f}%")

    with open(os.path.join(os.path.dirname(__file__), "..", "reports",
                           "trend_rider_regime_wf.json"), "w") as f:
        json.dump(dict(wf=[{**row, "gated": row["gated"], "base": row["base"]}
                           for row in wf_rows],
                       oracle=dict(n_er=n_er, q_on=q_on, **r)),
                  f, indent=1, default=float)


if __name__ == "__main__":
    main()
