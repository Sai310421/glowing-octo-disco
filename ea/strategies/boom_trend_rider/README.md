# BOOM Trend Rider v0 (EA)

Implements `docs/inbox/boom_trend_rider.md` — the **video-faithful** reproduction
of the TikTok clip mechanism: a symmetric, always-in, stop-and-reverse trend
rider for Deriv **BOOM_100** on **M1**. Rides each leg with an equal-lot pyramid,
keeps one opposite stop trailed with price at all times, banks the ladder on
every flip.

> Not deployable. No backtest has been run. No live use until Phase C
> validation passes (Monte Carlo P10, Non-Negotiable Rules 3/4) and a human
> approves (Layer 12). Compile in MetaEditor 5 first — no MT5 here.

## Files
- `BoomTrendRider_v0.mq5` — the Expert Advisor.

## Inputs (map to packet decisions)
| Input | Meaning | Packet |
|---|---|---|
| `InpDeltaMin`, `InpAtrMult`, `InpAtrPeriod` | pitch floor + ATR-adaptive pitch | decision 1 |
| `InpERPeriod`, `InpERRangeBelow`, `InpERTrendAbove` | Kaufman ER regime detector (hysteresis) | decision 1 |
| `InpRangeWiden`, `InpRangeHaltStack` | **range ⇒ widen pitch** (×2) and halt stacking | decision 1 |
| `InpLot`, `InpNMax` | equal lot per level, stack cap (no martingale) | ride |
| `InpRevDistMult` | reverse-stop distance = mult × pitch, trailed tighter only | decision 3 |
| `InpUsePerPosTP`, `InpCtp` | optional TP ladder (OFF = pure SAR like the clip) | ride |
| `InpUseLock`, `InpSpikeLookback`, `InpSpikeMaxVel`, `InpCalmVel`, `InpMinStackToLock` | velocity-spike delta lock (両建て) + calm unwind | decision 2 |
| `InpNewsMode`, `InpNewsWindows`, `InpNewsPreMin`, `InpNewsStraddleK` | news module: OFF / FLATTEN / LOCK / STRADDLE | decision 4 |
| `InpMinMarginLevel` | margin floor: halt new exposure below it | risk |
| `InpMagic` / `InpMagicLock` | ride basket vs lock leg (kept separate) | — |

## Behaviour
- **FLAT**: straddles price with a BUY STOP and a SELL STOP one pitch away;
  the first fill decides the ride direction.
- **RIDE**: adds a fixed lot each time price advances one pitch with the trend;
  keeps exactly one opposite stop `d_rev` behind price, tightened every tick,
  never loosened. When it fills, the whole old stack is closed (the ladder is
  banked) and the fill seeds the new ride in the other direction.
- **Range regime** (ER low): pitch is **widened** (`InpRangeWiden`) and stacking
  pauses — a stop-order grid narrowed in a range just multiplies whipsaws.
- **LOCKED**: a velocity spike against the stack triggers an equal-volume
  opposite market order (net delta 0). After calm: hedge dropped and ride
  resumes if the leg survived; stack realized and direction flipped if the
  spike became the new leg. Offsetting the locked cost is then carried by the
  normal flip cycles (full AI recovery lives in the v1.1 Delta Lock engine).
- **News windows** (server time, for real-symbol ports; BOOM_100 has no
  calendar): FLATTEN, LOCK, or STRADDLE (wide stop pair to harvest the
  announcement move, whose fill seeds a normal ride).

## Phase C (validation — required before any claim)
1. Deriv BOOM_100 tick/M1 in the MT5 Strategy Tester, real spread.
2. Sweep `Δ_min ∈ {30,50,100}` × `w_range ∈ {1,1.5,2,3}` × ER thresholds ×
   `N_max ∈ {5,7,10}`; `w_range=1` is the control that tests the
   widen-in-range decision.
3. Monte Carlo via `scripts/monte_carlo_validate.py`; accept only if
   `P(ruin) < 1%` and `E[log(E_T/E_0)] > 0`.

Reminder: the honest failure mode is chop — a false flip costs ~one pitch +
spread each time. The regime detector is the make-or-break component, not the
stack.
