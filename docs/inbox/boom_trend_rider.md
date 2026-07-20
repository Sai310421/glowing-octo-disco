# AMOS Knowledge Packet — BOOM Trend Rider v0 (video-faithful reproduction)

Source: frame-by-frame re-analysis (61 frames @1fps) of the 61s TikTok clip (@ml.trader54,
BOOM_100, MT5 mobile, M1) that also seeded `boom_drift_grid.md`.
Relation: sibling of `boom_drift_grid.md` (v0). The drift grid is a *drift-biased simplification*;
this packet captures what the video actually shows: a **symmetric, always-in, stop-and-reverse
trend rider**. Delta Lock (`boom_delta_lock_ai_recovery.md`) is reused as the sudden-change guard.
Status: Design packet + hardened EA (v1.00 production guards, v1.10 multi-symbol
auto-calibration + dynamic ATR trail; see the EA README).
Not compiled, not backtested, not deployable (Rules 3/7).

v1.10 addendum (XAUUSD port): the mechanism is unchanged; all thresholds that
were BOOM-scale absolutes become broker-derived — pitch floor and entry gate
from a measured spread EMA, lot/N_max from equity + leverage via OrderCalcMargin,
spike velocities in ATR multiples, and the reverse stop optionally trails
chandelier-style at k·ATR behind the leg's best price. On real symbols the news
module stops being optional: gold gaps on CPI/NFP/FOMC, so FLATTEN or LOCK
windows are part of the deployment config, and Phase C must be re-run per symbol.

## Summary

