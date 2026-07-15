#!/usr/bin/env python3
"""AMOS Monte Carlo report validator (Non-Negotiable Rule 4).

Enforces that any strategy/EA results file reports P10 / worst-decile
outcomes and a sufficient simulation count. Exits non-zero when a report is
missing required fields so CI can block undeployable claims.

The Monte Carlo simulation itself is not implemented here (that belongs to
the EA factory / research code). This validates the *reporting contract* so
average-case numbers can never stand in for worst-decile ones.

Usage:
    python3 scripts/monte_carlo_validate.py reports/<strategy>.mc.json [...]
"""
import json
import sys
from pathlib import Path

REQUIRED_FIELDS = [
    "strategy",
    "num_simulations",
    "median_return",
    "p10_return",          # 10th percentile / worst-decile return
    "p10_max_drawdown",    # worst-decile drawdown
    "worst_case_drawdown",
]

MIN_SIMULATIONS = 1000


def validate(path):
    errors = []
    try:
        data = json.loads(Path(path).read_text())
    except FileNotFoundError:
        return [f"{path}: file not found"]
    except json.JSONDecodeError as exc:
        return [f"{path}: invalid JSON ({exc})"]

    reports = data if isinstance(data, list) else [data]
    for index, report in enumerate(reports):
        if not isinstance(report, dict):
            errors.append(f"{path}[{index}]: expected an object")
            continue
        tag = report.get("strategy", f"{path}[{index}]")
        for field in REQUIRED_FIELDS:
            if field not in report:
                errors.append(f"{tag}: missing required field '{field}'")
        n = report.get("num_simulations")
        if isinstance(n, int) and n < MIN_SIMULATIONS:
            errors.append(
                f"{tag}: num_simulations {n} < required {MIN_SIMULATIONS}")
    return errors


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip())
        return 2

    errors = []
    for path in argv[1:]:
        errors.extend(validate(path))

    if errors:
        print("Monte Carlo validation FAILED "
              "(Rule 4 — P10/worst-decile required):")
        for err in errors:
            print(f"  - {err}")
        return 1

    print("Monte Carlo validation passed: P10/worst-decile reporting present.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
