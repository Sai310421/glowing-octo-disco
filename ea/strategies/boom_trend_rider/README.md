# BOOM Trend Rider v1 (EA)

Implements `docs/inbox/boom_trend_rider.md` — the **video-faithful** reproduction
of the TikTok clip mechanism: a symmetric, always-in, stop-and-reverse trend
rider on **M1**. Rides each leg with an equal-lot pyramid, keeps one opposite
stop trailed with price at all times, banks the ladder on every flip. v1.00 is
the production-hardened build (same bar as the v1.11 Delta Lock hardening
pass); **v1.10 makes it multi-symbol (XAUUSD-ready)** with broker
auto-calibration and a dynamic ATR trail.

> Code-complete, but **not compiled and not backtested** — there is no
> MetaTrader here. Compile in MetaEditor 5, run the Phase C backtest, and get
> Monte Carlo + human approval (Rules 3/4, Layer 12) before any live use.

## Files
- `BoomTrendRider_v1.mq5` — the Expert Advisor.

## v1.10 — XAUUSD / multi-symbol additions

**Broker auto-calibration** (`InpAutoCalibrate`, default ON):
- **Spread detection**: the EA maintains an EMA of the live ask−bid spread.
  The pitch floor becomes `max(InpDeltaMin, InpPitchSpreadMult × avgSpread)`
  and new exposure is skipped whenever the current spread blows out past
  `InpSpreadSpikeMult × avgSpread` (news, rollover, thin liquidity) — no
  hand-tuned point values per broker.
