#!/usr/bin/env python3
"""Feature/label engineering for a numeric OHLCV AI direction model on XAUUSD.

User request: build "1 AI-model EA" (numeric ONNX model, not vision), aimed at
the STRATEGY LAB "AI TRADER" sales page (PF 1.66, Sharpe 4.57, WR 76-78%,
maxDD 11.6-14.6% on XAUUSD, 2022-2026) - used as a REFERENCE target only.
Those numbers are third-party marketing claims, unverified, and this session
has already found one prior "amazing PF" claim (PCI/VWAP, PF 2.83 claimed)
fail real-data reproduction (PF 0.7-0.9). This module's job is to produce
HONEST walk-forward numbers on the same real data used throughout this repo -
whatever they turn out to be.

All features below are causal (built only from information available at bar
close t; no future bar informs any feature at row t).

Bars: M5 (matches every other harness in this repo - trend_direction_bt.py,
trend_rider_regime_wf.py, hyperscalp_bt.py).
"""

import numpy as np
import pandas as pd

CONTRACT = 100.0
SPREAD = 0.28
SLIP = 0.04
ROUND_TRIP_COST = SPREAD + 2 * SLIP  # entry pays half-spread+slip, exit too


def load(path):
    df = pd.read_csv(path, skiprows=1) if _has_header_comment(path) else pd.read_csv(path)
    df["time"] = pd.to_datetime(df["time"]).dt.tz_localize(None)
    ohlc = df[["open", "high", "low", "close"]]
    df["high"] = ohlc.max(axis=1)
    df["low"] = ohlc.min(axis=1)
    return df.reset_index(drop=True)


def _has_header_comment(path):
    with open(path) as f:
        return f.readline().startswith("#")


def make_m5(df):
    agg = {"open": "first", "high": "max", "low": "min", "close": "last"}
    if "volume" in df.columns:
        agg["volume"] = "sum"
    m5 = df.set_index("time").resample("5min").agg(agg).dropna(subset=["open"]).reset_index()
    return m5


def wilder_atr_rsi_adx(h, l, c, p=14):
    prev = np.concatenate(([c[0]], c[:-1]))
    tr = np.maximum(h - l, np.maximum(np.abs(h - prev), np.abs(l - prev)))
    atr = pd.Series(tr).ewm(alpha=1 / p, adjust=False).mean().values

    delta = np.diff(c, prepend=c[0])
    gain = np.where(delta > 0, delta, 0.0)
    loss = np.where(delta < 0, -delta, 0.0)
    avg_gain = pd.Series(gain).ewm(alpha=1 / p, adjust=False).mean().values
    avg_loss = pd.Series(loss).ewm(alpha=1 / p, adjust=False).mean().values
    rs = avg_gain / np.maximum(avg_loss, 1e-12)
    rsi = 100 - 100 / (1 + rs)

    up = np.maximum(h - prev, 0.0)
    dn = np.maximum(prev - l, 0.0)  # simplified DM using prev close as proxy
    plus_dm = np.where((up > dn) & (up > 0), up, 0.0)
    minus_dm = np.where((dn > up) & (dn > 0), dn, 0.0)
    a = 1 / p
    pdi = 100 * pd.Series(plus_dm).ewm(alpha=a, adjust=False).mean().values / np.maximum(atr, 1e-9)
    mdi = 100 * pd.Series(minus_dm).ewm(alpha=a, adjust=False).mean().values / np.maximum(atr, 1e-9)
    dx = 100 * np.abs(pdi - mdi) / np.maximum(pdi + mdi, 1e-9)
    adx = pd.Series(dx).ewm(alpha=a, adjust=False).mean().values
    return atr, rsi, adx


def kaufman_er(c, n=20):
    dif = np.abs(np.diff(c, prepend=c[0]))
    csum = np.cumsum(dif)
    num = np.abs(c - np.concatenate((np.full(n, np.nan), c[:-n])))
    den = csum - np.concatenate((np.full(n, np.nan), csum[:-n]))
    return num / np.maximum(den, 1e-12)


