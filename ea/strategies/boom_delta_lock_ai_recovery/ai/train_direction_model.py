#!/usr/bin/env python3
"""Train the BOOM direction model and export it to ONNX for the EA.

Pipeline (spec section 20, "Self Optimization"): learn in Python, ship only a
validated model to the EA. This is a SCAFFOLD. It needs real Deriv BOOM_100
data and honest out-of-sample validation. It does not ship a model and makes
no performance claim (Rule 3).

I/O contract is fixed by ai/FEATURES.md (must match AssembleFeatures in the EA):
  input  'features'      float32[1, 14]
  output 'probabilities' float32[1, 3]   class order [RANGE, UP, DOWN]

Usage:
  python3 train_direction_model.py --csv bars.csv --out direction.onnx
  (csv columns: time, open, high, low, close, spread ...)
"""
import argparse

# Canonical feature order — MUST match ai/FEATURES.md and the EA.
FEATURES = [
    "atr", "tick_velocity", "spread", "ema_slope", "adx", "rsi",
    "mss", "bos", "displacement", "liquidity_sweep", "fvg", "vegas",
    "spike_age", "distance_from_high",
]
CLASS_ORDER = ["RANGE", "UP", "DOWN"]   # indices 0, 1, 2
N_FEATURES = len(FEATURES)


def build_features(df):
    """Return an (N, 14) float array in FEATURES order.

    Computed features are filled from price/indicators; the six ICT/structure
    features (mss, bos, displacement, liquidity_sweep, fvg, vegas) are 0.0
    placeholders until defined AND validated for importance on a synthetic
    index (see FEATURES.md). Requires pandas/numpy + a TA lib of your choice.
    """
    import numpy as np  # noqa: F401  (import guarded so the file imports cleanly)
    raise NotImplementedError(
        "Implement feature construction from your bar data. Keep the exact "
        "FEATURES order. Leave ICT features at 0.0 until validated."
    )


def make_labels(df, horizon=10, eps=None):
    """3-class forward label: future return over `horizon` bars.

    UP if future return > +eps, DOWN if < -eps, else RANGE. Choosing `eps`
    (e.g. a multiple of ATR or the round-trip cost) and `horizon` is a modeling
    decision that must be justified by validation, not guessed here.
    """
    raise NotImplementedError("Define labels; justify horizon/eps in validation.")


def train(csv_path, onnx_out):
    import numpy as np
    try:
        import pandas as pd
        import torch
        import torch.nn as nn
    except ImportError as exc:
        raise SystemExit(f"Missing dependency: {exc}. Need pandas + torch.")

    df = pd.read_csv(csv_path)
    X = np.asarray(build_features(df), dtype=np.float32)
    y = np.asarray(make_labels(df), dtype=np.int64)

    # Time-ordered split (NO shuffling — this is a time series).
    cut = int(len(X) * 0.7)
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
    for _ in range(200):
        opt.zero_grad()
        p = model(Xtr_t).clamp_min(1e-9)
        loss = loss_fn(p.log(), ytr_t)
        loss.backward()
        opt.step()

    # Honest out-of-sample check — recovery is negative-EV without real edge.
    with torch.no_grad():
        pred = model(torch.from_numpy(Xte)).argmax(1).numpy()
    acc = float((pred == yte).mean()) if len(yte) else 0.0
    print(f"Out-of-sample accuracy: {acc:.3f} (must beat the majority-class "
          f"baseline AND translate to positive-EV recovery before use).")

    dummy = torch.zeros(1, N_FEATURES)
    torch.onnx.export(
        model, dummy, onnx_out,
        input_names=["features"], output_names=["probabilities"],
        dynamic_axes=None, opset_version=13,
    )
    print(f"Exported {onnx_out}: input features[1,{N_FEATURES}] float32, "
          f"output probabilities[1,{len(CLASS_ORDER)}] float32, "
          f"classes {CLASS_ORDER}.")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", help="bar data CSV (Deriv BOOM_100)")
    ap.add_argument("--out", default="direction.onnx", help="ONNX output path")
    args = ap.parse_args()
    if not args.csv:
        print(__doc__)
        print("\nNo --csv given. Provide real BOOM_100 data to train. "
              "This scaffold ships no model and makes no performance claim.")
        return
    train(args.csv, args.out)


if __name__ == "__main__":
    main()
