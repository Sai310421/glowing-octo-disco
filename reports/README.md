# Reports (Backtest & Monte Carlo Validation)

Validation evidence for every EA before it can be considered deployable
(Layer 08). No trading claim is accepted without a report here
(Non-Negotiable Rule 3).

## Required artifacts per strategy

1. **Backtest report** — period, symbol, timeframe, net profit, max
   drawdown, trade count, Sharpe/Sortino.
2. **Monte Carlo report** (`<strategy>.mc.json`) — must report P10 /
   worst-decile outcomes and pass `scripts/monte_carlo_validate.py`
   (Non-Negotiable Rule 4).

## Monte Carlo report schema

```json
{
  "strategy": "example_breakout",
  "num_simulations": 1000,
  "median_return": 0.18,
  "p10_return": -0.04,
  "p10_max_drawdown": 0.22,
  "worst_case_drawdown": 0.31
}
```

Validate before merge / deployment:

```bash
python3 scripts/monte_carlo_validate.py reports/example_breakout.mc.json
```

A non-zero exit blocks the claim: the worst-decile (P10) results are the
governing numbers, not the average case.
