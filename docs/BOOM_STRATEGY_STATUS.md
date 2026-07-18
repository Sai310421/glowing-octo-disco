# BOOM Strategy Suite — Status Map

A single place to see where the BOOM work stands. Nothing here is validated or
deployable yet (Non-Negotiable Rules 3/7): no backtest has been run and no AI
model is trained. This map is a landing pad, not a claim.

Last updated by the AMOS pipeline; see git history for details.

## What exists

| Component | File | Status | Gated on |
|---|---|---|---|
| v0 packet | `docs/inbox/boom_drift_grid.md` | design done | — |
| v0 EA | `ea/strategies/boom_drift_grid/BoomDriftGrid_v0.mq5` | code done, not compiled/tested | MT5 compile + Phase C backtest |
| v1 packet (§8 survival) | `docs/inbox/boom_drift_grid_v1.md` | design done | v0 Phase C results |
| v1.1 packet (Delta Lock + AI) | `docs/inbox/boom_delta_lock_ai_recovery.md` | design done | v0 Phase C + AI model |
| Trend Rider packet (video-faithful) | `docs/inbox/boom_trend_rider.md` | design done | — |
| Trend Rider EA | `ea/strategies/boom_trend_rider/BoomTrendRider_v1.mq5` | hardened v1.20 (guards, persistence, kill-switch; XAUUSD-ready auto-calibration, ATR trail, adaptive timeframe); not compiled/tested | MT5 compile + Phase C backtest per symbol |
| v1.1 EA skeleton | `ea/strategies/boom_delta_lock_ai_recovery/BoomDeltaLockAIRecovery_v1_1.mq5` | code done, AI safe-stubbed | MT5 compile + model + Phase C |
| AI I/O contract | `ea/strategies/boom_delta_lock_ai_recovery/ai/FEATURES.md` | fixed | — |
| AI trainer | `ea/strategies/boom_delta_lock_ai_recovery/ai/train_direction_model.py` | runnable given data | real BOOM_100 data |
| Monte Carlo validator | `scripts/monte_carlo_validate.py` | working | — |
| MC report templates | `reports/*.mc.template.json` | honest placeholders (fail on purpose) | real backtest output |

Everything else (OpenClaude review→auto-merge, spec, risk governor, intake) is in
place; see `docs/AMOS_LEVEL50_MASTER_SPEC.md`.

## The one thing that unblocks everything

**Run the v0 backtest** in the MT5 Strategy Tester on Deriv BOOM_100 (real
spread), then drop the numbers into `reports/boom_drift_grid.mc.json` and run:

```bash
python3 scripts/monte_carlo_validate.py reports/boom_drift_grid.mc.json
```

Accept only if `P(ruin) < 1%` and `E[log] > 0`. That result decides whether v1 /
v1.1 get built for real.

## Ordered next steps (for when you're back — no rush)

1. Compile `BoomDriftGrid_v0.mq5` in MetaEditor; paste any errors and they get fixed.
2. Backtest v0; fill `reports/boom_drift_grid.mc.json`.
3. Collect BOOM_100 bar/feature data; train the direction model
   (`train_direction_model.py --csv ...`) and check out-of-sample edge.
4. If v0 survives and the model has edge → wire/enable v1.1 (`InpUseONNX=true`).

## Notes to remember

- The Codex dispatcher and NotebookLM export do **not** auto-fire after the
  OpenClaude bot auto-merges (GitHub's `GITHUB_TOKEN` does not trigger cascading
  workflows). Dispatch is done on demand instead. A repo PAT would restore full
  auto-cascade if ever wanted — it is not needed now.
- Delta Lock freezes *directional* risk, not cost; recovery must beat carry cost.
- The AI recovery only has value if the model shows real out-of-sample edge on
  BOOM_100 — otherwise it is negative-EV. Validate before enabling.
- Trend Rider is the *video-faithful* mechanism (symmetric SAR, BUY ladder on
  up-legs too); Drift Grid remains the drift-biased simplification. Backtest
  both — they fail in different regimes (Rider dies in chop, Grid dies on
  spikes). Range regime ⇒ **widen** the pitch, never narrow (stop-order grid).