def build_features(m5):
    c = m5["close"].values
    h = m5["high"].values
    l = m5["low"].values
    n = len(c)

    atr, rsi, adx = wilder_atr_rsi_adx(h, l, c, 14)
    er20 = kaufman_er(c, 20)

    ema20 = pd.Series(c).ewm(span=20, adjust=False).mean().values
    ema50 = pd.Series(c).ewm(span=50, adjust=False).mean().values
    ema200 = pd.Series(c).ewm(span=200, adjust=False).mean().values

    bb_mid = pd.Series(c).rolling(20).mean().values
    bb_std = pd.Series(c).rolling(20).std(ddof=0).values
    bb_z = (c - bb_mid) / np.maximum(bb_std, 1e-9)

    ret1 = np.diff(c, prepend=c[0]) / c
    ret_std20 = pd.Series(ret1).rolling(20).std(ddof=0).values

    feat = pd.DataFrame(index=m5.index)
    feat["ret_1"]   = pd.Series(c).pct_change(1)
    feat["ret_3"]   = pd.Series(c).pct_change(3)
    feat["ret_6"]   = pd.Series(c).pct_change(6)
    feat["ret_12"]  = pd.Series(c).pct_change(12)
    feat["ret_24"]  = pd.Series(c).pct_change(24)
    feat["atr_norm"] = atr / c
    feat["rsi14"]    = rsi
    feat["adx14"]    = adx
    feat["er20"]     = er20
    feat["ema20_dist"]  = (c - ema20) / c
    feat["ema50_dist"]  = (c - ema50) / c
    feat["ema200_dist"] = (c - ema200) / c
    feat["ema_stack"]   = np.sign(ema20 - ema50) + np.sign(ema50 - ema200)
    feat["bb_z"]      = bb_z
    feat["vol20"]     = ret_std20
    feat["vol_ratio"] = atr / np.maximum(pd.Series(atr).rolling(50).mean().values, 1e-9)

    if "volume" in m5.columns:
        vol = m5["volume"].values.astype(float)
        vol_mean = pd.Series(vol).rolling(50).mean().values
        feat["vol_z"] = (vol - vol_mean) / np.maximum(pd.Series(vol).rolling(50).std(ddof=0).values, 1e-9)

    t = pd.to_datetime(m5["time"])
    hour = t.dt.hour + t.dt.minute / 60.0
    feat["hour_sin"] = np.sin(2 * np.pi * hour / 24.0)
    feat["hour_cos"] = np.cos(2 * np.pi * hour / 24.0)
    feat["dow"] = t.dt.dayofweek

    return feat


def build_labels(m5, horizon=12, k_atr=0.5):
    """label=1 if fwd move > threshold, 0 if < -threshold, NaN otherwise.
    threshold = max(round-trip cost, k_atr * ATR) so the label targets an
    economically meaningful move, not spread-level noise."""
    c = m5["close"].values
    atr, _, _ = wilder_atr_rsi_adx(m5["high"].values, m5["low"].values, c, 14)
    n = len(c)
    fwd = np.full(n, np.nan)
    fwd[:n - horizon] = c[horizon:] - c[:n - horizon]
    thr = np.maximum(ROUND_TRIP_COST, k_atr * atr)
    label = np.full(n, np.nan)
    label[fwd > thr] = 1.0
    label[fwd < -thr] = 0.0
    return pd.Series(label, index=m5.index), pd.Series(fwd, index=m5.index)


def month_slices(times):
    ts = pd.Series(pd.to_datetime(times))
    key = ts.dt.to_period("M")
    out = []
    for p in key.unique():
        idx = np.where(key == p)[0]
        out.append((str(p), int(idx[0]), int(idx[-1]) + 1))
    return out
