#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise ValueError("benchmark results are empty")
    for row in rows:
        if row.get("schema_version") == 1:
            suffix = row["model"].rsplit("-", 1)[-1]
            if suffix in {"luna", "terra", "sol"}:
                base = f"{suffix}-direct"
                row["strategy_id"] = base if row["reasoning_effort"] == "high" else f"{base}-{row['reasoning_effort']}"
            else:
                row["strategy_id"] = f"direct:{row['model']}:{row['reasoning_effort']}"
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
    return rows


def usage_cost(usage: dict[str, Any], prices: dict[str, Any]) -> float:
    model = usage["model"]
    if model not in prices:
        raise ValueError(f"missing price snapshot for {model}")
    price = prices[model]
    cached = usage["cached_input_tokens"]
    uncached = max(0, usage["input_tokens"] - cached)
    return (
        uncached * price["input"]
        + cached * price["cached_input"]
        + usage["output_tokens"] * price["output"]
    ) / 1_000_000


def cost(row: dict[str, Any], prices: dict[str, Any]) -> float:
    return sum(usage_cost(usage, prices) for usage in row["model_usage"])


def pct(n: float, d: float) -> str:
    return f"{(100 * n / d):.1f}%" if d else "n/a"


def signed_pct(value: float) -> str:
    return f"{value:+.1%}"


def yes_no(value: bool) -> str:
    return "yes" if value else "no"


