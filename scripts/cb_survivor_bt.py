#!/usr/bin/env python3
"""CB Survivor grid economics on real XAUUSD 1m data.

Question answered (README of the EA repro): does churned volume x CB_Per_Lot
beat the grid's net trading bleed - and what tail does the nanpin structure
carry while doing it?

Simulates the manual's recommended XAUUSD set on the user-supplied ork.ad 1m
series (176,888 bars, 2026-01-04..07-03, vendor glitches repaired):
  BaseLot 0.01, NanpinPips 25 (pip=$0.10 => $2.50 spacing), MaxPositions 25,
  basket TP $1.0 combined excluding stuck (> $3.3 loss), TailCut from pool,
  ReverseGrid (trigger 10, spacing x1.5, TP $1/0.01), SlotFree (TriggerA 50
  pips, gap 100, TriggerB rotation 70%/1h), lot ladder x2.0 from level 20,
  BulkClear +$10 with re-anchor. Decisions on 1m closes (conservative);
  costs charged per side: half-spread + slippage.

Outputs: monthly net trading PnL (CB excluded), closed volume and CB income
at the given $/lot, break-even CB rate, max floating drawdown, max total
lots, margin peak. Spread sensitivity sweep included.
"""

import json
import os
import numpy as np
import pandas as pd

CONTRACT = 100.0
PIP = 0.10
START_EQ = 10_000.0
LEVERAGE = 100.0

P = {
    "base_lot": 0.01, "nanpin_pips": 25.0, "max_pos": 25,
    "normal_profit": 1.0, "stuck": 3.3,
    "lot_from": 20, "lot_mult": 2.0,
    "bulk_clear": 10.0,
    "o2_extra": 50.0, "o2_gap": 100.0, "rot_win_bars": 60, "rot_thr": 0.70,
    "rev_trigger": 10, "rev_mult": 1.5, "rev_tp": 1.0,
}


def load_1m(path):
    df = pd.read_csv(path, skiprows=1)
    df["time"] = pd.to_datetime(df["time"]).dt.tz_localize(None)
    ohlc = df[["open", "high", "low", "close"]]
    df["high"] = ohlc.max(axis=1)
    df["low"] = ohlc.min(axis=1)
    return df.reset_index(drop=True)


