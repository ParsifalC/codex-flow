#!/usr/bin/env python3
"""Deterministic Worker lifecycle evaluator for FlowPilot."""
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
    "retry_review": "retry_review",
    "fail": "fail",
}
JOIN_POLICIES = {"opportunistic", "quorum", "required"}
WRITER_FALLBACKS = {"parent_delta", "replan"}
EPOCH_MILLISECONDS_THRESHOLD = 100_000_000_000
PROGRESS_QUALITIES = {"meaningful", "activity_only", "none"}
CHECKPOINT_STATUSES = {"not_requested", "requested", "received", "harvested"}
REPLAN_SCOPES = {"uncovered_scope", "checkpoint_remaining_delta"}
CHECKPOINT_REUSE_MODES = {"retained_workspace", "harvested_snapshot_only"}


def _strict_timeout(value: Any, label: str) -> float:
    if type(value) not in (int, float):
        raise ValueError(f"{label} must be a number")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{label} must be finite")
    return result


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
    checkpoint_rearm_seconds: float | None = None

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "LifecyclePolicy":
        if type(value) is not dict:
            raise ValueError("stage policy must be an object")
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
            if type(value[key]) is not bool:
                raise ValueError(f"{key} must be boolean")
        if type(value["join_policy"]) is not str or type(value["fallback_policy"]) is not str:
            raise ValueError("join_policy and fallback_policy must be strings")
        if type(value["min_successful_workers"]) is not int:
            raise ValueError("min_successful_workers must be an integer")
        raw_soft = value.get("soft_timeout_seconds")
        raw_rearm = value.get("checkpoint_rearm_seconds")
        policy = cls(
            join_policy=value["join_policy"],
            min_successful_workers=value["min_successful_workers"],
            idle_timeout_seconds=_strict_timeout(value["idle_timeout_seconds"], "idle_timeout_seconds"),
            hard_timeout_seconds=_strict_timeout(value["hard_timeout_seconds"], "hard_timeout_seconds"),
            cancel_if_superseded=value["cancel_if_superseded"],
            cancel_stragglers_after_quorum=value["cancel_stragglers_after_quorum"],
            fallback_policy=value["fallback_policy"],
            soft_timeout_seconds=None if raw_soft is None else _strict_timeout(raw_soft, "soft_timeout_seconds"),
            checkpoint_rearm_seconds=None if raw_rearm is None else _strict_timeout(raw_rearm, "checkpoint_rearm_seconds"),
        )
        policy.validate()
        return policy

    def validate(self) -> None:
        if self.join_policy not in JOIN_POLICIES:
            raise ValueError(f"invalid join policy: {self.join_policy}")
        if self.fallback_policy not in FALLBACK_ACTIONS:
            raise ValueError(f"invalid fallback policy: {self.fallback_policy}")
        if type(self.min_successful_workers) is not int or self.min_successful_workers < 0:
            raise ValueError("min_successful_workers must be a non-negative integer")
        if self.join_policy == "opportunistic" and self.min_successful_workers != 0:
            raise ValueError("opportunistic stage must use min_successful_workers=0")
        if self.join_policy != "opportunistic" and self.min_successful_workers < 1:
            raise ValueError(f"{self.join_policy} stage requires at least one successful worker")
        for label, value in (("idle_timeout_seconds", self.idle_timeout_seconds), ("hard_timeout_seconds", self.hard_timeout_seconds)):
            if type(value) not in (int, float) or not math.isfinite(float(value)) or value <= 0:
                raise ValueError(f"{label} must be a positive finite number")
        if self.hard_timeout_seconds < self.idle_timeout_seconds:
            raise ValueError("hard_timeout_seconds must be >= idle_timeout_seconds")
        if self.soft_timeout_seconds is not None:
            if type(self.soft_timeout_seconds) not in (int, float) or not math.isfinite(float(self.soft_timeout_seconds)):
                raise ValueError("soft_timeout_seconds must be finite")
            if self.soft_timeout_seconds <= 0 or self.soft_timeout_seconds >= self.hard_timeout_seconds:
                raise ValueError("soft_timeout_seconds must be positive and lower than hard_timeout_seconds")
        if self.checkpoint_rearm_seconds is not None:
            if type(self.checkpoint_rearm_seconds) not in (int, float) or not math.isfinite(float(self.checkpoint_rearm_seconds)):
                raise ValueError("checkpoint_rearm_seconds must be finite")
            if self.checkpoint_rearm_seconds <= 0 or self.checkpoint_rearm_seconds >= self.hard_timeout_seconds:
                raise ValueError("checkpoint_rearm_seconds must be positive and lower than hard_timeout_seconds")
            if self.soft_timeout_seconds is not None and self.soft_timeout_seconds + self.checkpoint_rearm_seconds >= self.hard_timeout_seconds:
                raise ValueError("checkpoint_rearm_seconds must leave time for a second checkpoint before hard_timeout_seconds")


