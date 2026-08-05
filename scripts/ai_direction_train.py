#!/usr/bin/env python3
"""Train + walk-forward-verify a numeric OHLCV LightGBM direction model on
real XAUUSD M5 data, honestly, against the STRATEGY LAB "AI TRADER" sales
page reference numbers (PF 1.66, Sharpe 4.57, WR 76-78%, maxDD 11.6-14.6%,
XAUUSD, 2022-2026). Those are unverified third-party marketing claims - this
script does not target them, it measures what a real model trained on the
data this repo actually has produces, walk-forward, no lookahead.

Design (expanding-window walk-forward, same cadence as
scripts/trend_rider_regime_wf.py): train on all months before the test
month, predict on the test month, only take a trade when predicted
probability clears a confidence band (p_hi/p_lo); hold for the label's
horizon, then exit. Reports per-fold and aggregate PF/Sharpe/WR/maxDD, and
the classifier's own AUC/accuracy on the labeled subset (separate from the
confidence-filtered trading numbers).
"""

import json
import os
import numpy as np
import pandas as pd
from lightgbm import LGBMClassifier
from sklearn.metrics import roc_auc_score, accuracy_score

from ai_direction_features import (
    load, make_m5, build_features, build_labels, month_slices,
    CONTRACT, SPREAD, SLIP, ROUND_TRIP_COST,
)

LOT = 0.01
HORIZON = 12          # bars (M5) = 1h forward
K_ATR = 0.5
WARMUP = 250           # bars to drop for indicator warmup at the very start
CONF_BANDS = (0.55, 0.60, 0.65)  # p_hi; p_lo = 1 - p_hi (symmetric)

LGBM_PARAMS = dict(
    n_estimators=200, num_leaves=15, max_depth=4, learning_rate=0.05,
    subsample=0.8, colsample_bytree=0.8, min_child_samples=50,
    reg_lambda=1.0, verbose=-1,
)


def sharpe_of(pnls, periods_per_year):
    if len(pnls) < 2 or np.std(pnls) == 0:
        return 0.0
    return float(np.mean(pnls) / np.std(pnls) * np.sqrt(periods_per_year))


def simulate_fold(proba, m5, i0, i1, p_hi, p_lo, horizon=HORIZON):
    c = m5["close"].values
    trades = []  # (pnl_dollars_per_lot,)
    i = i0
    while i < i1 - horizon:
        p = proba[i]
        direction = 0
        if p >= p_hi: direction = 1
        elif p <= p_lo: direction = -1
        if direction != 0:
            entry = c[i] + direction * (SPREAD / 2 + SLIP)
            exitp = c[i + horizon] - direction * (SPREAD / 2 + SLIP)
            pnl = direction * (exitp - entry) * LOT * CONTRACT
            trades.append(pnl)
            i += horizon  # no overlapping trades
        else:
            i += 1
    return trades


def maxdd_of(pnls, start_eq=10_000.0):
    eq = start_eq + np.cumsum(pnls)
    peak = np.maximum.accumulate(np.concatenate(([start_eq], eq)))[1:]
    dd = (peak - eq) / peak
    return float(dd.max()) if len(dd) else 0.0


