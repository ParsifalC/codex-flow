#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


def load_jsonl(path: Path) -> list[dict]:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise ValueError("benchmark results are empty")
    return rows


def cost(row: dict, prices: dict) -> float:
    model = row["model"]
    if model not in prices:
        raise ValueError(f"missing price snapshot for {model}")
    p = prices[model]
    cached = row["cached_input_tokens"]
    uncached = max(0, row["input_tokens"] - cached)
    return (
        uncached * p["input"]
        + cached * p["cached_input"]
        + row["output_tokens"] * p["output"]
    ) / 1_000_000


def pct(n: int, d: int) -> str:
    return f"{(100 * n / d):.1f}%" if d else "n/a"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--prices", required=True)
    ap.add_argument("--analysis", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--title", default="Codex benchmark report")
    args = ap.parse_args()

    rows = load_jsonl(Path(args.results))
    prices = json.loads(Path(args.prices).read_text())
    analysis = json.loads(Path(args.analysis).read_text())

    total_cost = sum(cost(row, prices) for row in rows)
    total_input = sum(row["input_tokens"] for row in rows)
    total_cached = sum(row["cached_input_tokens"] for row in rows)
    total_output = sum(row["output_tokens"] for row in rows)
    passed = sum(1 for row in rows if row["passed"])
    infra_failures = sum(1 for row in rows if row.get("codex_exit_code", 0) != 0)
    repairs = sum(row["repair_cycles"] for row in rows)

    grouped: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for row in rows:
        grouped[(row["model"], row["reasoning_effort"])].append(row)

    lines = [
        f"# {args.title}",
        "",
        "## Overall",
        "",
        f"- Runs completed: **{len(rows)}**",
        f"- Passed: **{passed}/{len(rows)} ({pct(passed, len(rows))})**",
        f"- Infrastructure/CLI failures: **{infra_failures}**",
        f"- Repair cycles: **{repairs}**",
        f"- Estimated model cost: **${total_cost:.6f}**",
        f"- Tokens: input **{total_input:,}**, cached input **{total_cached:,}**, output **{total_output:,}**",
        "",
        "## Configuration results",
        "",
        "| Model | Effort | Runs | Pass rate | Repairs | Estimated cost | Avg cost/run |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ]

    for (model, effort), items in sorted(grouped.items()):
        item_passed = sum(1 for item in items if item["passed"])
        item_repairs = sum(item["repair_cycles"] for item in items)
        item_cost = sum(cost(item, prices) for item in items)
        lines.append(
            f"| {model} | {effort} | {len(items)} | {pct(item_passed, len(items))} | "
            f"{item_repairs} | ${item_cost:.6f} | ${item_cost / len(items):.6f} |"
        )

    lines.extend(["", "## Advisory routing", ""])
    recommendations = analysis.get("recommendations", {})
    for task_class in ("routine", "complex", "critical"):
        rec = recommendations.get(task_class)
        if rec:
            lines.append(
                f"- **{task_class}**: `{rec['model']}` / `{rec['reasoning_effort']}` — "
                f"pass {rec['pass_rate']:.1%}, ${rec['average_cost_usd']:.6f}/run, n={rec['samples']}"
            )
        else:
            lines.append(f"- **{task_class}**: no tested configuration passed the evidence gate")

    lines.extend([
        "",
        "> Routing output is advisory only. Benchmark policy is not modified automatically.",
        "",
    ])
    Path(args.output).write_text("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
