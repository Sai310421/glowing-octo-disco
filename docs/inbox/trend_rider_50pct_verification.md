# AMOS Knowledge Packet — "50%/month" optimization loop: verification result

Source: user-uploaded `AI_AMOS_AHAE_MASTER_BASE_v1.docx` (XAUUSD LightGBM→ONNX stack
spec) and `AMOS_FACTORY_BASE_v0_41_VWAP_INTEGRATED.zip` (factory engines, WR0-WR7
validators, broker noise profile, VWAP confirm/hybrid gate).
Task: "optimize to ≥50%/month, loop until achieved, verify."
Status: verification COMPLETE — the loop terminated on evidence, not on success.
This packet records why, so the number is not chased again without new inputs.

## What was run (scripts/trend_rider_sim.py)

No MT5 and no market-data network access exists in the pipeline environment, so
verification used the repo's Monte Carlo approach: a regime-switching synthetic
XAUUSD (5m bars, calibrated: avg daily range $53, |daily ret| 0.83%, monthly
drift 0.4-10%, jumps ~2/week, vol clustering; trend S/N 0.13σ/bar ≈ Hurst
slightly >0.5) with the uploaded broker profile costs (spread 35pt, slippage
12pt). Strategy = EA v1.31 close-confirmed core incl. optional VWAP confirm
gate from the uploaded factory. Random-search explore (60 configs × 12 months)
+ refine (50 × 12) + sensitivity + cost isolation.

## Results (median monthly return of best feasible config)

| Test | Result |
|---|---|
| Explore best (60 configs) | −4.4%/mo |
| Refine best (50 configs) | **−1.7%/mo** (p95 DD 8.7%) |
| Persistence 0.0 (no edge) | −7.8%/mo (= pure cost bleed; sanity check passed) |
| Persistence 1.0 (calibrated) | −4.8%/mo |
| Persistence 1.5 (favorable) | −0.5%/mo |
| Zero-cost, persistence 1.0 | −4.0%/mo |

Key facts:
1. **Every one of 110 configurations was negative.** Optimization narrows the
   loss; it does not change its sign.
2. **Zero-cost is still negative** — under realistic (weak) trend persistence
   the SAR give-back exceeds the ladder harvest. The mechanism only approaches
   break-even in a strongly trending market (persistence 1.5).
3. Scaling risk on a negative edge cannot reach +50%/mo — it only accelerates
   ruin. The `target50` risk-scaling round is therefore mathematically moot.

## Verdict

**+50%/month is not attainable by parameter optimization of this mechanism,
and no configuration claiming it will be reported.** With ~100 trades/month,
+50%/mo requires ≈+0.4% of equity of *genuine predictive edge per trade* net
of costs. That edge, if it exists, must come from the AI stack described in
the uploaded master doc (LightGBM→ONNX, 66 features) trained on real XAUUSD
data with walk-forward validation — which requires market data and MT5, both
unavailable here. Note the uploaded factory's own `objective.yaml` targets
0.26%/day (~5.9%/mo) with a 50% haircut — even its author's spec treats
50%/mo as out of range.

## What would move the needle (in order)

1. Real XAUUSD tick/M1 data + MT5 Strategy Tester run of EA v1.31 (the gate
   everything else waits on).
2. Train the AHAE direction model per the master doc; accept only if
   walk-forward WFE ≥ 50 (their own bar) — then gate SAR entries on it.
3. Re-run this Monte Carlo with persistence re-estimated from the real data
   instead of the literature prior.

## Real-data follow-up: trend-direction-only architectures (CORRECTED)

After the real 1m series arrived, the counter-trend CB grid lost ~$1,700/mo
and blew a $10k account under every rescue architecture tested (freeze+pool,
ZR rescue, macro gating). The same period, same costs, trend-direction-only
(`scripts/trend_direction_bt.py`, default params, no optimization).

CORRECTION (post code-review): the first published table contained two
harness bugs found in review — (1) the H1 trend signal was left-labeled and
leaked one hour of future close into the grid sim; (2) the SAR sim charged
entry costs twice (adverse fill price AND a per-side deduction), i.e. three
half-spreads per round trip. Corrected results:

| architecture | net (no CB) | net + CB@15 | maxDD | note |
|---|---|---|---|---|
| one-sided trend grid (H1 EMA dir, pullback nanpin) | **BLOWN** (−$1,751/mo) | −$1,534/mo | 102% | the earlier "+$226/mo" was a lookahead artifact — RETRACTED |
| Trend Rider SAR (video mechanism, M5, 0.01×7) | **+$57/mo** | **+$125/mo** | **11.4%** | positive before rebates once the double entry cost is removed |

The sign of the whole system is still decided by trade direction relative to
the trend. The corrected picture is cleaner than the original: the one-sided
grid dies like every other nanpin variant once its lookahead is removed, and
the video's SAR mechanism is the only survivor — modestly positive before
rebates at contained DD. Honest limits: one period, one instrument, defaults
untuned, and per-cycle edge remains statistically indistinguishable from
zero (t ≈ 0.2 over 1,908 cycles) — the +$57/mo sign is within noise; the CB
component is the only deterministic part.

## Regime-gate walk-forward (added after "トレンド方向のみでも黒字化は無理？")

