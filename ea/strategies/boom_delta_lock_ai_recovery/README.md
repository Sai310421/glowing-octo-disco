# BOOM Delta Lock & AI Recovery v1.1 (EA)

Implements `docs/inbox/boom_delta_lock_ai_recovery.md` for Deriv **BOOM_100**.

> **Not deployable yet.** The deterministic logic (drift grid, equal-volume delta
> lock, lock verify + rebalance, recovery basket, finite-risk caps, state machine,
> emergency) is implemented and hardened. The **AI direction model runs via ONNX
> when a validated model is loaded**; with no model, `AIPredict()` returns RANGE at
> zero confidence, so the gate always yields WAIT and **no recovery trades are
> taken**. Gated on v0 Phase C validation AND a validated model; needs Monte Carlo
> P10 acceptance and human approval before any live use (Rules 3/4/7, Layer 12).

## v1.11 hardening
- **No order churn**: the equal-volume BUY STOP is re-placed only when the SELL
  lot changes or the price drifts past half `d_bs` — not every tick.
- **Lock rebalance**: a small `|BUY−SELL|` imbalance (e.g. a partial fill) is
  corrected toward net-zero before falling back to Emergency.
- **AI_WAIT timeout**: a lock is not held forever — it closes after `tau_max`.
- **Fixed** a double-counted SafetyBuffer; **ONNX** I/O uses flat `float[]` arrays
  matching the `[1,14] -> [1,3]` contract; removed a risky mid-recovery flip.
- Needs an MT5 compile pass (no MetaEditor here) — paste any errors to fix.

## Files
- `BoomDeltaLockAIRecovery_v1_1.mq5` — the EA (compile in MetaEditor 5).

## What is implemented (deterministic)
- **Phase A** — equal-lot SELL pyramid; on exposure, a **dynamic BUY STOP whose
  lot equals the total SELL lot** is kept on top (equal-volume hedge, §4).
- **Phase B** — when the BUY STOP fills, the net position is ~0; `LockValid()`
  checks `|BUY_total - SELL_total| <= 0.01` (§6). Failure → Emergency.
- **Phase C** — recovery runs in a **separate magic number** (§9), pyramids in
  the AI-chosen direction, capped by `RecoveryLot <= mult * LockedLot`, a max
  recovery drawdown, and `tau_max` (§14). Stops when
  `total PnL >= CloseCost + SafetyBuffer` (§13), then closes everything.
- **State machine** (§17) and **Emergency** (§18: margin floor, spread).
- **Hard-risk inputs** (§15-16) are fixed inputs; the AI stub only chooses
  direction/entry/wait and cannot change any risk parameter.

## AI wiring (contract in `ai/FEATURES.md`)
- `AIPredict()` now assembles the 14-feature vector and runs the ONNX model per
  the fixed contract (`features[1,14]` -> `probabilities[1,3]`, classes
  `[RANGE, UP, DOWN]`). **Any failure or missing model -> safe WAIT** (no
  recovery trades). Enable with `InpUseONNX=true` + `InpOnnxModelFile` once a
  validated `.onnx` is in `MQL5/Files`.
- Computed features: atr, tick_velocity, spread, ema_slope, adx, rsi, spike_age,
  distance_from_high. The six ICT/structure features (mss, bos, displacement,
  liquidity_sweep, fvg, vegas) are **0.0 placeholders** until defined AND shown
  to matter on a synthetic index (no real order flow) — see `ai/FEATURES.md`.
- Train + export the model with `ai/train_direction_model.py` (needs real data;
  ships no model, makes no claim). Confirm the exported tensor names/shapes match
  the contract before enabling.

## Before testing
- Calibrate `Delta` / `d_bs` to your Deriv feed's digits (see the v0 README).
- `CloseCost()` is a conservative approximation — replace with your broker's real
  spread/commission/swap model for Phase C.
- Verify the equal-volume lock holds under partial fills / requotes.

## Validation (AMOS Phase C — required before any claim)
1. Backtest Phase A + lock on Deriv BOOM_100 tick data (real spread).
2. Train + validate the AI direction model in Python; export ONNX; prove
   **out-of-sample directional edge** (else recovery is negative-EV).
3. Fill `reports/boom_delta_lock_ai_recovery.mc.json` and run
   `python3 scripts/monte_carlo_validate.py ...`; accept only if
   `P(ruin) < 1%` and `E[log] > 0`.
