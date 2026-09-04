#!/usr/bin/env python3
"""Deterministic Worker lifecycle evaluator for FlowPilot.

This module is copied automatically with the strategy package by both Unix and
Windows installers. It turns observable Worker facts plus an ExecutionPlan
StagePolicy into a deterministic lifecycle decision. Semantic scope overlap
remains a Parent responsibility; timing/state transitions, checkpoint harvest,
cancellation requirements, remaining-delta replans, and writable replacement
fencing do not.
"""
from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass
from typing import Any, Iterable

FALLBACK_ACTIONS = {
    "continue_partial": "continue_partial",
    "parent_delta": "parent_delta",
    "replan": "replan",
    "fail": "fail",
}
JOIN_POLICIES = {"opportunistic", "quorum", "required"}
WRITER_FALLBACKS = {"parent_delta", "replan"}
EPOCH_MILLISECONDS_THRESHOLD = 100_000_000_000
PROGRESS_QUALITIES = {"meaningful", "activity_only", "none"}
CHECKPOINT_STATUSES = {"not_requested", "requested", "received", "harvested"}
REPLAN_SCOPES = {"uncovered_scope", "checkpoint_remaining_delta"}
CHECKPOINT_REUSE_MODES = {"retained_workspace", "harvested_snapshot_only"}


@dataclass(frozen=True)
class LifecyclePolicy:
    join_policy: str
    min_successful_workers: int
    idle_timeout_seconds: float
    hard_timeout_seconds: float
    cancel_if_superseded: bool
    cancel_stragglers_after_quorum: bool
    fallback_policy: str
    soft_timeout_seconds: float | None = None

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "LifecyclePolicy":
        required = {
            "join_policy",
            "min_successful_workers",
            "idle_timeout_seconds",
            "hard_timeout_seconds",
            "cancel_if_superseded",
            "cancel_stragglers_after_quorum",
            "fallback_policy",
        }
        missing = required.difference(value)
        if missing:
            raise ValueError(f"stage policy missing fields: {sorted(missing)}")
        for key in ("cancel_if_superseded", "cancel_stragglers_after_quorum"):
            if not isinstance(value[key], bool):
                raise ValueError(f"{key} must be boolean")
        raw_soft_timeout = value.get("soft_timeout_seconds")
        policy = cls(
            join_policy=str(value["join_policy"]),
            min_successful_workers=int(value["min_successful_workers"]),
            idle_timeout_seconds=float(value["idle_timeout_seconds"]),
            hard_timeout_seconds=float(value["hard_timeout_seconds"]),
            cancel_if_superseded=value["cancel_if_superseded"],
            cancel_stragglers_after_quorum=value["cancel_stragglers_after_quorum"],
            fallback_policy=str(value["fallback_policy"]),
            soft_timeout_seconds=(None if raw_soft_timeout is None else float(raw_soft_timeout)),
        )
        policy.validate()
        return policy

    def validate(self) -> None:
        if self.join_policy not in JOIN_POLICIES:
            raise ValueError(f"invalid join policy: {self.join_policy}")
        if self.min_successful_workers < 0:
            raise ValueError("min_successful_workers cannot be negative")
        if self.join_policy == "opportunistic" and self.min_successful_workers != 0:
            raise ValueError("opportunistic stage must use min_successful_workers=0")
        if self.join_policy != "opportunistic" and self.min_successful_workers < 1:
            raise ValueError(f"{self.join_policy} stage requires at least one successful worker")
        if self.idle_timeout_seconds <= 0:
            raise ValueError("idle_timeout_seconds must be positive")
        if self.hard_timeout_seconds < self.idle_timeout_seconds:
            raise ValueError("hard_timeout_seconds must be >= idle_timeout_seconds")
        if self.soft_timeout_seconds is not None:
            if self.soft_timeout_seconds <= 0:
                raise ValueError("soft_timeout_seconds must be positive when set")
            if self.soft_timeout_seconds >= self.hard_timeout_seconds:
                raise ValueError("soft_timeout_seconds must be lower than hard_timeout_seconds")
        if self.fallback_policy not in FALLBACK_ACTIONS:
            raise ValueError(f"invalid fallback policy: {self.fallback_policy}")


