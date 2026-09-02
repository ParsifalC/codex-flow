#!/usr/bin/env python3
"""Deterministic strategy resolver and ExecutionPlan compiler for codex-flow.

FlowPilot owns semantic TaskProfile construction. This module is the single source
of truth for policy precedence, release defaults, modifiers, runtime constraints,
and the final ExecutionPlan. Strategy-specific optimization decisions are loaded
from the built-in strategy registry.
"""
from __future__ import annotations

import argparse
import json
import os
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

from strategies import all_specs as all_strategy_specs
from strategies import get as get_strategy
from strategies import names as strategy_names
from strategies.base import WorkerBudget

CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
DEFAULT_POLICY = CODEX_HOME / "codex-flow.toml"
REPO_POLICY_NAME = ".codex-flow.toml"

STRATEGIES = strategy_names()
ROUTING_MODES = ("adaptive", "direct", "delegate")
COMPLEXITIES = ("small", "routine", "complex", "critical")
LEVELS = ("low", "medium", "high", "critical")
EFFORTS = ("high", "xhigh", "max")
SCOPES = ("local", "module", "cross-module", "repo-wide")
PARALLELISM = ("none", "limited", "high")
ITERATION = ("one-shot", "iterative", "heavy-loop")
QUALITY_INTENTS = ("normal", "strong", "absolute")
REVIEW_MODES = ("auto", "standard", "strict")
FANOUT_MODES = ("auto", "conservative", "aggressive")
EFFORT_RANK = {name: idx for idx, name in enumerate(EFFORTS)}


