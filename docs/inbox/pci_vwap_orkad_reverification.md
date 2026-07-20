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

## Verdict

- The reported result is **not explainable by hour/weekday selection alone**
  (Test 1), and the underlying mechanism is **directionally sound in
  mean-reverting conditions** (Test 2). The ~2.18%/mo claim is *plausible*.
- It remains **unproven** until, on the real parquet + BT code: (1) an
  out-of-sample split; (2) hour-perturbation robustness (h∈{0,2,12,14} should
  degrade gracefully — a cliff means the hours are curve-fit); (3) a
  fill-assumption / lookahead audit; (4) WFE ≥ 0.50 per the factory's own bar.
- 2.18%/mo also re-confirms the earlier verdict: honest optimizer output on
  real data lands at percent-scale monthly returns, not 50%.
