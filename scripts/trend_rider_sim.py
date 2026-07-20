#!/usr/bin/env python3
"""Monte Carlo optimizer for the BoomTrendRider v1.31 mechanism on XAUUSD-like data.

HONEST SCOPE (read before trusting any number):
- No historical data is reachable from this environment, so prices are SYNTHETIC:
  a regime-switching model (trend / range / jump) calibrated to public XAUUSD
  statistics (daily vol ~1%, 5m ATR ~$1.5-3 at $3350, session-free).
- Broker costs come from the uploaded AMOS factory broker profile:
  spread 35 points ($0.35), slippage p50 12 points, applied per market order.
- Synthetic markets answer "how does the MECHANISM behave under assumed trend
  persistence and realistic costs"; they cannot prove a real-market edge.
  The trend-persistence sensitivity run exists precisely because that
  assumption dominates the result.

Strategy implemented = EA v1.31 close-confirmed core:
  seed on close beyond flat extremes +- pitch, pyramid every pitch (close
  basis), chandelier ATR trail (tighten-only), flip on close beyond trail,
  ER regime detector (range => widen pitch, halt stacking), optional VWAP
  confirm gate (from the uploaded VWAP factory: longs only above session
  VWAP, shorts only below), risk-based lot sizing per flip.

Usage:
  python3 scripts/trend_rider_sim.py --round explore   # wide random search
  python3 scripts/trend_rider_sim.py --round refine    # refine around best
  python3 scripts/trend_rider_sim.py --round target50  # risk needed for 50%/mo
"""

import argparse
import json
import math
import os
import numpy as np

BARS_PER_DAY = 288          # 5m bars
DAYS_PER_MONTH = 22
BARS = BARS_PER_DAY * DAYS_PER_MONTH
P0 = 3350.0                 # XAUUSD-ish level
SPREAD = 0.35               # broker_profile: 35 points
SLIP = 0.12                 # broker_profile: p50 slippage
CONTRACT = 100.0            # oz per lot
LEVERAGE = 100.0
START_EQ = 10_000.0

RESULTS = os.path.join(os.path.dirname(__file__), "..", "reports",
                       "trend_rider_opt.json")


def gen_month(rng, persistence=1.0):
    """One month of 5m closes. persistence scales trend-regime drift:
    1.0 = calibrated base case, 0.0 = pure noise (no edge), 1.5 = favorable."""
    # regime chain: 0=range, 1=up-trend, 2=down-trend
    # avg trend leg ~ 4h (48 bars), avg range ~ 8h (96 bars)
    stay_r, stay_t = 1 - 1 / 96, 1 - 1 / 48
    sigma = 0.0006            # per-bar log-vol => ~1% daily
    # Trend drift 0.13*sigma per bar: a 48-bar leg drifts ~0.38% against
    # ~0.42% of accumulated noise - trends are real but ambiguous, matching
    # intraday gold (Hurst only slightly above 0.5). The earlier 0.42*sigma
    # calibration produced cartoonishly clean trends and absurd returns.
    drift = 0.00008 * persistence
    kappa = 0.03              # range regime: OU pull toward the range anchor
    n = BARS
    states = np.empty(n, dtype=np.int8)
    s = 0
    for i in range(n):
        u = rng.random()
        if s == 0:
            if u > stay_r:
                s = 1 if rng.random() < 0.5 else 2
        else:
            if u > stay_t:
                s = 0
        states[i] = s
    # vol clustering: slow lognormal modulation
    vol_mod = np.exp(0.35 * np.cumsum(rng.normal(0, 1, n)) / math.sqrt(n))
    vol_mod /= vol_mod.mean()
    eps = rng.normal(0, 1, n) * sigma * vol_mod
    # jumps: ~2 per week, 4-10 sigma, random sign (news shocks)
    jump = np.zeros(n)
    njump = rng.poisson(2 * DAYS_PER_MONTH / 5)
    if njump:
        idx = rng.integers(0, n, njump)
        jump[idx] = rng.choice([-1, 1], njump) * sigma * rng.uniform(4, 10, njump)
    logp = np.empty(n)
    lp = math.log(P0)
    anchor = lp
    for i in range(n):
        s = states[i]
        if s == 0:
            r = -kappa * (lp - anchor) + eps[i] + jump[i]
        else:
            anchor = lp   # anchor rides along so the next range forms locally
            r = (drift if s == 1 else -drift) + eps[i] + jump[i]
        lp += r
        logp[i] = lp
    close = np.exp(logp)
    # crude intrabar range for ATR: |ret| + noise floor
    tr = np.abs(np.diff(close, prepend=close[0])) + close * sigma * 0.8
    return close, tr, states


