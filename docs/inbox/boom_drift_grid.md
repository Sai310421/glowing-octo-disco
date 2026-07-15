# AMOS Knowledge Packet — BOOM Drift Grid v0

Source: reverse-engineered from a 61s TikTok clip (BOOM_100, MT5 mobile, M1) by MSS Group.
Origin spec: `_boom_drift_grid_spec_v0.pdf` (v0, 2026-07-15).
Status: Packet for Phase C implementation + validation. Not deployable (Rule 3/7).

## Summary

A reactive, non-predictive stop-order grid for the Deriv synthetic index BOOM_100 on M1.
The system does not forecast direction; it straddles price with pending stop orders and lets the
market pick the side. Because BOOM_100 drifts down slowly and spikes up rarely, v0 is
drift-biased: a **SELL grid** harvests the downward drift, while a **BUY STOP** stands ready as a
reverse/spike hedge. Grid pitch is tightened in low volatility and widened in high volatility.

Honest framing (carry into validation): on a broker synthetic, downward drift and up-spike
expectation are near-offsetting by design, so any real edge lives in the **exit logic** and
**spike avoidance**, not in the grid itself. Validation priority is exit rule x spike filter,
not grid spacing alone.

## Key Concepts

- Non-predictive, reactive entry via stop orders (market decides direction).
- Drift-biased SELL grid (harvest mu_B < 0) + single BUY STOP reverse hedge.
- Fixed lot per level (rho = 1, NO martingale in v0).
- Basket PnL managed as a group; three candidate exit rules (per-position TP / basket TP / trailing).
- Primary risk = up-spike (Poisson) hitting the full SELL stack; v0 has no SL (added in v1).
- Volatility-adaptive pitch (narrow in low vol, wide in high vol).

## TODO
- [ ] Validate EA Logic against the Risk Governor (risk, DD, margin, black-swan controls)
- [ ] Add Monte Carlo P10 / worst-decile validation for any trading claim
- [ ] Confirm no secrets or destructive commands are included
- [ ] Generate the NotebookLM Summary section
- [ ] Draft SNS / content ideas where applicable
- [ ] Open a Codex implementation task once merged
- [ ] Phase C: backtest v0 on Deriv BOOM_100 tick/M1 with realistic spread
- [ ] Compare exit rules A/B/C x pitch Delta in {30, 50, 100} x spike-filter {on, off}
- [ ] Report P(ruin) < 1%, E[log(E_T/E_0)] > 0, and P95(DD) before considering v1

## EA Logic
```text
Symbol/Timeframe: BOOM_100 (Deriv synthetic), M1.

Signal:
  None predictive. Orders are pending stops straddling current price p_t.
  Down-drift bias => SELL side is the primary harvester.

Entry (SELL grid, section 3):
  Seed a SELL STOP at p_t. After a fill at level k (price p_e,k),
  arm the next SELL STOP one pitch below:
    SellEntry_{k+1}  iff  p_t <= p_e,k - Delta
    lot L_{k+1} = L        (fixed lot, no martingale)
  Cap concurrent positions at N_max.

Reverse hedge (BUY STOP, section 4):
  BuyStop price = p_t + d_bs,  lot L_bs = L
  Purpose: catch a reversal / up-spike opposite the SELL stack.
  v0 hedge ratio = 1/N_g (~14% at N_g=7) -> structurally thin; see Risk.
  Candidate improvement to test: make the BUY STOP spike-TRIGGERED rather than
  always-on, to cut chop bleed before v1.

Exit (section 5 — choose per Phase C run):
  A) Per-position TP:  TP_i = p_e,i - c_tp * Delta,  c_tp in [1,3]
  B) Basket TP:        close all when PnL_k(p) >= Pi_tgt
  C) Trailing basket:  close when PnL_k_max - PnL_k(p) >= c_tr * PnL_k_max

Risk (v0 = no SL; this is the make-or-break section):
  - Up-spike hits all N_g SELLs while only 1 BUY STOP offsets.
  - Exposure cap N_max = 10 (test 5..15).
  - v1 adds: basket SL (position sizing by risk alpha), spike filter, dynamic hedge.
```

## Mathematical Concepts
```text
Price model (BOOM_100, section 2):
  dp_t = mu_B dt + sigma dW_t + J dN_t
    mu_B < 0            : slow downward drift (favors SELL)
    J > 0, dN_t ~ Poisson(lambda_s) : rare up-spikes (~1 per 100 ticks on BOOM_100)

Basket PnL for k SELLs (section 3.2):
  p_bar_k = (1/k) * sum_{i=1..k} p_e,i = p_e,1 - (k-1)*Delta/2
  PnL_k(p) = k * L * (p_bar_k - p) * V * 100
  (per-level ladder profits step by ~Delta*V, matching the observed video ladder)

Expected drift harvest per unit time (section 7.1):
  E[profit]/t ~ N_g * L * |mu_B| * V * 100

Spike loss, the killer (section 7.2):
  Loss_spike = (N_g - 1) * L * (J + delta) * V * 100
  Example N_g=7, J=300pt, delta=50pt -> ~ $21 gross, ~ $11 net after BUY-STOP offset.
  Edge exists only if  E[profit]/t  >  Loss_spike * lambda_s  after costs.

v1 survival (section 8):
  Basket SL / sizing:  MaxLoss = N_max*L*(s+delta_max)*V*100 <= alpha*E_t
  Spike filter:        G_spike = 1[ |p_t - p_{t-tau}|/tau < v_max ]; if 0 => halt new SELLs
  Dynamic hedge:       L_bs = L * min(N_g*phi_h, Phi(m_t)),  phi_h in [0.3,1.0]

Variables (section 1):
  p_t price; Delta grid pitch (~50pt, test 30..100); L lot (0.01);
  V ~ $0.01/pt per 0.01 lot (50pt ~ $0.50); N_g grid count (~7); N_max cap (10);
  d_bs BUY STOP distance (30..150pt); mu_B drift (<0); lambda_s spike rate; J spike size.

Validation (section 9, acceptance):
  P(ruin) < 1%  AND  E[log(E_T/E_0)] > 0  ; report WR, PF, P95(DD);
  robustness via Monte Carlo (estimate q_hat, kappa_hat). Must pass
  scripts/monte_carlo_validate.py (P10 / worst-decile required, Rule 4).
```

## SNS Ideas

- "Reverse-engineering a TikTok BOOM_100 bot into a validated spec" — process thread.
- Honest-take angle: why high-win-rate grid clips hide the spike tail (P10 matters).
- Before/after: raw clip vs Monte Carlo P10 survival chart.

## NotebookLM Summary

BOOM Drift Grid v0 formalizes a reactive stop-order grid for BOOM_100 (M1): a drift-biased SELL
grid harvests the synthetic's downward drift while a thin BUY STOP hedges the rare up-spike, with
fixed lots and no martingale. v0 has no stop-loss; the dominant risk is a Poisson up-spike hitting
the full SELL stack. The genuine edge, if any, is in exit timing and spike avoidance rather than
the grid, so Phase C tests exit rules against pitch and a spike filter, and accepts only if
P(ruin) < 1% and E[log] > 0 under Monte Carlo P10. v1 adds basket SL, a spike filter, and a
dynamic hedge for survival.