- **Leverage/margin adaptation**: lot size is derived from equity and
  `InpRiskPctPerFlip` (the % of equity one false flip may cost), then the
  full-stack margin is checked against `InpMaxMarginUsePct` of equity using
  `OrderCalcMargin` (which reflects the account's real leverage and the
  symbol's margin rate). The stack cap `N_max` — and if necessary the lot —
  are reduced automatically until the worst case fits.
- **Spike thresholds in ATR units**: `InpSpikeAtrMult` / `InpCalmAtrMult`
  replace the fixed price-unit velocities, so the delta lock works on gold,
  indices, or BOOM alike. Manual price-unit inputs remain for
  `InpAutoCalibrate=false`.
- Trail re-pricing step also auto-scales (fraction of ATR/spread).

**Broker-adaptive timeframe** (v1.20, `InpAutoTimeframe`, default ON):
- The EA no longer cares which chart timeframe it is attached to. It walks the
  ladder M1→M5→M15→M30→H1→H4 and picks the **fastest timeframe whose average
  bar range clears `InpTfRangeSpreadMult × avgSpread`** — on a wide-spread
  broker the bars of a too-fast timeframe are smaller than the cost of
  crossing the spread, so pitch and trail would degenerate into churn.
- The choice is re-checked every `InpTfReviewMin` minutes; stepping back down
  to a faster timeframe requires a 30% margin (hysteresis) so the EA does not
  flap between timeframes intra-session. On a switch, indicators are rebuilt
  and pitch/regime/sizing recompute; open positions and stops are price-based
  and unaffected.
- `InpAutoTimeframe=false` + `InpTimeframe` gives a fixed manual timeframe.

**MQL5 economic calendar** (v1.30, `InpUseCalendar`, default ON):
- The built-in MT5 calendar (`CalendarValueHistory`/`CalendarEventById`)
  is polled every `InpCalRefreshMin` minutes for events of at least
  `InpCalMinImportance` (default HIGH — CPI/NFP/FOMC tier) in the symbol's
  currencies (`InpCalCurrencies="auto"` derives them from the symbol; XAUUSD
  → USD). Each event opens a news window from `InpCalPreMin` before to
  `InpCalPostMin` after, handled by the same `InpNewsMode` action
  (FLATTEN default / LOCK / STRADDLE). Manual `InpNewsWindows` ranges
  still work and are OR-ed in.
- Status line shows a countdown (`news in Xm`) when an event is near.
- **Honest limits**: the calendar API returns nothing in the Strategy
  Tester and needs a terminal connected to MetaQuotes — the EA logs one
  warning and falls back to manual windows there. Backtests therefore do
  NOT include calendar behaviour; validate news handling on demo, or via
  manual windows in the tester. For synthetics (BOOM_100) set
  `InpNewsMode=NEWS_OFF`.

**Dynamic ATR trail** (`InpTrailMode = TRAIL_ATR`, default):
- Chandelier-style: the reverse stop sits `InpTrailAtrMult × ATR` behind the
  **best price of the current leg** and only ever tightens. Volatility
  expansion widens the distance for new legs; contraction hugs the trend.
  `TRAIL_PITCH` keeps the v1.00 fixed-multiple-of-pitch behaviour.
- The trail distance is floored at `InpPitchSpreadMult × avgSpread` so the
  stop can never sit inside the broker's cost band.

Recommended XAUUSD starting point: defaults as shipped (auto ON, TRAIL_ATR,
risk 0.5%/flip), `InpNewsMode=NEWS_FLATTEN` or `NEWS_LOCK` with the day's
red-calendar windows in `InpNewsWindows` — unlike BOOM, gold gaps hard on
CPI/NFP/FOMC. All prices are in the symbol's own chart units.

## Production hardening (v1.00)
- **Two-step flip** (`ST_FLIP`): the reverse-stop fill flips the direction
  first, then the old stack is closed with retries; a slow or rejected close
  can never trigger a second, phantom flip.
- **Lock verify + rebalance**: in `ST_LOCKED` the hedge volume is checked
  against the stack volume every tick; small gaps (partial fills) are
  corrected up to `InpLockRebalMax` times, then the EA flattens via
  `ST_EMERGENCY` instead of carrying unknown exposure.
- **Account guards**: daily-loss halt (`InpMaxDailyLossPct`, flat until the
  next server day), equity-peak drawdown **kill-switch**
  (`InpMaxDrawdownPct`, stays down until re-init by design), margin-level
  floor, free-margin precheck per add, max-spread gate for new exposure.
- **Execution hygiene**: lot normalization to the symbol's step/min/max,
  stops-level and freeze-level respected on every pending placement/modify,
  churn guard (`InpTrailStep`) so stops are re-priced by meaningful steps
  instead of every tick, backoff after any rejected operation
  (`InpOpBackoffSec`), input validation at init.
- **Restart safety**: state persists in GlobalVariables and is reconciled
  against live positions on init (live positions win); an interrupted flip
  (both sides open) is detected and resumed; the kill-switch survives
  restarts.
- **Status line** on the chart (state, direction, stack, pitch/regime, equity).

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
| `InpLockTolLots`, `InpLockRebalMax` | lock volume tolerance and rebalance attempts | decision 2 |
| `InpNewsMode`, `InpNewsWindows`, `InpNewsPreMin`, `InpNewsStraddleK` | news module: OFF / FLATTEN / LOCK / STRADDLE | decision 4 |
| `InpMinMarginLevel`, `InpMaxDailyLossPct`, `InpMaxDrawdownPct`, `InpMaxSpreadPts`, `InpCooldownSec` | account guards + kill-switch | risk |
| `InpTrailStep`, `InpOpBackoffSec`, `InpShowComment` | execution hygiene | — |
| `InpMagic` / `InpMagicLock` | ride basket vs lock leg (kept separate) | — |

## Behaviour
- **FLAT**: straddles price with a BUY STOP and a SELL STOP one pitch away,
  both re-priced to follow price; the first fill decides the ride direction.
- **RIDE**: adds a fixed lot each time price advances one pitch with the trend;
  keeps exactly one opposite stop `d_rev` behind price, tightened in steps of
  `InpTrailStep`, never loosened. When it fills → **FLIP**: the whole old
  stack is closed (the ladder is banked) and the fill seeds the new ride.
- **Range regime** (ER low): pitch is **widened** (`InpRangeWiden`) and
  stacking pauses — a stop-order grid narrowed in a range just multiplies
  whipsaws.
- **LOCKED**: a velocity spike against the stack triggers an equal-volume
  opposite market order (net delta 0), verified and rebalanced. After calm:
  hedge dropped and ride resumes if the leg survived; stack realized and the
  engine reseeds if the spike became the new leg. Offsetting the locked cost
  is then carried by the normal flip cycles (full AI recovery lives in the
  v1.1 Delta Lock engine).
- **News windows** (server time; for real-symbol ports — BOOM_100 has no
  calendar): FLATTEN, LOCK (double-hedge-guarded), or STRADDLE (wide stop
  pair whose fill seeds a normal ride after the window).

## Deployment checklist (in order)
1. Compile `BoomTrendRider_v1.mq5` in MetaEditor 5 — paste any errors back
   into the pipeline and they get fixed.
2. Strategy Tester: Deriv BOOM_100, tick/M1, **real spread**. Sweep
   `Δ_min ∈ {30,50,100}` × `w_range ∈ {1,1.5,2,3}` × ER thresholds ×
   `N_max ∈ {5,7,10}`; `w_range=1` is the control that tests the
   widen-in-range decision.
3. Monte Carlo via `scripts/monte_carlo_validate.py`; accept only if
   `P(ruin) < 1%` and `E[log(E_T/E_0)] > 0`.
4. Demo account soak (≥ 2 weeks) with `InpMaxDailyLossPct`/`InpMaxDrawdownPct`
   at final values; verify restart recovery by killing the terminal mid-ride.
5. Human approval (Layer 12) before any real-money attach.

Reminder: the honest failure mode is chop — a false flip costs ~one pitch +
spread each time. The regime detector is the make-or-break component, not the
stack.
