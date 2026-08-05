# AI_XAUUSD_Trader v1.00

Requested after reviewing a third-party sales page ("STRATEGY LAB AI TRADER":
claimed PF 1.66, Sharpe 4.57, WR 76-78%, maxDD 11.6-14.6% on XAUUSD,
2022-2026). **This EA does not reproduce those numbers and does not claim
to.** They are unverified marketing claims; see
`docs/inbox/ai_direction_model_verification.md` for why they don't
plausibly reproduce on the real data this repo has.

## What this is

A real LightGBM direction model (20 numeric OHLCV features, M5 bars,
1-hour-forward label) trained and walk-forward tested on this repo's real
XAUUSD 1m data, exported to ONNX, and wired into a full MT5 EA:
`OnnxCreate`/`OnnxRun` inference, hand-ported feature computation (exact
parity with the Python training code, including a from-scratch Wilder-EWM
ATR/RSI/ADX - not MT5's built-in `iADX`, which uses a different formula),
time-exit position management, and standard risk guards (spread cap, daily
loss halt, equity DD kill-switch).

## Honest result

Walk-forward OOS AUC across 5 monthly folds: **0.47-0.57** — statistically
indistinguishable from a coin flip. Trading PF sits at 1.00-1.04 with ~50%
win rate regardless of confidence threshold; any apparent profit comes from
the $15/lot cashback convention used throughout this repo, not model skill.
Full detail: `docs/inbox/ai_direction_model_verification.md`.

## Why it still ships

The user asked for a complete AI-model EA as infrastructure. `InpMode`
defaults to `MODE_SHADOW`: the EA loads the model, computes features, runs
inference, and prints/shows its decision every closed M5 bar - but places
no orders. `MODE_ADVISORY` is the same with a persistent chart panel.
`MODE_LIVE` actually trades and exists because it was asked for, not
because the model is validated - **do not run MODE_LIVE on a real account
without your own independent validation.**

## Files

- `AI_XAUUSD_Trader_v1.mq5` — the EA (model loaded as a compiled-in
  resource; nothing to copy to `MQL5/Files` manually).
- `model/ai_xauusd_direction.onnx` — the exported model.
- `model/meta.json` — feature order (must match the EA's `ComputeFeatures()`
  exactly), horizon, and the honest OOS note.
- `scripts/ai_direction_features.py`, `scripts/ai_direction_train.py`,
  `scripts/ai_direction_export_onnx.py` (repo root `scripts/`) — the full
  training/validation/export pipeline, re-runnable on new data.

## Setup

1. Compile in MetaEditor (the `.onnx` under `model/` is bundled in as a
   resource at compile time via `#resource "model\\ai_xauusd_direction.onnx"
   as uchar ExtModel[]`).
2. Attach to an XAUUSD chart (any chart timeframe - the EA always evaluates
   on its own M5 series internally, matching what the model was trained on).
3. Leave `InpMode = MODE_SHADOW` and watch the Experts log / chart comment
   for a while before considering `MODE_LIVE`.

## Retraining on new data

```bash
cd scripts
CB_DATA=/path/to/new_xauusd_1m.csv python3 ai_direction_train.py       # honest WF check first
CB_DATA=/path/to/new_xauusd_1m.csv python3 ai_direction_export_onnx.py # only if the WF check shows real edge
```
`ai_direction_export_onnx.py` refuses to finish (raises) if the onnxruntime
vs. native-model parity check fails - it will not silently ship a broken
ONNX file.
