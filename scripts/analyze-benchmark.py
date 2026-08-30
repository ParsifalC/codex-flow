#!/usr/bin/env python3
from __future__ import annotations

import argparse, json, sys, tomllib
from collections import defaultdict
from pathlib import Path

EFFORT_RANK = {"high": 0, "xhigh": 1, "max": 2}
TASK_CLASSES = {"routine", "complex", "critical"}
NONNEGATIVE_INTS = {"input_tokens", "cached_input_tokens", "output_tokens", "repair_cycles"}


def load_jsonl(path: Path):
    rows = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        required = {
            "schema_version", "task_id", "task_class", "model", "reasoning_effort",
            "passed", "input_tokens", "cached_input_tokens", "output_tokens", "repair_cycles",
        }
        missing = required - row.keys()
        if missing:
            raise ValueError(f"{path}:{n}: missing {sorted(missing)}")
        if row["schema_version"] != 1:
            raise ValueError(f"{path}:{n}: unsupported schema_version {row['schema_version']!r}")
        if not isinstance(row["task_id"], str) or not row["task_id"].strip():
            raise ValueError(f"{path}:{n}: invalid task_id")
        if row["task_class"] not in TASK_CLASSES:
            raise ValueError(f"{path}:{n}: invalid task_class {row['task_class']!r}")
        if not isinstance(row["model"], str) or not row["model"].strip():
            raise ValueError(f"{path}:{n}: invalid model")
        if row["reasoning_effort"] not in EFFORT_RANK:
            raise ValueError(f"{path}:{n}: invalid reasoning_effort {row['reasoning_effort']!r}")
        if type(row["passed"]) is not bool:
            raise ValueError(f"{path}:{n}: passed must be boolean")
        for field in NONNEGATIVE_INTS:
            value = row[field]
            if type(value) is not int or value < 0:
                raise ValueError(f"{path}:{n}: {field} must be a non-negative integer")
        if row["cached_input_tokens"] > row["input_tokens"]:
            raise ValueError(f"{path}:{n}: cached_input_tokens exceeds input_tokens")
        rows.append(row)
    if not rows:
        raise ValueError(f"{path}: no benchmark rows")
    return rows


def validate_prices(prices):
    for model, price in prices.items():
        for key in ("input", "cached_input", "output"):
            if key not in price or not isinstance(price[key], (int, float)) or price[key] < 0:
                raise ValueError(f"invalid {key} price for {model}")


def run_cost(row, price):
    uncached = row["input_tokens"] - row["cached_input_tokens"]
    return (
        uncached * price["input"]
        + row["cached_input_tokens"] * price["cached_input"]
        + row["output_tokens"] * price["output"]
    ) / 1_000_000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--prices", required=True)
    ap.add_argument("--policy", default="policy/benchmark.toml")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    policy = tomllib.load(open(args.policy, "rb"))
    q = policy["quality"]
    prices = json.loads(Path(args.prices).read_text())
    validate_prices(prices)
    rows = load_jsonl(Path(args.results))

    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["task_class"], row["model"], row["reasoning_effort"])].append(row)

    thresholds = {
        "routine": q["routine_min_pass_rate"],
        "complex": q["complex_min_pass_rate"],
        "critical": q["critical_min_pass_rate"],
    }
    min_samples = q["min_samples_per_configuration"]
    max_repairs = q["max_average_repair_cycles"]
    summary = []
    for (task_class, model, effort), items in sorted(grouped.items()):
        if model not in prices:
            raise ValueError(f"missing price snapshot for {model}")
        pass_rate = sum(1 for x in items if x["passed"]) / len(items)
        avg_repairs = sum(x["repair_cycles"] for x in items) / len(items)
        avg_cost = sum(run_cost(x, prices[model]) for x in items) / len(items)
        quality_ok = (
            len(items) >= min_samples
            and pass_rate >= thresholds[task_class]
            and avg_repairs <= max_repairs
        )
        summary.append({
            "task_class": task_class,
            "model": model,
            "reasoning_effort": effort,
            "samples": len(items),
            "pass_rate": round(pass_rate, 4),
            "average_repair_cycles": round(avg_repairs, 4),
            "average_cost_usd": round(avg_cost, 6),
            "quality_gate": quality_ok,
        })

    recommendations = {}
    for task_class in ("routine", "complex", "critical"):
        eligible = [x for x in summary if x["task_class"] == task_class and x["quality_gate"]]
        if eligible:
            best = min(
                eligible,
                key=lambda x: (
                    x["average_cost_usd"],
                    EFFORT_RANK[x["reasoning_effort"]],
                    x["model"],
                ),
            )
            recommendations[task_class] = {
                "model": best["model"],
                "reasoning_effort": best["reasoning_effort"],
                "average_cost_usd": best["average_cost_usd"],
                "pass_rate": best["pass_rate"],
                "samples": best["samples"],
            }
        else:
            recommendations[task_class] = None

    result = {"recommendations": recommendations, "configurations": summary, "advisory_only": True}
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        for cls, rec in recommendations.items():
            if rec:
                print(f"{cls}: {rec['model']} / {rec['reasoning_effort']} (${rec['average_cost_usd']:.6f}/run, pass={rec['pass_rate']:.1%})")
            else:
                print(f"{cls}: no configuration passed the quality gate")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"benchmark analysis failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
