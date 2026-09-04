"""Balanced quality/quota/latency strategy."""
from __future__ import annotations

from .base import (
    StagePolicy,
    StrategySpec,
    TaskBudgetPolicy,
    WorkerBudget,
    never,
    small_low_risk_is_direct,
    standard_effort,
)


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


def implementation_soft_timeout(task) -> int:
    if task.complexity == "critical" or task.risk == "critical":
        return 1800
    if task.complexity == "complex" or task.scope == "repo-wide" or task.iteration_intensity == "heavy-loop":
        return 1500
    return 1200


def implementation_checkpoint_rearm_seconds(task) -> int:
    if task.complexity == "critical" or task.risk == "critical":
        return 360
    if task.complexity == "complex" or task.scope in {"cross-module", "repo-wide"} or task.iteration_intensity == "heavy-loop":
        return 300
    return 240


def implementation_repair_attempts(task) -> int:
    if task.complexity in {"complex", "critical"} or task.risk == "critical" or task.scope == "repo-wide" or task.iteration_intensity == "heavy-loop":
        return 2
    return 1


def implementation_maximum_work_units(task) -> int:
    if task.scope == "repo-wide" or task.iteration_intensity == "heavy-loop":
        semantic_maximum = 3
    elif task.complexity in {"complex", "critical"} or task.scope == "cross-module" or task.risk == "critical":
        semantic_maximum = 2
    else:
        semantic_maximum = 1
    topology_floor = min(task.writable_workstreams, worker_budget(task).max_implementers)
    return max(semantic_maximum, topology_floor)


def task_budget(task) -> TaskBudgetPolicy:
    maximum_work_units = implementation_maximum_work_units(task)
    if task.complexity == "critical" or task.risk == "critical" or task.scope == "repo-wide" or task.iteration_intensity == "heavy-loop":
        soft_timeout, hard_timeout = 3000, 3600
    elif task.complexity == "complex" or task.scope == "cross-module" or task.risk == "high":
        soft_timeout, hard_timeout = 2700, 3300
    else:
        soft_timeout, hard_timeout = 2400, 3000
    return TaskBudgetPolicy(
        soft_timeout_seconds=soft_timeout,
        hard_timeout_seconds=hard_timeout,
        max_work_units=maximum_work_units,
        max_implementation_attempts=maximum_work_units + 2,
        max_replans=2,
        max_replacements=2,
        max_review_attempts=2,
        parent_finalization_seconds=180,
    )


def lifecycle(task, stage: str) -> StagePolicy:
    if stage == "exploration":
        return StagePolicy("quorum", 1, 180, 1200, True, True, "parent_delta")
    if stage == "implementation":
        maximum_work_units = implementation_maximum_work_units(task)
        bounded_mode = maximum_work_units > 1
        return StagePolicy(
            "required", 1, 240, 2400, False, False, "replan",
            soft_timeout_seconds=implementation_soft_timeout(task),
            checkpoint_rearm_seconds=implementation_checkpoint_rearm_seconds(task),
            max_worker_repair_attempts=implementation_repair_attempts(task),
            work_unit_mode="bounded" if bounded_mode else "single",
            minimum_work_units=1,
            join_between_work_units=bounded_mode,
            maximum_work_units=maximum_work_units,
            require_write_paths=bounded_mode,
        )
    if stage == "review":
        return StagePolicy("required", 1, 180, 1800, True, False, "retry_review")
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
    task_budget=task_budget,
)
