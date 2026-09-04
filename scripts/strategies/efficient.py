"""Quota-efficient strategy."""
from __future__ import annotations

from .base import (
    StagePolicy,
    ReasoningRolloutDecision,
    StrategySpec,
    TaskBudgetPolicy,
    WorkerBudget,
    never,
    small_low_risk_is_direct,
    standard_effort,
)


_EFFORT_RANK = {"high": 0, "xhigh": 1, "max": 2}


def _max_effort(*values: str) -> str:
    return max(values, key=lambda value: _EFFORT_RANK[value])


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


def implementation_soft_timeout(task) -> int:
    """Advisory convergence budget; the hard implementation ceiling stays unchanged."""
    if task.complexity == "critical" or task.risk == "critical":
        return 1200
    if task.complexity == "complex" or task.scope == "repo-wide" or task.iteration_intensity == "heavy-loop":
        return 900
    return 600


def implementation_repair_attempts(task) -> int:
    """Bound local test-fix loops without conflating them with lifecycle fallback."""
    if (
        task.complexity in {"complex", "critical"}
        or task.risk == "critical"
        or task.scope == "repo-wide"
        or task.iteration_intensity == "heavy-loop"
    ):
        return 2
    return 1


def implementation_minimum_work_units(task) -> int:
    """Keep long implementation transactions bounded without creating unsafe write concurrency."""
    if task.scope == "repo-wide" or task.iteration_intensity == "heavy-loop":
        return 3
    if task.complexity in {"complex", "critical"} or task.scope == "cross-module" or task.risk == "critical":
        return 2
    return 1


def task_budget(task) -> TaskBudgetPolicy:
    """Return the efficient strategy's cumulative task-level reservation caps."""
    if task.scope == "repo-wide" or task.iteration_intensity == "heavy-loop":
        max_work_units = 3
        max_attempts = 4
    elif (
        task.complexity in {"complex", "critical"}
        or task.scope == "cross-module"
        or task.risk == "critical"
    ):
        max_work_units = 2
        max_attempts = 3
    else:
        max_work_units = 1
        max_attempts = 2
    return TaskBudgetPolicy(
        soft_timeout_seconds=1500,
        hard_timeout_seconds=1800,
        max_work_units=max_work_units,
        max_implementation_attempts=max_attempts,
        max_replans=1,
        max_replacements=1,
    )


def reasoning_rollout(
    task,
    _role: str,
    policy,
    parent_reasoning: str,
    legacy_worker_reasoning: str,
) -> ReasoningRolloutDecision:
    """Compare current efficient Worker effort with the rollout proposal."""
    policy.validate()
    if task.complexity == "critical" or task.risk == "critical":
        class_target = policy.critical
    elif task.complexity == "complex" or task.risk == "high":
        class_target = policy.complex
    else:
        class_target = policy.routine
    # Rollout proposal intentionally starts from the explicit rollout floors
    # and Parent effort. Legacy's next-tier bump is the behavior being tested;
    # including it here would make adaptive unable to select an effort equal to
    # Parent, defeating the rollout's allow-equal contract.
    proposed = _max_effort(class_target, policy.minimum, parent_reasoning)
    selected = proposed if policy.mode == "adaptive" else legacy_worker_reasoning
    decision = ReasoningRolloutDecision(
        mode=policy.mode,
        legacy_worker_reasoning=legacy_worker_reasoning,
        proposed_worker_reasoning=proposed,
        selected_worker_reasoning=selected,
        applied=policy.mode == "adaptive",
    )
    decision.validate()
    return decision


def lifecycle(task, stage: str) -> StagePolicy:
    if stage == "exploration":
        return StagePolicy("quorum", 1, 120, 900, True, True, "parent_delta")
    if stage == "implementation":
        minimum_work_units = implementation_minimum_work_units(task)
        return StagePolicy(
            "required",
            1,
            180,
            1800,
            False,
            False,
            "replan",
            soft_timeout_seconds=implementation_soft_timeout(task),
            max_worker_repair_attempts=implementation_repair_attempts(task),
            work_unit_mode="bounded" if minimum_work_units > 1 else "single",
            minimum_work_units=minimum_work_units,
            join_between_work_units=minimum_work_units > 1,
            maximum_work_units=minimum_work_units,
            require_write_paths=minimum_work_units > 1,
        )
    if stage == "review":
        return StagePolicy("quorum", 1, 150, 1200, True, True, "parent_delta")
    raise ValueError(f"invalid lifecycle stage: {stage}")


STRATEGY = StrategySpec(
    name="efficient",
    description="minimize expensive parent usage and total waste while offloading deep execution to efficient workers",
    adaptive_route=adaptive_route,
    effort=standard_effort,
    worker_budget=worker_budget,
    independent_review=never,
    lifecycle=lifecycle,
    quota_sensitive=True,
    task_budget=task_budget,
    reasoning_rollout=reasoning_rollout,
)
