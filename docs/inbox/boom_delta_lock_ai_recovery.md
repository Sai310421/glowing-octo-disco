# AMOS Knowledge Packet — BOOM Delta Lock & AI Recovery Engine (spec v1.1)

Source: MSS Group spec "BOOM Drift Grid - Delta Lock & AI Recovery Engine", v1.1 (frozen).
Relation: evolves `boom_drift_grid.md` (v0) and `boom_drift_grid_v1.md` (§8). Replaces the thin
1/N_g hedge with an **equal-volume delta lock** and adds an **AI directional recovery** subsystem.
Status: Design packet. Implementation gated on v0 Phase C validation AND a trained/validated AI
model. Not deployable (Rules 3/7).

Naming note: this spec's "Phase A/B/C" (Drift / Lock / Recovery) are runtime states and are NOT
the AMOS "Phase C" validation stage. Where this packet says "validation", it means the AMOS stage.

## Summary

A three-state engine for BOOM_100. Phase A (Drift Profit) runs the equal-lot SELL pyramid from
v0 to harvest the downward drift. Phase B (Delta Lock) fires when an up-spike triggers a BUY STOP
whose lot equals the total SELL lot, taking the net position to zero and stopping directional
risk. Phase C (AI Recovery) then runs an ONNX model (AMOS/AHAE) to pick the highest-probability
direction and opens a separate, finite-risk recovery basket to cover the locked loss plus carry
costs, then closes everything. It is explicitly not martingale: equal-lot pyramid + equal-volume
lock + AI-chosen direction + hard finite-risk caps. Objective: maximise expected growth while
keeping ruin probability inside a defined risk budget.

## Key Concepts

- Equal-lot SELL pyramid, no martingale (Phase A).
- Equal-volume delta lock: BUY STOP lot = total SELL lot => net 0, directional risk halted (Phase B).
  Lock freezes directional exposure, NOT cost (spread/commission/swap/slippage continue).
- AI directional recovery in a SEPARATE magic-number basket (Phase C), never touching the lock.
- Confidence gate + hard-risk boundary: AI chooses only {UP, DOWN, RANGE, Confidence, Entry, Wait};
  it may NOT change lot, SL/TP, max DD, max SELL, margin floor, or stop conditions.
- Finite recovery: capped lot, capped DD, capped time; stop when PnL covers close cost + buffer.
- Emergency state on any execution/hedge/feed/model/margin/gap anomaly.

## TODO
- [ ] Validate EA Logic against the Risk Governor (risk, DD, margin, black-swan controls)
- [ ] Add Monte Carlo P10 / worst-decile validation for any trading claim
- [ ] Confirm no secrets or destructive commands are included
- [ ] Generate the NotebookLM Summary section
- [ ] Draft SNS / content ideas where applicable
- [ ] Gate: implement only after v0 Phase C passes AND an AI model with demonstrated directional edge exists
- [ ] Prove the AI recovery has edge on BOOM_100 (else recovery is negative-EV); validate feature importance
- [ ] Verify equal-volume lock holds within +/-0.01 lot under partial fills / requotes

## EA Logic
```text
State machine (section 17):
  IDLE -> SELL_DRIFT -> SELL_PYRAMID -> SPIKE_WARNING -> BUY_STOP_TRIGGER
       -> DELTA_LOCK -> LOCK_VERIFY -> AI_WAIT
       -> {DOWN_RECOVERY | UP_RECOVERY} -> TARGET_REACHED -> CLOSE_ALL -> COOLDOWN -> IDLE

Phase A - Drift Profit (sections 3-4):
  - SELL only (BOOM drifts down). BUY is hedge-only, never for profit.
  - Add SELL when Price <= LastEntry - Delta. Equal lot L (0.01). Cap N_max.
  - On each SELL add, REPLACE the BUY STOP: delete the old one, place a new one at
    price + d_bs with lot = total SELL lot (equal-volume, section 4).

Phase B - Delta Lock (sections 5-6):
  - BUY STOP fills => BUY total == SELL total => net position 0 => directional risk halted.
  - LOCK_VERIFY: BUY total == SELL total within +/-0.01 lot; check pending count,
    fill failures, margin level, spread. Anomaly => Emergency.
  - Lock stops DIRECTION only; spread/commission/swap/slippage still accrue.

Phase C - AI Recovery (sections 7-14):
  - Run ONNX (AMOS/AHAE). Output class {0 RANGE, 1 UP, 2 DOWN} + probabilities.
  - Confidence gate (section 8): act only if Confidence >= 0.68 AND (Pmax - Psecond) >= 0.20,
    else WAIT.
  - Recovery uses a NEW magic number (section 9); the lock basket is left untouched.
  - DOWN -> SELL pyramid (Price <= lastSell - Delta). UP -> BUY pyramid (short holds on BOOM).
    RANGE -> WAIT (optionally micro-lot only).
  - Stop (section 13): TotalPnL >= CloseCost + SafetyBuffer, where
    CloseCost = spread + commission + swap + expected slippage. Then CLOSE_ALL.

Hard risk (sections 15-16) - AI cannot change:
  max SELL, max lot, max DD, max time, max spread, min margin level, SL/TP, stop conditions.

Emergency (section 18): execution/hedge/feed/ONNX failure, margin shortfall, abnormal spread,
price gap, or DD limit => Emergency Close.
```

