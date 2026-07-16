#!/usr/bin/env python3
"""Train the BOOM direction model and export it to ONNX for the EA.

Pipeline (spec section 20, "Self Optimization"): learn in Python, ship only a
validated model to the EA. It needs real Deriv BOOM_100 data and honest
out-of-sample validation. It ships no model and makes no performance claim
(Rule 3).

I/O contract is fixed by ai/FEATURES.md (must match AssembleFeatures in the EA):
  input  'features'      float32[1, 14]
  output 'probabilities' float32[1, 3]   class order [RANGE, UP, DOWN]

Input CSV schema (one row per bar, oldest first):
  time, open, high, low, close[, spread]
  'spread' is in points; if absent it is treated as 0.

TRAIN/SERVE SKEW WARNING: these feature formulas are a reference implementation
in pandas and will NOT match MT5's iATR/iRSI/iADX exactly. For production, prefer
generating the feature vector in the EA (AssembleFeatures) and dumping it to CSV,
so the SAME code computes features at train and inference time.

Usage:
  python3 train_direction_model.py --csv bars.csv --out direction.onnx
  python3 train_direction_model.py --smoke-test        # synthetic data, no claim
"""
import argparse

# Canonical feature order — MUST match ai/FEATURES.md and the EA.
FEATURES = [
    "atr", "tick_velocity", "spread", "ema_slope", "adx", "rsi",
    "mss", "bos", "displacement", "liquidity_sweep", "fvg", "vegas",
    "spike_age", "distance_from_high",
]
ICT_FEATURES = ["mss", "bos", "displacement", "liquidity_sweep", "fvg", "vegas"]
CLASS_ORDER = ["RANGE", "UP", "DOWN"]   # indices 0, 1, 2
N_FEATURES = len(FEATURES)


def _wilder(series, period):
    """Wilder smoothing (RMA), used by ATR/RSI/ADX."""
    return series.ewm(alpha=1.0 / period, adjust=False).mean()


def build_features(df, atr_p=14, rsi_p=14, adx_p=14, ema_p=50,
                   spike_tau=5, spike_vel=40.0, high_lookback=100):
    """Return a DataFrame of the 14 features in FEATURES order.

    Computed: atr, tick_velocity, spread, ema_slope, adx, rsi, spike_age,
    distance_from_high. The six ICT/structure features are 0.0 placeholders
    until defined AND validated for importance on a synthetic index (no real
    order flow) — see ai/FEATURES.md.
    """
    import numpy as np
    import pandas as pd

    o, h, l, c = df["open"], df["high"], df["low"], df["close"]
    prev_c = c.shift(1)

    # True Range / ATR (Wilder)
    tr = pd.concat([h - l, (h - prev_c).abs(), (l - prev_c).abs()], axis=1).max(axis=1)
    atr = _wilder(tr, atr_p)

    # RSI (Wilder)
    delta = c.diff()
    gain = _wilder(delta.clip(lower=0.0), rsi_p)
    loss = _wilder((-delta).clip(lower=0.0), rsi_p)
    rs = gain / loss.replace(0.0, np.nan)
    rsi = 100.0 - 100.0 / (1.0 + rs)
    rsi = rsi.fillna(50.0)

    # ADX (Wilder)
    up_move = h.diff()
    down_move = -l.diff()
    plus_dm = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
    minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)
    atr_di = _wilder(tr, adx_p).replace(0.0, np.nan)
    plus_di = 100.0 * _wilder(pd.Series(plus_dm, index=df.index), adx_p) / atr_di
    minus_di = 100.0 * _wilder(pd.Series(minus_dm, index=df.index), adx_p) / atr_di
    dx = 100.0 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0.0, np.nan)
    adx = _wilder(dx.fillna(0.0), adx_p)

    # EMA slope
    ema = c.ewm(span=ema_p, adjust=False).mean()
    ema_slope = ema.diff()

    # tick velocity (bar proxy, matches EA c0-c1)
    tick_velocity = c.diff()

    # spread (points) if provided
    spread = df["spread"] if "spread" in df.columns else pd.Series(0.0, index=df.index)

    # spike_age: bars since the last up-spike over `spike_tau`
    spike = ((c - c.shift(spike_tau)) / spike_tau) >= spike_vel
    age = np.full(len(df), float(high_lookback))
    last = -1
    spike_vals = spike.to_numpy()
    for i in range(len(df)):
        if spike_vals[i]:
            last = i
        age[i] = float(min(high_lookback, i - last)) if last >= 0 else float(high_lookback)
    spike_age = pd.Series(age, index=df.index)

    # distance_from_high over a rolling window
    distance_from_high = h.rolling(high_lookback, min_periods=1).max() - c

    out = pd.DataFrame(index=df.index)
    out["atr"] = atr
    out["tick_velocity"] = tick_velocity
    out["spread"] = spread
    out["ema_slope"] = ema_slope
    out["adx"] = adx
    out["rsi"] = rsi
    for name in ICT_FEATURES:
        out[name] = 0.0                      # placeholder until validated
    out["spike_age"] = spike_age
    out["distance_from_high"] = distance_from_high
    return out[FEATURES]