The video system is always in the market on the side of the current trend leg. It stacks
fixed 0.01 lots every Δ ≈ 50 index points as the leg advances (equal-lot pyramid, no
martingale), producing the observed profit ladder (+0.24 / +0.77 / +1.29 / +1.82 / +2.33 /
+2.83 USD — evenly spaced ≈ 0.5 USD steps). One opposite-direction stop order is armed at all
times about one pitch away and is **re-trailed continuously as price advances** ("常に価格を
追っている"). When the leg ends, price walks into the opposite stop: the old stack is closed
(banking the ladder = 利益の積み重ね) and the filled stop becomes seed #1 of the new stack in
the new direction. The engine is direction-symmetric: the clip shows a BUY ladder on the
16:10–16:21 up-leg and a SELL ladder on the 16:21–16:35 down-leg of the same M1 session.

## Video evidence (frame timestamps at 1fps)

| Frame | Time | Observation |
|---|---|---|
| f_001–f_005 | 0:00–0:05 | 7 SELL 0.01 stacked, ladder +0.24…+3.57 USD, pitch ≈ 51 pt; single BUY STOP 0.01 sandwiched ~1 pitch above the lowest SELL; all lines hug price |
| f_010–f_013 | 0:09–0:13 | after an up-move: BUY 0.01 (−0.11…−0.30) open with SELL STOP 0.01 just below — direction flipped, old BUYs (+1.29, +1.93) from the up-leg still visible |
| f_020 | 0:19 | BUY STOP and a small SELL both at price — the flip moment (brief both-sided state) |
| f_030–f_050 | 0:29–0:49 | SELL ladder rebuilt on the down-leg (+0.19…+2.36), BUY STOP re-armed and trailed between the two lowest SELL levels |
| f_060 | 0:59 | outro (TikTok handle) |

## Key Concepts

- Always-in, symmetric stop-and-reverse (SAR): ride the leg, flip on reversal — 基本順張り、常に反転に準備.
- Equal-lot pyramid every Δ in the trend direction (no martingale); profits accrue as a ladder.
- Single opposite stop, lot = 1 unit (flip seed, NOT a full hedge), re-trailed every tick.
- Banked profit comes from closing the stack on flip; the flip order loses at most ~Δ if the
  reversal is false — the asymmetry (ladder gain vs one-pitch give-back) is the whole edge claim.
- Regime-adaptive pitch (design decision below); Delta Lock guard for spikes; news module split out.

## Design decisions (the four open questions)

### 1. レンジ相場ではピッチを狭める?広げる? → **広げる**
This is a *stop-order* (breakout-side) grid: entries are placed in the direction of travel, so
in a range every entry is bought high / sold low and then mean-reverts — each whipsaw costs up
to one pitch plus spread. Narrowing the pitch in a range multiplies the number of whipsaws;
narrowing is correct only for the opposite mechanism (mean-reversion *limit* grids). Faithful
rule: pitch must stay **outside the noise band**:

- Δ_t = max(Δ_min, c_atr · ATR_M1(n)) — volatility floor.
- Regime detector: Kaufman Efficiency Ratio ER = |p_t − p_{t−n}| / Σ|p_i − p_{i−1}|.
- ER < er_lo (range): Δ_t ← Δ_t · w_range (default ×2) and stacking is halted beyond the seed
  (seed + reverse stop keep straddling price, so a breakout is never missed).
- ER ≥ er_hi (trend): full stacking at Δ_t. Between the two: keep current mode (hysteresis).

### 2. 急変時は両建てロック → 後で相殺? → **はい (Delta Lock を流用)**
On a velocity spike against the stack (|p_t − p_{t−τ}|/τ ≥ v_max), a same-volume opposite
market order freezes net delta at 0 (両建てロック). Lock freezes *directional* risk, not cost.
Offsetting afterwards ("その後の取引で相殺") is exactly the Recovery phase of spec v1.1 —
v0 of this EA implements the deterministic part only: unwind the lock when velocity calms
(resume ride if the leg survived; flip if the spike became the new leg) and let subsequent
flip cycles absorb the locked cost. AI-directed recovery stays in the v1.1 engine.

### 3. 常に価格を追う → reverse stop trailing
The opposite stop is re-priced every tick to distance d_rev (default = Δ_t) behind the best
price of the leg, monotonically (never loosened). This is what the video's moving dashed line is.

### 4. 指標(経済指標)は別ロジックで利益最大化 → **separate module, default OFF**
BOOM_100 is a Deriv synthetic index — no economic calendar affects it; the module exists for
porting to real symbols. Time-window driven, three modes: FLATTEN (close & halt through the
window), LOCK (delta-lock through the window), STRADDLE (halt stacking, arm a symmetric wide
stop pair k_news·Δ to harvest the announcement breakout, then hand the fill to the normal
ride logic). Windows are broker-server time, `HH:MM-HH:MM;...` format.

## TODO
- [ ] Validate EA Logic against the Risk Governor (risk, DD, margin, black-swan controls)
- [ ] Add Monte Carlo P10 / worst-decile validation for any trading claim
- [ ] Confirm no secrets or destructive commands are included
- [ ] Generate the NotebookLM Summary section
- [ ] Draft SNS / content ideas where applicable
- [ ] Compile `BoomTrendRider_v1.mq5` in MetaEditor; fix any errors
- [ ] Phase C: backtest on Deriv BOOM_100 tick/M1, realistic spread; compare vs BoomDriftGrid v0
- [ ] Sweep: Δ_min ∈ {30,50,100} × w_range ∈ {1.5,2,3} × er thresholds × N_max ∈ {5,7,10}
- [ ] Measure whipsaw cost in ranges with w_range=1 (control) to verify the "widen" decision
- [ ] Report P(ruin) < 1%, E[log(E_T/E_0)] > 0, P95(DD) before any live consideration

## EA Logic
```text
Symbol/Timeframe: BOOM_100 (Deriv synthetic), M1. Direction-symmetric.

State machine:
  FLAT -> RIDE(dir) -> (flip) -> RIDE(-dir) -> ...
  RIDE -> LOCKED (velocity spike against stack) -> RIDE | flip
  any  -> NEWS_{FLATTEN|LOCK|STRADDLE} during a configured window

FLAT (seed):
  Straddle price with BUY STOP @ ask+Δ_t and SELL STOP @ bid−Δ_t (lot L).
  First fill decides dir; remaining pendings are deleted.

RIDE(dir):
  Stack:  when price has advanced ≥ Δ_t beyond the last stack entry in the trend
          direction and count < N_max and regime != RANGE-halt: add market lot L.
  Reverse stop: exactly one opposite stop, lot L, at distance d_rev from current
          price, trailed monotonically tighter every tick (never loosened).
  Flip:   opposite-type position appears (reverse stop filled) =>
          close whole old stack (bank ladder), the fill is seed #1 of RIDE(-dir),
          arm a fresh reverse stop on the other side.
  Optional per-position TP at c_tp·Δ_t (default OFF — video shows pure SAR).

LOCKED (sudden change, 両建て):
  Trigger: velocity = |p_t − p_{t−τ}|/τ ≥ v_max AGAINST the stack while count ≥ 2.
  Action:  market order, opposite type, lot = total stack volume (magic = lock magic),
           delete pendings. Net delta = 0.
  Unwind:  when velocity < v_calm:
             price back on stack side of lock price  => close lock leg, resume RIDE
             price ≥ Δ_t beyond lock price against stack => close stack legs
                (realize), keep lock leg as new seed, flip dir.

Regime/pitch (every tick, computed on closed M1 bars):
  Δ_t   = max(Δ_min, c_atr · ATR(n_atr))
  ER    = |close_0 − close_n| / Σ_{i=1..n} |close_{i−1} − close_i|
  ER < er_lo  => RANGE:  Δ_t *= w_range; no stacking beyond seed
  ER ≥ er_hi  => TREND:  normal stacking       (hysteresis in between)

News windows (separate logic, default OFF; server time "HH:MM-HH:MM;..."):
  FLATTEN:  close everything InpNewsPreMin before the window, halt inside it.
  LOCK:     delta-lock before the window, unwind after it.
  STRADDLE: halt stacking, cancel reverse stop, arm BUY STOP @ +k_news·Δ_t and
            SELL STOP @ −k_news·Δ_t; a fill inside the window seeds a normal RIDE.

Risk (v0):
  Equal lot L everywhere, N_max cap, margin-level floor halts new exposure.
  No basket SL in v0 (same honest gap as drift grid v0 — v1 layer applies).
```

## Mathematical Concepts
```text
Ladder value at flip (k stacked, pitch Δ, lot L, tick value V per point):
  positions sit at p_1, p_1±Δ, ...; at flip trigger d_rev beyond the best price:
  PnL_flip ≈ L·V·100 · [ k·(x − d_rev) − Δ·k(k−1)/2 ]   where x = leg length from seed.
  Grows ~quadratically-capped-linear in x; give-back per false flip ≈ L·V·100·d_rev.

Edge condition (per leg pair):
  E[ladder gain | leg ≥ 2Δ] · P(leg ≥ 2Δ)  >  (d_rev + spread)·L·V·100 · P(whipsaw)
  Range regime raises P(whipsaw) sharply => widening Δ (w_range) lowers trade count
  and pushes entries outside the noise band; this is the testable claim of decision 1.

Whipsaw cost in a range of half-width R:
  pitch Δ < R  => alternating fills, each losing ≈ (Δ + spread) — narrowing multiplies
  loss frequency ∝ 1/Δ while loss size only falls ∝ Δ: net cost/time rises as spread
  dominates. Δ > 2R => no fills inside the range. Hence: widen, never narrow.

Velocity spike guard: v_t = |p_t − p_{t−τ}|/τ ; lock at v_t ≥ v_max, unwind at v < v_calm.
Lock is cost-neutral in delta but pays spread twice + swap while held (v1.1 §5-6 applies).
```