def _release_defaults_path() -> Path:
    candidates = (
        Path(__file__).resolve().with_name("defaults.toml"),
        Path(__file__).resolve().parent.parent / "policy" / "defaults.toml",
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("codex-flow release defaults not found; reinstall codex-flow")


@dataclass(frozen=True)
class TaskProfile:
    complexity: str = "routine"
    uncertainty: str = "medium"
    risk: str = "medium"
    scope: str = "module"
    parallelism: str = "limited"
    write_conflict: str = "low"
    exploration_need: str = "medium"
    verification_cost: str = "medium"
    iteration_intensity: str = "iterative"
    writable_workstreams: int = 1
    quality_intent: str = "normal"

    def validate(self) -> None:
        if self.complexity not in COMPLEXITIES:
            raise ValueError(f"invalid complexity: {self.complexity}")
        if self.uncertainty not in LEVELS[:3]:
            raise ValueError(f"invalid uncertainty: {self.uncertainty}")
        if self.risk not in LEVELS:
            raise ValueError(f"invalid risk: {self.risk}")
        if self.scope not in SCOPES:
            raise ValueError(f"invalid scope: {self.scope}")
        if self.parallelism not in PARALLELISM:
            raise ValueError(f"invalid parallelism: {self.parallelism}")
        if self.write_conflict not in {"low", "high"}:
            raise ValueError(f"invalid write_conflict: {self.write_conflict}")
        if self.exploration_need not in LEVELS[:3]:
            raise ValueError(f"invalid exploration_need: {self.exploration_need}")
        if self.verification_cost not in LEVELS[:3]:
            raise ValueError(f"invalid verification_cost: {self.verification_cost}")
        if self.iteration_intensity not in ITERATION:
            raise ValueError(f"invalid iteration_intensity: {self.iteration_intensity}")
        if self.writable_workstreams < 1:
            raise ValueError("writable_workstreams must be positive")
        if self.quality_intent not in QUALITY_INTENTS:
            raise ValueError(f"invalid quality_intent: {self.quality_intent}")


@dataclass(frozen=True)
class Modifiers:
    review: str = "auto"
    fanout: str = "auto"

    def validate(self) -> None:
        if self.review not in REVIEW_MODES:
            raise ValueError(f"invalid review modifier: {self.review}")
        if self.fanout not in FANOUT_MODES:
            raise ValueError(f"invalid fanout modifier: {self.fanout}")


@dataclass(frozen=True)
class PolicySnapshot:
    parent_capability_policy: str
    parent_model_floor: str
    parent_min_reasoning: str
    parent_routine_reasoning: str
    parent_complex_reasoning: str
    parent_critical_reasoning: str
    worker_capability_policy: str
    worker_model: str
    worker_resolved_model: str
    worker_min_reasoning: str
    worker_routine_reasoning: str
    worker_complex_reasoning: str
    worker_critical_reasoning: str

    def validate(self) -> None:
        for label, value in (
            ("parent_min_reasoning", self.parent_min_reasoning),
            ("parent_routine_reasoning", self.parent_routine_reasoning),
            ("parent_complex_reasoning", self.parent_complex_reasoning),
            ("parent_critical_reasoning", self.parent_critical_reasoning),
            ("worker_min_reasoning", self.worker_min_reasoning),
            ("worker_routine_reasoning", self.worker_routine_reasoning),
            ("worker_complex_reasoning", self.worker_complex_reasoning),
            ("worker_critical_reasoning", self.worker_critical_reasoning),
        ):
            if value not in EFFORTS:
                raise ValueError(f"invalid {label}: {value}")


@dataclass(frozen=True)
class ResolvedPolicy:
    strategy: str
    routing: str
    modifiers: Modifiers
    capability: PolicySnapshot
    max_concurrent_threads: int
    max_repair_cycles: int
    repo_policy: str | None = None

    def validate(self) -> None:
        if self.strategy not in STRATEGIES:
            raise ValueError(f"invalid strategy: {self.strategy}")
        if self.routing not in ROUTING_MODES:
            raise ValueError(f"invalid routing mode: {self.routing}")
        self.modifiers.validate()
        self.capability.validate()
        if self.max_concurrent_threads < 1:
            raise ValueError("max_concurrent_threads must be positive")
        if self.max_repair_cycles < 0:
            raise ValueError("max_repair_cycles cannot be negative")


@dataclass(frozen=True)
class RuntimeState:
    quota_pressure: str = "unknown"
    max_concurrent_threads: int = 4
    max_repair_cycles: int = 2

    def validate(self) -> None:
        if self.quota_pressure not in {"unknown", "low", "medium", "high", "critical"}:
            raise ValueError(f"invalid quota_pressure: {self.quota_pressure}")
        if self.max_concurrent_threads < 1:
            raise ValueError("max_concurrent_threads must be positive")
        if self.max_repair_cycles < 0:
            raise ValueError("max_repair_cycles cannot be negative")


@dataclass(frozen=True)
class ExecutionPlan:
    schema_version: int
    strategy: str
    routing: str
    review_modifier: str
    fanout_modifier: str
    quality_intent: str
    parent_capability_policy: str
    parent_model_floor: str
    parent_reasoning: str
    explorer_capability_policy: str | None
    explorer_model: str | None
    explorer_reasoning: str | None
    implementer_capability_policy: str | None
    implementer_model: str | None
    implementer_reasoning: str | None
    reviewer_capability_policy: str | None
    reviewer_model: str | None
    reviewer_reasoning: str | None
    worker_budget: WorkerBudget
    exploration_workers: int
    implementation_workers: int
    reviewer_workers: int
    planned_worker_count: int
    review_mode: str
    max_repair_cycles: int
    max_concurrent_threads: int
    escalate_on_failure: bool
    quota_pressure: str
    repo_policy: str | None = None
    context_mode: str = "compact-fresh"
    notes: tuple[str, ...] = field(default_factory=tuple)

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["notes"] = list(self.notes)
        return data


def _section_body(text: str, section: str) -> re.Match[str] | None:
    return re.search(
        rf"(?ms)^\[{re.escape(section)}\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)",
        text,
    )


def policy_value(path: Path | None, section: str, key: str, default: str = "") -> str:
    if path is None:
        return default
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return default
    match = _section_body(text, section)
    if not match:
        return default
    key_match = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", match.group(1))
    if not key_match:
        return default
    value = re.sub(r"\s+#.*$", "", key_match.group(1)).strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value or default


def _policy_int(path: Path | None, section: str, key: str, default: int) -> int:
    raw = policy_value(path, section, key, str(default))
    try:
        return int(raw)
    except ValueError:
        return default


def _release_value(section: str, key: str, fallback: str = "") -> str:
    return policy_value(_release_defaults_path(), section, key, fallback)


def _release_int(section: str, key: str, fallback: int) -> int:
    return _policy_int(_release_defaults_path(), section, key, fallback)


def _quoted(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def set_policy_value(path: Path, section: str, key: str, value: str) -> None:
    if not path.exists():
        raise FileNotFoundError(f"policy not found: {path}")
    text = path.read_text(encoding="utf-8-sig")
    match = _section_body(text, section)
    line = f"{key} = {_quoted(value)}"
    if match:
        body = match.group(1)
        key_re = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
        if key_re.search(body):
            body = key_re.sub(line, body)
        else:
            if body and not body.endswith("\n"):
                body += "\n"
            body += line + "\n"
        text = text[: match.start(1)] + body + text[match.end(1) :]
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        if text and not text.endswith("\n\n"):
            text += "\n"
        text += f"[{section}]\n{line}\n"
    path.write_text(text, encoding="utf-8")


def _effort_max(*values: str) -> str:
    valid = [value for value in values if value in EFFORT_RANK]
    if not valid:
        raise ValueError("no valid reasoning effort supplied")
    return max(valid, key=lambda value: EFFORT_RANK[value])


def _effort_next(value: str) -> str:
    if value not in EFFORT_RANK:
        raise ValueError(f"invalid reasoning effort: {value}")
    return EFFORTS[min(len(EFFORTS) - 1, EFFORT_RANK[value] + 1)]


def _release_capability() -> PolicySnapshot:
    worker_model = _release_value("models", "worker_model")
    snapshot = PolicySnapshot(
        parent_capability_policy=_release_value("models", "parent_policy"),
        parent_model_floor=_release_value("models", "parent_min_model"),
        parent_min_reasoning=_release_value("reasoning.parent", "minimum"),
        parent_routine_reasoning=_release_value("reasoning.parent", "routine"),
        parent_complex_reasoning=_release_value("reasoning.parent", "complex"),
        parent_critical_reasoning=_release_value("reasoning.parent", "critical"),
        worker_capability_policy=_release_value("models", "worker_policy"),
        worker_model="auto",
        worker_resolved_model=worker_model,
        worker_min_reasoning=_release_value("reasoning.worker", "minimum"),
        worker_routine_reasoning=_release_value("reasoning.worker", "routine"),
        worker_complex_reasoning=_release_value("reasoning.worker", "complex"),
        worker_critical_reasoning=_release_value("reasoning.worker", "critical"),
    )
    snapshot.validate()
    return snapshot


def discover_repo_policy(start: Path | None = None) -> Path | None:
    current = (start or Path.cwd()).resolve()
    if current.is_file():
        current = current.parent
    while True:
        candidate = current / REPO_POLICY_NAME
        if candidate.is_file() and candidate.resolve() != DEFAULT_POLICY.resolve():
            return candidate
        if (current / ".git").exists() or current.parent == current:
            return None
        current = current.parent


def _user_capability(path: Path) -> PolicySnapshot:
    release = _release_capability()
    parent_floor = policy_value(path, "parent", "min_reasoning_effort", release.parent_min_reasoning)
    worker_floor = policy_value(path, "worker", "min_reasoning_effort", release.worker_min_reasoning)
    snapshot = PolicySnapshot(
        parent_capability_policy=policy_value(path, "parent", "model_policy", release.parent_capability_policy),
        parent_model_floor=policy_value(path, "parent", "min_model", release.parent_model_floor),
        parent_min_reasoning=parent_floor,
        parent_routine_reasoning=policy_value(path, "parent", "routine_effort", release.parent_routine_reasoning),
        parent_complex_reasoning=policy_value(path, "parent", "complex_effort", release.parent_complex_reasoning),
        parent_critical_reasoning=policy_value(path, "parent", "critical_effort", release.parent_critical_reasoning),
        worker_capability_policy=policy_value(path, "worker", "model_policy", release.worker_capability_policy),
        worker_model=policy_value(path, "worker", "model", "auto"),
        worker_resolved_model=policy_value(path, "worker", "resolved_model", release.worker_resolved_model),
        worker_min_reasoning=worker_floor,
        worker_routine_reasoning=policy_value(path, "worker", "routine_effort", release.worker_routine_reasoning),
        worker_complex_reasoning=policy_value(path, "worker", "complex_effort", release.worker_complex_reasoning),
        worker_critical_reasoning=policy_value(path, "worker", "critical_effort", release.worker_critical_reasoning),
    )
    snapshot.validate()
    return snapshot


def _raise_capability_floors(base: PolicySnapshot, repo: Path | None) -> PolicySnapshot:
    if repo is None:
        base.validate()
        return base

    def repo_effort(section: str, key: str, fallback: str) -> str:
        value = policy_value(repo, section, key, "")
        return _effort_max(fallback, value) if value else fallback

    result = PolicySnapshot(
        parent_capability_policy=base.parent_capability_policy,
        parent_model_floor=base.parent_model_floor,
        parent_min_reasoning=repo_effort("parent", "min_reasoning_effort", base.parent_min_reasoning),
        parent_routine_reasoning=repo_effort("parent", "routine_effort", base.parent_routine_reasoning),
        parent_complex_reasoning=repo_effort("parent", "complex_effort", base.parent_complex_reasoning),
        parent_critical_reasoning=repo_effort("parent", "critical_effort", base.parent_critical_reasoning),
        worker_capability_policy=base.worker_capability_policy,
        worker_model=base.worker_model,
        worker_resolved_model=base.worker_resolved_model,
        worker_min_reasoning=repo_effort("worker", "min_reasoning_effort", base.worker_min_reasoning),
        worker_routine_reasoning=repo_effort("worker", "routine_effort", base.worker_routine_reasoning),
        worker_complex_reasoning=repo_effort("worker", "complex_effort", base.worker_complex_reasoning),
        worker_critical_reasoning=repo_effort("worker", "critical_effort", base.worker_critical_reasoning),
    )
    result.validate()
    return result


def resolve_policy(user_policy: Path, repo_policy: Path | None = None) -> ResolvedPolicy:
    """Resolve release + user + already-selected repository policy."""
    repo = repo_policy
    strategy = policy_value(user_policy, "strategy", "profile", _release_value("strategy", "profile"))
    routing = policy_value(user_policy, "routing", "mode", _release_value("routing", "mode"))
    review = policy_value(user_policy, "modifiers", "review", _release_value("modifiers", "review"))
    fanout = policy_value(user_policy, "modifiers", "fanout", _release_value("modifiers", "fanout"))
    max_threads = _policy_int(user_policy, "runtime", "max_concurrent_threads", _release_int("runtime", "max_concurrent_threads", 4))
    max_repairs = _policy_int(user_policy, "runtime", "max_repair_cycles", _release_int("runtime", "max_repair_cycles", 2))

    if repo is not None:
        strategy = policy_value(repo, "strategy", "profile", strategy)
        routing = policy_value(repo, "routing", "mode", routing)
        review = policy_value(repo, "modifiers", "review", review)
        fanout = policy_value(repo, "modifiers", "fanout", fanout)
        repo_threads = policy_value(repo, "runtime", "max_concurrent_threads", "")
        repo_repairs = policy_value(repo, "runtime", "max_repair_cycles", "")
        if repo_threads:
            try:
                max_threads = min(max_threads, int(repo_threads))
            except ValueError:
                pass
        if repo_repairs:
            try:
                max_repairs = min(max_repairs, int(repo_repairs))
            except ValueError:
                pass

    resolved = ResolvedPolicy(
        strategy=strategy,
        routing=routing,
        modifiers=Modifiers(review=review, fanout=fanout),
        capability=_raise_capability_floors(_user_capability(user_policy), repo),
        max_concurrent_threads=max_threads,
        max_repair_cycles=max_repairs,
        repo_policy=str(repo) if repo is not None else None,
    )
    resolved.validate()
    return resolved


def _configured_effort(task: TaskProfile, policy: PolicySnapshot, role: str) -> str:
    if role == "parent":
        floor, routine = policy.parent_min_reasoning, policy.parent_routine_reasoning
        complex_effort, critical = policy.parent_complex_reasoning, policy.parent_critical_reasoning
    else:
        floor, routine = policy.worker_min_reasoning, policy.worker_routine_reasoning
        complex_effort, critical = policy.worker_complex_reasoning, policy.worker_critical_reasoning
    if task.complexity == "critical" or task.risk == "critical":
        target = critical
    elif task.complexity == "complex" or task.risk == "high":
        target = complex_effort
    else:
        target = routine
    return _effort_max(floor, target)


def quota_pressure_from_snapshot(snapshot: dict[str, Any] | None) -> str:
    if not isinstance(snapshot, dict):
        return "unknown"
    rate_limits = snapshot.get("rateLimits")
    if not isinstance(rate_limits, dict):
        return "unknown"
    used_values: list[float] = []
    for slot in ("primary", "secondary"):
        window = rate_limits.get(slot)
        if not isinstance(window, dict):
            continue
        raw = window.get("usedPercent")
        if isinstance(raw, (int, float)) and not isinstance(raw, bool):
            used_values.append(float(raw))
    if not used_values:
        return "unknown"
    used = max(used_values)
    if used >= 90:
        return "critical"
    if used >= 75:
        return "high"
    if used >= 50:
        return "medium"
    return "low"


def detect_quota_pressure() -> str:
    override = os.environ.get("CODEX_FLOW_QUOTA_PRESSURE")
    if override in {"unknown", "low", "medium", "high", "critical"}:
        return override
    try:
        from telemetry_core.app_server import AppServer
        with AppServer() as app:
            if not app.available:
                return "unknown"
            return quota_pressure_from_snapshot(app.rate_limits())
    except Exception:
        return "unknown"


def _desired_role_capability(task: TaskProfile, spec, policy: PolicySnapshot, role: str) -> tuple[str, str | None]:
    target = spec.capability(task, role)
    if target == "parent":
        model = None if policy.parent_model_floor == "auto" else policy.parent_model_floor
        return policy.parent_capability_policy, model
    if target == "worker":
        return policy.worker_capability_policy, policy.worker_resolved_model or policy.worker_model
    raise ValueError(f"invalid capability target for {role}: {target}")


def _exploration_demand(task: TaskProfile, bonus: int = 0) -> int:
    if task.parallelism == "none":
        return 0
    if bonus < 0:
        raise ValueError("exploration bonus cannot be negative")
    score = 0
    score += {"low": 0, "medium": 1, "high": 2}[task.uncertainty]
    score += {"low": 0, "medium": 1, "high": 2}[task.exploration_need]
    score += {"small": 0, "routine": 0, "complex": 1, "critical": 2}[task.complexity]
    score += {"local": 0, "module": 0, "cross-module": 1, "repo-wide": 2}[task.scope]
    if task.verification_cost == "high":
        score += 1
    score += bonus
    if score <= 1:
        return 0
    return min(4, max(1, (score + 1) // 2))


def _reviewer_demand(task: TaskProfile, review_mode: str, bonus: int = 0) -> int:
    if review_mode != "independent+parent":
        return 0
    if bonus < 0:
        raise ValueError("reviewer bonus cannot be negative")
    demand = 1 + bonus
    if task.complexity == "critical" or task.risk == "critical" or task.verification_cost == "high":
        demand += 1
    return demand


def _fit_total_worker_budget(
    exploration_workers: int,
    implementation_workers: int,
    reviewer_workers: int,
    budget: WorkerBudget,
) -> tuple[int, int, int]:
    while exploration_workers + implementation_workers + reviewer_workers > budget.max_total_workers:
        if exploration_workers > 0:
            exploration_workers -= 1
        elif implementation_workers > 1:
            implementation_workers -= 1
        elif reviewer_workers > 1:
            reviewer_workers -= 1
        else:
            break
    return exploration_workers, implementation_workers, reviewer_workers


def compile_plan(
    task: TaskProfile,
    *,
    strategy: str = "efficient",
    routing_mode: str = "adaptive",
    modifiers: Modifiers | None = None,
    policy: PolicySnapshot | None = None,
    runtime: RuntimeState | None = None,
    repo_policy: str | None = None,
) -> ExecutionPlan:
    task.validate()
    modifiers = modifiers or Modifiers()
    modifiers.validate()
    policy = policy or _release_capability()
    policy.validate()
    runtime = runtime or RuntimeState(
        max_concurrent_threads=_release_int("runtime", "max_concurrent_threads", 4),
        max_repair_cycles=_release_int("runtime", "max_repair_cycles", 2),
    )
    runtime.validate()
    spec = get_strategy(strategy)
    budget = spec.worker_budget(task)
    budget.validate()
    if routing_mode not in ROUTING_MODES:
        raise ValueError(f"invalid routing mode: {routing_mode}")

    route = spec.adaptive_route(task) if routing_mode == "adaptive" else routing_mode
    delegated = route == "delegate"
    parent_effort = _effort_max(
        _configured_effort(task, policy, "parent"),
        spec.effort(task, "parent"),
    )
    role_efforts = {
        role: _effort_max(
            _configured_effort(task, policy, "worker"),
            spec.effort(task, role),
            _effort_next(parent_effort),
        )
        for role in ("explorer", "implementer", "reviewer")
    }

    exploration_workers = 0
    implementation_workers = 0
    reviewer_workers = 0
    review_mode = "parent"
    concurrency = 1
    notes: list[str] = list(spec.notes(task))

    if parent_effort == "max" and delegated:
        notes.append("parent reasoning is already max; worker-role reasoning cannot exceed max and is held at max")

    if delegated:
        implementation_workers = 1
        exploration_workers = min(
            _exploration_demand(task, spec.exploration_bonus(task)),
            budget.max_explorers,
            runtime.max_concurrent_threads,
        )

        proven_writable = min(
            task.writable_workstreams,
            runtime.max_concurrent_threads,
            budget.max_implementers,
        )
        allow_parallel_write = (
            task.parallelism == "high"
            and task.write_conflict == "low"
            and proven_writable >= 2
        )
        if allow_parallel_write and (spec.allow_parallel_write or modifiers.fanout == "aggressive"):
            implementation_workers = proven_writable
            notes.append(
                f"parallel writable execution authorized across {implementation_workers} proven isolated workstreams"
            )

        if modifiers.fanout == "conservative":
            exploration_workers = min(exploration_workers, 1)
            implementation_workers = 1
        elif modifiers.fanout == "aggressive" and task.parallelism == "high":
            exploration_workers = min(
                budget.max_explorers,
                runtime.max_concurrent_threads,
                max(exploration_workers, 2),
            )

        if modifiers.review == "strict":
            review_mode = "independent+parent"
        elif modifiers.review == "standard":
            review_mode = "parent"
        elif spec.independent_review(task):
            review_mode = "independent+parent"

        reviewer_workers = min(
            _reviewer_demand(task, review_mode, spec.reviewer_bonus(task)),
            budget.max_reviewers,
            runtime.max_concurrent_threads,
        )

        if task.parallelism == "none":
            exploration_workers = 0
            implementation_workers = 1
            reviewer_workers = min(reviewer_workers, 1)

        exploration_workers, implementation_workers, reviewer_workers = _fit_total_worker_budget(
            exploration_workers,
            implementation_workers,
            reviewer_workers,
            budget,
        )
        concurrency = min(
            runtime.max_concurrent_threads,
            max(1, exploration_workers, implementation_workers, reviewer_workers),
        )

    if runtime.quota_pressure in {"high", "critical"}:
        notes.append("quota pressure is high; speculative fan-out and repair budget are constrained before quality floors")
        if spec.quota_sensitive:
            exploration_workers = min(exploration_workers, 1)
            implementation_workers = min(implementation_workers, 1)
            reviewer_workers = min(reviewer_workers, 1)
            concurrency = min(runtime.max_concurrent_threads, max(1, exploration_workers, implementation_workers, reviewer_workers))

    repair_cycles = runtime.max_repair_cycles
    if runtime.quota_pressure == "critical" and spec.quota_sensitive:
        repair_cycles = min(repair_cycles, 1)

    if route == "direct":
        exploration_workers = 0
        implementation_workers = 0
        reviewer_workers = 0
        concurrency = 1
        explorer_capability_policy: str | None = None
        explorer_model: str | None = None
        explorer_reasoning: str | None = None
        implementer_capability_policy: str | None = None
        implementer_model: str | None = None
        implementer_reasoning: str | None = None
        reviewer_capability_policy: str | None = None
        reviewer_model: str | None = None
        reviewer_reasoning: str | None = None
        review_mode = "parent"
    else:
        if exploration_workers > 0:
            explorer_capability_policy, explorer_model = _desired_role_capability(task, spec, policy, "explorer")
            explorer_reasoning = role_efforts["explorer"]
            if explorer_capability_policy != policy.worker_capability_policy:
                notes.append("explorer role requests parent-class capability; use runtime override when supported")
        else:
            explorer_capability_policy = None
            explorer_model = None
            explorer_reasoning = None

        implementer_capability_policy, implementer_model = _desired_role_capability(task, spec, policy, "implementer")
        implementer_reasoning = role_efforts["implementer"]
        if implementer_capability_policy != policy.worker_capability_policy:
            notes.append("implementer role requests parent-class capability; use runtime override when supported")

        if reviewer_workers > 0:
            reviewer_capability_policy, reviewer_model = _desired_role_capability(task, spec, policy, "reviewer")
            reviewer_reasoning = role_efforts["reviewer"]
            if reviewer_capability_policy != policy.worker_capability_policy:
                notes.append("reviewer role requests parent-class capability; use runtime override when supported")
        else:
            reviewer_capability_policy = None
            reviewer_model = None
            reviewer_reasoning = None

    planned_worker_count = exploration_workers + implementation_workers + reviewer_workers
    return ExecutionPlan(
        schema_version=7,
        strategy=strategy,
        routing=route,
        review_modifier=modifiers.review,
        fanout_modifier=modifiers.fanout,
        quality_intent=task.quality_intent,
        parent_capability_policy=policy.parent_capability_policy,
        parent_model_floor=policy.parent_model_floor,
        parent_reasoning=parent_effort,
        explorer_capability_policy=explorer_capability_policy,
        explorer_model=explorer_model,
        explorer_reasoning=explorer_reasoning,
        implementer_capability_policy=implementer_capability_policy,
        implementer_model=implementer_model,
        implementer_reasoning=implementer_reasoning,
        reviewer_capability_policy=reviewer_capability_policy,
        reviewer_model=reviewer_model,
        reviewer_reasoning=reviewer_reasoning,
        worker_budget=budget,
        exploration_workers=exploration_workers,
        implementation_workers=implementation_workers,
        reviewer_workers=reviewer_workers,
        planned_worker_count=planned_worker_count,
        review_mode=review_mode,
        max_repair_cycles=repair_cycles,
        max_concurrent_threads=concurrency,
        escalate_on_failure=True,
        quota_pressure=runtime.quota_pressure,
        repo_policy=repo_policy,
        notes=tuple(notes),
    )


def configured_strategy(path: Path) -> str:
    return policy_value(path, "strategy", "profile", _release_value("strategy", "profile"))


def configured_routing(path: Path) -> str:
    return policy_value(path, "routing", "mode", _release_value("routing", "mode"))


def _print_profiles() -> None:
    for spec in all_strategy_specs():
        print(f"{spec.name:10} {spec.description}")


def _task_from_args(ns: argparse.Namespace) -> TaskProfile:
    return TaskProfile(
        complexity=ns.complexity,
        uncertainty=ns.uncertainty,
        risk=ns.risk,
        scope=ns.scope,
        parallelism=ns.parallelism,
        write_conflict=ns.write_conflict,
        exploration_need=ns.exploration_need,
        verification_cost=ns.verification_cost,
        iteration_intensity=ns.iteration_intensity,
        writable_workstreams=ns.writable_workstreams,
        quality_intent=ns.quality_intent,
    )


def _repo_arg(value: str | None) -> tuple[Path | None, bool]:
    if not value or value == "auto":
        return discover_repo_policy(), False
    if value == "none":
        return None, True
    return Path(value), False


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="codex-flow strategy")
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("profiles")
    show = sub.add_parser("show")
    show.add_argument("--json", action="store_true")
    show.add_argument("--effective", action="store_true")
    show.add_argument("--repo-policy", default="auto")

    set_cmd = sub.add_parser("set")
    set_cmd.add_argument("profile", choices=STRATEGIES)

    routing = sub.add_parser("routing")
    routing.add_argument("mode", nargs="?", choices=ROUTING_MODES)

    plan = sub.add_parser("plan")
    plan.add_argument("--profile", choices=STRATEGIES)
    plan.add_argument("--routing", choices=ROUTING_MODES)
    plan.add_argument("--review", choices=REVIEW_MODES)
    plan.add_argument("--fanout", choices=FANOUT_MODES)
    plan.add_argument("--repo-policy", default="auto")
    plan.add_argument("--complexity", choices=COMPLEXITIES, default="routine")
    plan.add_argument("--uncertainty", choices=LEVELS[:3], default="medium")
    plan.add_argument("--risk", choices=LEVELS, default="medium")
    plan.add_argument("--scope", choices=SCOPES, default="module")
    plan.add_argument("--parallelism", choices=PARALLELISM, default="limited")
    plan.add_argument("--write-conflict", choices=("low", "high"), default="low")
    plan.add_argument("--exploration-need", choices=LEVELS[:3], default="medium")
    plan.add_argument("--verification-cost", choices=LEVELS[:3], default="medium")
    plan.add_argument("--iteration-intensity", choices=ITERATION, default="iterative")
    plan.add_argument("--writable-workstreams", type=int, default=1)
    plan.add_argument("--quality-intent", choices=QUALITY_INTENTS, default="normal")
    plan.add_argument(
        "--quota-pressure",
        choices=("auto", "unknown", "low", "medium", "high", "critical"),
        default="auto",
    )
    plan.add_argument("--max-threads", type=int)
    plan.add_argument("--max-repairs", type=int)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_parser()
    ns = parser.parse_args(list(argv) if argv is not None else None)
    command = ns.command or "show"

    if command == "profiles":
        _print_profiles()
        return 0
    if command == "show":
        if getattr(ns, "effective", False):
            repo, _disabled = _repo_arg(getattr(ns, "repo_policy", "auto"))
            resolved = resolve_policy(ns.policy, repo)
            result = {
                "strategy": resolved.strategy,
                "routing": resolved.routing,
                "review": resolved.modifiers.review,
                "fanout": resolved.modifiers.fanout,
                "repo_policy": resolved.repo_policy,
                "valid": True,
            }
            if getattr(ns, "json", False):
                print(json.dumps(result, ensure_ascii=False, indent=2))
            else:
                print(
                    f"strategy={resolved.strategy} routing={resolved.routing} "
                    f"review={resolved.modifiers.review} fanout={resolved.modifiers.fanout}"
                )
            return 0
        strategy = configured_strategy(ns.policy)
        routing_mode = configured_routing(ns.policy)
        valid = strategy in STRATEGIES and routing_mode in ROUTING_MODES
        if getattr(ns, "json", False):
            print(json.dumps({"strategy": strategy, "routing": routing_mode, "valid": valid}, ensure_ascii=False, indent=2))
        else:
            print(f"strategy={strategy} routing={routing_mode}")
        return 0 if valid else 2
    if command == "set":
        set_policy_value(ns.policy, "strategy", "profile", ns.profile)
        print(f"strategy={ns.profile}")
        return 0
    if command == "routing":
        if ns.mode is None:
            print(configured_routing(ns.policy))
            return 0
        set_policy_value(ns.policy, "routing", "mode", ns.mode)
        print(f"routing={ns.mode}")
        return 0
    if command == "plan":
        repo, _disabled = _repo_arg(ns.repo_policy)
        resolved = resolve_policy(ns.policy, repo)
        strategy = ns.profile or resolved.strategy
        routing_mode = ns.routing or resolved.routing
        modifiers = Modifiers(
            review=ns.review or resolved.modifiers.review,
            fanout=ns.fanout or resolved.modifiers.fanout,
        )
        max_threads = resolved.max_concurrent_threads
        if ns.max_threads is not None:
            max_threads = min(max_threads, ns.max_threads)
        max_repairs = resolved.max_repair_cycles
        if ns.max_repairs is not None:
            max_repairs = min(max_repairs, ns.max_repairs)
        quota_pressure = detect_quota_pressure() if ns.quota_pressure == "auto" else ns.quota_pressure
        plan_obj = compile_plan(
            _task_from_args(ns),
            strategy=strategy,
            routing_mode=routing_mode,
            modifiers=modifiers,
            policy=resolved.capability,
            runtime=RuntimeState(
                quota_pressure=quota_pressure,
                max_concurrent_threads=max_threads,
                max_repair_cycles=max_repairs,
            ),
            repo_policy=resolved.repo_policy,
        )
        print(json.dumps(plan_obj.to_dict(), ensure_ascii=False, indent=2))
        return 0
    parser.error(f"unsupported command: {command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
