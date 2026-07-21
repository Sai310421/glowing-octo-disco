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

## Real-data follow-up (added later): trend-direction-only architectures

After the real 1m series arrived, the counter-trend CB grid lost ~$1,700/mo
and blew a $10k account under every rescue architecture tested (freeze+pool,
ZR rescue, macro gating). The same period, same costs, trend-direction-only
(`scripts/trend_direction_bt.py`, default params, no optimization):

| architecture | net (no CB) | net + CB@15 | maxDD | note |
|---|---|---|---|---|
| one-sided trend grid (H1 EMA dir, pullback nanpin) | −$387/mo | **+$226/mo** | **83.6%** | first net-positive, but one deep pullback nearly killed it (float $11.7k) |
| Trend Rider SAR (video mechanism, M5, 0.01×7) | −$24/mo | **+$44/mo** | **14.5%** | break-even before rebates, contained risk |

The sign of the whole system is decided by trade direction relative to the
trend — not by exits, rescues, pools or hedges. On this trending half-year
the video's SAR mechanism is break-even at costs on real data (vs -$1,700/mo
counter-trend), and per-lot rebates put it modestly positive. Honest limits:
one period, one instrument, defaults untuned, CB rate must actually be paid,
and the one-sided grid's +$226/mo is not deployable at 83.6% maxDD.
