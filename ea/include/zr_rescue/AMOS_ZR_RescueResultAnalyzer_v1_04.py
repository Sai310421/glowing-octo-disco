#!/usr/bin/env python3
"""
AMOS ZR RescueResult Analyzer v1.04

Reads AMOS_ZR_WR4_RescueLog.csv exported by AMOS_ZR_RescueModule_v1_04.mqh
and answers:
- Did rescue help?
- Did rescue stall profit?
- Was rescue too late?
- Was rescue too early?
- Which state/slot/policy combinations are dangerous?

Usage:
  python AMOS_ZR_RescueResultAnalyzer_v1_04.py --csv AMOS_ZR_WR4_RescueLog.csv
  python AMOS_ZR_RescueResultAnalyzer_v1_04.py --csv AMOS_ZR_WR4_RescueLog.csv --out report.csv
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import pandas as pd


def load_log(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(f"CSV not found: {path}")
    df = pd.read_csv(path)
    required = {
        "time", "event", "rescue_result", "market_state", "strategy_slot", "policy",
        "danger_score", "hedge_mode", "vwap_sigma", "bigplayer_score",
        "basket_profit", "completion_value", "target", "turn_count",
        "equity_dd", "daily_dd", "margin_level", "duration_sec",
        "reattack_allowed", "frozen"
    }
    missing = sorted(required - set(df.columns))
    if missing:
        raise ValueError(f"Missing columns: {missing}")
    for col in [
        "danger_score", "vwap_sigma", "bigplayer_score", "basket_profit",
        "completion_value", "target", "turn_count", "equity_dd", "daily_dd",
        "margin_level", "duration_sec"
    ]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    df["time"] = pd.to_datetime(df["time"], errors="coerce")
    return df


def classify_rows(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    out["helped"] = out["rescue_result"].isin(["HELPED_PROFIT", "HELPED_ZERO"])
    out["profit_stalled"] = out["rescue_result"].eq("PROFIT_STALLED")
    out["too_late"] = out["rescue_result"].eq("TOO_LATE") | (
        (out["event"].eq("ZR_CLOSE")) &
        ((out["equity_dd"] >= out["equity_dd"].quantile(0.80)) | (out["daily_dd"] >= out["daily_dd"].quantile(0.80)))
    )
    out["too_early"] = out["rescue_result"].eq("TOO_EARLY") | (
        (out["event"].isin(["ZR_ARMED", "ZR_START"])) & (out["danger_score"] < 35)
    )
    out["freeze_skip"] = out["event"].isin(["ZR_ORDER_FREEZE", "ZR_ORDER_SKIP_FROZEN"])
    out["chaos_exit_only_ok"] = ~((out["market_state"].eq("CHAOS")) & (~out["policy"].eq("EXIT_ONLY")))
    return out


def summarize(df: pd.DataFrame) -> pd.DataFrame:
    close_df = df[df["event"].eq("ZR_CLOSE")].copy()
    if close_df.empty:
        close_df = df.copy()

    keys = ["market_state", "strategy_slot", "policy"]
    summary = close_df.groupby(keys, dropna=False).agg(
        rescues=("event", "count"),
        helped_rate=("helped", "mean"),
        stalled_rate=("profit_stalled", "mean"),
        too_late_rate=("too_late", "mean"),
        too_early_rate=("too_early", "mean"),
        avg_completion=("completion_value", "mean"),
        avg_profit=("basket_profit", "mean"),
        avg_duration_sec=("duration_sec", "mean"),
        max_equity_dd=("equity_dd", "max"),
        max_daily_dd=("daily_dd", "max"),
        min_margin_level=("margin_level", "min"),
        avg_turns=("turn_count", "mean"),
    ).reset_index()

    for col in ["helped_rate", "stalled_rate", "too_late_rate", "too_early_rate"]:
        summary[col] = (summary[col] * 100).round(2)
    return summary.sort_values(["helped_rate", "stalled_rate"], ascending=[False, True])


def print_findings(df: pd.DataFrame, summary: pd.DataFrame) -> None:
    close_df = df[df["event"].eq("ZR_CLOSE")]
    total = len(close_df)
    print("\n=== AMOS ZR RescueResult Analysis v1.04 ===")
    print(f"Total closed rescues: {total}")
    if total:
        print(f"Helped rate: {close_df['helped'].mean()*100:.2f}%")
        print(f"Profit-stalled rate: {close_df['profit_stalled'].mean()*100:.2f}%")
        print(f"Too-late rate: {close_df['too_late'].mean()*100:.2f}%")
        print(f"Too-early rate: {close_df['too_early'].mean()*100:.2f}%")

    freeze_count = int(df["freeze_skip"].sum()) if "freeze_skip" in df else 0
    chaos_violations = int((~df["chaos_exit_only_ok"]).sum()) if "chaos_exit_only_ok" in df else 0
    print(f"Execution freeze/skip events: {freeze_count}")
    print(f"CHAOS non-EXIT_ONLY violations: {chaos_violations}")

    if not summary.empty:
        print("\n--- Best / worst policy groups ---")
        print(summary.head(10).to_string(index=False))
        risky = summary[(summary["stalled_rate"] >= 30) | (summary["too_late_rate"] >= 25) | (summary["max_daily_dd"] >= 3)]
        if not risky.empty:
            print("\n--- Risky groups to weaken or disable ---")
            print(risky.to_string(index=False))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True, help="Path to AMOS_ZR_WR4_RescueLog.csv")
    parser.add_argument("--out", help="Optional output summary CSV")
    args = parser.parse_args()

    try:
        df = classify_rows(load_log(Path(args.csv)))
        summary = summarize(df)
        print_findings(df, summary)
        if args.out:
            summary.to_csv(args.out, index=False)
            print(f"\nSaved summary: {args.out}")
        return 0
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
