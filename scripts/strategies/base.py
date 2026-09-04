"""Shared contracts for built-in codex-flow strategy modules."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Tuple

Task = Any
RouteFn = Callable[[Task], str]
EffortFn = Callable[[Task, str], str]
BudgetFn = Callable[[Task], "WorkerBudget"]
PredicateFn = Callable[[Task], bool]
CapabilityFn = Callable[[Task, str], str]
DemandFn = Callable[[Task], int]
NotesFn = Callable[[Task], Tuple[str, ...]]
LifecycleFn = Callable[[Task, str], "StagePolicy"]
TaskBudgetFn = Callable[[Task], "TaskBudgetPolicy | None"]
ReasoningRolloutFn = Callable[
    [Task, str, "ReasoningRolloutPolicy", str, str], "ReasoningRolloutDecision"
]

STAGES = ("exploration", "implementation", "review")
JOIN_POLICIES = ("opportunistic", "quorum", "required")
FALLBACK_POLICIES = ("continue_partial", "parent_delta", "replan", "fail")
WORK_UNIT_MODES = ("single", "bounded")


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
class TaskBudgetPolicy:
    """Cumulative task budget carried across Worker attempts and replans.

    This is deliberately separate from :class:`StagePolicy`: stage lifecycle
    limits describe one Worker stage, while these counters are reservations in
    a durable task ledger and therefore cannot be reset by recompiling a plan.
    """

    soft_timeout_seconds: int
    hard_timeout_seconds: int
    max_work_units: int
    max_implementation_attempts: int
    max_replans: int
    max_replacements: int

    @classmethod
    def from_dict(cls, value: Any) -> "TaskBudgetPolicy":
        if type(value) is not dict:
            raise ValueError("task budget policy must be an object")
        required = (
            "soft_timeout_seconds",
            "hard_timeout_seconds",
            "max_work_units",
            "max_implementation_attempts",
            "max_replans",
            "max_replacements",
        )
        missing = [name for name in required if name not in value]
        if missing:
            raise ValueError(f"task budget policy missing fields: {missing}")
        unknown = sorted(set(value).difference(required))
        if unknown:
            raise ValueError(f"task budget policy has unknown fields: {unknown}")
        policy = cls(**{name: value[name] for name in required})
        policy.validate()
        return policy

    def validate(self) -> None:
        for name, value in (
            ("soft_timeout_seconds", self.soft_timeout_seconds),
            ("hard_timeout_seconds", self.hard_timeout_seconds),
            ("max_work_units", self.max_work_units),
            ("max_implementation_attempts", self.max_implementation_attempts),
            ("max_replans", self.max_replans),
            ("max_replacements", self.max_replacements),
        ):
            # bool is an int subclass, but accepting it here makes malformed
            # JSON policy silently turn into a real budget.
            if type(value) is not int:
                raise ValueError(f"{name} must be an integer")
            if value < 0:
                raise ValueError(f"{name} cannot be negative")
        if self.soft_timeout_seconds < 1:
            raise ValueError("soft_timeout_seconds must be positive")
        if self.hard_timeout_seconds <= self.soft_timeout_seconds:
            raise ValueError("hard_timeout_seconds must be greater than soft_timeout_seconds")
        if self.max_work_units < 1:
            raise ValueError("max_work_units must be positive")
        if self.max_implementation_attempts < 1:
            raise ValueError("max_implementation_attempts must be positive")


REASONING_ROLLOUT_MODES = ("legacy", "shadow", "adaptive")
REASONING_EFFORTS = ("high", "xhigh", "max")


@dataclass(frozen=True)
class ReasoningRolloutPolicy:
    """Optional efficient-worker reasoning rollout configuration."""

    mode: str = "shadow"
    minimum: str = "high"
    routine: str = "high"
    complex: str = "xhigh"
    critical: str = "max"

    @classmethod
    def from_dict(cls, value: Any) -> "ReasoningRolloutPolicy":
        if type(value) is not dict:
            raise ValueError("reasoning rollout policy must be an object")
        fields = ("mode", "minimum", "routine", "complex", "critical")
        unknown = sorted(set(value).difference(fields))
        if unknown:
            raise ValueError(f"reasoning rollout policy has unknown fields: {unknown}")
        policy = cls(**{name: value[name] for name in fields if name in value})
        policy.validate()
        return policy

    def validate(self) -> None:
        if type(self.mode) is not str or self.mode not in REASONING_ROLLOUT_MODES:
            raise ValueError(f"invalid reasoning rollout mode: {self.mode}")
        for name, value in (
            ("minimum", self.minimum),
            ("routine", self.routine),
            ("complex", self.complex),
            ("critical", self.critical),
        ):
            if type(value) is not str or value not in REASONING_EFFORTS:
                raise ValueError(f"invalid reasoning rollout {name}: {value}")


@dataclass(frozen=True)
class ReasoningRolloutDecision:
    """Planner output comparing legacy and rollout-selected Worker effort."""

    mode: str
    legacy_worker_reasoning: str
    proposed_worker_reasoning: str
    selected_worker_reasoning: str
    applied: bool

    def validate(self) -> None:
        if type(self.mode) is not str or self.mode not in REASONING_ROLLOUT_MODES:
            raise ValueError(f"invalid reasoning rollout mode: {self.mode}")
        for name, value in (
            ("legacy_worker_reasoning", self.legacy_worker_reasoning),
            ("proposed_worker_reasoning", self.proposed_worker_reasoning),
            ("selected_worker_reasoning", self.selected_worker_reasoning),
        ):
            if type(value) is not str or value not in REASONING_EFFORTS:
                raise ValueError(f"invalid {name}: {value}")
        if type(self.applied) is not bool:
            raise ValueError("reasoning rollout applied must be boolean")


@dataclass(frozen=True)
class StagePolicy:
    """Strategy-owned lifecycle preference for one delegated execution stage.

    The planner normalizes worker counts and applies hard Runtime time ceilings.
    FlowPilot owns live progress/scope observation and executes the resulting
    policy without treating a wait-call timeout as a Worker timeout. A soft
    timeout is an advisory convergence/checkpoint budget and never implies
    cancellation by itself. `max_worker_repair_attempts`, when set on an
    implementation stage, bounds local validation-failure fix loops inside one
    Worker and is independent from Parent-level `max_repair_cycles`.

    `work_unit_mode=bounded` requires Parent to partition implementation into
    multiple acceptance-bounded units and join back to Parent between units.
    This is a logical execution boundary, not permission for overlapping writers.
    `maximum_work_units`, when set, is a plan-level manifest bound; it does not
    create additional worker capacity. `require_write_paths` opts a new bounded
    policy into path-level preflight validation.
    """

    join_policy: str
    min_successful_workers: int
    idle_timeout_seconds: int
    hard_timeout_seconds: int
    cancel_if_superseded: bool = True
    cancel_stragglers_after_quorum: bool = False
    fallback_policy: str = "parent_delta"
    soft_timeout_seconds: int | None = None
    max_worker_repair_attempts: int | None = None
    work_unit_mode: str = "single"
    minimum_work_units: int = 1
    join_between_work_units: bool = False
    maximum_work_units: int | None = None
    require_write_paths: bool = False

    def validate(self) -> None:
        for name, value in (
            ("min_successful_workers", self.min_successful_workers),
            ("idle_timeout_seconds", self.idle_timeout_seconds),
            ("hard_timeout_seconds", self.hard_timeout_seconds),
            ("minimum_work_units", self.minimum_work_units),
        ):
            if type(value) is not int:
                raise ValueError(f"{name} must be an integer")
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
        if self.soft_timeout_seconds is not None:
            if type(self.soft_timeout_seconds) is not int:
                raise ValueError("soft_timeout_seconds must be an integer when set")
            if self.soft_timeout_seconds < 1:
                raise ValueError("soft_timeout_seconds must be positive when set")
            if self.soft_timeout_seconds >= self.hard_timeout_seconds:
                raise ValueError("soft_timeout_seconds must be lower than hard_timeout_seconds")
        if self.max_worker_repair_attempts is not None:
            if type(self.max_worker_repair_attempts) is not int:
                raise ValueError("max_worker_repair_attempts must be an integer when set")
            if self.max_worker_repair_attempts < 0:
                raise ValueError("max_worker_repair_attempts cannot be negative")
        if self.work_unit_mode not in WORK_UNIT_MODES:
            raise ValueError(f"invalid work_unit_mode: {self.work_unit_mode}")
        if self.minimum_work_units < 1:
            raise ValueError("minimum_work_units must be positive")
        if type(self.join_between_work_units) is not bool:
            raise ValueError("join_between_work_units must be boolean")
        if self.maximum_work_units is not None:
            if type(self.maximum_work_units) is not int:
                raise ValueError("maximum_work_units must be an integer when set")
            if self.maximum_work_units < 1:
                raise ValueError("maximum_work_units must be positive when set")
        if self.work_unit_mode == "single":
            if self.minimum_work_units != 1:
                raise ValueError("single work-unit mode requires minimum_work_units=1")
            if self.join_between_work_units:
                raise ValueError("single work-unit mode cannot join between work units")
            if self.maximum_work_units is not None and self.maximum_work_units != 1:
                raise ValueError("single work-unit mode requires maximum_work_units=1")
        elif not self.join_between_work_units:
            raise ValueError("bounded work-unit mode requires a Parent join between work units")
        elif self.maximum_work_units is not None and self.maximum_work_units < self.minimum_work_units:
            raise ValueError("bounded work-unit mode requires maximum_work_units >= minimum_work_units")
        if type(self.require_write_paths) is not bool:
            raise ValueError("require_write_paths must be boolean")
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
    task_budget: TaskBudgetFn | None = None
    reasoning_rollout: ReasoningRolloutFn | None = None


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
