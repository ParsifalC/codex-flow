"""Shared contracts for built-in codex-flow strategy modules."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

Task = Any
RouteFn = Callable[[Task], str]
EffortFn = Callable[[Task, str], str]
BudgetFn = Callable[[Task], "WorkerBudget"]
PredicateFn = Callable[[Task], bool]
CapabilityFn = Callable[[Task, str], str]
DemandFn = Callable[[Task], int]
NotesFn = Callable[[Task], tuple[str, ...]]
LifecycleFn = Callable[[Task, str], "StagePolicy"]

STAGES = ("exploration", "implementation", "review")
JOIN_POLICIES = ("opportunistic", "quorum", "required")
FALLBACK_POLICIES = ("continue_partial", "parent_delta", "replan", "fail")


def worker_capability(_task: Task, _role: str) -> str:
    """Use the configured efficient-worker capability for this role."""
    return "worker"


def zero_demand(_task: Task) -> int:
    return 0


def no_notes(_task: Task) -> tuple[str, ...]:
    return ()


@dataclass(frozen=True)
class WorkerBudget:
    """Strategy preference envelope before Runtime safety/ceiling enforcement."""

    max_explorers: int
    max_implementers: int
    max_reviewers: int
    max_total_workers: int
    speculation: str = "medium"

    def validate(self) -> None:
        for name, value in (
            ("max_explorers", self.max_explorers),
            ("max_implementers", self.max_implementers),
            ("max_reviewers", self.max_reviewers),
            ("max_total_workers", self.max_total_workers),
        ):
            if value < 0:
                raise ValueError(f"{name} cannot be negative")
        if self.max_implementers < 1:
            raise ValueError("max_implementers must be positive")
        if self.max_total_workers < 1:
            raise ValueError("max_total_workers must be positive")
        if self.speculation not in {"low", "medium", "high"}:
            raise ValueError(f"invalid speculation level: {self.speculation}")


@dataclass(frozen=True)
class StagePolicy:
    """Strategy-owned lifecycle preference for one delegated execution stage.

    The planner normalizes worker counts and applies hard Runtime time ceilings.
    FlowPilot owns live progress/scope observation and executes the resulting
    policy without treating a wait-call timeout as a Worker timeout.
    """

    join_policy: str
    min_successful_workers: int
    idle_timeout_seconds: int
    hard_timeout_seconds: int
    cancel_if_superseded: bool = True
    cancel_stragglers_after_quorum: bool = False
    fallback_policy: str = "parent_delta"

    def validate(self) -> None:
        if self.join_policy not in JOIN_POLICIES:
            raise ValueError(f"invalid join policy: {self.join_policy}")
        if self.min_successful_workers < 0:
            raise ValueError("min_successful_workers cannot be negative")
        if self.join_policy == "opportunistic" and self.min_successful_workers != 0:
            raise ValueError("opportunistic stages must use min_successful_workers=0")
        if self.join_policy in {"quorum", "required"} and self.min_successful_workers < 1:
            raise ValueError(f"{self.join_policy} stages require at least one successful worker")
        if self.idle_timeout_seconds < 1:
            raise ValueError("idle_timeout_seconds must be positive")
        if self.hard_timeout_seconds < self.idle_timeout_seconds:
            raise ValueError("hard_timeout_seconds must be >= idle_timeout_seconds")
        if self.fallback_policy not in FALLBACK_POLICIES:
            raise ValueError(f"invalid fallback policy: {self.fallback_policy}")


def standard_lifecycle(_task: Task, stage: str) -> StagePolicy:
    """Balanced lifecycle baseline for future strategies that do not override it."""
    if stage == "exploration":
        return StagePolicy("quorum", 1, 180, 1200, True, True, "parent_delta")
    if stage == "implementation":
        return StagePolicy("required", 1, 240, 2400, False, False, "replan")
    if stage == "review":
        return StagePolicy("required", 1, 180, 1800, True, False, "parent_delta")
    raise ValueError(f"invalid lifecycle stage: {stage}")


@dataclass(frozen=True)
class StrategySpec:
    name: str
    description: str
    adaptive_route: RouteFn
    effort: EffortFn
    worker_budget: BudgetFn
    independent_review: PredicateFn
    capability: CapabilityFn = worker_capability
    exploration_bonus: DemandFn = zero_demand
    reviewer_bonus: DemandFn = zero_demand
    notes: NotesFn = no_notes
    lifecycle: LifecycleFn = standard_lifecycle
    allow_parallel_write: bool = False
    quota_sensitive: bool = False


def standard_effort(task: Task, role: str) -> str:
    """Cheap-parent / strong-worker baseline.

    Parent effort is reserved for high-value orchestration. Worker effort is one
    tier higher by default because the efficient worker model is materially
    cheaper and should absorb the deep execution loop.
    """
    if task.complexity == "critical" or task.risk == "critical":
        return "xhigh" if role == "parent" else "max"
    return "high" if role == "parent" else "xhigh"


def never(_task: Task) -> bool:
    return False


def small_low_risk_is_direct(task: Task) -> bool:
    return task.complexity == "small" and task.risk in {"low", "medium"}