def make_labels(df, horizon=10, atr_k=0.5, atr_p=14):
    """3-class forward label over `horizon` bars with an ATR-scaled RANGE band.

    band_t = atr_k * ATR_t / close_t
    fret_t = close_{t+h} / close_t - 1
    UP(1) if fret > band, DOWN(2) if fret < -band, else RANGE(0).

    `horizon` and `atr_k` are modeling choices that MUST be justified by
    validation, not accepted as-is.
    """
    import numpy as np
    import pandas as pd

    c = df["close"]
    prev_c = c.shift(1)
    tr = pd.concat([df["high"] - df["low"],
                    (df["high"] - prev_c).abs(),
                    (df["low"] - prev_c).abs()], axis=1).max(axis=1)
    atr = _wilder(tr, atr_p)
    band = atr_k * atr / c
    fret = c.shift(-horizon) / c - 1.0

    label = pd.Series(0, index=df.index, dtype="int64")   # RANGE
    label[fret > band] = 1                                 # UP
    label[fret < -band] = 2                                # DOWN
    label[fret.isna()] = -1                                # drop (no future)
    return label


def _prepare(df):
    import numpy as np
    X = build_features(df)
    y = make_labels(df)
    mask = (~X.isna().any(axis=1)) & (y >= 0)
    X = X[mask].to_numpy(dtype=np.float32)
    y = y[mask].to_numpy(dtype=np.int64)
    return X, y


def train(csv_path, onnx_out):
    import numpy as np
    import pandas as pd
    df = pd.read_csv(csv_path)
    X, y = _prepare(df)
    if len(X) < 2000:
        raise SystemExit(f"Only {len(X)} usable rows; need substantially more real data.")

    try:
        import torch
        import torch.nn as nn
    except ImportError as exc:
        raise SystemExit(f"Missing dependency for training/export: {exc} (need torch).")

    cut = int(len(X) * 0.7)   # time-ordered split, NO shuffle
    Xtr, Xte, ytr, yte = X[:cut], X[cut:], y[:cut], y[cut:]

    class MLP(nn.Module):
        def __init__(self, n_in, n_out):
            super().__init__()
            self.net = nn.Sequential(
                nn.Linear(n_in, 32), nn.ReLU(),
                nn.Linear(32, 16), nn.ReLU(),
                nn.Linear(16, n_out),
            )

        def forward(self, x):
            return torch.softmax(self.net(x), dim=1)   # single output = probabilities

    model = MLP(N_FEATURES, len(CLASS_ORDER))
    opt = torch.optim.Adam(model.parameters(), lr=1e-3)
    loss_fn = nn.NLLLoss()
    Xtr_t, ytr_t = torch.from_numpy(Xtr), torch.from_numpy(ytr)
    for _ in range(300):
        opt.zero_grad()
        p = model(Xtr_t).clamp_min(1e-9)
        loss_fn(p.log(), ytr_t).backward()
        opt.step()

    with torch.no_grad():
        pred = model(torch.from_numpy(Xte)).argmax(1).numpy()
    acc = float((pred == yte).mean()) if len(yte) else 0.0
    base = float((yte == np.bincount(ytr, minlength=3).argmax()).mean()) if len(yte) else 0.0
    print(f"OOS accuracy {acc:.3f} vs majority baseline {base:.3f}. "
          f"Beating the baseline is necessary but NOT sufficient — it must also "
          f"translate to positive-EV recovery in the backtest before use.")

    torch.onnx.export(
        model, torch.zeros(1, N_FEATURES), onnx_out,
        input_names=["features"], output_names=["probabilities"], opset_version=13,
    )
    print(f"Exported {onnx_out}: features[1,{N_FEATURES}] -> probabilities"
          f"[1,{len(CLASS_ORDER)}], classes {CLASS_ORDER}.")


def smoke_test():
    """Run the feature/label code on a synthetic random walk. Verifies the code
    paths execute; it is NOT a result and says nothing about edge."""
    import numpy as np
    import pandas as pd
    n = 3000
    steps = np.random.default_rng(0).normal(0, 5, n).cumsum() + 100000.0
    close = pd.Series(steps)
    df = pd.DataFrame({
        "time": np.arange(n),
        "open": close.shift(1).fillna(close.iloc[0]),
        "high": close + 3.0,
        "low": close - 3.0,
        "close": close,
        "spread": 2.0,
    })
    X, y = _prepare(df)
    counts = np.bincount(y, minlength=3)
    print(f"smoke-test OK: X={X.shape}, features={N_FEATURES}, "
          f"class counts RANGE/UP/DOWN = {counts.tolist()} (synthetic; not a result).")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", help="bar data CSV (Deriv BOOM_100)")
    ap.add_argument("--out", default="direction.onnx", help="ONNX output path")
    ap.add_argument("--smoke-test", action="store_true", help="run on synthetic data")
    args = ap.parse_args()
    if args.smoke_test:
        smoke_test()
        return
    if not args.csv:
        print(__doc__)
        print("\nNo --csv given. Provide real BOOM_100 data to train, or "
              "--smoke-test to exercise the pipeline. Ships no model, no claim.")
        return
    train(args.csv, args.out)


if __name__ == "__main__":
    main()
