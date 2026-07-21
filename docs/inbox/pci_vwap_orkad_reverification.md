# AMOS Knowledge Packet — OrkAD PCI/VWAP best candidate: independent re-verification

Source: user-uploaded `AMOS_Phase3_PCI_VWAP_OrkAD_BEST_R2_E008.zip` (.set/.json/README
only — no EA code, no data). Claim: XAUUSD M5 VWAP-band reversion, hours UTC 1&13,
Mon-Wed, PF 2.83, WR 83%, maxDD 2.99%, 100 trades / 6 months, ~2.18%/mo, MC fail 0%.
Tooling: `scripts/pci_vwap_reverify.py` → `reports/pci_vwap_reverify.json`.
Limits: the source parquet and Python BT code were NOT available; tests below are
the two verifications possible without them.

## Test 1 — selection-bias null (can cherry-picking alone explain it?)

No-edge trades (EV=0, RR 1.8, n=100/cell), best cell of a grid:

| search size | null best-cell PF p95 / p99 | null best WR p95 | P(best PF ≥ 2.83) |
|---|---|---|---|
| 60 cells | 1.87 / 2.20 | 51% | 0.00% |
| 2,760 cells | 2.29 / 2.39 | 56% | 0.00% |
| 20,000 cells | 2.49 / 2.70 | 58% | 0.00% |

WR 83% sits 4.9σ above the null even assuming trades are so correlated that
n_eff=25. **Hour/weekday cherry-picking alone cannot produce these numbers.**

Caveats that keep this from being an endorsement:
- The candidate uses partial closes (half off at +0.55) — that accounting
  mechanically inflates "win rate", so the 83% is weaker evidence than it looks;
  PF is the robust metric, and PF 2.83 is only modestly above the 20k-cell null
  p99 (2.70). The optimizer searched ≥4 dimensions (h, wd, r, e), so the real
  search space may be large.
- A fill/lookahead bug in the (unseen) BT code would produce exactly this
  signature and is NOT excluded by this test.

## Test 2 — mechanism sign on calibrated synthetic XAUUSD (candidate's costs)

VWAP ±2σ edge-zone reversion, ER gate, SL 0.7·ATR, TP 1.8R, spread 28pt +
slip + $7/lot commission, unfiltered by session (the synthetic has none):

| market regime mix | median monthly | median PF |
|---|---|---|
| mean-reverting only (OU range) | **+19.6%** | 1.11 |
| calibrated (trends + ranges) | −4.3% | 0.98 |
| trend-heavy | −18.5% | 0.89 |

**The mechanism genuinely profits when conditions are mean-reverting and is
run over by trends.** This makes the strategy's hour filter (trade only
mean-reverting sessions) coherent in principle — and also its single point of
failure: the edge lives in the session selection, which is exactly the part a
6-month/100-trade sample cannot pin down.

## Test 3 — real-data reproduction (added after the data upload)

Data: user-supplied `XAUUSD_1m_20260104_20260703_orkad.csv` (ork.ad free sample,
176,888 rows, UTC-verified against broker data by the user, avg feed diff $0.60;
11 vendor glitch rows with high<low repaired to row max/min), resampled to M5
(35,439 bars) — the SAME period and data family as the candidate's parquet.
Harness: `scripts/pci_vwap_bt.py`, conservative fills (entry pays half-spread +
slippage, worst-case SL-first intrabar ordering), costs per the .set.

All four plausible readings of the ambiguous .set fields:

| interpretation | trades | WR | PF | total ret | maxDD |
|---|---|---|---|---|---|
| wide zone, fade | 192 | 52.1% | 0.80 | −18.3% | 23.2% |
| wide zone, reversed signal | 192 | 57.8% | 1.04 | −1.7% | 20.3% |
| strict zone, fade | 76 | 56.6% | 1.01 | −1.6% | 6.8% |
| strict zone, reversed | 77 | 54.5% | 1.08 | +0.2% | 9.4% |
| **claimed** | **100** | **83%** | **2.83** | **+13.7%** | **2.99%** |

Supporting runs: IS/OOS half-split (PF 1.08 → 0.60 — no hidden edge), hour
perturbation h∈{0,1,2}×{12,13,14} (PF 0.75–0.92 everywhere, no cliff and no
peak at (1,13) — the chosen hours add nothing robust on this feed),
partial-close-as-R variant (PF 0.81).

**The claimed metrics do not reproduce.** Feed difference explains ~0.2 of PF
(the user's own cross-check), not 1.8+. The most likely source of the gap is
the cycle/leg subsystem the .set hints at (`max_legs_per_cycle=4`,
`max_open_cycles=3`, `target_cycle_profit_pct=1.2`, `max_cycle_dd_pct=3`) —
a recovery-basket accounting that mechanically produces high win rates by
holding losing cycles to a small profit target, concentrating losses into
rare large events; and/or optimistic fills in the unseen BT code. Reproducing
that requires the original Python BT source.

## Verdict

- UPDATED after Test 3: **the candidate's claimed metrics failed independent
  real-data reproduction.** Every plausible single-position reading of the
  .set lands at PF 0.80–1.08 (break-even at best) on the same-family data and
  period, with no robustness in the chosen hours. Do NOT deploy this .set.
- The claim is now bounded to two possibilities: an unimplemented
  cycle/recovery subsystem (whose high WR is an accounting artifact with tail
  risk), or optimistic fills / lookahead in the unseen BT code. Auditing
  either requires the original Python BT source.
- Tests 1-2 remain valid as method results: selection alone couldn't have
  produced the claim, and VWAP reversion only earns in mean-reverting
  conditions. Test 3 shows this feed/period doesn't deliver those conditions
  at the chosen hours.
