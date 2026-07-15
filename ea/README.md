# EA Code Factory (Layer 06)

Home for Expert Advisor (EA) source and shared includes generated from AMOS
knowledge packets. Codex implements here in response to dispatch issues
(Layer 05); nothing is deployed without validation (Layer 08/09) and human
approval (Layer 12).

## Structure

```
ea/
  strategies/   # one folder or .mq5 per strategy
  include/      # shared .mqh helpers (risk, sizing, logging)
```

## Conventions

- MQL5 (`.mq5` / `.mqh`) is the primary target; Python/Pine research code
  lives under `scripts/` or a strategy subfolder.
- Every strategy must document its Signal / Entry / Exit / Risk logic, and
  reference the source packet under `docs/inbox/`.
- No strategy is considered deployable until it has:
  - a backtest report under `reports/`,
  - a Monte Carlo report that passes `scripts/monte_carlo_validate.py`
    (P10 / worst-decile required — Non-Negotiable Rule 4),
  - risk controls per `docs/RISK_GOVERNOR.md`.

## Manual fallback

Strategies can be authored by hand here without the Codex loop; the
validation gates above still apply before deployment.