@dataclass(frozen=True)
class CheckpointRecord:
    sequence: int
    generation: int
    requested_at: float
    received_at: float | None = None
    harvested_at: float | None = None

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "CheckpointRecord":
        if type(value) is not dict:
            raise ValueError("checkpoint record must be an object")
        for key in ("sequence", "generation"):
            if type(value.get(key)) is not int:
                raise ValueError(f"checkpoint {key} must be an integer")
        if "requested_at" not in value:
            raise ValueError("checkpoint record missing requested_at")
        return cls(
            sequence=value["sequence"],
            generation=value["generation"],
            requested_at=_strict_timeout(value["requested_at"], "checkpoint requested_at"),
            received_at=None if value.get("received_at") is None else _strict_timeout(value["received_at"], "checkpoint received_at"),
            harvested_at=None if value.get("harvested_at") is None else _strict_timeout(value["harvested_at"], "checkpoint harvested_at"),
        )

    def validate(self, *, started_at: float, now: float) -> None:
        if self.sequence < 1 or self.generation < 0:
            raise ValueError("checkpoint sequence must be positive and generation non-negative")
        for label, value in (
            ("requested_at", self.requested_at),
            ("received_at", self.received_at),
            ("harvested_at", self.harvested_at),
        ):
            if value is None:
                continue
            if type(value) not in (int, float) or not math.isfinite(float(value)):
                raise ValueError(f"checkpoint {label} must be finite")
            if value > EPOCH_MILLISECONDS_THRESHOLD:
                raise ValueError(f"checkpoint {label} must use Unix seconds")
            if value < started_at or value > now:
                raise ValueError(f"checkpoint {label} must be between started_at and now")
        if self.received_at is not None and self.received_at < self.requested_at:
            raise ValueError("checkpoint received_at cannot precede requested_at")
        if self.harvested_at is not None:
            if self.received_at is None:
                raise ValueError("checkpoint harvested_at requires received_at")
            if self.harvested_at < self.received_at:
                raise ValueError("checkpoint harvested_at cannot precede received_at")


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
    generation: int = 0
    checkpoint_sequence: tuple[CheckpointRecord, ...] | None = None

    def meaningful_progress_at(self) -> float:
        return self.last_progress_at if self.last_meaningful_progress_at is None else self.last_meaningful_progress_at

    def checkpoint_records(self) -> tuple[CheckpointRecord, ...]:
        if self.checkpoint_sequence is not None:
            return self.checkpoint_sequence
        if self.checkpoint_requested_at is None and self.checkpoint_received_at is None and self.checkpoint_harvested_at is None:
            return ()
        return (CheckpointRecord(1, self.generation, self.checkpoint_requested_at, self.checkpoint_received_at, self.checkpoint_harvested_at),)

    def latest_checkpoint(self) -> CheckpointRecord | None:
        records = self.checkpoint_records()
        return records[-1] if records else None

    def latest_harvested_checkpoint(self) -> CheckpointRecord | None:
        harvested = [record for record in self.checkpoint_records() if record.harvested_at is not None]
        return harvested[-1] if harvested else None

    def checkpoint_status(self) -> str:
        latest = self.latest_checkpoint()
        if latest is None:
            return "not_requested"
        if latest.harvested_at is not None:
            return "harvested"
        if latest.received_at is not None:
            return "received"
        return "requested"

    def validate(self) -> None:
        if not self.scope_id:
            raise ValueError("scope_id is required")
        if self.stage not in {"exploration", "implementation", "review"}:
            raise ValueError(f"invalid stage: {self.stage}")
        if type(self.generation) is not int or self.generation < 0:
            raise ValueError("generation must be a non-negative integer")
        timestamps = [self.started_at, self.last_progress_at, self.now]
        timestamps.extend(v for v in (
            self.last_meaningful_progress_at,
            self.checkpoint_requested_at,
            self.checkpoint_received_at,
            self.checkpoint_harvested_at,
        ) if v is not None)
        if any(type(v) not in (int, float) or not math.isfinite(float(v)) or v < 0 for v in timestamps):
            raise ValueError("timestamps must be finite non-negative seconds")
        if any(v > EPOCH_MILLISECONDS_THRESHOLD for v in timestamps):
            raise ValueError("timestamps must use Unix seconds")
        if self.now < self.started_at:
            raise ValueError("now cannot precede started_at")
        if self.last_progress_at < self.started_at or self.last_progress_at > self.now:
            raise ValueError("last_progress_at must be between started_at and now")
        meaningful = self.meaningful_progress_at()
        if meaningful < self.started_at or meaningful > self.last_progress_at:
            raise ValueError("last_meaningful_progress_at must be between started_at and last_progress_at")
        has_legacy_checkpoint = any(v is not None for v in (
            self.checkpoint_requested_at,
            self.checkpoint_received_at,
            self.checkpoint_harvested_at,
        ))
        if self.checkpoint_sequence is not None and has_legacy_checkpoint:
            raise ValueError("legacy checkpoint fields cannot be combined with checkpoint sequence")
        if self.checkpoint_sequence is None:
            if self.checkpoint_received_at is not None and self.checkpoint_requested_at is None:
                raise ValueError("checkpoint_received_at requires checkpoint_requested_at")
            if self.checkpoint_harvested_at is not None and self.checkpoint_received_at is None:
                raise ValueError("checkpoint_harvested_at requires checkpoint_received_at")
        records = self.checkpoint_records()
        for index, record in enumerate(records, start=1):
            if record.sequence != index:
                raise ValueError("checkpoint sequences must be contiguous starting at 1")
            if record.generation != self.generation:
                raise ValueError("checkpoint generation must equal observation generation")
            record.validate(started_at=self.started_at, now=self.now)
            if index < len(records) and record.harvested_at is None:
                raise ValueError("every checkpoint except the latest must be harvested")
            if index > 1:
                previous = records[index - 2]
                if previous.harvested_at is None:
                    raise ValueError("a new checkpoint cannot start before the previous one is harvested")
                if record.requested_at < previous.harvested_at:
                    raise ValueError("checkpoint requested_at cannot precede previous harvest")
        if self.checkpoint_status() not in CHECKPOINT_STATUSES:
            raise AssertionError("invalid checkpoint status")
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
    checkpoint_generation: int
    checkpoint_sequence: int
    next_checkpoint_sequence: int | None
    harvested_checkpoint_sequence: int
    checkpoint_rearm_at: float | None
    checkpoint_rearm_remaining_seconds: float | None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _progress_metrics(policy: LifecyclePolicy, observation: WorkerObservation) -> tuple[float, float, float, str]:
    idle = max(0.0, observation.now - observation.last_progress_at)
    wall = max(0.0, observation.now - observation.started_at)
    meaningful_at = observation.meaningful_progress_at()
    meaningful_idle = max(0.0, observation.now - meaningful_at)
    if meaningful_at > observation.started_at and meaningful_idle < policy.idle_timeout_seconds:
        quality = "meaningful"
    elif observation.in_flight or idle < policy.idle_timeout_seconds:
        quality = "activity_only"
    else:
        quality = "none"
    return idle, meaningful_idle, wall, quality