@dataclass(frozen=True)
class WorkerObservation:
    scope_id: str
    stage: str
    started_at: float
    last_progress_at: float
    now: float
    last_meaningful_progress_at: float | None = None
    checkpoint_requested_at: float | None = None
    checkpoint_received_at: float | None = None
    checkpoint_harvested_at: float | None = None
    writable: bool = False
    in_flight: bool = False
    terminal_success: bool = False
    terminal_failure: bool = False
    scope_superseded: bool = False
    cancel_confirmed: bool = False
    replacement_isolated: bool = False

    def meaningful_progress_at(self) -> float:
        # Backward compatibility: callers that do not yet distinguish liveness
        # activity from acceptance-relevant progress retain historical behavior.
        return self.last_progress_at if self.last_meaningful_progress_at is None else self.last_meaningful_progress_at

    def checkpoint_status(self) -> str:
        if self.checkpoint_harvested_at is not None:
            return "harvested"
        if self.checkpoint_received_at is not None:
            return "received"
        if self.checkpoint_requested_at is not None:
            return "requested"
        return "not_requested"

    def validate(self) -> None:
        if not self.scope_id:
            raise ValueError("scope_id is required")
        if self.stage not in {"exploration", "implementation", "review"}:
            raise ValueError(f"invalid stage: {self.stage}")
        timestamps = {
            "started_at": self.started_at,
            "last_progress_at": self.last_progress_at,
            "now": self.now,
        }
        optional_timestamps = {
            "last_meaningful_progress_at": self.last_meaningful_progress_at,
            "checkpoint_requested_at": self.checkpoint_requested_at,
            "checkpoint_received_at": self.checkpoint_received_at,
            "checkpoint_harvested_at": self.checkpoint_harvested_at,
        }
        timestamps.update({key: value for key, value in optional_timestamps.items() if value is not None})
        if any(not math.isfinite(value) for value in timestamps.values()):
            raise ValueError("timestamps must be finite seconds")
        if any(value < 0 for value in timestamps.values()):
            raise ValueError("timestamps cannot be negative")
        if any(value > EPOCH_MILLISECONDS_THRESHOLD for value in timestamps.values()):
            raise ValueError(
                "timestamps must use seconds, not milliseconds; pass Unix seconds such as time.time()"
            )
        if self.last_progress_at < self.started_at:
            raise ValueError("last_progress_at cannot precede started_at")
        if self.now < self.started_at:
            raise ValueError("now cannot precede started_at")
        meaningful_at = self.meaningful_progress_at()
        if meaningful_at < self.started_at:
            raise ValueError("last_meaningful_progress_at cannot precede started_at")
        if meaningful_at > self.last_progress_at:
            raise ValueError("last_meaningful_progress_at cannot be newer than last_progress_at")
        for label in ("checkpoint_requested_at", "checkpoint_received_at", "checkpoint_harvested_at"):
            value = getattr(self, label)
            if value is not None and value < self.started_at:
                raise ValueError(f"{label} cannot precede started_at")
            if value is not None and value > self.now:
                raise ValueError(f"{label} cannot be in the future")
        if self.checkpoint_received_at is not None and self.checkpoint_requested_at is None:
            raise ValueError("checkpoint_received_at requires checkpoint_requested_at")
        if self.checkpoint_harvested_at is not None and self.checkpoint_received_at is None:
            raise ValueError("checkpoint_harvested_at requires checkpoint_received_at")
        if (
            self.checkpoint_requested_at is not None
            and self.checkpoint_received_at is not None
            and self.checkpoint_received_at < self.checkpoint_requested_at
        ):
            raise ValueError("checkpoint_received_at cannot precede checkpoint_requested_at")
        if (
            self.checkpoint_received_at is not None
            and self.checkpoint_harvested_at is not None
            and self.checkpoint_harvested_at < self.checkpoint_received_at
        ):
            raise ValueError("checkpoint_harvested_at cannot precede checkpoint_received_at")
        if self.checkpoint_status() not in CHECKPOINT_STATUSES:  # pragma: no cover
            raise AssertionError(f"invalid checkpoint status: {self.checkpoint_status()}")
        if self.terminal_success and self.terminal_failure:
            raise ValueError("worker cannot be both terminal-success and terminal-failure")
        if self.cancel_confirmed and (self.terminal_success or self.terminal_failure):
            raise ValueError("cancel_confirmed cannot be combined with another terminal state")