def composition(row: dict[str, Any]) -> str:
    if row["strategy"] == "direct":
        return f"{row['model']} / {row['reasoning_effort']}"
    policy = row.get("reasoning_policy", "fixed")
    if policy == "adaptive":
        return f"{row['model']} parent → {row['worker_model']} worker / adaptive"
    return f"{row['model']} parent → {row['worker_model']} worker / {row['reasoning_effort']}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--prices", required=True)
    ap.add_argument("--analysis", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--title", default="Codex strategy benchmark report")
    args = ap.parse_args()

    rows = load_jsonl(Path(args.results))
    prices = json.loads(Path(args.prices).read_text())
    analysis = json.loads(Path(args.analysis).read_text())

    total_cost = sum(cost(row, prices) for row in rows)
    total_input = sum(row["input_tokens"] for row in rows)
    total_cached = sum(row["cached_input_tokens"] for row in rows)
    total_output = sum(row["output_tokens"] for row in rows)
    passed = sum(1 for row in rows if row["passed"])
    first_passed = sum(1 for row in rows if row["first_passed"])
    infra_failures = sum(1 for row in rows if row.get("codex_exit_code", 0) != 0)
    repairs = sum(row["repair_cycles"] for row in rows)
    reviews = sum(row["review_cycles"] for row in rows)

    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[row["strategy_id"]].append(row)

    lines = [
        f"# {args.title}",
        "",
        "> Dollar figures are **API-equivalent reference costs** calculated from the pinned API price snapshot. Flow cost includes parent and worker usage. They are not ChatGPT subscription charges.",
        "",
        "## Overall",
        "",
        f"- Runs completed: **{len(rows)}**",
        f"- Final pass: **{passed}/{len(rows)} ({pct(passed, len(rows))})**",
        f"- First pass: **{first_passed}/{len(rows)} ({pct(first_passed, len(rows))})**",
        f"- Infrastructure/CLI failures: **{infra_failures}**",
        f"- Repair cycles: **{repairs}**",
        f"- Parent review cycles: **{reviews}**",
        f"- API-equivalent reference cost: **${total_cost:.6f}**",
        f"- Tokens: input **{total_input:,}**, cached input **{total_cached:,}**, output **{total_output:,}**",
        "",
        "## Strategy results",
        "",
        "| Strategy | Composition | Runs | Final pass | First pass | Repairs | Reviews | Avg wall | Avg reference cost |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for strategy_id, items in sorted(grouped.items()):
        item_passed = sum(1 for item in items if item["passed"])
        item_first = sum(1 for item in items if item["first_passed"])
        item_repairs = sum(item["repair_cycles"] for item in items)
        item_reviews = sum(item["review_cycles"] for item in items)
        item_cost = sum(cost(item, prices) for item in items)
        item_wall = sum(item.get("wall_time_seconds", 0) for item in items) / len(items)
        lines.append(
            f"| {strategy_id} | {composition(items[0])} | {len(items)} | {pct(item_passed, len(items))} | "
            f"{pct(item_first, len(items))} | {item_repairs} | {item_reviews} | {item_wall:.1f}s | ${item_cost / len(items):.6f} |"
        )

    lines.extend([
        "",
        "## Sol capability evidence",
        "",
        "Sol is compared only with other direct strategies at the same reasoning effort.",
        "",
        "| Class | Comparator | Pass gain | First-pass gain | Repair reduction | Enough evidence | Advantage |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ])
    for task_class in ("routine", "complex", "critical"):
        item = analysis.get("sol_capability_evidence", {}).get(task_class)
        if not item:
            lines.append(f"| {task_class} | n/a | n/a | n/a | n/a | no | no |")
            continue
        lines.append(
            f"| {task_class} | {item['competitor_strategy_id']} | {signed_pct(item['pass_rate_gain'])} | "
            f"{signed_pct(item['first_pass_rate_gain'])} | {item['average_repair_reduction']:+.2f} | "
            f"{yes_no(item['evidence_sufficient'])} | {yes_no(item['advantage_demonstrated'])} |"
        )

    lines.extend([
        "",
        "## Fixed-high flow evidence",
        "",
        "Flow must preserve Sol quality, reduce total parent+worker cost versus Sol, and improve over Luna direct.",
        "",
        "| Class | Pass Δ vs Sol | Cost reduction vs Sol | Pass gain vs Luna | First-pass gain vs Luna | Enough evidence | Advantage |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for task_class in ("routine", "complex", "critical"):
        item = analysis.get("flow_advantage_evidence", {}).get(task_class)
        if not item:
            lines.append(f"| {task_class} | n/a | n/a | n/a | n/a | no | no |")
            continue
        lines.append(
            f"| {task_class} | {signed_pct(item['pass_rate_delta_vs_sol'])} | {item['cost_reduction_vs_sol']:.1%} | "
            f"{signed_pct(item['pass_rate_gain_vs_worker'])} | {signed_pct(item['first_pass_rate_gain_vs_worker'])} | "
            f"{yes_no(item['evidence_sufficient'])} | {yes_no(item['advantage_demonstrated'])} |"
        )

    lines.extend([
        "",
        "## Adaptive reasoning evidence",
        "",
        "Adaptive flow is compared only with fixed-high flow and is excluded from the same-effort Sol comparison.",
        "",
        "| Class | Pass gain | First-pass gain | Repair reduction | Cost change | Wall-time change | Enough evidence | Value |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for task_class in ("routine", "complex", "critical"):
        item = analysis.get("adaptive_reasoning_evidence", {}).get(task_class)
        if not item:
            lines.append(f"| {task_class} | n/a | n/a | n/a | n/a | n/a | no | no |")
            continue
        lines.append(
            f"| {task_class} | {signed_pct(item['pass_rate_gain'])} | {signed_pct(item['first_pass_rate_gain'])} | "
            f"{item['average_repair_reduction']:+.2f} | {signed_pct(item['cost_change'])} | {signed_pct(item['wall_time_change'])} | "
            f"{yes_no(item['evidence_sufficient'])} | {yes_no(item['value_demonstrated'])} |"
        )

    lines.extend(["", "## Advisory routing", ""])
    recommendations = analysis.get("recommendations", {})
    for task_class in ("routine", "complex", "critical"):
        rec = recommendations.get(task_class)
        if rec:
            lines.append(
                f"- **{task_class}**: `{rec['strategy_id']}` — pass {rec['pass_rate']:.1%}, "
                f"API-equivalent ${rec['average_cost_usd']:.6f}/run, n={rec['samples']}"
            )
        else:
            lines.append(f"- **{task_class}**: no tested strategy passed the evidence gate")

    lines.extend([
        "",
        "> Conclusions are advisory and pre-registered thresholds are applied before cost comparison. Benchmark policy is not modified automatically.",
        "",
    ])
    Path(args.output).write_text("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
