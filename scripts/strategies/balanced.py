"""Balanced quality/quota/latency strategy."""
from __future__ import annotations

from .base import StagePolicy, StrategySpec, WorkerBudget, never, small_low_risk_is_direct, standard_effort


def adaptive_route(task) -> str:
    if small_low_risk_is_direct(task):
        return "direct"
    return "delegate" if task.complexity in {"routine", "complex", "critical"} and task.iteration_intensity != "one-shot" else "direct"


def worker_budget(task) -> WorkerBudget:
    if task.complexity in {"complex", "critical"} or task.scope == "repo-wide":
        return WorkerBudget(3, 3, 1, 5, "medium")
    if task.uncertainty == "high" or task.iteration_intensity == "heavy-loop":
        return WorkerBudget(3, 2, 1, 4, "medium")
    return WorkerBudget(2, 2, 1, 4, "medium")


def lifecycle(_task, stage: str) -> StagePolicy:
    if stage == "exploration":
        return StagePolicy("quorum", 1, 180, 1200, True, True, "parent_delta")
    if stage == "implementation":
        return StagePolicy("required", 1, 240, 2400, False, False, "replan")
    if stage == "review":
        return StagePolicy("required", 1, 180, 1800, True, False, "parent_delta")
    raise ValueError(f"invalid lifecycle stage: {stage}")


STRATEGY = StrategySpec(
    name="balanced",
    description="balance quality, quota consumption, and latency with moderate safe worker fan-out",
    adaptive_route=adaptive_route,
    effort=standard_effort,
    worker_budget=worker_budget,
    independent_review=never,
    lifecycle=lifecycle,
    allow_parallel_write=True,
    quota_sensitive=True,
)
