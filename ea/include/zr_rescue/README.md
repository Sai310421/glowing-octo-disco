# AMOS ZR RescueModule (user-supplied, archived)

Zone Recovery rescue module v1.01 / v1.02 (AdaptiveOptimal) supplied by the
repo owner, plus BT presets and the result analyzer. v1.02 adds the adaptive
A/B scheme (standard Fixed+FirstAnchor vs defensive Rolling+Expanding,
switched by an internal danger score: CHAOS state, DD, spread, turn count,
policy) and a PCI-style completion that credits estimated cashback into the
basket exit decision.

Integration contract: the parent EA must own `InpMagicNumber`, `m_trade`,
`m_position`, `m_pip_size` (see the header of the .mqh).

## Empirical verdict on the CB Survivor grid (2026-01..07 real XAUUSD 1m)

`scripts/cb_survivor_bt.py::simulate_zr` reproduces the module's core
(zone = ATR_H1×0.25, alternating legs ×1.35, max 4 turns, CB-credited
completion, ADX trend guard, basket time stop, hard-DD stop) as the rescue
engine for the CB Survivor grid, and a further variant gates all new grid
risk by an H1 ADX<25 macro filter:

| architecture | net (no CB) | outcome |
|---|---|---|
| v2 freeze + pool amortization | −$1,698/mo | $10k account blown |
| v3 ZR rescue (M15 ADX gate) | −$1,698/mo | blown; 6-8k rescues, only 13-38 complete, rest time out |
| v4 ZR rescue + H1 ADX<25 macro gate | −$1,698/mo | blown |

The rescue mechanics themselves work (floating DD stays bounded at
~$0.4-1.3k vs $10.8k unhedged), but on a trending half-year the grid
*manufactures stuck positions faster than any rescue can digest them* —
the loss is created at entry time (seeding against the trend), and no
downstream rescue engineering recovers a negative-EV entry conveyor.
The module is sound as a **bounded-risk containment layer**; it is not a
profitability layer. Pair it with an entry engine that is EV-positive
before rescue (see `docs/inbox/` verdict packets).