## Mathematical Concepts
```text
Equal-volume lock (section 4-6):
  BUY_stop_lot = sum(SELL_lots) ;  lock valid iff |BUY_total - SELL_total| <= 0.01

Confidence gate (section 8):
  act iff  Confidence >= 0.68  AND  (P_max - P_second) >= 0.20 ;  else WAIT

Recovery stop (section 13):
  TotalPnL >= CloseCost + SafetyBuffer
  CloseCost = Spread + Commission + Swap + ExpectedSlippage

Recovery caps (section 14):
  RecoveryLot <= 0.5 * LockedLot        (range 0.25 .. 0.75)
  Recovery DD <= 0.5 .. 1.0 %
  Recovery time <= tau_max

AI I/O (section 7):
  features: ATR, TickVelocity, Spread, EMA slope, ADX, RSI, MSS, BOS, Displacement,
            LiquiditySweep, FVG, Vegas, SpikeAge, DistanceFromHigh
  output:   class in {0 RANGE, 1 UP, 2 DOWN} + probability vector

Parameters (section 19):
  Delta 50pt; SELL lot 0.01; d_bs 50pt; N_max 10; RecoveryMult 0.50; Confidence 0.68;
  ProbGap 0.20; RecoveryDD 1.0%; maxSpread (broker-opt); minMarginLevel 800-1200%; tau_max (opt).

Objective (section 21):
  maximise E[log growth] subject to P(ruin) <= risk budget (NOT "never lose").

Validation (AMOS Phase C): backtest with real Deriv spread; the AI direction model must show
out-of-sample edge (else recovery is negative-EV); accept only if P(ruin) < 1% and E[log] > 0
via scripts/monte_carlo_validate.py (P10 / worst-decile, Rule 4). Note: on a synthetic index with
no real order flow, ICT-style features (MSS/BOS/FVG/LiquiditySweep) need empirical importance
checks before being trusted.
```

## SNS Ideas

- "Delta Lock explained: how to freeze a grid's directional risk (and why it isn't free)."
- Honest series: the AI recovery only works if the model beats chance on BOOM — how we test that.
- Risk-budget framing: maximise growth within a defined ruin probability, not "never lose".

## NotebookLM Summary

The BOOM Delta Lock & AI Recovery Engine (v1.1) is a three-state system: a drift-harvesting
equal-lot SELL pyramid (A), an equal-volume BUY-STOP delta lock that zeroes net exposure when an
up-spike hits (B), and an ONNX-driven directional recovery basket with a confidence gate and hard
finite-risk caps that covers the locked loss plus carry costs before closing everything (C). It is
deliberately not martingale; risk limits and the AI's authority are strictly separated (the model
only chooses direction/entry/wait). The design's success hinges on the AI having real directional
edge on BOOM_100 after a spike, which must be demonstrated out-of-sample. Implementation is gated
on v0 validation and a validated model; deployment requires Monte Carlo P10 acceptance
(P(ruin) < 1%, E[log] > 0) and human approval. V2 adds adaptive grid/hedge, multi-symbol, an
AI ensemble, daily Monte Carlo, and Python-side self-optimization that only ships validated params.
