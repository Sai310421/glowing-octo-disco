#!/usr/bin/env python3
"""Independent re-verification of the OrkAD Phase3 PCI/VWAP best candidate
(reverse_h1_13_wd1_2_3_r2.0_e0.08: PF 2.83, WR 83%, 100 trades, 2.18%/mo).

The original parquet data and BT code were not provided, so two tests that
do NOT require them are run:

TEST 1 - selection-bias null: the candidate name encodes a picked cell of an
  hour/weekday grid. Simulate a NO-EDGE strategy (EV=0 after costs, RR 1.8)
  across grids of increasing size and record the distribution of the BEST
  cell's PF/WR. If the observed PF 2.83 sits far beyond the null best, the
  result cannot be explained by hour/weekday cherry-picking alone (it then
  hinges on the BT code being fill/lookahead-correct, which remains
  unverifiable here).

TEST 2 - mechanism sign: implement the strategy's core (session-VWAP +-2sigma
  edge-zone reversion, ER<thr regime gate as the ADX<30 proxy, SL 0.7*ATR,
  TP 1.8R, 0.7% risk/trade) on the calibrated synthetic XAUUSD from
  trend_rider_sim (OU range regime => genuine reversion exists) with the
  candidate's own costs (spread 28pt, slip 4pt, commission $7/lot round).
  This checks whether the MECHANISM has positive expectancy under realistic
  costs, independent of their data.
"""

import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trend_rider_sim import (gen_month, atr_series, er_series, session_vwap,
                             BARS_PER_DAY, DAYS_PER_MONTH, CONTRACT, P0)

RESULTS = os.path.join(os.path.dirname(__file__), "..", "reports",
                       "pci_vwap_reverify.json")

OBS_PF, OBS_WR, OBS_N = 2.8317, 0.83, 100
RR = 1.8


def test1_selection_null():
    """Best-cell PF/WR distribution for a no-edge grid search."""
    rng = np.random.default_rng(7)
    p0 = 1.0 / (1.0 + RR)          # EV=0 win rate for RR 1.8 (costs embedded)
    out = {}
    for cells in (60, 2760, 20000):
        reps = 400 if cells <= 2760 else 100
        best_pf = np.empty(reps)
        best_wr = np.empty(reps)
        for r in range(reps):
            wins = rng.binomial(OBS_N, p0, cells)
            pf = wins * RR / np.maximum(OBS_N - wins, 1)
            i = np.argmax(pf)
            best_pf[r] = pf[i]
            best_wr[r] = wins[i] / OBS_N
        out[cells] = {
            "p95_best_pf": float(np.percentile(best_pf, 95)),
            "p99_best_pf": float(np.percentile(best_pf, 99)),
            "p95_best_wr": float(np.percentile(best_wr, 95)),
            "p_best_pf_ge_obs": float((best_pf >= OBS_PF).mean()),
        }
        print(f"grid={cells:6d} cells: null best-cell PF p95={out[cells]['p95_best_pf']:.2f} "
              f"p99={out[cells]['p99_best_pf']:.2f}  best WR p95={out[cells]['p95_best_wr']*100:.0f}%  "
              f"P(best PF>=2.83)={out[cells]['p_best_pf_ge_obs']*100:.2f}%")
    # correlated-trades caveat: effective n smaller inflates the null
    p0v = p0
    for neff in (100, 50, 25):
        sd = math.sqrt(p0v * (1 - p0v) / neff)
        z = (OBS_WR - p0v) / sd
        print(f"  z-score of WR83% vs null at effective n={neff:3d}: {z:.1f} sigma")
    return out


