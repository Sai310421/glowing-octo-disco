# BOOM Delta Lock & AI Recovery v1.1 (EA skeleton)

Implements `docs/inbox/boom_delta_lock_ai_recovery.md` for Deriv **BOOM_100**.

> **Skeleton, not deployable.** The deterministic logic (drift grid, equal-volume
> delta lock, lock verify, recovery basket, finite-risk caps, state machine,
> emergency) is implemented. The **AI direction model is a safe stub**: with no
> trained ONNX model loaded, `AIPredict()` returns RANGE at zero confidence, so
> the confidence gate always yields WAIT and **no recovery trades are taken**.
> Gated on v0 Phase C validation AND a validated model; needs Monte Carlo P10
> acceptance and human approval before any live use (Rules 3/4/7, Layer 12).

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

## What is stubbed (needs a model)
- `AIPredict()` — assemble the §7 feature vector, run the ONNX model, and fill
  `dir/pmax/psecond`. Left unimplemented until a validated model exists; no
  fabricated inference. Set `InpUseONNX=true` and `InpOnnxModelFile` once a model
  (`.onnx`) is placed under `MQL5/Files` and its tensor shapes are wired in.

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
