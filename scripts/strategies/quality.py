"""Correctness- and verification-first strategy."""
from __future__ import annotations

from .base import StagePolicy, StrategySpec, WorkerBudget, small_low_risk_is_direct, standard_effort


def adaptive_route(task) -> str:
    if task.quality_intent in {"strong", "absolute"}:
        return "delegate"
    if small_low_risk_is_direct(task):
        return "direct"
    return "delegate" if task.complexity != "small" or task.risk in {"high", "critical"} or task.uncertainty == "high" else "direct"


def effort(task, role: str) -> str:
    if task.quality_intent == "absolute":
        return "max"
    if task.quality_intent == "strong":
        return "xhigh" if role == "parent" else "max"
    if task.complexity == "critical" or task.risk == "critical":
        return "xhigh" if role == "parent" else "max"
    if task.complexity == "complex" or task.risk == "high" or task.verification_cost == "high":
        return "xhigh" if role == "parent" else "max"
    return standard_effort(task, role)


def worker_budget(task) -> WorkerBudget:
    if task.quality_intent == "absolute":
        return WorkerBudget(4, 4, 2, 8, "high")
    if task.quality_intent == "strong":
        return WorkerBudget(4, 3, 2, 7, "high")
    if task.complexity == "critical" or task.risk == "critical":
        return WorkerBudget(4, 3, 2, 7, "high")
    if task.complexity == "complex" or task.risk == "high" or task.verification_cost == "high":
        return WorkerBudget(4, 3, 2, 6, "high")
    return WorkerBudget(2, 2, 1, 4, "high")


def independent_review(task) -> bool:
    return (
        task.quality_intent in {"strong", "absolute"}
        or task.complexity != "small"
        or task.risk in {"high", "critical"}
        or task.verification_cost == "high"
    )


def capability(task, role: str) -> str:
    """Select Parent-class capability only where it adds decision value.

    Strong/absolute intent upgrades implementation and independent review, while
    ordinary read-only exploration stays on the efficient Worker capability.
    Explorers upgrade only for genuinely critical technical risk/complexity.
    """
    critical = task.complexity == "critical" or task.risk == "critical"
    if role == "explorer":
        return "parent" if critical else "worker"
    if role in {"implementer", "reviewer"}:
        return "parent" if critical or task.quality_intent in {"strong", "absolute"} else "worker"
    return "worker"


def exploration_bonus(task) -> int:
    if task.quality_intent == "absolute":
        return 4
    if task.quality_intent == "strong":
        return 2
    return 0


def reviewer_bonus(task) -> int:
    return 1 if task.quality_intent == "absolute" else 0


def notes(task) -> tuple[str, ...]:
    if task.quality_intent == "strong":
        return ("strong quality intent authorizes parent-class implementer and reviewer capability",)
    if task.quality_intent == "absolute":
        return ("absolute quality intent prioritizes correctness over quota and latency within runtime safety ceilings",)
    return ()


def implementation_soft_timeout(task) -> int:
    if task.quality_intent == "absolute" or task.complexity == "critical" or task.risk == "critical":
        return 2700
    if (
        task.quality_intent == "strong"
        or task.complexity == "complex"
        or task.scope == "repo-wide"
        or task.iteration_intensity == "heavy-loop"
        or task.verification_cost == "high"
    ):
        return 2400
    return 1800


def implementation_checkpoint_rearm_seconds(task) -> int:
    if task.quality_intent == "absolute" or task.complexity == "critical" or task.risk == "critical":
        return 600
    if (
        task.quality_intent == "strong"
        or task.complexity == "complex"
        or task.scope in {"cross-module", "repo-wide"}
        or task.iteration_intensity == "heavy-loop"
        or task.verification_cost == "high"
    ):
        return 480
    return 360


def implementation_repair_attempts(task) -> int:
    if (
        task.quality_intent in {"strong", "absolute"}
        or task.complexity in {"complex", "critical"}
        or task.risk in {"high", "critical"}
        or task.scope == "repo-wide"
        or task.iteration_intensity == "heavy-loop"
        or task.verification_cost == "high"
    ):
        return 3
    return 2


def implementation_maximum_work_units(task) -> int:
    if (
        task.quality_intent == "absolute"
        or task.complexity == "critical"
        or task.risk == "critical"
        or task.scope == "repo-wide"
        or task.iteration_intensity == "heavy-loop"
    ):
        return 4
    if (
        task.quality_intent == "strong"
        or task.complexity == "complex"
        or task.scope == "cross-module"
        or task.verification_cost == "high"
    ):
        return 3
    return 1


def lifecycle(task, stage: str) -> StagePolicy:
    if stage == "exploration":
        return StagePolicy("quorum", 2, 300, 2400, True, False, "parent_delta")
    if stage == "implementation":
        maximum_work_units = implementation_maximum_work_units(task)
        bounded_mode = maximum_work_units > 1
        return StagePolicy(
            "required",
            1,
            300,
            3600,
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
        return StagePolicy("required", 2, 300, 3000, False, False, "replan")
    raise ValueError(f"invalid lifecycle stage: {stage}")


STRATEGY = StrategySpec(
    name="quality",
    description="maximize correctness through deep reasoning, scalable verification, and role-scoped parent-class capability",
    adaptive_route=adaptive_route,
    effort=effort,
    worker_budget=worker_budget,
    independent_review=independent_review,
    capability=capability,
    exploration_bonus=exploration_bonus,
    reviewer_bonus=reviewer_bonus,
    notes=notes,
    lifecycle=lifecycle,
    allow_parallel_write=True,
)
