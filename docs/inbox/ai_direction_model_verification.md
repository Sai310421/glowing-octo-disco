# AMOS Knowledge Packet — Numeric AI direction model: verification result

Source: user request to build "1つの学習AI搭載EA" (one AI-model EA), referencing
a third-party product's sales page (STRATEGY LAB "AI TRADER", XAUUSD,
2022-2026 backtest: PF 1.66, Sharpe 4.57, win rate 76-78%, maxDD 11.6-14.6%,
total return +157.7% over 4.5 years, 2,984 trades). Those are unverified
third-party marketing claims and are NOT reproduced or targeted here — this
packet measures what a real model, trained on this repo's own real XAUUSD
1m data (2026-01..07), actually produces on honest walk-forward evaluation.

## What was built (scripts/ai_direction_features.py, ai_direction_train.py)

- Features (causal only, M5 bars): multi-lag returns, ATR/RSI/ADX(14),
  Kaufman ER(20), EMA20/50/200 distance + stack, Bollinger z-score, rolling
  volatility and its ratio to a 50-bar average, session time-of-day
  (sin/cos) and day-of-week.
- Label: sign of the forward price move over a fixed horizon, only counted
  if it exceeds `max(round-trip cost, 0.5×ATR)` (ambiguous/small moves
  dropped from training so the classifier targets economically meaningful
  moves, not spread-level noise).
- Model: LightGBM binary classifier (shallow: num_leaves=15, max_depth=4,
  200 trees, subsampled) - deliberately conservative given the small
  per-fold sample sizes.
- Validation: expanding-window walk-forward (same cadence as
  `trend_rider_regime_wf.py`) - train on all months before the test month,
  predict on the test month, only trade when the predicted probability
  clears a confidence band; no lookahead anywhere in the pipeline.

## Results (two horizons tested; both a priori reasonable, not cherry-picked)

**1-hour horizon (12 M5 bars):**

| fold | AUC | ACC |
|---|---|---|
| 2026-03 | 0.514 | 0.498 |
| 2026-04 | 0.528 | 0.523 |
| 2026-05 | 0.536 | 0.527 |
| 2026-06 | 0.505 | 0.510 |
| 2026-07 | 0.473 | 0.451 |

Trading (walk-forward OOS, 3.9 test-months): PF 0.96-1.07, win rate ~50%
at every confidence threshold tried (0.55/0.60/0.65); net return sign flips
with the threshold (+$87/mo to +$10/mo to +$54/mo, no monotonic pattern).
The `net+CB` column looks positive mainly because of the same deterministic
$15/lot cashback that inflates every other result in this repo, not because
of model skill.

**4-hour horizon (48 M5 bars, chosen because
`docs/inbox/mathematical_framework.md` §1 flags VR(4h)=0.83 as the ONLY
real in-sample statistical structure found in this data):**

| fold | AUC | ACC |
|---|---|---|
| 2026-03 | 0.568 | 0.516 |
| 2026-04 | 0.530 | 0.525 |
| 2026-05 | 0.521 | 0.508 |
| 2026-06 | 0.468 | 0.469 |
| 2026-07 | 0.490 | 0.388 |

Trading: PF 0.96/0.96/1.07 across thresholds, net swinging from -$103/mo to
+$102/mo with no stable sign. One fold (2026-07, thin sample) even scores
below 0.5 AUC - worse than a coin flip - which is itself evidence of pure
noise rather than a small stable edge.

## Verdict

**No measured directional edge.** AUC hovers at 0.47-0.57 across ten
fold/horizon combinations - indistinguishable from 0.50 (random) given the
sample sizes involved, and the sign instability across confidence
thresholds is the signature of noise, not a weak-but-real signal. This is
the same conclusion the math framework already reached by a different
route (VR≈1 at 1h, per-cycle SAR edge t≈0.2): standard OHLCV technical
features do not carry information about XAUUSD's next 1-4 hours beyond
what price itself already reflects, at least on the 6 months of data this
repo has access to.

The sales page's claimed Sharpe 4.57 / PF 1.66 / 76-78% win rate over 4.5
years is not explained by this exercise. The most likely explanations,
consistent with every other "too good" claim already found not to
reproduce in this repo (PCI/VWAP, PF 2.83 claimed → PF 0.7-0.9 measured):
optimistic backtest fill/tick assumptions, curve-fit parameters on a
long in-sample window with no out-of-sample check shown, or a
cherry-picked reporting period.

## What would change this conclusion

1. More real history (years, not 6 months) - AUC estimates at n≈5,000-9,000
   labeled rows per fold are themselves noisy; a stable edge, if it exists,
   needs more folds to separate from luck.
2. Features actually tied to the VR(4h) mean-reversion mechanism itself
   (distance from a slow anchor with the drift explicitly hedged out) per
   math-framework §6 item 2, rather than generic technical indicators fed
   to a generic classifier.
3. Cross-instrument training (multiple correlated symbols) to raise the
   effective sample size, per math-framework §6 item 3.
4. Independent replication of the sales page's own claim would require
   their actual backtest code/fill assumptions - unavailable here.

## Status

Not proceeding to ONNX export / EA integration on this model - shipping an
"AI-model EA" whose model has no measured edge would repeat exactly the
kind of unverified claim this repo's discipline exists to prevent. Decision
on next steps (ship an edge-agnostic ONNX scaffold anyway with clear
labeling, extend the feature/data search, or drop this line) is with the
user.
