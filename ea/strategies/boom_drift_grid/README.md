# BOOM Drift Grid v0 (EA)

Implements `docs/inbox/boom_drift_grid.md`. Reactive, drift-biased SELL grid
with a BUY STOP reverse hedge for Deriv **BOOM_100** on **M1**.

> Not deployable. v0 has **no stop-loss** by design. No live use until Phase C
> validation passes (Monte Carlo P10, Non-Negotiable Rules 3/4) and a human
> approves (Layer 12). No backtest has been run yet — the report under
> `reports/` is an empty template, not a result.

## Files
- `BoomDriftGrid_v0.mq5` — the Expert Advisor (compile in MetaEditor 5).

## Inputs (map to spec sections)
| Input | Meaning | Spec |
|---|---|---|
| `InpDelta` | grid pitch in index price units (default 50) | §1/§3 |
| `InpLot` | fixed lot per level, no martingale (0.01) | §3 |
| `InpNMax` | max concurrent SELL positions (10) | §6 |
| `InpUseBuyHedge`, `InpBuyStopDist` | reverse BUY STOP hedge + distance | §4 |
| `InpExitMode` | exit rule A / B / C | §5 |
| `InpCtp` / `InpBasketTgt` / `InpCtr` | params for A / B / C | §5 |
| `InpUseSpikeFilter`, `InpSpikeLookback`, `InpSpikeMaxVel` | spike filter (v1 preview, OFF by default) | §8.2 |

## Behaviour (v0)
- **SELL grid**: keeps one SELL STOP armed one `Delta` below the lowest SELL
  entry (or below price when flat). Each fill arms the next one lower, up to
  `N_max`. Fixed lot, no martingale.
- **BUY STOP hedge**: while SELL-exposed, keeps one BUY STOP `d_bs` above price
  to catch a reversal / up-spike.
- **Exit**: A per-position TP; B basket TP (close all at `Pi_tgt`); C trailing
  basket (give back `c_tr` of peak). Choose per Phase C run.

## Calibration note
`Delta` and `d_bs` are in the chart's index price units. On your Deriv feed,
confirm that a 1-unit price change equals 1 "pt" as used in the spec (the clip
showed ladder steps of ~50, e.g. 1368270 to 1368219). Adjust defaults to match
your symbol's digits before testing.

## Phase C (validation — required before any claim)
1. Load Deriv BOOM_100 tick/M1 history into the MT5 Strategy Tester (real spread).
2. Sweep exit rule A/B/C x `Delta in {30,50,100}` x spike-filter {on,off}.
3. Export per-run metrics and run a Monte Carlo pass; write the result to
   `reports/boom_drift_grid.mc.json` and validate:
   ```bash
   python3 scripts/monte_carlo_validate.py reports/boom_drift_grid.mc.json
   ```
4. Accept only if `P(ruin) < 1%` and `E[log(E_T/E_0)] > 0` (§9). Otherwise iterate
   or move to v1 (basket SL, spike filter, dynamic hedge — §8).

Reminder: the edge, if any, lives in the **exit rule and spike avoidance**, not
the grid itself — prioritise those in the sweep.