def atr_series(tr, period=14):
    a = np.empty_like(tr)
    a[0] = tr[:period].mean()
    k = 1.0 / period
    for i in range(1, len(tr)):
        a[i] = a[i - 1] + k * (tr[i] - a[i - 1])
    return a


def er_series(close, period=20):
    n = len(close)
    er = np.ones(n)
    d = np.abs(np.diff(close, prepend=close[0]))
    csum = np.cumsum(d)
    for i in range(period, n):
        den = csum[i] - csum[i - period]
        num = abs(close[i] - close[i - period])
        er[i] = num / den if den > 0 else 1.0
    return er


def session_vwap(close, tr):
    """Day-anchored VWAP with synthetic volume ~ true range (proxy)."""
    vwap = np.empty_like(close)
    for d in range(DAYS_PER_MONTH):
        a, b = d * BARS_PER_DAY, (d + 1) * BARS_PER_DAY
        v = tr[a:b] + 1e-9
        vwap[a:b] = np.cumsum(close[a:b] * v) / np.cumsum(v)
    return vwap


def run_month(close, atr, er, vwap, p):
    """Simulate one month; returns (final_equity, max_dd, trades)."""
    eq = START_EQ
    peak = eq
    max_dd = 0.0
    trades = 0
    dirn = 0                 # 0 flat, +1 long, -1 short
    entries = []             # entry prices (per unit lot each)
    lot = 0.0
    last_add = 0.0
    leg_ext = 0.0
    trail = 0.0
    flat_hi = flat_lo = 0.0
    rng_mode = False

    def pitch(i):
        d = max(p["c_atr"] * atr[i], 4.0 * SPREAD)
        return d * (p["w_range"] if rng_mode else 1.0)

    def tdist(i):
        return max(p["k_trail"] * atr[i], 4.0 * SPREAD)

    def mtm(px):
        return sum((px - e) if dirn > 0 else (e - px) for e in entries) * lot * CONTRACT

    cost_open = (SPREAD + SLIP) * CONTRACT   # per lot, per market entry

    for i in range(30, len(close)):
        c = close[i]
        # regime hysteresis
        if er[i] < p["er_lo"]:
            rng_mode = True
        elif er[i] >= p["er_hi"]:
            rng_mode = False

        cur = eq + (mtm(c) if dirn != 0 else 0.0)
        peak = max(peak, cur)
        max_dd = max(max_dd, (peak - cur) / peak)
        if cur <= START_EQ * 0.1:      # ruin floor: stop simulating
            return cur, max_dd, trades

        if dirn == 0:
            d = pitch(i)
            go = 0
            if flat_lo > 0 and c >= flat_lo + d:
                go = 1
            elif flat_hi > 0 and c <= flat_hi - d:
                go = -1
            if go and p["use_vwap"]:
                if go > 0 and c < vwap[i]:
                    go = 0
                if go < 0 and c > vwap[i]:
                    go = 0
            if go:
                dirn = go
                td = tdist(i)
                lot = max(0.01, round(eq * p["risk"] / ((td + SPREAD) * CONTRACT), 2))
                # margin cap
                lot = min(lot, math.floor(eq * LEVERAGE / (c * CONTRACT) * 0.3 * 100) / 100)
                if lot < 0.01:
                    return cur, max_dd, trades
                entries = [c]
                eq -= cost_open * lot
                trades += 1
                last_add = c
                leg_ext = c
                trail = 0.0
                flat_hi = flat_lo = 0.0
            else:
                flat_hi = c if flat_hi <= 0 else max(flat_hi, c)
                flat_lo = c if flat_lo <= 0 else min(flat_lo, c)
            continue

        # in a ride ------------------------------------------------------
        if (dirn > 0 and c > leg_ext) or (dirn < 0 and c < leg_ext):
            leg_ext = c
        d = pitch(i)
        # stack
        if not (rng_mode and p["halt_in_range"]) and len(entries) < p["n_max"]:
            if (dirn > 0 and c >= last_add + d) or (dirn < 0 and c <= last_add - d):
                ok_vwap = (not p["use_vwap"]) or (dirn > 0 and c >= vwap[i]) or (dirn < 0 and c <= vwap[i])
                if ok_vwap:
                    entries.append(c)
                    eq -= cost_open * lot
                    trades += 1
                    last_add = c
        # trail (tighten-only)
        td = tdist(i)
        t_new = leg_ext - td if dirn > 0 else leg_ext + td
        trail = t_new if trail == 0.0 else (max(trail, t_new) if dirn > 0 else min(trail, t_new))
        # flip on close beyond trail
        if (dirn > 0 and c <= trail) or (dirn < 0 and c >= trail):
            eq += mtm(c) - SPREAD * CONTRACT * lot * len(entries)  # close costs
            # flip seed becomes the new ride
            dirn = -dirn
            td = tdist(i)
            lot = max(0.01, round(eq * p["risk"] / ((td + SPREAD) * CONTRACT), 2))
            lot = min(lot, math.floor(max(eq, 1) * LEVERAGE / (c * CONTRACT) * 0.3 * 100) / 100)
            if lot < 0.01 or eq <= START_EQ * 0.1:
                return eq, max_dd, trades
            entries = [c]
            eq -= cost_open * lot
            trades += 1
            last_add = c
            leg_ext = c
            trail = 0.0

    if dirn != 0:
        eq += mtm(close[-1]) - SPREAD * CONTRACT * lot * len(entries)
    return eq, max_dd, trades


