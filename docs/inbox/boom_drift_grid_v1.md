# AMOS Knowledge Packet — BOOM Drift Grid v1 (survival layer)

Source: MSS Group spec `_boom_drift_grid_spec_v0.pdf`, section 8 (v1 improvements).
Depends on: `docs/inbox/boom_drift_grid.md` (v0) and `ea/strategies/boom_drift_grid/`.
Status: Design packet. Implementation is **gated on v0 Phase C results** (see Gate).
Not deployable (Rules 3/7).

## Summary

v1 adds the survival layer that v0 deliberately omits. v0 is a reactive, drift-biased SELL
grid with a thin BUY STOP hedge and **no stop-loss**; its dominant risk is an up-spike hitting
the full SELL stack. v1 introduces four controls: risk-based position sizing with a basket
stop-loss, a spike filter that halts new SELLs during a spike, a dynamic BUY STOP hedge that
scales with exposure, and equity management (withdrawals + drawdown halt). None of these change
the core idea; they bound the tail so the strategy can survive long enough for the drift edge
(if any) to show.

## Gate (why this is not built yet)

Which v1 controls matter, and their parameter ranges, depend on v0's Phase C evidence:
- Implement/enable a control only after v0 backtest shows the failure it fixes (e.g. build the
  spike filter first only if the spike is confirmed as the ruin driver).
- Do not implement v1 before v0 has a passing or clearly-failing Phase C report in
  `reports/`. This packet exists so the design is ready; the code follows the data.

## Key Concepts

- Risk-based sizing + basket SL (bound worst-case loss to a fraction of equity).
- Spike filter: pause new SELL entries when short-horizon velocity is too high.
- Dynamic hedge: BUY STOP lot scales with current SELL exposure, not a fixed 1/N_g.
- Equity management: rule-based withdrawals and a drawdown kill-switch.

## TODO
- [ ] Validate EA Logic against the Risk Governor (risk, DD, margin, black-swan controls)
- [ ] Add Monte Carlo P10 / worst-decile validation for any trading claim
- [ ] Confirm no secrets or destructive commands are included
- [ ] Generate the NotebookLM Summary section
- [ ] Draft SNS / content ideas where applicable
- [ ] Gate: only implement after v0 Phase C report exists in reports/
- [ ] Implement 8.1 (basket SL + sizing) and 8.2 (spike filter) first; 8.3/8.4 second
- [ ] Re-run Phase C with v1 controls; accept only if P(ruin) < 1% and E[log] > 0

## EA Logic
```text
Builds on ea/strategies/boom_drift_grid/BoomDriftGrid_v0.mq5. Additions:

8.1 Basket stop-loss + risk-based sizing:
  - Bound the worst-case basket loss to a fraction alpha of equity.
  - Derive lot L from alpha, N_max, worst-case adverse move (s + delta_max).
  - Close the whole basket if floating loss reaches the basket SL.

8.2 Spike filter (halt new SELLs):
  - Compute short-horizon velocity over tau bars.
  - If velocity >= v_max (spike), do not arm new SELL STOPs.
  - (v0 already ships this input, default OFF; v1 tunes and enables it.)

8.3 Dynamic BUY STOP hedge:
  - Scale the hedge lot with current SELL exposure (not a fixed 1/N_g).
  - L_bs grows as the SELL stack grows, capped by a hedge fraction phi_h.

8.4 Equity management:
  - Withdrawal rule: when equity doubles vs last withdrawal, withdraw f.
  - Drawdown kill-switch: if drawdown B_t >= b_max, halt new entries.

Risk: v1's purpose is survival. Every control is validated in Phase C before enabling.
```

## Mathematical Concepts
```text
8.1 Risk-based sizing (bound worst-case loss to alpha*equity):
  MaxLoss = N_max * L * (s + delta_max) * V * 100 <= alpha * E_t
  => L = (alpha * E_t) / (N_max * (s + delta_max) * V * 100)
  s = basket SL distance (test 100..400 price units); delta_max = worst adverse gap.

8.2 Spike filter:
  G_spike = 1[ |p_t - p_{t-tau}| / tau < v_max ]
  G_spike = 0  =>  suspend new SELL entries.

8.3 Dynamic hedge:
  L_bs = L * min( N_g * phi_h , Phi(m_t) )
  m_t  = current_exposure / max_exposure ;  phi_h in [0.3, 1.0]  (v0 used 1/N_g ~ 0.14)

8.4 Equity management:
  withdraw f when  E_t >= 2 * E_last_wd ;  halt when drawdown B_t >= b_max.

New parameters (spec section 10):
  s (basket SL): test 100..400 ; phi_h (hedge): 0.3..1.0 ; v_max (spike): to fit;
  alpha (risk budget), b_max (max drawdown), f (withdrawal fraction).

Validation: same acceptance as v0 — P(ruin) < 1% and E[log(E_T/E_0)] > 0, Monte Carlo P10
via scripts/monte_carlo_validate.py, plus a lower P95(DD) than v0 to justify the added logic.
```

## SNS Ideas

- "How we made a grid bot survivable" — v0 (no SL) vs v1 (risk-sized SL + spike filter) DD comparison.
- Teaching angle: why fixed-lot grids need a basket SL and a spike filter, not martingale.

## NotebookLM Summary

BOOM Drift Grid v1 is the survival layer over v0: risk-based sizing with a basket stop-loss
(8.1), a spike filter that halts new SELL entries during up-spikes (8.2), a dynamic BUY STOP
hedge that scales with exposure (8.3), and equity management with withdrawals and a drawdown
kill-switch (8.4). The design is fixed but implementation is gated on v0's Phase C evidence:
each control is built and enabled only after the backtest confirms the failure it addresses,
and v1 must pass the same Monte Carlo P10 acceptance as v0 while lowering worst-case drawdown.