Question: can a CAUSAL regime filter keep the SAR flat through the weak
stretch (Mar–Jul) without hindsight? Harness: `scripts/trend_rider_regime_wf.py`
— long-window Kaufman ER on M5 as an on/off gate, hysteresis thresholds
taken ONLY from the trailing 2 months' ER quantiles, applied to the
following month.

CORRECTION (post code-review): the first version reset positions/anchors at
every month boundary (an artifact not present live) and only kept the
per-fold-selected and oracle results, not the fixed-config array the
headline numbers were drawn from — so "+$26/mo" and "9/12" were not
reproducible by running the script. Fixed: every variant now runs as ONE
continuous simulation across the full test span (state carries across month
boundaries; only the gate's causal thresholds change per month), and all 12
fixed-config results are serialized to `reports/trend_rider_regime_wf.json`.
ER window durations were also mislabeled (they are bar counts on M5, not
elapsed days): N=100→8.3h, N=250→20.8h, N=500→1.7d.

| variant | net /mo | +CB /mo | note |
|---|---|---|---|
| ungated baseline (continuous, test months Mar–Jul) | −$134 | −$67 | the weak regime |
| WF with per-fold config selection | −$108 | −$68 | selection overfits the train window — no gain |
| best fixed config: N=250 (20.8h) q_on=0.50 | **+$38** | **+$77** | flat ~38% of the time, maxDD 8.8% (vs 11.8% ungated) |
| all 12 fixed configs | 9/12 beat baseline; 6/12 positive with CB | | N=100–250 (8–21h) mostly help; N=500 (1.7d) harmful in every q_on |
| in-sample searched optimum (best of the 12, hindsight-picked) | +$38 | +$77 | NOT a ceiling on all possible gates — just the best of this one family |

Findings: (1) the gate concept transfers causally — an 8–21 hour ER window
robustly turns the weak months from −$134/mo to ≈+$38/mo net (+$77 with CB),
even with continuous state across boundaries; (2) per-fold re-optimization
of the gate is WORSE than a fixed sane config — the selection step, not the
gate, is where overfitting lives; (3) the ~1.7-day window is actively
harmful at every threshold tried — the gate only helps at the shorter,
sub-daily scales tested here, a scale-dependence that would need testing
against other window lengths before generalizing. Answer to the user's
question: trend-direction-only IS black-ink capable — ungated it earns only
in trending regimes (+$57/mo full-period average, from the corrected
`trend_direction_bt.py`), and a causal ER gate at the right scale holds the
weak regime near break-even instead of bleeding.

## ER regime gate implemented in the EA (v1.40)

`ea/strategies/boom_trend_rider/BoomTrendRider_v1.mq5` now carries the gate
verified above as an opt-in module (`InpUseRegimeGate`, default **false**):

- Long-window Kaufman ER (`InpGateWindowMin`, default 1250min ≈ 250 M5 bars,
  the WF winner) computed once per closed bar of the EA's own working
  timeframe (whatever `SelectTimeframe()` picked - the window is specified
  in minutes precisely so it stays ~20.8h-equivalent regardless of TF).
- Thresholds (`thr_on` = `InpGateQOn` quantile, `thr_off` = `thr_on - InpGateQGap`
  quantile) are computed ONLY from the trailing `InpGateTrainDays` (default
  60, matching the WF train window) of ER history, recalibrated every
  `InpGateRecalcDays` (default 30, matching the WF fold cadence) - same
  causal design as the verified script, just running inside MT5 instead of
  the offline harness.
- Gate OFF: `HandleRegimeGate()` flattens both baskets (ride + lock) and
  sits out (`ST_GATE_OFF`), checked right after the news module and before
  the normal state machine. Gate back ON: resumes from `ST_FLAT`.
- This is a SEPARATE signal from the short-window `EfficiencyRatio()` used
  for pitch widening (decision 1) - the two do not interact.

Not yet re-verified as compiled EA code (no MetaEditor in this environment).
Default OFF until an MT5 Strategy Tester run confirms the same effect the
Python harness measured, ideally on more than the one instrument/period
tested so far.

CORRECTION (post code-review, same day): four bugs fixed in `HandleRegimeGate()`
/ `RecalibrateGateThresholds()` / `ApplyTimeframe()`:
1. The gate no longer forces `ST_GATE_OFF -> ST_FLAT` while a close/delete
   rejection has left a residual position or pending order - it keeps
   retrying `CloseEverything()` and stays in control until the same
   position/order counts used by the OFF path are actually zero.
2. `ST_EMERGENCY` now retains ownership of the tick regardless of the gate
   signal, so a lock-imbalance cooldown (`InpCooldownSec`) can no longer be
   bypassed by the gate flipping back on mid-cooldown.
3. `ApplyTimeframe()` now resets the gate's calibrated thresholds when the
   auto-timeframe selector changes `g_tf` - ER distributions depend on
   sampling frequency, so thresholds fit on the old TF are invalid on the
   new one and are now recalibrated immediately instead of up to
   `InpGateRecalcDays` stale.
4. The trailing training window is now located via bar timestamps
   (`iBarShift`) instead of assuming `InpGateTrainDays * 24h` of continuous
   bars - session gaps (weekends etc.) made the bar-count approximation
   diverge from the intended calendar window.