def _replan_contract(observation: WorkerObservation, fallback_policy: str | None) -> tuple[str | None, str | None]:
    if fallback_policy != "replan":
        return None, None
    if observation.latest_harvested_checkpoint() is None:
        return "uncovered_scope", None
    return (
        "checkpoint_remaining_delta",
        "harvested_snapshot_only" if observation.replacement_isolated else "retained_workspace",
    )


def _decision(policy: LifecyclePolicy, observation: WorkerObservation, *, state: str, action: str, reason: str, cancel_required: bool, replacement_allowed: bool, fence_required: bool, fallback_policy: str | None) -> LifecycleDecision:
    idle, meaningful_idle, wall, quality = _progress_metrics(policy, observation)
    replan_scope, reuse = _replan_contract(observation, fallback_policy)
    latest = observation.latest_checkpoint()
    latest_harvested = observation.latest_harvested_checkpoint()
    latest_sequence = latest.sequence if latest is not None else 0
    if latest_harvested is not None and policy.checkpoint_rearm_seconds is not None:
        rearm_at = latest_harvested.harvested_at + policy.checkpoint_rearm_seconds
        rearm_remaining = max(0.0, rearm_at - observation.now)
    else:
        rearm_at = None
        rearm_remaining = None
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
        checkpoint_reuse_mode=reuse,
        wall_seconds=wall,
        fallback_policy=fallback_policy,
        checkpoint_generation=observation.generation,
        checkpoint_sequence=latest_sequence,
        next_checkpoint_sequence=latest_sequence + 1 if action == "request_checkpoint" else None,
        harvested_checkpoint_sequence=latest_harvested.sequence if latest_harvested is not None else 0,
        checkpoint_rearm_at=rearm_at,
        checkpoint_rearm_remaining_seconds=rearm_remaining,
    )


