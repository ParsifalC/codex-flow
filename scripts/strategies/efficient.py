"""Quota-efficient strategy."""
from __future__ import annotations

from .base import WorkerBudget, StrategySpec, never, small_low_risk_is_direct, standard_effort


def adaptive_route(task) -> str:
    if small_low_risk_is_direct(task):
        return "direct"
    return "delegate" if task.iteration_intensity != "one-shot" or task.scope in {"cross-module", "repo-wide"} else "direct"


def worker_budget(task) -> WorkerBudget:
    if task.complexity == "critical" or task.scope == "repo-wide" or task.iteration_intensity == "heavy-loop":
        return WorkerBudget(2, 2, 1, 5, "low")
    if task.uncertainty == "high" or task.exploration_need == "high":
        return WorkerBudget(2, 2, 1, 5, "low")
    return WorkerBudget(1, 1, 1, 2, "low")


STRATEGY = StrategySpec(
    name="efficient",
    description="minimize expensive parent usage and total waste while offloading deep execution to efficient workers",
    adaptive_route=adaptive_route,
    effort=standard_effort,
    worker_budget=worker_budget,
    independent_review=never,
    quota_sensitive=True,
)
