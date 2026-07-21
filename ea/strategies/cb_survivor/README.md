# CB Survivor EA (reproduction)

Reproduction of the "CB Survivor EA" from its user manual
(`CB_Survivor_Manual.pdf`): a hedged nanpin grid whose profit engine is
**per-lot cashback volume**, kept alive by four survival mechanisms —
combined-basket TP, TailCut (pool-funded buyout of stuck positions),
ReverseGrid (pool refill), and SlotFree (Offset2 slot rotation) — plus
BulkClear and the on-chart control panel.

> Not deployable. Compile in MetaEditor 5, then demo-test (the manual's own
> instruction) before any real funds. **A nanpin grid's tail risk is
> unbounded** — pool/TailCut/BulkClear smooth the equity curve, they do not
> remove the blowup scenario. Phase C validation required (Rules 3/7).

## Files
- `CBSurvivor_v1.mq5` — the Expert Advisor.

## Defaults vs the manual's recommended XAUUSD M1 set
Inputs default to the manual's section-level defaults. The manual's section 12
recommends for XAUUSD M1: `NormalProfit=1.0`, `NanpinLotMultiplier=2.0`,
`Offset2_ExtraPips=50`, `Offset2_GapPips=100`, `ReverseGrid_TriggerCount=10`,
`CB_Per_Lot=15.0` (rest as defaults). Apply via the inputs dialog.

## Mechanisms (manual section → code)
| Manual | Code |
|---|---|
| §2 grid basics | `ManageMainGrid` — hedged seed, nanpin every `NanpinPips` against each side, cap `MaxPositions`/side |
| §3 basket TP | `ManageBasket` — combined (or per-side when BASKET OFF) floating PnL excluding stuck (loss > `StuckThreshold`) ≥ `NormalProfit` ⇒ close basket |
| §4 TailCut | `ManageTailCut` — pool ≥ worst stuck loss ⇒ buy it out; all realized PnL flows through the pool; negative pool resets to 0 after 5s |
| §5 ReverseGrid | `ManageReverseGrid` v1.10 (author-corrected) — hedge leg mirrors the NET stuck volume ⇒ stuck minus frozen (両バリ固定); shrinks as TailCut amortizes, realizing into the pool; separate magic |
| §6 SlotFree | `ManageSlotFree` — at full slots: TriggerA (newest-entry distance ≥ `Offset2_ExtraPips`) OR TriggerB (close-rotation < `Rotation_Threshold`% of previous window) ⇒ close newest (+1 if gap ≥ `Offset2_GapPips`), cooldown |
| §7 lot ladder | `NanpinLot` — ×`NanpinLotMultiplier` from level `NanpinLotFrom` |
| §8 BulkClear | equity ≥ base + `BulkClearProfit` ⇒ flatten, re-anchor base, optional auto-stop |
| §9 weekend | `CLOSE_ALL_WE` / `ACTION_NONE` |
| §10-11 panel | all 9 buttons + P&L/pool/daily/CB/counters readout; state persists in GlobalVariables |

## Flagged assumptions (not specified by the manual)
1. **Seeding**: one starter position per side is kept open (hedged grid start).
2. **ReverseGrid semantics (v1.10)**: per the author's correction, the
   reverse leg is a delta hedge equal to the net stuck volume — it freezes
   the stuck minus; pool profits then amortize it (利益はマイナスを減らす).
   The v1.00 reading (independent counter-chain with per-position TP) is
   retired.
4. **TriggerA/B combination**: OR (manual lists both without stating logic).
5. **Pips**: 1 pip = 10 × `_Point` ($0.10 on 2-digit XAUUSD). Verify against
   your broker's digits before live use.
6. 履歴 (history) panel toggle is omitted (chart-display cosmetic only).

If the original EA's behaviour differs on any of these, say which and the
implementation will be aligned.

## Honest economics note
The design intent is: churned volume × `CB_Per_Lot` rebate ≥ grid bleed.
With the recommended set (0.01 lot, 25-pip grid, CB $15/lot) the EA must
keep net trading loss under ~$0.15 per 0.01-lot round trip to break even
before rebates. Whether that holds is a Phase C question — backtest the grid
WITHOUT the CB credit first, then add CB × realized volume; and confirm the
rebate program's terms actually pay on this kind of volume.

## Phase C result on real data (2026-01-04..07-03, ork.ad 1m, scripts/cb_survivor_bt.py)

Recommended XAUUSD set, $10k start, decisions on 1m closes, spread sweep:

| spread | net trading PnL (no CB) | volume | CB @$15/lot | net+CB | break-even CB | outcome |
|---|---|---|---|---|---|---|
| $0.20 | −$1,824/mo | 77.5 lot/mo | +$1,163/mo | **−$661/mo** | $23.5/lot | account blown |
| $0.28 | −$1,842/mo | 26.6 lot/mo | +$399/mo | **−$1,442/mo** | $69.2/lot | account blown |
| $0.35 | −$1,710/mo | 18.5 lot/mo | +$277/mo | **−$1,433/mo** | $92.6/lot | account blown |

This half-year was a strong gold bull (+$1,655 range): the 25-pip/25-level
grid's covered range ($62.5) was overrun for weeks at a time, and the
survival mechanisms converted the unbounded floating loss into a realized
bleed of ~$1,700-1,850/mo that no realistic rebate rate ($5-15/lot; break-even
here $23-93/lot) can cover. Max floating DD ~$10.8k ⇒ margin call on $10k.
A larger account avoids the blowup but not the negative net economics.

**Verdict: on trending regimes the CB engine cannot pay for the grid. Do not
run this EA unattended on gold with the recommended set.** If used at all, it
needs a regime filter (range-only operation) and per-month kill criteria —
and that modified system would require its own Phase C pass.

## v2 result — author-corrected dynamics (両バリ固定 + プール償却)

After the author's correction the simulation freezes the stuck minus with an
equal-volume hedge and lets the pool amortize it (scripts/cb_survivor_bt.py,
`simulate_lock`). Same data, same recommended set:

| spread | max floating DD | net trading (no CB) | volume | net+CB@15 | break-even CB |
|---|---|---|---|---|---|
| $0.20 | **$586** (was $10,852) | −$1,698/mo | 62.6 lot/mo | −$759/mo | $27.1/lot |
| $0.28 | **$577** | −$1,698/mo | 46.7 lot/mo | −$997/mo | $36.3/lot |
| $0.35 | **$588** | −$1,700/mo | 38.0 lot/mo | −$1,130/mo | $44.7/lot |

The correction works exactly as described for RISK: the minus is frozen and
steps down through 2,600-4,800 TailCuts. What it cannot remove is the
pre-lock cost: a position only becomes "stuck" (and hedgeable) after losing
`StuckThreshold` ($3.3), and a trend manufactures a fresh stuck position
every ~25-33 pips on the re-seeding side — a structural bleed of ~$1,700/mo
on this bull half-year, spread-independent. CB at realistic rates covers
roughly half of it. In ranging months the same engine should be net positive;
regime gating remains the decisive missing piece.
