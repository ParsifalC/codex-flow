"""Wall-clock-latency strategy."""
from __future__ import annotations

from .base import StagePolicy, StrategySpec, WorkerBudget, never, small_low_risk_is_direct, standard_effort


def adaptive_route(task) -> str:
    if small_low_risk_is_direct(task):
        return "direct"
    return "delegate" if task.parallelism != "none" and task.complexity != "small" else "direct"


def worker_budget(task) -> WorkerBudget:
    if task.complexity in {"complex", "critical"} or task.scope in {"cross-module", "repo-wide"}:
        return WorkerBudget(4, 8, 1, 8, "high")
    return WorkerBudget(3, 8, 1, 8, "high")


def lifecycle(_task, stage: str) -> StagePolicy:
    if stage == "exploration":
        return StagePolicy("opportunistic", 0, 60, 600, True, True, "continue_partial")
    if stage == "implementation":
        return StagePolicy("required", 1, 120, 1200, False, False, "replan")
    if stage == "review":
        return StagePolicy("quorum", 1, 90, 900, True, True, "parent_delta")
    raise ValueError(f"invalid lifecycle stage: {stage}")


STRATEGY = StrategySpec(
    name="speed",
    description="minimize wall-clock latency by saturating proven-safe worker concurrency",
    adaptive_route=adaptive_route,
    effort=standard_effort,
    worker_budget=worker_budget,
    independent_review=never,
    lifecycle=lifecycle,
    allow_parallel_write=True,
)
