# AMOS Knowledge Packet — Mathematical framework (measured on real XAUUSD 1m, 2026-01..07)

All quantities measured from the user-supplied series (`scripts/` harnesses);
formulas first, numbers second. This packet is the deductive counterpart of the
session's inductive experiments — same conclusions, now with the mechanism.

## 1. Market structure: variance ratios

VR(q) = Var(r_q) / (q·Var(r_1)); VR>1 momentum, VR<1 mean reversion.

| horizon | VR | reading |
|---|---|---|
| 5m | 1.027 | ~random, faint momentum |
| 15m | 0.936 | mild reversion |
| 1h | 0.967 | ~random |
| **4h** | **0.828** | **strongest structure: mean reversion** |
| 1d | 1.027 | ~random + macro drift |

lag-1 autocorr: 5m −0.042, 1h −0.038. σ(1m) = 5.8 bp (≈42% annualized).

Implication: intraday XAUUSD is a weakly mean-reverting oscillation riding a
macro drift. Counter-trend systems die from the drift (proven empirically);
trend systems at M5 face VR≈1 (≈zero local edge); the only statistically
notable exploitable structure in-sample is **4h-scale reversion** — but only
if the macro drift is hedged out (trade the residual, not the price).

## 2. SAR (Trend Rider) expectancy

Per flip cycle with stack k, pitch Δ, trail d, leg length L:
  gain(L) ≈ Σ_{i=0}^{k-1} max(L − d − iΔ, −(d+iΔ))·lot·V  − (k+1)·cost
Profitable iff the leg-length distribution has enough mass at L ≫ d+kΔ —
a fat-tail harvest: lose ~d often, win multiples rarely.

Measured (M5, defaults, 1,908 cycles, per 0.01 lot): win rate 27.1%,
avgWin $30.9, avgLoss $11.6 → payoff b = 2.66; expectancy
p·b − q = 0.271·2.66 − 0.729 ≈ −0.01 ≈ 0. Mean cycle −$0.077, σ_cycle $38.5.
This is the textbook trend-following profile sitting exactly at cost-adjusted
break-even — consistent with VR(5m)≈1.

## 3. Statistical significance — what is actually known

t-stat of the trading edge: (−0.077)/(38.5/√1908) ≈ −0.09 → the market edge
is **indistinguishable from zero** (95% CI per cycle ≈ ±$0.88). The ONLY
statistically certain profit component is the deterministic cashback:
+$0.209/cycle at $15/lot. Everything hinges on not letting variance eat it.

## 4. Growth ceiling (Kelly)

Per-cycle μ = −0.077 + 0.209 = +$0.132, σ = $38.5.
- Kelly fraction: f* = μ/σ² ≈ 1.0e-4 per dollar — the edge justifies only
  microscopic risk.
- Max expected log-growth at full Kelly: g* = μ²/(2σ²) ≈ 5.9e-6 per cycle
  × ~324 cycles/mo ≈ **0.19%/month** (half-Kelly ≈ 0.1%/mo for sane DD).
- Capital for P(DD>50%) < 1% at 0.01-lot cycle risk: E ≳ σ²·ln(100)/(2μ)
  ≈ **$25.8k per 0.01-lot unit** (diffusion approximation).

This is the mathematically honest ceiling of the current system: **~0.2%/mo.**
The earlier 50%/mo target is off by a factor of ~250 — not a tuning gap, an
information gap. Monthly return scales as μ²/σ², so it rises with the SQUARE
of edge improvements but only linearly with risk: more risk without more edge
only raises DD.

## 5. Cashback economics (exact)

Net/month = V·(cb − c_eff), c_eff = trading loss per churned lot.
Measured: SAR c_eff = $5.36/lot (26.6 lot/6mo); one-sided grid c_eff =
$9.46/lot (240.9 lot/6mo). Both < cb=$15 → both net positive; the grid churns
9× the volume (higher CB income) but at 83.6% maxDD — variance, not edge.
Requirement for any CB engine: **c_eff < cb with bounded σ_cycle.**

## 6. What the math says to build next (in order of expected μ gain)

1. **Raise μ per cycle via regime filtering**: only run SAR when a
   momentum-regime statistic (rolling VR>1 / ER>er_hi on the entry TF) holds;
   sit flat otherwise. Every avoided chop cycle adds ~$d+spread to μ.
2. **Harvest the VR(4h)=0.83 reversion on the drift residual**: fade
   deviations of price from a slow anchor (e.g., 1d EMA), delta-hedging the
   anchor direction — the only in-sample structure with real statistical
   teeth. Needs its own Phase C.
3. **Raise cycle count N across instruments**: t-stat and Kelly certainty
   scale with √N; three uncorrelated symbols ≈ 1.7× faster edge confirmation.
4. **AI direction model (AHAE doc)**: any p→p+ε on flip direction moves μ
   quadratically into g*. WFE ≥ 0.5 gate before trusting it.

Anti-goals the math forbids: raising lots without raising μ (g unchanged,
DD up); adding recovery layers below negative-μ entries (proven: containment
only); optimizing exits when μ≈0 comes from entries.
