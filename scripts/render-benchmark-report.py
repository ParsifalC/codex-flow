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
    if row["strategy"] == "runtime":
        return f"{row['model']} / {row['reasoning_effort']} parent → runtime-selected workers"
    policy = row.get("reasoning_policy", "fixed")
    if policy == "adaptive":
        return f"{row['model']} parent → {row['worker_model']} worker / adaptive"
    return f"{row['model']} parent → {row['worker_model']} worker / {row['reasoning_effort']}"


def token_metrics(items: list[dict[str, Any]]) -> dict[str, float]:
    count = len(items)
    total_input = sum(item["input_tokens"] for item in items)
    total_cached = sum(item["cached_input_tokens"] for item in items)
    total_output = sum(item["output_tokens"] for item in items)
    parent_tokens = 0
    worker_tokens = 0
    for item in items:
        for usage in item.get("model_usage", []):
            tokens = usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
            if usage.get("role") == "parent":
                parent_tokens += tokens
            elif usage.get("role") == "worker":
                worker_tokens += tokens
    return {
        "total_tokens": (total_input + total_output) / count,
        "parent_tokens": parent_tokens / count,
        "worker_tokens": worker_tokens / count,
        "cached_input_tokens": total_cached / count,
        "net_new_input_tokens": (total_input - total_cached) / count,
        "cache_rate": total_cached / total_input if total_input else 0.0,
    }


def relative_change(value: float, reference: float) -> float | None:
    return value / reference - 1 if reference else None


def fmt_avg_tokens(value: float) -> str:
    return f"{round(value):,}"


def fmt_change(value: float | None) -> str:
    return signed_pct(value) if value is not None else "n/a"


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
    total_tokens = total_input + total_output
    net_new_input = total_input - total_cached
    passed = sum(1 for row in rows if row["passed"])
    first_passed = sum(1 for row in rows if row["first_passed"])
    infra_failures = sum(1 for row in rows if row.get("codex_exit_code", 0) != 0)
    repairs = sum(row["repair_cycles"] for row in rows)
    reviews = sum(row["review_cycles"] for row in rows)

    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[row["strategy_id"]].append(row)
    strategy_tokens = {strategy_id: token_metrics(items) for strategy_id, items in grouped.items()}
    sol_tokens = strategy_tokens.get("sol-direct")

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
        f"- Total tokens: **{total_tokens:,}**",
        f"- Input tokens: **{total_input:,}** — cached **{total_cached:,}**, net-new **{net_new_input:,}**",
        f"- Output tokens: **{total_output:,}**",
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

    runtime_actors: dict[tuple[str, str, str, str], int] = defaultdict(int)
    for row in rows:
        if row["strategy"] == "runtime":
            for usage in row["model_usage"]:
                key = (row["strategy_id"], usage["role"], usage["model"], usage["reasoning_effort"])
                runtime_actors[key] += usage["calls"]
    if runtime_actors:
        lines.extend([
            "", "## Runtime actor usage", "",
            "Runtime worker configuration may differ from planner-selected actors. The following model/effort values come from recorded usage attribution.",
            "", "| Strategy | Role | Model | Effort | Calls |",
            "| --- | --- | --- | --- | ---: |",
        ])
        for (strategy_id, role, model, effort), calls in sorted(runtime_actors.items()):
            lines.append(f"| {strategy_id} | {role} | {model} | {effort} | {calls} |")

    lines.extend([
        "",
        "## Token efficiency",
        "",
        "This table separates raw token volume from where the work ran. Runtime Parent/Worker values come from FlowPilot role-attributed telemetry; net-new input excludes cached input. Deltas use `sol-direct` as the paired high-capability baseline when present.",
        "",
        "| Strategy | Avg total tokens | Avg Parent tokens | Avg Worker tokens | Avg cached input | Avg net-new input | Cache rate | Total Δ vs Sol | Net-new Δ vs Sol | Parent reduction vs Sol |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for strategy_id, items in sorted(grouped.items()):
        metrics = strategy_tokens[strategy_id]
        if sol_tokens is not None:
            total_delta = relative_change(metrics["total_tokens"], sol_tokens["total_tokens"])
            net_new_delta = relative_change(metrics["net_new_input_tokens"], sol_tokens["net_new_input_tokens"])
        else:
            total_delta = net_new_delta = None
        if items[0]["strategy"] != "direct" and sol_tokens is not None:
            parent_reduction = 1 - metrics["parent_tokens"] / sol_tokens["total_tokens"] if sol_tokens["total_tokens"] else None
        else:
            parent_reduction = None
        lines.append(
            f"| {strategy_id} | {fmt_avg_tokens(metrics['total_tokens'])} | {fmt_avg_tokens(metrics['parent_tokens'])} | "
            f"{fmt_avg_tokens(metrics['worker_tokens'])} | {fmt_avg_tokens(metrics['cached_input_tokens'])} | "
            f"{fmt_avg_tokens(metrics['net_new_input_tokens'])} | {metrics['cache_rate']:.1%} | "
            f"{fmt_change(total_delta)} | {fmt_change(net_new_delta)} | {fmt_change(parent_reduction)} |"
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
