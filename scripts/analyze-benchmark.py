#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

EFFORT_RANK = {"high": 0, "xhigh": 1, "max": 2}
TASK_CLASSES = ("routine", "complex", "critical")
NONNEGATIVE_INTS = {"input_tokens", "cached_input_tokens", "output_tokens", "repair_cycles"}


def legacy_strategy_id(row: dict[str, Any]) -> str:
    suffix = row["model"].rsplit("-", 1)[-1]
    if suffix in {"luna", "terra", "sol"}:
        base = f"{suffix}-direct"
        return base if row["reasoning_effort"] == "high" else f"{base}-{row['reasoning_effort']}"
    return f"direct:{row['model']}:{row['reasoning_effort']}"


def validate_usage(usage: dict[str, Any], label: str) -> None:
    for field in ("input_tokens", "cached_input_tokens", "output_tokens"):
        value = usage.get(field)
        if type(value) is not int or value < 0:
            raise ValueError(f"{label}: {field} must be a non-negative integer")
    if usage["cached_input_tokens"] > usage["input_tokens"]:
        raise ValueError(f"{label}: cached_input_tokens exceeds input_tokens")


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
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
        if row["schema_version"] not in {1, 2}:
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
        validate_usage(row, f"{path}:{n}")

        if row["schema_version"] == 1:
            row["strategy_id"] = legacy_strategy_id(row)
            row["strategy"] = "direct"
            row["reasoning_policy"] = "fixed"
            row["worker_model"] = None
            row["worker_reasoning_effort"] = None
            row["first_passed"] = row["passed"] and row["repair_cycles"] == 0
            row["review_cycles"] = 0
            row["model_usage"] = [{
                "role": "direct",
                "model": row["model"],
                "reasoning_effort": row["reasoning_effort"],
                "calls": row["repair_cycles"] + 1,
                "input_tokens": row["input_tokens"],
                "cached_input_tokens": row["cached_input_tokens"],
                "output_tokens": row["output_tokens"],
            }]
        else:
            for field in ("strategy_id", "strategy", "reasoning_policy", "first_passed", "review_cycles", "model_usage"):
                if field not in row:
                    raise ValueError(f"{path}:{n}: missing {field}")
            if not isinstance(row["strategy_id"], str) or not row["strategy_id"]:
                raise ValueError(f"{path}:{n}: invalid strategy_id")
            if row["strategy"] not in {"direct", "flow"}:
                raise ValueError(f"{path}:{n}: invalid strategy")
            if row["reasoning_policy"] not in {"fixed", "adaptive"}:
                raise ValueError(f"{path}:{n}: invalid reasoning_policy")
            if type(row["first_passed"]) is not bool:
                raise ValueError(f"{path}:{n}: first_passed must be boolean")
            if type(row["review_cycles"]) is not int or row["review_cycles"] < 0:
                raise ValueError(f"{path}:{n}: review_cycles must be a non-negative integer")
            if not isinstance(row["model_usage"], list) or not row["model_usage"]:
                raise ValueError(f"{path}:{n}: model_usage must be a non-empty array")
            summed = {"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0}
            for index, usage in enumerate(row["model_usage"]):
                if not isinstance(usage, dict):
                    raise ValueError(f"{path}:{n}: model_usage[{index}] must be an object")
                if usage.get("role") not in {"direct", "parent", "worker"}:
                    raise ValueError(f"{path}:{n}: invalid model_usage role")
                if not isinstance(usage.get("model"), str) or not usage["model"]:
                    raise ValueError(f"{path}:{n}: invalid model_usage model")
                if usage.get("reasoning_effort") not in EFFORT_RANK:
                    raise ValueError(f"{path}:{n}: invalid model_usage reasoning effort")
                if type(usage.get("calls")) is not int or usage["calls"] < 1:
                    raise ValueError(f"{path}:{n}: model_usage calls must be >= 1")
                validate_usage(usage, f"{path}:{n}:model_usage[{index}]")
                for key in summed:
                    summed[key] += usage[key]
            if any(row[key] != value for key, value in summed.items()):
                raise ValueError(f"{path}:{n}: top-level usage does not equal model_usage sum")
            if row["strategy"] == "direct":
                if row["reasoning_policy"] != "fixed" or row.get("worker_model") is not None or row.get("worker_reasoning_effort") is not None:
                    raise ValueError(f"{path}:{n}: direct strategy has invalid policy or worker metadata")
                if any(
                    usage["role"] != "direct"
                    or usage["model"] != row["model"]
                    or usage["reasoning_effort"] != row["reasoning_effort"]
                    for usage in row["model_usage"]
                ):
                    raise ValueError(f"{path}:{n}: direct model_usage does not match strategy metadata")
            else:
                if not isinstance(row.get("worker_model"), str) or not row["worker_model"]:
                    raise ValueError(f"{path}:{n}: flow strategy requires worker_model")
                if row.get("worker_reasoning_effort") not in EFFORT_RANK:
                    raise ValueError(f"{path}:{n}: flow strategy requires worker_reasoning_effort")
                for usage in row["model_usage"]:
                    if usage["role"] == "direct":
                        raise ValueError(f"{path}:{n}: flow model_usage cannot use direct role")
                    expected_model = row["model"] if usage["role"] == "parent" else row["worker_model"]
                    expected_effort = row["reasoning_effort"] if usage["role"] == "parent" else row["worker_reasoning_effort"]
                    if usage["model"] != expected_model or usage["reasoning_effort"] != expected_effort:
                        raise ValueError(f"{path}:{n}: flow model_usage does not match actor metadata")
        rows.append(row)
    if not rows:
        raise ValueError(f"{path}: no benchmark rows")
    return rows


def validate_prices(prices: dict[str, Any]) -> None:
    for model, price in prices.items():
        for key in ("input", "cached_input", "output"):
            if key not in price or not isinstance(price[key], (int, float)) or price[key] < 0:
                raise ValueError(f"invalid {key} price for {model}")


def usage_cost(usage: dict[str, Any], prices: dict[str, Any]) -> float:
    model = usage["model"]
    if model not in prices:
        raise ValueError(f"missing price snapshot for {model}")
    price = prices[model]
    uncached = usage["input_tokens"] - usage["cached_input_tokens"]
    return (
        uncached * price["input"]
        + usage["cached_input_tokens"] * price["cached_input"]
        + usage["output_tokens"] * price["output"]
    ) / 1_000_000


def run_cost(row: dict[str, Any], prices: dict[str, Any]) -> float:
    return sum(usage_cost(usage, prices) for usage in row["model_usage"])


def summarize(items: list[dict[str, Any]], prices: dict[str, Any], threshold: float, min_samples: int, max_repairs: float) -> dict[str, Any]:
    first = items[0]
    samples = len(items)
    identity_fields = (
        "task_class", "strategy_id", "strategy", "reasoning_policy", "model",
        "reasoning_effort", "worker_model", "worker_reasoning_effort",
    )
    identities = {tuple(item.get(field) for field in identity_fields) for item in items}
    if len(identities) != 1:
        raise ValueError(f"strategy {first['strategy_id']} has inconsistent model, policy, or effort metadata")
    sample_keys = {(item["task_id"], item.get("repetition", 1)) for item in items}
    if len(sample_keys) != samples:
        raise ValueError(f"strategy {first['strategy_id']} contains duplicate task/repetition samples")
    pass_rate = sum(1 for item in items if item["passed"]) / samples
    first_pass_rate = sum(1 for item in items if item["first_passed"]) / samples
    avg_repairs = sum(item["repair_cycles"] for item in items) / samples
    avg_reviews = sum(item["review_cycles"] for item in items) / samples
    avg_cost = sum(run_cost(item, prices) for item in items) / samples
    avg_wall = sum(item.get("wall_time_seconds", 0.0) for item in items) / samples
    quality_ok = samples >= min_samples and pass_rate >= threshold and avg_repairs <= max_repairs
    return {
        "task_class": first["task_class"],
        "strategy_id": first["strategy_id"],
        "strategy": first["strategy"],
        "reasoning_policy": first["reasoning_policy"],
        "model": first["model"],
        "reasoning_effort": first["reasoning_effort"],
        "worker_model": first.get("worker_model"),
        "worker_reasoning_effort": first.get("worker_reasoning_effort"),
        "samples": samples,
        "pass_rate": round(pass_rate, 4),
        "first_pass_rate": round(first_pass_rate, 4),
        "average_repair_cycles": round(avg_repairs, 4),
        "average_review_cycles": round(avg_reviews, 4),
        "average_cost_usd": round(avg_cost, 6),
        "average_wall_time_seconds": round(avg_wall, 3),
        "quality_gate": quality_ok,
        "_sample_keys": sample_keys,
    }


def delta(value: float, reference: float) -> float:
    return round(value - reference, 4)


def capability_comparison(task_class: str, by_id: dict[str, dict[str, Any]], comparison: dict[str, Any]) -> dict[str, Any] | None:
    sol_id = comparison["sol_strategy_id"]
    sol = by_id.get(sol_id)
    competitors = [
        item for item in by_id.values()
        if item["strategy"] == "direct"
        and item["strategy_id"] != sol_id
        and item["reasoning_policy"] == "fixed"
        and sol is not None
        and item["reasoning_effort"] == sol["reasoning_effort"]
    ]
    if sol is None or not competitors:
        return None
    competitor = max(
        competitors,
        key=lambda item: (item["pass_rate"], item["first_pass_rate"], -item["average_repair_cycles"]),
    )
    paired = sol["_sample_keys"] == competitor["_sample_keys"]
    controlled = sol["strategy"] == "direct" and sol["reasoning_policy"] == "fixed"
    enough = (
        sol["samples"] >= comparison["min_samples"]
        and competitor["samples"] >= comparison["min_samples"]
        and paired
        and controlled
    )
    pass_gain = delta(sol["pass_rate"], competitor["pass_rate"])
    first_gain = delta(sol["first_pass_rate"], competitor["first_pass_rate"])
    repair_reduction = delta(competitor["average_repair_cycles"], sol["average_repair_cycles"])
    not_worse = sol["pass_rate"] >= competitor["pass_rate"]
    meaningful_gain = (
        pass_gain >= comparison["sol_min_pass_rate_gain"]
        or (pass_gain >= 0 and first_gain >= comparison["sol_min_first_pass_rate_gain"])
        or (pass_gain >= 0 and first_gain >= 0 and repair_reduction >= comparison["sol_min_repair_reduction"])
    )
    return {
        "task_class": task_class,
        "sol_strategy_id": sol_id,
        "competitor_strategy_id": competitor["strategy_id"],
        "samples": min(sol["samples"], competitor["samples"]),
        "evidence_sufficient": enough,
        "paired_samples": paired,
        "controlled_reasoning_effort": sol["reasoning_effort"],
        "pass_rate_gain": pass_gain,
        "first_pass_rate_gain": first_gain,
        "average_repair_reduction": repair_reduction,
        "advantage_demonstrated": enough and not_worse and meaningful_gain,
    }


def flow_comparison(task_class: str, by_id: dict[str, dict[str, Any]], comparison: dict[str, Any]) -> dict[str, Any] | None:
    flow = by_id.get(comparison["flow_strategy_id"])
    sol = by_id.get(comparison["sol_strategy_id"])
    worker = by_id.get(comparison["worker_strategy_id"])
    if flow is None or sol is None or worker is None:
        return None
    paired = flow["_sample_keys"] == sol["_sample_keys"] == worker["_sample_keys"]
    controlled_effort = sol["reasoning_effort"]
    controlled = (
        flow["strategy"] == "flow"
        and flow["reasoning_policy"] == "fixed"
        and sol["strategy"] == "direct"
        and sol["reasoning_policy"] == "fixed"
        and worker["strategy"] == "direct"
        and worker["reasoning_policy"] == "fixed"
        and flow["reasoning_effort"] == controlled_effort
        and flow["worker_reasoning_effort"] == controlled_effort
        and worker["reasoning_effort"] == controlled_effort
    )
    enough = (
        min(flow["samples"], sol["samples"], worker["samples"]) >= comparison["min_samples"]
        and paired
        and controlled
    )
    quality_delta = delta(flow["pass_rate"], sol["pass_rate"])
    cost_reduction = round(1 - flow["average_cost_usd"] / sol["average_cost_usd"], 4) if sol["average_cost_usd"] else 0.0
    worker_pass_gain = delta(flow["pass_rate"], worker["pass_rate"])
    worker_first_gain = delta(flow["first_pass_rate"], worker["first_pass_rate"])
    worker_repair_reduction = delta(worker["average_repair_cycles"], flow["average_repair_cycles"])
    quality_noninferior = quality_delta >= -comparison["flow_max_pass_rate_regression_vs_sol"]
    cost_ok = cost_reduction >= comparison["flow_min_cost_reduction_vs_sol"]
    worker_gain = (
        worker_pass_gain >= comparison["flow_min_pass_rate_gain_vs_worker"]
        or (worker_pass_gain >= 0 and worker_first_gain >= comparison["flow_min_first_pass_rate_gain_vs_worker"])
        or (worker_pass_gain >= 0 and worker_first_gain >= 0 and worker_repair_reduction >= comparison["flow_min_repair_reduction_vs_worker"])
    )
    return {
        "task_class": task_class,
        "flow_strategy_id": flow["strategy_id"],
        "quality_reference_strategy_id": sol["strategy_id"],
        "worker_reference_strategy_id": worker["strategy_id"],
        "samples": min(flow["samples"], sol["samples"], worker["samples"]),
        "evidence_sufficient": enough,
        "paired_samples": paired,
        "controlled_reasoning_effort": controlled_effort if controlled else None,
        "pass_rate_delta_vs_sol": quality_delta,
        "cost_reduction_vs_sol": cost_reduction,
        "pass_rate_gain_vs_worker": worker_pass_gain,
        "first_pass_rate_gain_vs_worker": worker_first_gain,
        "average_repair_reduction_vs_worker": worker_repair_reduction,
        "quality_noninferior_to_sol": quality_noninferior,
        "worker_quality_gain": worker_gain,
        "advantage_demonstrated": enough and quality_noninferior and cost_ok and worker_gain,
    }


def adaptive_comparison(task_class: str, by_id: dict[str, dict[str, Any]], comparison: dict[str, Any]) -> dict[str, Any] | None:
    fixed = by_id.get(comparison["flow_strategy_id"])
    adaptive = by_id.get(comparison["adaptive_flow_strategy_id"])
    if fixed is None or adaptive is None:
        return None
    paired = fixed["_sample_keys"] == adaptive["_sample_keys"]
    policies_match = (
        fixed["strategy"] == "flow"
        and fixed["reasoning_policy"] == "fixed"
        and adaptive["strategy"] == "flow"
        and adaptive["reasoning_policy"] == "adaptive"
    )
    enough = (
        min(fixed["samples"], adaptive["samples"]) >= comparison["min_samples"]
        and paired
        and policies_match
    )
    pass_gain = delta(adaptive["pass_rate"], fixed["pass_rate"])
    first_gain = delta(adaptive["first_pass_rate"], fixed["first_pass_rate"])
    repair_reduction = delta(fixed["average_repair_cycles"], adaptive["average_repair_cycles"])
    cost_change = round(adaptive["average_cost_usd"] / fixed["average_cost_usd"] - 1, 4) if fixed["average_cost_usd"] else 0.0
    wall_change = round(adaptive["average_wall_time_seconds"] / fixed["average_wall_time_seconds"] - 1, 4) if fixed["average_wall_time_seconds"] else 0.0
    quality_gain = (
        pass_gain >= comparison["adaptive_min_pass_rate_gain"]
        or (pass_gain >= 0 and first_gain >= comparison["adaptive_min_first_pass_rate_gain"])
        or (pass_gain >= 0 and first_gain >= 0 and repair_reduction >= comparison["adaptive_min_repair_reduction"])
    )
    return {
        "task_class": task_class,
        "fixed_strategy_id": fixed["strategy_id"],
        "adaptive_strategy_id": adaptive["strategy_id"],
        "samples": min(fixed["samples"], adaptive["samples"]),
        "evidence_sufficient": enough,
        "paired_samples": paired,
        "reasoning_policies_match": policies_match,
        "pass_rate_gain": pass_gain,
        "first_pass_rate_gain": first_gain,
        "average_repair_reduction": repair_reduction,
        "cost_change": cost_change,
        "wall_time_change": wall_change,
        "quality_gain": quality_gain,
        "value_demonstrated": enough and quality_gain and cost_change <= comparison["adaptive_max_cost_increase"],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--prices", required=True)
    ap.add_argument("--policy", default="policy/benchmark.toml")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    with open(args.policy, "rb") as policy_file:
        policy = tomllib.load(policy_file)
    if policy.get("schema_version") != 2:
        raise ValueError("benchmark policy schema_version must be 2")
    quality = policy["quality"]
    comparison = policy["comparison"]
    prices = json.loads(Path(args.prices).read_text())
    validate_prices(prices)
    rows = load_jsonl(Path(args.results))

    grouped: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[(row["task_class"], row["strategy_id"])].append(row)

    thresholds = {
        "routine": quality["routine_min_pass_rate"],
        "complex": quality["complex_min_pass_rate"],
        "critical": quality["critical_min_pass_rate"],
    }
    summaries = [
        summarize(items, prices, thresholds[task_class], quality["min_samples_per_configuration"], quality["max_average_repair_cycles"])
        for (task_class, _), items in sorted(grouped.items())
    ]

    recommendations: dict[str, Any] = {}
    sol_evidence: dict[str, Any] = {}
    flow_evidence: dict[str, Any] = {}
    adaptive_evidence: dict[str, Any] = {}
    for task_class in TASK_CLASSES:
        class_items = [item for item in summaries if item["task_class"] == task_class]
        eligible = [item for item in class_items if item["quality_gate"]]
        if eligible:
            best = min(
                eligible,
                key=lambda item: (item["average_cost_usd"], EFFORT_RANK[item["reasoning_effort"]], item["strategy_id"]),
            )
            recommendations[task_class] = {
                "strategy_id": best["strategy_id"],
                "strategy": best["strategy"],
                "model": best["model"],
                "reasoning_effort": best["reasoning_effort"],
                "worker_model": best["worker_model"],
                "average_cost_usd": best["average_cost_usd"],
                "pass_rate": best["pass_rate"],
                "samples": best["samples"],
            }
        else:
            recommendations[task_class] = None
        by_id = {item["strategy_id"]: item for item in class_items}
        sol_evidence[task_class] = capability_comparison(task_class, by_id, comparison)
        flow_evidence[task_class] = flow_comparison(task_class, by_id, comparison)
        adaptive_evidence[task_class] = adaptive_comparison(task_class, by_id, comparison)

    result = {
        "recommendations": recommendations,
        "configurations": [
            {key: value for key, value in summary.items() if not key.startswith("_")}
            for summary in summaries
        ],
        "sol_capability_evidence": sol_evidence,
        "flow_advantage_evidence": flow_evidence,
        "adaptive_reasoning_evidence": adaptive_evidence,
        "advisory_only": True,
    }
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        for task_class in TASK_CLASSES:
            sol = sol_evidence[task_class]
            flow = flow_evidence[task_class]
            adaptive = adaptive_evidence[task_class]
            print(
                f"{task_class}: sol advantage={sol and sol['advantage_demonstrated']}; "
                f"flow advantage={flow and flow['advantage_demonstrated']}; "
                f"adaptive value={adaptive and adaptive['value_demonstrated']}"
            )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"benchmark analysis failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