def _checkpoint_harvest_decision(policy: LifecyclePolicy, observation: WorkerObservation) -> LifecycleDecision:
    return _decision(
        policy, observation,
        state="progressing" if observation.last_progress_at > observation.started_at or observation.in_flight else "running",
        action="harvest_checkpoint",
        reason="worker checkpoint is available; harvest durable work before any fallback",
        cancel_required=False,
        replacement_allowed=False,
        fence_required=False,
        fallback_policy=None,
    )


def _fallback_decision(policy: LifecyclePolicy, observation: WorkerObservation, *, state: str, reason: str, terminal: bool) -> LifecycleDecision:
    if policy.fallback_policy == "retry_review" and observation.stage != "review":
        raise ValueError("retry_review fallback is only valid for review stage")
    fallback = FALLBACK_ACTIONS[policy.fallback_policy]
    cancel_required = not terminal
    fallback_creates_writer = policy.fallback_policy in WRITER_FALLBACKS
    fence_required = observation.stage == "implementation" and observation.writable and fallback_creates_writer

    if policy.fallback_policy == "retry_review":
        action = "retry_review"
        replacement_allowed = True
        reason += "; replacement is read-only and must consume a review_attempt reservation"
    elif fence_required and not terminal and not observation.replacement_isolated:
        action = "request_cancel"
        replacement_allowed = False
    else:
        action = fallback
        replacement_allowed = fallback == "replan" and (not fence_required or terminal or observation.replacement_isolated)
        if fence_required and observation.replacement_isolated and not terminal:
            reason += "; downstream writer is isolated and old output is fenced"

    if policy.fallback_policy == "replan" and observation.latest_harvested_checkpoint() is not None:
        reason += "; replan is restricted to harvested remaining_delta"
    if cancel_required:
        reason += "; non-terminal Worker cancellation is required"
    return _decision(
        policy, observation,
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
        policy, observation,
        state="superseded",
        action="continue" if terminal else "request_cancel",
        reason="scope is already covered; no fallback work is required",
        cancel_required=not terminal,
        replacement_allowed=False,
        fence_required=False,
        fallback_policy=None,
    )


def _soft_budget_decision(policy: LifecyclePolicy, observation: WorkerObservation) -> LifecycleDecision:
    _idle, _meaningful_idle, _wall, quality = _progress_metrics(policy, observation)
    state = "progressing" if observation.last_progress_at > observation.started_at or observation.in_flight else "running"
    checkpoint_status = observation.checkpoint_status()
    if checkpoint_status == "not_requested":
        action, suffix = "request_checkpoint", "request a non-terminal checkpoint"
    elif checkpoint_status == "requested":
        action, suffix = "await_checkpoint", "checkpoint is already requested"
    elif checkpoint_status == "received":
        return _checkpoint_harvest_decision(policy, observation)
    else:
        latest = observation.latest_harvested_checkpoint()
        rearm_at = None if latest is None or policy.checkpoint_rearm_seconds is None else latest.harvested_at + policy.checkpoint_rearm_seconds
        explicit = observation.last_meaningful_progress_at
        has_delta = latest is not None and explicit is not None and explicit > latest.harvested_at
        cooldown = rearm_at is not None and observation.now >= rearm_at
        if has_delta and cooldown:
            action, suffix = "request_checkpoint", "explicit meaningful progress and cooldown re-armed checkpointing"
        else:
            action = "continue"
            suffix = "harvested checkpoint remains current; no eligible rearm"
    return _decision(
        policy, observation,
        state=state,
        action=action,
        reason=f"soft worker execution budget reached; progress={quality}; {suffix}",
        cancel_required=False,
        replacement_allowed=False,
        fence_required=False,
        fallback_policy=None,
    )