def run_reversion_month(close, atr, er, vwap, cfg, rng):
    """Bracket-order VWAP-band reversion on one synthetic month."""
    eq = 100_000.0
    peak, max_dd = eq, 0.0
    wins = losses = 0
    gw = gl = 0.0
    pos = 0          # 0 flat, +-1
    entry = sl = tp = 0.0
    lots = 0.0
    cost_round = (cfg["spread"] + 2 * cfg["slip"]) * CONTRACT + cfg["commission"]
    # rolling sigma of price-vwap over one session
    dev = close - vwap
    n = len(close)
    for i in range(30, n):
        c = close[i]
        cur = eq if pos == 0 else eq + pos * (c - entry) * lots * CONTRACT
        peak = max(peak, cur)
        max_dd = max(max_dd, (peak - cur) / peak)

        if pos != 0:
            hit_sl = (pos > 0 and c <= sl) or (pos < 0 and c >= sl)
            hit_tp = (pos > 0 and c >= tp) or (pos < 0 and c <= tp)
            if hit_sl or hit_tp:
                px = sl if hit_sl else tp
                pnl = pos * (px - entry) * lots * CONTRACT - cost_round * lots
                eq += pnl
                if pnl >= 0:
                    wins += 1
                    gw += pnl
                else:
                    losses += 1
                    gl -= pnl
                pos = 0
            continue

        # flat: regime gate (ER as ADX proxy) + band edge reversal
        if er[i] >= cfg["er_max"]:
            continue
        d0 = i - (i % BARS_PER_DAY)
        sig = np.std(dev[max(d0, i - 96):i + 1])
        if sig <= 0:
            continue
        band = cfg["sigma_mult"] * sig
        edge = cfg["edge_zone"] * band
        z = dev[i]
        direction = 0
        if z >= band - edge:
            direction = -1          # fade the upper band
        elif z <= -band + edge:
            direction = +1          # fade the lower band
        if direction == 0:
            continue
        slN = cfg["sl_atr"] * atr[i]
        if slN <= 0:
            continue
        lots = max(0.01, round(eq * cfg["risk"] / (slN * CONTRACT), 2))
        entry = c
        sl = c - direction * slN
        tp = c + direction * RR * slN
        pos = direction

    tr = wins + losses
    pf = (gw / gl) if gl > 0 else float("inf")
    return eq / 100_000.0 - 1.0, max_dd, tr, (wins / tr if tr else 0.0), pf


def test2_mechanism(months=24):
    cfg = {"spread": 0.28, "slip": 0.04, "commission": 7.0,
           "er_max": 0.30, "sigma_mult": 2.0, "edge_zone": 0.08,
           "sl_atr": 0.7, "risk": 0.007}
    rows = []
    for pers, label in ((1.0, "calibrated"), (0.0, "pure-noise"), (1.5, "trendy")):
        rets, dds, trs, wrs, pfs = [], [], [], [], []
        for m in range(months):
            rng = np.random.default_rng(60_000 + m)
            close, trng, _ = gen_month(rng, pers)
            atr = atr_series(trng)
            er = er_series(close, 20)
            vwap = session_vwap(close, trng)
            r, dd, t, wr, pf = run_reversion_month(close, atr, er, vwap, cfg, rng)
            rets.append(r); dds.append(dd); trs.append(t); wrs.append(wr)
            if np.isfinite(pf):
                pfs.append(pf)
        row = {"persistence": pers,
               "median_monthly": float(np.median(rets)),
               "p5_monthly": float(np.percentile(rets, 5)),
               "p95_dd": float(np.percentile(dds, 95)),
               "trades_mo": float(np.mean(trs)),
               "win_rate": float(np.mean(wrs)),
               "median_pf": float(np.median(pfs)) if pfs else None}
        rows.append(row)
        print(f"{label:>10s}: med={row['median_monthly']*100:6.2f}%/mo "
              f"p5={row['p5_monthly']*100:6.2f}% p95DD={row['p95_dd']*100:4.1f}% "
              f"trades/mo={row['trades_mo']:4.0f} WR={row['win_rate']*100:4.1f}% "
              f"PF={row['median_pf'] if row['median_pf'] else float('nan'):.2f}")
    return rows


def main():
    print("TEST 1 - can hour/weekday cherry-picking alone produce PF 2.83 / WR 83%?")
    t1 = test1_selection_null()
    print("\nTEST 2 - mechanism sign on calibrated synthetic XAUUSD (candidate costs):")
    t2 = test2_mechanism()
    os.makedirs(os.path.dirname(os.path.abspath(RESULTS)), exist_ok=True)
    with open(RESULTS, "w") as f:
        json.dump({"observed": {"pf": OBS_PF, "wr": OBS_WR, "n": OBS_N},
                   "test1_selection_null": t1, "test2_mechanism": t2}, f, indent=1)
    print("\nsaved:", os.path.normpath(RESULTS))


if __name__ == "__main__":
    main()
