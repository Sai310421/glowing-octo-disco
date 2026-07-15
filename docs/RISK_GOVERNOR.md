# AMOS Risk Governor (Layer 09)

Status: Foundation Specification
Purpose: Define the non-negotiable risk controls every EA must satisfy
before it is considered deployable. No EA reaches live money without
passing this gate and receiving human sovereign approval (Layer 12).

---

## 1. Deployability Gate

An EA is **blocked** unless all of the following hold:

- A backtest report exists under `reports/`.
- A Monte Carlo report exists and passes `scripts/monte_carlo_validate.py`
  (P10 / worst-decile reported — Non-Negotiable Rule 4).
- Risk, drawdown, margin, and black-swan controls below are implemented and
  documented.

## 2. Risk Controls (minimum)

| Control | Requirement |
|---|---|
| Per-trade risk | Fixed fractional; default ceiling 1.0% of equity per trade |
| Max open risk | Aggregate open risk ceiling (default 3.0% of equity) |
| Daily loss stop | Halt new entries after a daily loss threshold (default 5%) |
| Max drawdown | Hard kill-switch at a strategy-specific max drawdown |
| Margin buffer | Never exceed a defined margin-utilization ceiling |
| Position sizing | Derived from stop distance, never fixed lots in production |

Defaults are conservative starting points; each strategy documents its own
values and the rationale, reviewed against the worst-decile numbers.

## 3. Black-Swan Controls

- Gap / slippage assumptions modeled in the Monte Carlo report.
- Correlation / concentration limits across simultaneously running EAs.
- Broker/feed outage behavior defined (flatten, hold, or alert).
- Worst-decile (P10) drawdown, not the average case, governs sizing.

## 4. Governance

- Rule 3: no trading claim is accepted without validation.
- Rule 4: Monte Carlo must report P10 / worst-decile.
- Rule 7: human approval is mandatory for live-money deployment.

## 5. Roadmap

This specification defines the contract. The enforcing implementation
(shared `ea/include/` risk module + CI check wiring the validator into the
EA pipeline) is tracked as EA factory work.
