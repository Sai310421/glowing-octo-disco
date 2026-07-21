# Strategy Suite — Status Map

A single index of every strategy / research item in this repo. **Nothing here is
validated or deployable** (Non-Negotiable Rules 3/7): no live backtest has been
run, no AI model is trained, and the one optimization loop that was run returned a
**negative** verdict. This map is a landing pad, not a claim.

Covers BOOM_100 strategies and some XAUUSD research that shares the same tooling.

## 1. BOOM Drift Grid line (drift-biased simplification)

| Component | File | Status | Gated on |
|---|---|---|---|
| v0 packet | `docs/inbox/boom_drift_grid.md` | design done | — |
| v0 EA | `ea/strategies/boom_drift_grid/BoomDriftGrid_v0.mq5` | code done, not compiled/tested | MT5 compile + Phase C backtest |
| v1 packet (§8 survival) | `docs/inbox/boom_drift_grid_v1.md` | design done | v0 Phase C results |
| v1.1 packet (Delta Lock + AI) | `docs/inbox/boom_delta_lock_ai_recovery.md` | design done | v0 Phase C + AI model |
| v1.1 EA (hardened v1.11) | `ea/strategies/boom_delta_lock_ai_recovery/BoomDeltaLockAIRecovery_v1_1.mq5` | code done, AI safe-stubbed | MT5 compile + model + Phase C |
| AI I/O contract | `.../boom_delta_lock_ai_recovery/ai/FEATURES.md` | fixed | — |
| AI trainer | `.../boom_delta_lock_ai_recovery/ai/train_direction_model.py` | runnable given data | real BOOM_100 data |

## 2. BOOM Trend Rider line (video-faithful mechanism)

| Component | File | Status | Gated on |
|---|---|---|---|
| Trend Rider packet | `docs/inbox/boom_trend_rider.md` | design done | — |
| Trend Rider EA | `ea/strategies/boom_trend_rider/BoomTrendRider_v1.mq5` | hardened v1.31 (guards, kill-switch, XAUUSD-ready auto-calibration, ATR trail, adaptive timeframe, MQL5 calendar, close-confirmed entries); not compiled/tested | MT5 compile + Phase C backtest per symbol |

Trend Rider is the *symmetric, always-in, stop-and-reverse* mechanism the source
video actually shows; Drift Grid is the drift-biased simplification. They fail in
different regimes — **Rider dies in chop, Grid dies on spikes** — so backtest both.

## 3. XAUUSD / cashback line (real 2026-H1 1m data where noted)

| Component | File | Status | Gated on |
|---|---|---|---|
| CB Survivor EA (manual repro, v1.10 delta-lock pool) | `ea/strategies/cb_survivor/CBSurvivor_v1.mq5` | manual-faithful code done (assumptions flagged in README); not compiled/tested | MT5 compile + demo + Phase C |
| ZR RescueModule (user-supplied v1.01/v1.02) | `ea/include/zr_rescue/` | archived + evaluated: containment layer, not profitability | — |

| Research item | File | Verdict |
|---|---|---|
| "50%/month" optimization loop | `docs/inbox/trend_rider_50pct_verification.md` · `scripts/trend_rider_sim.py` · `reports/trend_rider_opt.json` | **Negative** — the loop terminated on evidence, not success. Recorded so the number is not chased again without new inputs. |
| OrkAD PCI/VWAP best candidate | `docs/inbox/pci_vwap_orkad_reverification.md` · `scripts/pci_vwap_reverify.py` · `scripts/pci_vwap_bt.py` | **Failed real-data reproduction** — every plausible .set reading lands at PF 0.80–1.08 vs claimed 2.83. Do not deploy. |
| CB Survivor economics on real data | `scripts/cb_survivor_bt.py` | **Negative** — counter-trend grid loses ~$1,700/mo and blows $10k on the trending half-year under every rescue architecture (freeze+pool, ZR, macro gating). |
| Trend-direction-only architectures | `scripts/trend_direction_bt.py` · `reports/trend_direction_bt.json` | First net-positive results: Trend Rider SAR −$24/mo → +$44/mo with CB at 14.5% maxDD; one-sided grid +$226/mo with CB but 83.6% maxDD (undeployable). |
| Mathematical framework | `docs/inbox/mathematical_framework.md` | Kelly ceiling ~0.2%/mo at current edge; only real structure in-sample is VR(4h)=0.83 reversion. Sign is decided by direction-vs-trend, not exits/rescues. |

## 4. Shared tooling

| Component | File | Status |
|---|---|---|
| Monte Carlo validator | `scripts/monte_carlo_validate.py` | working |
| MC report templates | `reports/*.mc.template.json` | honest placeholders (fail on purpose until real data) |
| Claude Market Analyzer EA | `ea/strategies/claude_analyzer/ClaudeMarketAnalyzer.mq5` | rework of the uploaded GPT/Discord analyzer: Discord removed, analysis via Anthropic Messages API, on-chart panel + file output; not compiled/tested |

Platform layers (OpenClaude review→auto-merge, spec, risk governor, intake) are in
place; see `docs/AMOS_LEVEL50_MASTER_SPEC.md`.

## The one thing that unblocks the BOOM line

**Run the v0 backtest** in the MT5 Strategy Tester on Deriv BOOM_100 (real spread),
put the numbers in `reports/boom_drift_grid.mc.json`, then:

```bash
python3 scripts/monte_carlo_validate.py reports/boom_drift_grid.mc.json
```

Accept only if `P(ruin) < 1%` and `E[log] > 0`. That decides whether v1 / v1.1 get
built for real.

## Ordered next steps (no rush)

1. Compile `BoomDriftGrid_v0.mq5` (and `BoomTrendRider_v1.mq5`) in MetaEditor; paste any errors to fix.
2. Backtest v0; fill `reports/boom_drift_grid.mc.json`.
3. Collect BOOM_100 data; train the direction model (`train_direction_model.py --csv ...`); check out-of-sample edge.
4. If v0 survives and the model has edge → enable v1.1 (`InpUseONNX=true`).

## Notes to remember

- The Codex dispatcher and NotebookLM export do **not** auto-fire after the
  OpenClaude bot auto-merges (GitHub's `GITHUB_TOKEN` does not trigger cascading
  workflows). Dispatch is on demand; a repo PAT would restore auto-cascade if ever
  wanted — not needed now.
- Delta Lock freezes *directional* risk, not cost; recovery must beat carry cost.
- The AI recovery only has value if the model shows real out-of-sample edge —
  otherwise it is negative-EV. Validate before enabling.
- Range regime ⇒ **widen** the grid pitch, never narrow (it is a stop-order grid).
- Related work lives in other repos (EA/ICT, AMOS orchestration, data, infra). This
  repo is the AMOS knowledge OS + the BOOM/XAUUSD strategy record.