@dataclass(frozen=True)
class LifecycleDecision:
    state: str
    action: str
    reason: str
    cancel_required: bool
    replacement_allowed: bool
    fence_required: bool
    idle_seconds: float
    meaningful_idle_seconds: float
    progress_quality: str
    checkpoint_status: str
    replan_scope: str | None
    checkpoint_reuse_mode: str | None
    wall_seconds: float
    fallback_policy: str | None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _progress_metrics(
    policy: LifecyclePolicy,
    observation: WorkerObservation,
) -> tuple[float, float, float, str]:
    idle = max(0.0, observation.now - observation.last_progress_at)
    wall = max(0.0, observation.now - observation.started_at)
    meaningful_at = observation.meaningful_progress_at()
    meaningful_idle = max(0.0, observation.now - meaningful_at)
    has_meaningful_delta = meaningful_at > observation.started_at
    if has_meaningful_delta and meaningful_idle < policy.idle_timeout_seconds:
        quality = "meaningful"
    elif observation.in_flight or idle < policy.idle_timeout_seconds:
        quality = "activity_only"
    else:
        quality = "none"
    if quality not in PROGRESS_QUALITIES:  # pragma: no cover - defensive invariant
        raise AssertionError(f"invalid progress quality: {quality}")
    return idle, meaningful_idle, wall, quality


def _replan_contract(
    observation: WorkerObservation,
    fallback_policy: str | None,
) -> tuple[str | None, str | None]:
    if fallback_policy != "replan":
        return None, None
    if observation.checkpoint_status() != "harvested":
        return "uncovered_scope", None
    scope = "checkpoint_remaining_delta"
    reuse = "harvested_snapshot_only" if observation.replacement_isolated else "retained_workspace"
    if scope not in REPLAN_SCOPES or reuse not in CHECKPOINT_REUSE_MODES:  # pragma: no cover
        raise AssertionError("invalid replan checkpoint contract")
    return scope, reuse


def _decision(
    policy: LifecyclePolicy,
    observation: WorkerObservation,
    *,
    state: str,
    action: str,
    reason: str,
    cancel_required: bool,
    replacement_allowed: bool,
    fence_required: bool,
    fallback_policy: str | None,
) -> LifecycleDecision:
    idle, meaningful_idle, wall, quality = _progress_metrics(policy, observation)
    replan_scope, checkpoint_reuse_mode = _replan_contract(observation, fallback_policy)
    return LifecycleDecision(
        state=state,
        action=action,
        reason=reason,
        cancel_required=cancel_required,
        replacement_allowed=replacement_allowed,
        fence_required=fence_required,
        idle_seconds=idle,
        meaningful_idle_seconds=meaningful_idle,
        progress_quality=quality,
        checkpoint_status=observation.checkpoint_status(),
        replan_scope=replan_scope,
        checkpoint_reuse_mode=checkpoint_reuse_mode,
        wall_seconds=wall,
        fallback_policy=fallback_policy,
    )


def _checkpoint_harvest_decision(policy: LifecyclePolicy, observation: WorkerObservation) -> LifecycleDecision:
    return _decision(
        policy,
        observation,
        state="progressing" if observation.last_progress_at > observation.started_at or observation.in_flight else "running",
        action="harvest_checkpoint",
        reason=(
            "worker checkpoint is available; harvest completed work, changed files/current patch state, "
            "validation evidence, blockers, and remaining delta before any cancellation or fallback"
        ),
        cancel_required=False,
        replacement_allowed=False,
        fence_required=False,
        fallback_policy=None,
    )