def evaluate(p, months=16, persistence=1.0, seed0=0):
    rets, dds, trs = [], [], []
    for m in range(months):
        rng = np.random.default_rng(10_000 * seed0 + m)
        close, tr, _ = gen_month(rng, persistence)
        atr = atr_series(tr)
        er = er_series(close, p["er_n"])
        vwap = session_vwap(close, tr) if p["use_vwap"] else close
        eq, dd, t = run_month(close, atr, er, vwap, p)
        rets.append(eq / START_EQ - 1.0)
        dds.append(dd)
        trs.append(t)
    rets = np.array(rets)
    dds = np.array(dds)
    return {
        "median_monthly": float(np.median(rets)),
        "p5_monthly": float(np.percentile(rets, 5)),
        "mean_monthly": float(rets.mean()),
        "p95_dd": float(np.percentile(dds, 95)),
        "p_ruin": float((rets <= -0.9).mean()),
        "p_dd30": float((dds >= 0.30).mean()),
        "trades_mo": float(np.mean(trs)),
    }


def sample_params(rng):
    return {
        "c_atr": float(rng.uniform(1.5, 8.0)),
        "k_trail": float(rng.uniform(1.5, 6.0)),
        "er_n": int(rng.integers(12, 40)),
        "er_lo": float(rng.uniform(0.15, 0.35)),
        "er_hi": float(rng.uniform(0.40, 0.60)),
        "w_range": float(rng.uniform(1.5, 3.0)),
        "halt_in_range": bool(rng.random() < 0.7),
        "n_max": int(rng.integers(3, 11)),
        "risk": float(rng.uniform(0.002, 0.02)),
        "use_vwap": bool(rng.random() < 0.5),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--round", default="explore",
                    choices=["explore", "refine", "target50", "sensitivity"])
    ap.add_argument("--n", type=int, default=120)
    ap.add_argument("--months", type=int, default=16)
    args = ap.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(RESULTS)), exist_ok=True)
    state = {}
    if os.path.exists(RESULTS):
        with open(RESULTS) as f:
            state = json.load(f)

    rng = np.random.default_rng(42 if args.round == "explore" else 43)

    if args.round in ("explore", "refine"):
        best = state.get("best")
        rows = []
        for k in range(args.n):
            if args.round == "refine" and best:
                p = dict(best["params"])
                for key in ("c_atr", "k_trail", "er_lo", "er_hi", "w_range", "risk"):
                    p[key] = float(p[key] * rng.uniform(0.8, 1.25))
                p["er_hi"] = max(p["er_hi"], p["er_lo"] + 0.05)
                p["n_max"] = int(np.clip(best["params"]["n_max"] + rng.integers(-2, 3), 2, 12))
                p["use_vwap"] = bool(rng.random() < 0.5)
                p["er_n"] = int(np.clip(best["params"]["er_n"] + rng.integers(-6, 7), 8, 48))
                p["halt_in_range"] = bool(rng.random() < 0.7)
            else:
                p = sample_params(rng)
            m = evaluate(p, months=args.months, seed0=k + (500 if args.round == "refine" else 0))
            # objective.yaml constraints: max_total_dd 10% (p95), survival >= 95%
            feasible = m["p95_dd"] <= 0.20 and m["p_ruin"] == 0.0
            score = m["median_monthly"] if feasible else m["median_monthly"] - 1.0
            rows.append({"params": p, "metrics": m, "feasible": feasible, "score": score})
            print(f"[{k:3d}] med={m['median_monthly']*100:6.2f}%/mo p5={m['p5_monthly']*100:6.2f}% "
                  f"p95DD={m['p95_dd']*100:5.1f}% ruin={m['p_ruin']*100:4.1f}% "
                  f"tr={m['trades_mo']:5.0f} vwap={int(p['use_vwap'])} feas={int(feasible)}")
        rows.sort(key=lambda r: r["score"], reverse=True)
        state["best"] = rows[0]
        state.setdefault("rounds", []).append(
            {"round": args.round, "n": args.n, "top5": rows[:5]})
        with open(RESULTS, "w") as f:
            json.dump(state, f, indent=1)
        print("\nBEST:", json.dumps(rows[0], indent=1))

    elif args.round == "target50":
        best = state["best"]
        print("scaling risk on best params until median monthly >= 50%:")
        out = []
        for riskx in (1, 2, 4, 8, 16, 32, 64):
            p = dict(best["params"])
            p["risk"] = min(best["params"]["risk"] * riskx, 0.5)
            m = evaluate(p, months=32, seed0=900 + riskx)
            out.append({"risk": p["risk"], "metrics": m})
            print(f"risk={p['risk']*100:5.1f}%/flip med={m['median_monthly']*100:7.2f}%/mo "
                  f"p5={m['p5_monthly']*100:7.2f}% p95DD={m['p95_dd']*100:5.1f}% "
                  f"P(DD>30%)={m['p_dd30']*100:5.1f}% P(ruin)={m['p_ruin']*100:5.1f}%")
        state["target50"] = out
        with open(RESULTS, "w") as f:
            json.dump(state, f, indent=1)

    elif args.round == "sensitivity":
        best = state["best"]
        print("trend-persistence sensitivity of the best config:")
        out = []
        for pers in (0.0, 0.5, 1.0, 1.5):
            m = evaluate(best["params"], months=32, persistence=pers, seed0=700)
            out.append({"persistence": pers, "metrics": m})
            print(f"persistence={pers:3.1f} med={m['median_monthly']*100:7.2f}%/mo "
                  f"p5={m['p5_monthly']*100:7.2f}% p95DD={m['p95_dd']*100:5.1f}%")
        state["sensitivity"] = out
        with open(RESULTS, "w") as f:
            json.dump(state, f, indent=1)


if __name__ == "__main__":
    main()