def main():
    path = os.environ.get("CB_DATA",
        "/tmp/claude-0/-home-user-glowing-octo-disco/74058501-f7f7-5fe1-b123-2e20f42fe8bd/scratchpad/xauusd_1m_repaired.csv")
    df = load(path)
    m5 = make_m5(df)
    feat = build_features(m5)
    label, fwd = build_labels(m5, horizon=HORIZON, k_atr=K_ATR)
    months = month_slices(m5["time"].values)
    print("months:", [m[0] for m in months])
    print(f"bars={len(m5)}  labeled={label.notna().sum()}  "
          f"up={int((label==1).sum())} down={int((label==0).sum())}")

    feat_cols = feat.columns.tolist()
    X_all = feat.values
    y_all = label.values
    valid_row = ~np.isnan(X_all).any(axis=1)

    results = {ph: dict(trades=[], fold_auc=[], fold_acc=[], fold_n=[]) for ph in CONF_BANDS}
    months_days_total = 0.0

    for k in range(2, len(months)):
        tr0 = max(months[0][1], WARMUP)
        tr1 = months[k - 1][2]
        te0, te1 = months[k][1], months[k][2]
        mdays = (pd.to_datetime(m5["time"].iloc[te1 - 1]) - pd.to_datetime(m5["time"].iloc[te0])).days / 30.4
        months_days_total += mdays

        tr_mask = valid_row.copy()
        tr_mask[:tr0] = False
        tr_mask[tr1:] = False
        tr_mask &= ~np.isnan(y_all)
        Xtr, ytr = X_all[tr_mask], y_all[tr_mask]
        if len(np.unique(ytr)) < 2 or len(ytr) < 200:
            print(f"{months[k][0]}: skipped (insufficient labeled train rows: {len(ytr)})")
            continue

        model = LGBMClassifier(**LGBM_PARAMS)
        model.fit(Xtr, ytr)

        te_mask = np.zeros(len(m5), dtype=bool)
        te_mask[te0:te1] = True
        te_valid = te_mask & valid_row
        proba_full = np.full(len(m5), 0.5)
        if te_valid.any():
            proba_full[te_valid] = model.predict_proba(X_all[te_valid])[:, 1]

        te_labeled = te_valid & ~np.isnan(y_all)
        if te_labeled.sum() >= 20:
            yhat = (proba_full[te_labeled] >= 0.5).astype(int)
            auc = roc_auc_score(y_all[te_labeled], proba_full[te_labeled])
            acc = accuracy_score(y_all[te_labeled], yhat)
        else:
            auc, acc = float("nan"), float("nan")

        print(f"{months[k][0]}: train_n={len(ytr)}  test_labeled_n={int(te_labeled.sum())}  "
              f"AUC={auc:.3f}  ACC={acc:.3f}")

        for p_hi in CONF_BANDS:
            p_lo = 1.0 - p_hi
            trades = simulate_fold(proba_full, m5, te0, te1, p_hi, p_lo)
            results[p_hi]["trades"].extend(trades)
            results[p_hi]["fold_auc"].append(auc)
            results[p_hi]["fold_acc"].append(acc)
            results[p_hi]["fold_n"].append(len(trades))

    print(f"\n=== Aggregate out-of-sample (walk-forward, {months_days_total:.1f} test-months) ===")
    summary = {}
    for p_hi in CONF_BANDS:
        trades = results[p_hi]["trades"]
        n = len(trades)
        if n == 0:
            print(f"conf>={p_hi:.2f}: no trades taken")
            continue
        wins = [t for t in trades if t > 0]
        losses = [t for t in trades if t <= 0]
        gross_win = sum(wins); gross_loss = -sum(losses)
        pf = gross_win / gross_loss if gross_loss > 0 else float("inf")
        wr = len(wins) / n
        net = sum(trades)
        cb = n * LOT * 15.0  # $15/lot cashback convention used throughout this repo
        dd = maxdd_of(trades)
        trades_per_year = n / (months_days_total / 12.0) if months_days_total > 0 else 0
        sharpe = sharpe_of(trades, trades_per_year) if trades_per_year > 0 else 0.0
        print(f"conf>={p_hi:.2f}: n={n:4d}  WR={wr*100:5.1f}%  PF={pf:5.2f}  Sharpe(ann)={sharpe:5.2f}  "
              f"net={net:+9.2f} ({net/months_days_total:+7.2f}/mo)  +CB={(net+cb)/months_days_total:+7.2f}/mo  "
              f"maxDD={dd*100:5.1f}%")
        summary[p_hi] = dict(n=n, win_rate=wr, pf=pf, sharpe=sharpe, net=net,
                             net_mo=net / months_days_total,
                             net_cb_mo=(net + cb) / months_days_total, max_dd=dd)

    # feature importance from a final full-data fit (deployment candidate;
    # NOT used for any of the OOS numbers above)
    full_mask = valid_row & ~np.isnan(y_all)
    full_model = LGBMClassifier(**LGBM_PARAMS)
    full_model.fit(X_all[full_mask], y_all[full_mask])
    importances = sorted(zip(feat_cols, full_model.feature_importances_),
                         key=lambda x: -x[1])
    print("\nfeature importances (full-data fit, for reference only):")
    for name, imp in importances:
        print(f"  {name:14s} {imp}")

    with open(os.path.join(os.path.dirname(__file__), "..", "reports",
                           "ai_direction_wf.json"), "w") as f:
        json.dump(dict(months_test_days=months_days_total, summary=summary,
                       feature_importance=dict(importances)), f, indent=1, default=float)


if __name__ == "__main__":
    main()