def _fallback_decision(
    policy: LifecyclePolicy,
    observation: WorkerObservation,
    *,
    state: str,
    reason: str,
    terminal: bool,
) -> LifecycleDecision:
    fallback = FALLBACK_ACTIONS[policy.fallback_policy]
    cancel_required = not terminal
    fallback_creates_writer = policy.fallback_policy in WRITER_FALLBACKS
    fence_required = (
        observation.stage == "implementation"
        and observation.writable
        and fallback_creates_writer
    )
    if fence_required and not terminal and not observation.replacement_isolated:
        # Hard safety invariant: Parent delta and replacement Workers are both
        # downstream writers. Never let either write the same live scope while
        # the old Worker may resume. Confirm cancellation/termination first, or
        # move the downstream writer into a fresh isolated worktree and fence
        # the old output from integration.
        action = "request_cancel"
        replacement_allowed = False
    else:
        action = fallback
        replacement_allowed = fallback == "replan" and (
            not fence_required or terminal or observation.replacement_isolated
        )
        if fence_required and observation.replacement_isolated and not terminal:
            reason += "; downstream writer is explicitly isolated and old output is fenced from integration"
    if policy.fallback_policy == "replan" and observation.checkpoint_status() == "harvested":
        reason += "; replan is restricted to the harvested checkpoint remaining_delta and completed work must be preserved"
    if cancel_required:
        reason += "; non-terminal Worker cancellation is required"
    return _decision(
        policy,
        observation,
        state=state,
        action=action,
        reason=reason,
        cancel_required=cancel_required,
        replacement_allowed=replacement_allowed,
        fence_required=fence_required,
        fallback_policy=policy.fallback_policy,
    )


def _superseded_decision(policy: LifecyclePolicy, observation: WorkerObservation) -> LifecycleDecision:
    terminal = observation.terminal_failure or observation.cancel_confirmed
    return _decision(
        policy,
        observation,
        state="superseded",
        action="continue" if terminal else "request_cancel",
        reason=(
            "bounded scope is already covered with equivalent evidence; no fallback work is required"
            if terminal
            else "bounded scope is already covered with equivalent evidence; non-terminal Worker cancellation is required"
        ),
        cancel_required=not terminal,
        replacement_allowed=False,
        fence_required=False,
        fallback_policy=None,
    )


def _soft_budget_decision(policy: LifecyclePolicy, observation: WorkerObservation) -> LifecycleDecision:
    _idle, _meaningful_idle, _wall, quality = _progress_metrics(policy, observation)
    state = "progressing" if observation.last_progress_at > observation.started_at or observation.in_flight else "running"
    if quality == "meaningful":
        detail = "recent acceptance-relevant progress is visible"
    elif quality == "activity_only":
        detail = "liveness activity is visible but no recent acceptance-relevant delta is visible"
    else:
        detail = "no recent meaningful or liveness progress is visible"

    checkpoint_status = observation.checkpoint_status()
    if checkpoint_status == "not_requested":
        action = "request_checkpoint"
        suffix = "request a non-terminal checkpoint without cancelling Worker"
    elif checkpoint_status == "requested":
        action = "await_checkpoint"
        suffix = "checkpoint has been requested; let Worker reach a safe checkpoint without cancelling it"
    elif checkpoint_status == "received":
        return _checkpoint_harvest_decision(policy, observation)
    else:
        action = "continue"
        suffix = "checkpoint has already been harvested; continue until completion or a real lifecycle boundary"

    return _decision(
        policy,
        observation,
        state=state,
        action=action,
        reason=f"soft worker execution budget reached; {detail}; {suffix}",
        cancel_required=False,
        replacement_allowed=False,
        fence_required=False,
        fallback_policy=None,
    )