def simulate(df, spread=0.28, slip=0.04, p=P):
    c = df["close"].values
    ts = df["time"].values
    n = len(c)
    half = (spread / 2 + slip) * CONTRACT   # $ per lot per side

    eq = START_EQ
    base_eq = eq
    pool = 0.0
    buys, sells, rev = [], [], []           # [lot, entry]
    closed_lots = 0.0
    close_bars = []                         # bar indices of realized closes
    last_slotfree = -10
    max_float_dd = 0.0
    max_lots = 0.0
    peak_eqty = eq
    max_dd = 0.0
    n_trades = 0
    monthly = {}

    def flt(side, px):
        s = 0.0
        for lot, e in side[0]:
            s += side[1] * (px - e) * lot * CONTRACT
        return s

    def close_list(lst, sign, px, idx_keep=None):
        nonlocal eq, pool, closed_lots, n_trades
        keep = []
        for k, (lot, e) in enumerate(lst):
            if idx_keep is not None and k in idx_keep:
                keep.append((lot, e))
                continue
            pnl = sign * (px - e) * lot * CONTRACT - half * lot
            eq += pnl
            pool += pnl
            closed_lots += lot
            n_trades += 1
            close_bars.append(i)
        return keep

    for i in range(n):
        px = c[i]
        fb = flt((buys, +1), px)
        fs = flt((sells, -1), px)
        fr = sum(d * (px - e) * lot * CONTRACT for lot, e, d in rev)
        eqty = eq + fb + fs + fr
        peak_eqty = max(peak_eqty, eqty)
        max_dd = max(max_dd, (peak_eqty - eqty) / peak_eqty)
        max_float_dd = max(max_float_dd, -(fb + fs + fr))
        tot_lots = sum(l for l, _ in buys) + sum(l for l, _ in sells) + sum(l for l, _, _ in rev)
        max_lots = max(max_lots, tot_lots)
        mkey = str(ts[i])[:7]

        if eqty <= 0:   # margin call - the honest end state
            monthly.setdefault(mkey, 0.0)
            return dict(blown=True, month=mkey, eq=eqty, monthly=monthly,
                        closed_lots=closed_lots, max_float_dd=max_float_dd,
                        max_lots=max_lots, max_dd=max_dd, trades=n_trades)

        if pool < 0:
            pool = 0.0   # 5s reset ~ next bar

        # ---- basket TP (combined, stuck excluded)
        pnls_b = [(+1 * (px - e) * lot * CONTRACT - half * lot, k) for k, (lot, e) in enumerate(buys)]
        pnls_s = [(-1 * (px - e) * lot * CONTRACT - half * lot, k) for k, (lot, e) in enumerate(sells)]
        nb_stuck = {k for v, k in pnls_b if -v > p["stuck"]}
        ns_stuck = {k for v, k in pnls_s if -v > p["stuck"]}
        bpnl = sum(v for v, k in pnls_b if k not in nb_stuck) + \
               sum(v for v, k in pnls_s if k not in ns_stuck)
        if bpnl >= p["normal_profit"] and (len(pnls_b) + len(pnls_s) > len(nb_stuck) + len(ns_stuck)):
            buys = close_list(buys, +1, px, idx_keep=nb_stuck)
            sells = close_list(sells, -1, px, idx_keep=ns_stuck)

        # ---- TailCut
        worst = None
        for lst, sign in ((buys, +1), (sells, -1)):
            for k, (lot, e) in enumerate(lst):
                v = sign * (px - e) * lot * CONTRACT - half * lot
                if -v > p["stuck"] and (worst is None or v < worst[0]):
                    worst = (v, lst, sign, k)
        if worst and pool >= -worst[0]:
            v, lst, sign, k = worst
            lot, e = lst.pop(k)
            pnl = sign * (px - e) * lot * CONTRACT - half * lot
            eq += pnl; pool += pnl; closed_lots += lot; n_trades += 1
            close_bars.append(i)

        # ---- reverse grid
        main_total = len(buys) + len(sells)
        rdir = -1 if len(buys) >= len(sells) else +1
        if main_total > p["rev_trigger"] and len(rev) < p["max_pos"]:
            same = [e for lot, e, d in rev if d == rdir]
            gap = p["nanpin_pips"] * p["rev_mult"] * PIP
            if not same or (rdir == +1 and min(same) - px >= gap) or (rdir == -1 and px - max(same) >= gap):
                rev.append((p["base_lot"], px + rdir * (spread / 2 + slip), rdir))
        keep = []
        for lot, e, d in rev:
            v = d * (px - e) * lot * CONTRACT - half * lot
            if v >= p["rev_tp"] * (lot / p["base_lot"]):
                eq += v; pool += v; closed_lots += lot; n_trades += 1
                close_bars.append(i)
            else:
                keep.append((lot, e, d))
        rev = keep
        if main_total <= p["rev_trigger"] and rev:
            tot = sum(d * (px - e) * lot * CONTRACT - half * lot for lot, e, d in rev)
            if tot >= 0:
                for lot, e, d in rev:
                    v = d * (px - e) * lot * CONTRACT - half * lot
                    eq += v; pool += v; closed_lots += lot; n_trades += 1
                    close_bars.append(i)
                rev = []

        # ---- slot-free
        if i - last_slotfree >= 1:
            for lst, sign in ((buys, +1), (sells, -1)):
                if len(lst) < p["max_pos"]:
                    continue
                e1 = lst[-1][1]
                trigA = abs(px - e1) >= p["o2_extra"] * PIP
                cur = sum(1 for b in close_bars if i - p["rot_win_bars"] <= b < i)
                prev = sum(1 for b in close_bars if i - 2 * p["rot_win_bars"] <= b < i - p["rot_win_bars"])
                trigB = prev > 0 and cur < prev * p["rot_thr"]
                if trigA or trigB:
                    nclose = 1
                    if len(lst) >= 2 and abs(lst[-1][1] - lst[-2][1]) >= p["o2_gap"] * PIP:
                        nclose = 2
                    for _ in range(nclose):
                        lot, e = lst.pop()
                        pnl = sign * (px - e) * lot * CONTRACT - half * lot
                        eq += pnl; pool += pnl; closed_lots += lot; n_trades += 1
                        close_bars.append(i)
                    last_slotfree = i
                    break

        # ---- bulk clear
        eqty = eq + flt((buys, +1), px) + flt((sells, -1), px) + \
               sum(d * (px - e) * lot * CONTRACT for lot, e, d in rev)
        if eqty >= base_eq + p["bulk_clear"]:
            buys = close_list(buys, +1, px)
            sells = close_list(sells, -1, px)
            for lot, e, d in rev:
                v = d * (px - e) * lot * CONTRACT - half * lot
                eq += v; pool += v; closed_lots += lot; n_trades += 1
                close_bars.append(i)
            rev = []
            base_eq = eq

        # ---- seeding + nanpin
        def level_lot(lvl):
            return p["base_lot"] * (p["lot_mult"] if lvl >= p["lot_from"] else 1.0)
        if not buys:
            buys.append((level_lot(1), px + spread / 2 + slip))
        elif len(buys) < p["max_pos"] and buys[-1][1] - px >= p["nanpin_pips"] * PIP:
            buys.append((level_lot(len(buys) + 1), px + spread / 2 + slip))
        if not sells:
            sells.append((level_lot(1), px - spread / 2 - slip))
        elif len(sells) < p["max_pos"] and px - sells[-1][1] >= p["nanpin_pips"] * PIP:
            sells.append((level_lot(len(sells) + 1), px - spread / 2 - slip))

        monthly.setdefault(mkey, 0.0)
        if len(close_bars) > 20000:
            close_bars = close_bars[-2000:]
        monthly[mkey] = eq  # end-of-month running realized equity

    # liquidate remaining at the end for accounting
    px = c[-1]
    close_list(buys, +1, px)
    close_list(sells, -1, px)
    for lot, e, d in rev:
        eq += d * (px - e) * lot * CONTRACT - half * lot
        closed_lots += lot
    return dict(blown=False, eq=eq, monthly=monthly, closed_lots=closed_lots,
                max_float_dd=max_float_dd, max_lots=max_lots, max_dd=max_dd,
                trades=n_trades)


