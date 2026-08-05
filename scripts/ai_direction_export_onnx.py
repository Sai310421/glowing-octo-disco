#!/usr/bin/env python3
"""Fit the final numeric-OHLCV direction model on all available data and
export it to ONNX for MT5's OnnxCreate/OnnxRun, then verify onnxruntime's
predictions match the native LightGBM model on a held-out sample before
trusting it in the EA.

IMPORTANT: this model's walk-forward OOS numbers (scripts/ai_direction_train.py,
reports/ai_direction_wf.json) showed AUC ~0.47-0.57 (indistinguishable from a
coin flip) on the only real data this repo has (XAUUSD M5, 6 months). Fitting
on all data here does NOT change that finding - it produces a deployable
ONNX artifact for the EA scaffold, not a model with demonstrated edge. The EA
built around this must default to a mode that does not risk capital on this
model alone (see ea/strategies/ai_xauusd_trader/README.md).
"""

import json
import os
import numpy as np
from lightgbm import LGBMClassifier
import onnxmltools
from onnxmltools.convert.common.data_types import FloatTensorType
import onnxruntime as ort

from ai_direction_features import load, make_m5, build_features, build_labels
from ai_direction_train import LGBM_PARAMS, HORIZON, K_ATR

OUT_DIR = os.path.join(os.path.dirname(__file__), "..",
                       "ea", "strategies", "ai_xauusd_trader", "model")


def main():
    path = os.environ.get("CB_DATA",
        "/tmp/claude-0/-home-user-glowing-octo-disco/74058501-f7f7-5fe1-b123-2e20f42fe8bd/scratchpad/xauusd_1m_repaired.csv")
    df = load(path)
    m5 = make_m5(df)
    feat = build_features(m5)
    label, _ = build_labels(m5, horizon=HORIZON, k_atr=K_ATR)

    feat_cols = feat.columns.tolist()
    X = feat.values.astype(np.float32)
    y = label.values
    valid = ~np.isnan(X).any(axis=1) & ~np.isnan(y)
    Xv, yv = X[valid], y[valid]
    print(f"training final model on {len(yv)} labeled rows ({len(feat_cols)} features)")

    model = LGBMClassifier(**LGBM_PARAMS)
    model.fit(Xv, yv)

    os.makedirs(OUT_DIR, exist_ok=True)

    # zipmap=False: emit probabilities as a plain [N,2] tensor instead of a
    # sequence<map<int64,float>> - MT5's OnnxRun (matrix-based API) cannot
    # consume the zipmap/sequence output type the default converter emits.
    onnx_model = onnxmltools.convert_lightgbm(
        model, initial_types=[("input", FloatTensorType([None, len(feat_cols)]))],
        target_opset=15, zipmap=False)
    onnx_path = os.path.join(OUT_DIR, "ai_xauusd_direction.onnx")
    onnxmltools.utils.save_model(onnx_model, onnx_path)
    print(f"saved {onnx_path} ({os.path.getsize(onnx_path)} bytes)")

    # --- parity check: onnxruntime vs native LightGBM on a held-out sample ---
    rng = np.random.default_rng(42)
    sample_idx = rng.choice(len(Xv), size=min(2000, len(Xv)), replace=False)
    Xs = Xv[sample_idx]

    native_proba = model.predict_proba(Xs)[:, 1]

    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    input_name = sess.get_inputs()[0].name
    outputs = sess.get_outputs()
    print("ONNX outputs:", [(o.name, o.shape) for o in outputs])
    onnx_out = sess.run(None, {input_name: Xs.astype(np.float32)})
    # zipmap=False -> output 1 is a plain [N,2] tensor: [:,0]=P(down), [:,1]=P(up)
    proba_out = onnx_out[1]
    assert not isinstance(proba_out, list), "zipmap output leaked through - re-check convert_lightgbm(zipmap=False)"
    onnx_proba = proba_out[:, 1]

    max_abs_diff = float(np.max(np.abs(native_proba - onnx_proba)))
    mean_abs_diff = float(np.mean(np.abs(native_proba - onnx_proba)))
    print(f"parity check (n={len(Xs)}): max|diff|={max_abs_diff:.6f}  mean|diff|={mean_abs_diff:.6f}")
    ok = max_abs_diff < 1e-3
    print("PARITY " + ("OK" if ok else "FAILED — DO NOT SHIP THIS ONNX FILE"))

    meta = dict(
        feature_order=feat_cols,
        horizon_bars=HORIZON,
        bar_timeframe="M5",
        k_atr_label_threshold=K_ATR,
        n_features=len(feat_cols),
        onnx_output_index_label=0,
        onnx_output_index_proba=1,
        proba_class_index_up=1,
        parity_max_abs_diff=max_abs_diff,
        parity_mean_abs_diff=mean_abs_diff,
        parity_ok=ok,
        honest_oos_note=(
            "Walk-forward OOS AUC ~0.47-0.57 on the only real data available "
            "(XAUUSD M5, 2026-01..07, 6 months) - no measured directional edge. "
            "See reports/ai_direction_wf.json and docs/inbox/ai_direction_model_verification.md. "
            "This model is NOT validated for autonomous trading."
        ),
    )
    meta_path = os.path.join(OUT_DIR, "meta.json")
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=1)
    print(f"saved {meta_path}")

    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