def evaluate_worker(policy: LifecyclePolicy, observation: WorkerObservation) -> LifecycleDecision:
    policy.validate()
    observation.validate()
    idle, _meaningful_idle, wall, _quality = _progress_metrics(policy, observation)

    if observation.checkpoint_status() == "received":
        return _checkpoint_harvest_decision(policy, observation)
    if observation.terminal_success:
        return _decision(policy, observation, state="completed", action="consume_result", reason="worker reported terminal success", cancel_required=False, replacement_allowed=False, fence_required=False, fallback_policy=None)
    if observation.scope_superseded and policy.cancel_if_superseded:
        return _superseded_decision(policy, observation)
    if observation.terminal_failure:
        return _fallback_decision(policy, observation, state="failed", reason="worker reported terminal failure", terminal=True)
    if observation.cancel_confirmed:
        return _fallback_decision(policy, observation, state="cancelled", reason="worker cancellation/termination confirmed", terminal=True)
    if wall >= policy.hard_timeout_seconds:
        return _fallback_decision(policy, observation, state="stalled", reason="hard worker wall-clock ceiling reached", terminal=False)
    if not observation.in_flight and idle >= policy.idle_timeout_seconds:
        return _fallback_decision(policy, observation, state="stalled", reason="idle progress lease expired with no visible in-flight work", terminal=False)
    if policy.soft_timeout_seconds is not None and wall >= policy.soft_timeout_seconds:
        return _soft_budget_decision(policy, observation)
    return _decision(
        policy, observation,
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


def _load_checkpoint_sequence(raw: str) -> tuple[CheckpointRecord, ...]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid checkpoint sequence JSON: {exc}") from exc
    if type(value) is not list:
        raise ValueError("checkpoint sequence must be a JSON array")
    return tuple(CheckpointRecord.from_dict(item) for item in value)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="worker-lifecycle")
    parser.add_argument("--policy-json", required=True)
    parser.add_argument("--scope-id", required=True)
    parser.add_argument("--stage", choices=("exploration", "implementation", "review"), required=True)
    parser.add_argument("--started-at", type=float, required=True)
    parser.add_argument("--last-progress-at", type=float, required=True)
    parser.add_argument("--last-meaningful-progress-at", type=float)
    parser.add_argument("--checkpoint-requested-at", type=float)
    parser.add_argument("--checkpoint-received-at", type=float)
    parser.add_argument("--checkpoint-harvested-at", type=float)
    parser.add_argument("--now", type=float, required=True)
    parser.add_argument("--writable", action="store_true")
    parser.add_argument("--in-flight", action="store_true")
    parser.add_argument("--terminal-success", action="store_true")
    parser.add_argument("--terminal-failure", action="store_true")
    parser.add_argument("--scope-superseded", action="store_true")
    parser.add_argument("--cancel-confirmed", action="store_true")
    parser.add_argument("--replacement-isolated", action="store_true")
    parser.add_argument("--generation", type=int, default=0)
    parser.add_argument("--checkpoint-sequence-json")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    ns = build_parser().parse_args(list(argv) if argv is not None else None)
    policy = LifecyclePolicy.from_dict(_load_json_object(ns.policy_json, "policy"))
    sequence = None if ns.checkpoint_sequence_json is None else _load_checkpoint_sequence(ns.checkpoint_sequence_json)
    if sequence is not None and any(v is not None for v in (ns.checkpoint_requested_at, ns.checkpoint_received_at, ns.checkpoint_harvested_at)):
        raise ValueError("legacy checkpoint flags cannot be combined with --checkpoint-sequence-json")
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
        generation=ns.generation,
        checkpoint_sequence=sequence,
    )
    print(json.dumps(evaluate_worker(policy, observation).to_dict(), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