def main():
    path = os.environ.get("CB_DATA",
        "/tmp/claude-0/-home-user-glowing-octo-disco/74058501-f7f7-5fe1-b123-2e20f42fe8bd/scratchpad/uploads/wfo_data/XAUUSD_1m_20260104_20260703_orkad.csv")
    df = load_1m(path)
    months = (df["time"].iloc[-1] - df["time"].iloc[0]).days / 30.4
    print(f"bars={len(df)} months={months:.2f}")
    out = {}
    for spread in (0.20, 0.28, 0.35):
        r = simulate(df, spread=spread)
        net = r["eq"] - START_EQ
        cb15 = r["closed_lots"] * 15.0
        be = -net / r["closed_lots"] if r["closed_lots"] > 0 else float("nan")
        print(f"spread=${spread:.2f}: blown={r['blown']} netPnL(no CB)={net:+9.2f} USD "
              f"({net/months:+7.2f}/mo)  vol={r['closed_lots']:7.2f} lot "
              f"({r['closed_lots']/months:5.2f}/mo)  CB@15={cb15:+8.2f} ({cb15/months:+6.2f}/mo)  "
              f"net+CB={(net+cb15)/months:+7.2f}/mo  BE_CB=${be:5.2f}/lot  "
              f"maxFloatDD={r['max_float_dd']:8.2f}  maxDD={r['max_dd']*100:5.1f}%  maxLots={r['max_lots']:.2f}  trades={r['trades']}")

        out[str(spread)] = {k: (v if not isinstance(v, dict) else v) for k, v in r.items() if k != "monthly"}
        out[str(spread)]["net_no_cb"] = net
        out[str(spread)]["cb15_income"] = cb15
        out[str(spread)]["breakeven_cb_per_lot"] = be
    with open(os.path.join(os.path.dirname(__file__), "..", "reports", "cb_survivor_bt.json"), "w") as f:
        json.dump(out, f, indent=1, default=float)


if __name__ == "__main__":
    main()