def evaluate_worker(policy: LifecyclePolicy, observation: WorkerObservation) -> LifecycleDecision:
    """Evaluate one Worker without treating Parent wait intervals as evidence."""
    policy.validate()
    observation.validate()

    idle, _meaningful_idle, wall, _quality = _progress_metrics(policy, observation)

    # Preserve already-returned partial work before any terminal failure, hard
    # timeout, idle fallback, cancellation, or writer replacement can discard it.
    if observation.checkpoint_status() == "received":
        return _checkpoint_harvest_decision(policy, observation)

    if observation.terminal_success:
        return _decision(
            policy,
            observation,
            state="completed",
            action="consume_result",
            reason="worker reported terminal success",
            cancel_required=False,
            replacement_allowed=False,
            fence_required=False,
            fallback_policy=None,
        )

    if observation.scope_superseded and policy.cancel_if_superseded:
        return _superseded_decision(policy, observation)

    if observation.terminal_failure:
        return _fallback_decision(
            policy,
            observation,
            state="failed",
            reason="worker reported terminal failure",
            terminal=True,
        )

    if observation.cancel_confirmed:
        return _fallback_decision(
            policy,
            observation,
            state="cancelled",
            reason="worker cancellation/termination confirmed",
            terminal=True,
        )

    if wall >= policy.hard_timeout_seconds:
        return _fallback_decision(
            policy,
            observation,
            state="stalled",
            reason="hard worker wall-clock ceiling reached",
            terminal=False,
        )

    if not observation.in_flight and idle >= policy.idle_timeout_seconds:
        return _fallback_decision(
            policy,
            observation,
            state="stalled",
            reason="idle progress lease expired with no visible in-flight work",
            terminal=False,
        )

    if policy.soft_timeout_seconds is not None and wall >= policy.soft_timeout_seconds:
        return _soft_budget_decision(policy, observation)

    return _decision(
        policy,
        observation,
        state="progressing" if observation.last_progress_at > observation.started_at or observation.in_flight else "running",
        action="continue",
        reason="worker remains non-terminal with an active liveness lease",
        cancel_required=False,
        replacement_allowed=False,
        fence_required=False,
        fallback_policy=None,
    )


def _load_json_object(raw: str, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid {label} JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="worker-lifecycle")
    parser.add_argument("--policy-json", required=True)
    parser.add_argument("--scope-id", required=True)
    parser.add_argument("--stage", choices=("exploration", "implementation", "review"), required=True)
    parser.add_argument("--started-at", type=float, required=True, help="Unix timestamp in seconds")
    parser.add_argument("--last-progress-at", type=float, required=True, help="Unix timestamp in seconds")
    parser.add_argument(
        "--last-meaningful-progress-at",
        type=float,
        help=(
            "Unix timestamp for the latest acceptance-relevant delta; omit for legacy behavior "
            "that treats last-progress-at as meaningful"
        ),
    )
    parser.add_argument("--checkpoint-requested-at", type=float, help="Unix timestamp when Parent requested checkpoint")
    parser.add_argument("--checkpoint-received-at", type=float, help="Unix timestamp when Worker returned checkpoint payload")
    parser.add_argument("--checkpoint-harvested-at", type=float, help="Unix timestamp when Parent persisted/consumed checkpoint payload")
    parser.add_argument("--now", type=float, required=True, help="Unix timestamp in seconds")
    parser.add_argument("--writable", action="store_true")
    parser.add_argument("--in-flight", action="store_true")
    parser.add_argument("--terminal-success", action="store_true")
    parser.add_argument("--terminal-failure", action="store_true")
    parser.add_argument("--scope-superseded", action="store_true")
    parser.add_argument("--cancel-confirmed", action="store_true")
    parser.add_argument("--replacement-isolated", action="store_true")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    ns = build_parser().parse_args(list(argv) if argv is not None else None)
    policy = LifecyclePolicy.from_dict(_load_json_object(ns.policy_json, "policy"))
    observation = WorkerObservation(
        scope_id=ns.scope_id,
        stage=ns.stage,
        started_at=ns.started_at,
        last_progress_at=ns.last_progress_at,
        now=ns.now,
        last_meaningful_progress_at=ns.last_meaningful_progress_at,
        checkpoint_requested_at=ns.checkpoint_requested_at,
        checkpoint_received_at=ns.checkpoint_received_at,
        checkpoint_harvested_at=ns.checkpoint_harvested_at,
        writable=ns.writable,
        in_flight=ns.in_flight,
        terminal_success=ns.terminal_success,
        terminal_failure=ns.terminal_failure,
        scope_superseded=ns.scope_superseded,
        cancel_confirmed=ns.cancel_confirmed,
        replacement_isolated=ns.replacement_isolated,
    )
    print(json.dumps(evaluate_worker(policy, observation).to_dict(), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
