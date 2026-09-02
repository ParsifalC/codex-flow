"""Wall-clock-latency strategy."""
from __future__ import annotations

from .base import WorkerBudget, StrategySpec, never, small_low_risk_is_direct, standard_effort


def adaptive_route(task) -> str:
    if small_low_risk_is_direct(task):
        return "direct"
    return "delegate" if task.parallelism != "none" and task.complexity != "small" else "direct"


def worker_budget(task) -> WorkerBudget:
    if task.complexity in {"complex", "critical"} or task.scope in {"cross-module", "repo-wide"}:
        return WorkerBudget(4, 8, 1, 8, "high")
    return WorkerBudget(3, 8, 1, 8, "high")


STRATEGY = StrategySpec(
    name="speed",
    description="minimize wall-clock latency by saturating proven-safe worker concurrency",
    adaptive_route=adaptive_route,
    effort=standard_effort,
    worker_budget=worker_budget,
    independent_review=never,
    allow_parallel_write=True,
)
