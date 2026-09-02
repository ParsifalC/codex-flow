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
