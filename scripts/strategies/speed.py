"""Wall-clock-latency strategy."""
from __future__ import annotations

from .base import StagePolicy, StrategySpec, TaskBudgetPolicy, WorkerBudget, never, small_low_risk_is_direct, standard_effort


def adaptive_route(task) -> str:
    if small_low_risk_is_direct(task):
        return "direct"
    return "delegate" if task.parallelism != "none" and task.complexity != "small" else "direct"


def worker_budget(task) -> WorkerBudget:
    if task.complexity in {"complex", "critical"} or task.scope in {"cross-module", "repo-wide"}:
        return WorkerBudget(4, 8, 1, 8, "high")
    return WorkerBudget(3, 8, 1, 8, "high")


def implementation_soft_timeout(task) -> int:
    if (
        task.complexity == "critical"
        or task.risk == "critical"
        or task.scope == "repo-wide"
        or task.iteration_intensity == "heavy-loop"
    ):
        return 720
    if task.complexity == "complex" or task.scope == "cross-module":
        return 600
    return 420


def implementation_checkpoint_rearm_seconds(_task) -> int:
    return 180


def implementation_repair_attempts(_task) -> int:
    return 1


def implementation_maximum_work_units(task) -> int:
    if (
        task.complexity == "critical"
        or task.risk == "critical"
        or task.scope == "repo-wide"
        or task.iteration_intensity == "heavy-loop"
    ):
        semantic_maximum = 4
    elif task.complexity == "complex" or task.scope == "cross-module":
        semantic_maximum = 3
    else:
        semantic_maximum = 1
    # A proven writable workstream is already a natural implementation unit.
    # Never compile a task budget that authorizes fewer logical units than the
    # strategy can legitimately schedule as parallel implementers.
    topology_floor = min(task.writable_workstreams, worker_budget(task).max_implementers)
    return max(semantic_maximum, topology_floor)


def task_budget(task) -> TaskBudgetPolicy:
    """Cap total speed-mode execution so replans cannot erase the latency goal."""
    maximum_work_units = implementation_maximum_work_units(task)
    return TaskBudgetPolicy(
        soft_timeout_seconds=1200,
        hard_timeout_seconds=1800,
        max_work_units=maximum_work_units,
        max_implementation_attempts=maximum_work_units + 1,
        max_replans=1,
        max_replacements=1,
    )


def lifecycle(task, stage: str) -> StagePolicy:
    if stage == "exploration":
        return StagePolicy("opportunistic", 0, 60, 600, True, True, "continue_partial")
    if stage == "implementation":
        maximum_work_units = implementation_maximum_work_units(task)
        bounded_mode = maximum_work_units > 1
        return StagePolicy(
            "required",
            1,
            120,
            1200,
            False,
            False,
            "replan",
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
    task_budget=task_budget,
)
