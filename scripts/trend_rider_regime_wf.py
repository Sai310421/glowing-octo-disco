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

Walk-forward: train 2 months -> test 1 month, rolling monthly.

IMPORTANT (fixed after review): every variant below - baseline, each of the
12 fixed (N, q_on) candidates, and the per-fold-selected config - is run as
ONE CONTINUOUS simulation across the whole test span (first test month's
start to the last test month's end), not as separate per-month sim() calls.
The only thing that changes between months is which gate array segment is
active (each month's thresholds still come only from ITS OWN trailing
2-month train window, so causality is preserved); positions, breakout
anchors and trailing state now carry across month boundaries exactly as
they would in live trading. Every fixed candidate's continuous result is
serialized to reports/trend_rider_regime_wf.json - "N of 12 beat baseline"
and the headline config are read directly from that array, not typed in by
hand.

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
BAR_MIN = 5  # M5

ER_WINDOWS = (100, 250, 500)
Q_ON = (0.40, 0.50, 0.60, 0.70)
Q_OFF_GAP = 0.20


def bars_to_human(n_bars):
    hours = n_bars * BAR_MIN / 60.0
    if hours < 36:
        return f"{hours:.1f}h"
    return f"{hours/24.0:.1f}d"


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
    """SAR core (corrected costs) over bars [i0, i1); gate=None -> ungated.
    ONE continuous pass - caller is responsible for the gate array already
    spanning [i0, i1) with fold-appropriate (causal) thresholds baked in."""
    eq = 0.0
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
            if dirn != 0:
                for e in entries:
                    eq += dirn * (px - e) * LOT * CONTRACT - HALF * LOT
                    vol += LOT
                dirn = 0
                entries = []
            flat_hi = flat_lo = px
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


def hysteresis_from_quantiles(er, thr_on, thr_off, i0, i1):
    """Hysteresis gate segment over [i0, i1); starts ON if er[i0] >= thr_on."""
    g = np.zeros(len(er), dtype=bool)
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


def causal_thresholds(er, n_er, tr0, tr1, q_on):
    vals = er[max(tr0, n_er):tr1]
    vals = vals[~np.isnan(vals)]
    thr_on = np.quantile(vals, q_on)
    thr_off = np.quantile(vals, max(q_on - Q_OFF_GAP, 0.0))
    return thr_on, thr_off


def main():
    path = os.environ.get("CB_DATA",
        "/tmp/claude-0/-home-user-glowing-octo-disco/74058501-f7f7-5fe1-b123-2e20f42fe8bd/scratchpad/uploads/wfo_data/XAUUSD_1m_20260104_20260703_orkad.csv")
    times, c, h, l, atr, csum = make_m5(load(path))
    ers = {n: er_series(c, csum, n) for n in ER_WINDOWS}
    months = month_slices(times)
    print("months:", [m[0] for m in months])
    print("ER window durations:", {n: bars_to_human(n) for n in ER_WINDOWS})

    warm = max(ER_WINDOWS) + 30
    n_bars = len(c)

    # continuous test span = first test fold's start .. last month's end
    test_i0 = months[2][1]
    test_i1 = months[-1][2]
    test_months_days = (pd.to_datetime(times[test_i1 - 1]) - pd.to_datetime(times[test_i0])).days / 30.4

    def continuous_gate_for_family(n_er, q_on_fn):
        """Build one gate array spanning [test_i0, test_i1) by stitching each
        month's OWN causal thresholds (from its trailing 2-month window).
        q_on_fn(month_index) -> q_on to use for that month (fixed or selected)."""
        er = ers[n_er]
        g = np.zeros(n_bars, dtype=bool)
        for k in range(2, len(months)):
            tr0 = max(months[k - 2][1], warm)
            tr1 = months[k - 1][2]
            te0, te1 = months[k][1], months[k][2]
            q_on = q_on_fn(k)
            thr_on, thr_off = causal_thresholds(er, n_er, tr0, tr1, q_on)
            seg = hysteresis_from_quantiles(er, thr_on, thr_off, te0, te1)
            g[te0:te1] = seg[te0:te1]
        return g

    # --- baseline: continuous, no gate ---
    base = sim(c, atr, csum, None, test_i0, test_i1)
    base_net_mo = base["net"] / test_months_days
    base_cb_mo = (base["net"] + base["vol"] * 15.0) / test_months_days
    print(f"\nbaseline (continuous, {test_months_days:.1f}mo): "
          f"net={base_net_mo:+7.2f}/mo  +CB={base_cb_mo:+7.2f}/mo  maxDD={base['max_dd']*100:5.1f}%")

    # --- all 12 fixed configs, each run as ONE continuous sim ---
    fixed_results = []
    for n_er in ER_WINDOWS:
        for q_on in Q_ON:
            g = continuous_gate_for_family(n_er, lambda k, q=q_on: q)
            r = sim(c, atr, csum, g, test_i0, test_i1)
            net_mo = r["net"] / test_months_days
            cb_mo = (r["net"] + r["vol"] * 15.0) / test_months_days
            fixed_results.append(dict(n_er=n_er, q_on=q_on, net_mo=net_mo, cb_mo=cb_mo,
                                      off_frac=r["off_frac"], max_dd=r["max_dd"], flips=r["flips"]))
            print(f"fixed N={n_er:3d} ({bars_to_human(n_er)}) q_on={q_on:.2f}: "
                  f"net={net_mo:+7.2f}/mo  +CB={cb_mo:+7.2f}/mo  off={r['off_frac']*100:4.1f}%  "
                  f"maxDD={r['max_dd']*100:4.1f}%")

    beat = sum(1 for r in fixed_results if r["net_mo"] > base_net_mo)
    pos_cb = sum(1 for r in fixed_results if r["cb_mo"] > 0)
    headline = max(fixed_results, key=lambda r: r["net_mo"])
    print(f"\nfixed-config family: {beat}/{len(fixed_results)} beat the continuous baseline "
          f"({base_net_mo:+.2f}/mo); {pos_cb}/{len(fixed_results)} positive net+CB")
    print(f"best fixed config (in-sample search over this family): N={headline['n_er']} "
          f"q_on={headline['q_on']:.2f} -> net={headline['net_mo']:+.2f}/mo +CB={headline['cb_mo']:+.2f}/mo")

    # --- per-fold selection (selects (N,q_on) per fold from TRAIN score only) ---
    def per_fold_q_on(k):
        er_choices = {}
        for n_er in ER_WINDOWS:
            er = ers[n_er]
            tr0 = max(months[k - 2][1], warm)
            tr1 = months[k - 1][2]
            best = None
            for q_on in Q_ON:
                thr_on, thr_off = causal_thresholds(er, n_er, tr0, tr1, q_on)
                g_tr = hysteresis_from_quantiles(er, thr_on, thr_off, tr0, tr1)
                r_tr = sim(c, atr, csum, g_tr, tr0, tr1)
                score = r_tr["net"] + r_tr["vol"] * 15.0
                if best is None or score > best[0]:
                    best = (score, n_er, q_on)
            er_choices[n_er] = best
        best_overall = max(er_choices.values(), key=lambda t: t[0])
        return best_overall[1], best_overall[2]  # n_er, q_on

    g_wf = np.zeros(n_bars, dtype=bool)
    wf_fold_log = []
    for k in range(2, len(months)):
        n_er, q_on = per_fold_q_on(k)
        tr0 = max(months[k - 2][1], warm)
        tr1 = months[k - 1][2]
        te0, te1 = months[k][1], months[k][2]
        thr_on, thr_off = causal_thresholds(ers[n_er], n_er, tr0, tr1, q_on)
        seg = hysteresis_from_quantiles(ers[n_er], thr_on, thr_off, te0, te1)
        g_wf[te0:te1] = seg[te0:te1]
        wf_fold_log.append(dict(month=months[k][0], n_er=n_er, q_on=q_on))
    r_wf = sim(c, atr, csum, g_wf, test_i0, test_i1)
    wf_net_mo = r_wf["net"] / test_months_days
    wf_cb_mo = (r_wf["net"] + r_wf["vol"] * 15.0) / test_months_days
    print(f"\nper-fold selection (continuous): net={wf_net_mo:+7.2f}/mo  +CB={wf_cb_mo:+7.2f}/mo  "
          f"maxDD={r_wf['max_dd']*100:5.1f}%  folds={wf_fold_log}")

    # --- in-sample searched optimum over this ER-gate family (NOT a ceiling
    #     on all possible gates - just the best of the 12 candidates tested,
    #     applied causally fold-by-fold like the fixed configs above but
    #     picked with full-period hindsight) ---
    searched_best = max(fixed_results, key=lambda r: r["net_mo"])
    print(f"\nin-sample searched optimum (hindsight pick among the 12 candidates, "
          f"NOT an upper bound on all possible gates): N={searched_best['n_er']} "
          f"q_on={searched_best['q_on']:.2f} net={searched_best['net_mo']:+.2f}/mo "
          f"+CB={searched_best['cb_mo']:+.2f}/mo")

    with open(os.path.join(os.path.dirname(__file__), "..", "reports",
                           "trend_rider_regime_wf.json"), "w") as f:
        json.dump(dict(
            test_months_days=test_months_days,
            baseline=dict(net_mo=base_net_mo, cb_mo=base_cb_mo, max_dd=base["max_dd"]),
            fixed_configs=fixed_results,
            beat_baseline_count=beat,
            positive_with_cb_count=pos_cb,
            per_fold_selection=dict(net_mo=wf_net_mo, cb_mo=wf_cb_mo,
                                    max_dd=r_wf["max_dd"], folds=wf_fold_log),
            searched_optimum=searched_best,
        ), f, indent=1, default=float)


if __name__ == "__main__":
    main()
