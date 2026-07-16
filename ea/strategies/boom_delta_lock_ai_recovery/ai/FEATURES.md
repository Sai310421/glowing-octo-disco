# AI Direction Model — I/O Contract (single source of truth)

Both the Python trainer (`train_direction_model.py`) and the EA
(`BoomDeltaLockAIRecovery_v1_1.mq5`, `AssembleFeatures`) must agree on this
exact order. Changing the order requires changing both sides.

## Feature vector (float32[1, 14])

| idx | name             | source        | status |
|-----|------------------|---------------|--------|
| 0   | atr              | iATR          | computed |
| 1   | tick_velocity    | close0-close1 | computed (bar proxy) |
| 2   | spread           | ask-bid (pts) | computed |
| 3   | ema_slope        | ema0-ema1     | computed |
| 4   | adx              | iADX          | computed |
| 5   | rsi              | iRSI          | computed |
| 6   | mss              | structure     | TODO -> 0.0 |
| 7   | bos              | structure     | TODO -> 0.0 |
| 8   | displacement     | structure     | TODO -> 0.0 |
| 9   | liquidity_sweep  | structure     | TODO -> 0.0 |
| 10  | fvg              | structure     | TODO -> 0.0 |
| 11  | vegas            | EMA ribbon    | TODO -> 0.0 |
| 12  | spike_age        | bars since spike | computed |
| 13  | distance_from_high | highHH-close | computed |

The six structure/ICT features (6-11) are zero placeholders until defined and,
importantly, validated for importance on BOOM_100 — a **synthetic index has no
real order flow**, so ICT concepts may carry no signal. Ship them only if a
feature-importance check on real data says they help.

## Output (float32[1, 3])

Softmax probabilities in this class order (matches the EA's AI_* constants):

| idx | class | EA constant |
|-----|-------|-------------|
| 0   | RANGE | AI_RANGE = 0 |
| 1   | UP    | AI_UP = 1 |
| 2   | DOWN  | AI_DOWN = 2 |

## ONNX graph

- input tensor name: `features`, shape `[1, 14]`, dtype float32
- output tensor name: `probabilities`, shape `[1, 3]`, dtype float32
- single input, single output (MT5-friendly; no ZipMap)

## Honesty gate

A trained model is worthless here unless it shows **out-of-sample directional
edge** on BOOM_100 after a spike. Recovery is negative-EV otherwise. Validate
before wiring `InpUseONNX=true`.
