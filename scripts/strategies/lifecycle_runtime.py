#!/usr/bin/env python3
"""Deterministic Worker lifecycle evaluator for FlowPilot.

This module is copied automatically with the strategy package by both Unix and
Windows installers. It turns observable Worker facts plus an ExecutionPlan
StagePolicy into a deterministic lifecycle decision. Semantic scope overlap
remains a Parent responsibility; timing/state transitions and writable
replacement fencing do not.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from typing import Any, Iterable

TERMINAL_STATES = {"completed", "failed", "cancelled"}
FALLBACK_ACTIONS = {
    "continue_partial": "continue_partial",
    "parent_delta": "parent_delta",
    "replan": "replan",
    "fail": "fail",
}
JOIN_POLICIES = {"opportunistic", "quorum", "required"}


@dataclass(frozen=True)
class LifecyclePolicy:
    join_policy: str
    min_successful_workers: int
    idle_timeout_seconds: float
    hard_timeout_seconds: float
    cancel_if_superseded: bool
    cancel_stragglers_after_quorum: bool
    fallback_policy: str

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
        policy = cls(
            join_policy=str(value["join_policy"]),
            min_successful_workers=int(value["min_successful_workers"]),
            idle_timeout_seconds=float(value["idle_timeout_seconds"]),
            hard_timeout_seconds=float(value["hard_timeout_seconds"]),
            cancel_if_superseded=bool(value["cancel_if_superseded"]),
            cancel_stragglers_after_quorum=bool(value["cancel_stragglers_after_quorum"]),
            fallback_policy=str(value["fallback_policy"]),
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
        if self.fallback_policy not in FALLBACK_ACTIONS:
            raise ValueError(f"invalid fallback policy: {self.fallback_policy}")


@dataclass(frozen=True)
class WorkerObservation:
    scope_id: str
    stage: str
    started_at: float
    last_progress_at: float
    now: float
    writable: bool = False
    in_flight: bool = False
    terminal_success: bool = False
    terminal_failure: bool = False
    scope_superseded: bool = False
    cancel_confirmed: bool = False
    replacement_isolated: bool = False

    def validate(self) -> None:
        if not self.scope_id:
            raise ValueError("scope_id is required")
        if self.stage not in {"exploration", "implementation", "review"}:
            raise ValueError(f"invalid stage: {self.stage}")
        if self.started_at < 0 or self.last_progress_at < 0 or self.now < 0:
            raise ValueError("timestamps cannot be negative")
        if self.last_progress_at < self.started_at:
            raise ValueError("last_progress_at cannot precede started_at")
        if self.now < self.started_at:
            raise ValueError("now cannot precede started_at")
        if self.terminal_success and self.terminal_failure:
            raise ValueError("worker cannot be both terminal-success and terminal-failure")


@dataclass(frozen=True)
class LifecycleDecision:
    state: str
    action: str
    reason: str
    replacement_allowed: bool
    fence_required: bool
    idle_seconds: float
    wall_seconds: float
    fallback_policy: str | None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _fallback_decision(
    policy: LifecyclePolicy,
    observation: WorkerObservation,
    *,
    state: str,
    reason: str,
    terminal: bool,
) -> LifecycleDecision:
    fallback = FALLBACK_ACTIONS[policy.fallback_policy]
    fence_required = (
        observation.stage == "implementation"
        and observation.writable
        and policy.fallback_policy == "replan"
    )
    if fence_required and not terminal and not observation.replacement_isolated:
        # Hard safety invariant: never start a replacement for the same writable
        # scope while the old Worker may still resume and write. Parent must
        # confirm termination/cancellation first, or explicitly move the
        # replacement into a fresh isolated worktree and fence the old output
        # from integration.
        action = "request_cancel"
        replacement_allowed = False
    else:
        action = fallback
        replacement_allowed = fallback == "replan" and (terminal or observation.replacement_isolated)
        if fence_required and observation.replacement_isolated and not terminal:
            reason += "; replacement is explicitly isolated and old output is fenced from integration"
    return LifecycleDecision(
        state=state,
        action=action,
        reason=reason,
        replacement_allowed=replacement_allowed,
        fence_required=fence_required,
        idle_seconds=max(0.0, observation.now - observation.last_progress_at),
        wall_seconds=max(0.0, observation.now - observation.started_at),
        fallback_policy=policy.fallback_policy,
    )


def evaluate_worker(policy: LifecyclePolicy, observation: WorkerObservation) -> LifecycleDecision:
    """Evaluate one Worker without treating Parent wait intervals as evidence."""
    policy.validate()
    observation.validate()

    idle = max(0.0, observation.now - observation.last_progress_at)
    wall = max(0.0, observation.now - observation.started_at)

    if observation.terminal_success:
        return LifecycleDecision(
            state="completed",
            action="consume_result",
            reason="worker reported terminal success",
            replacement_allowed=False,
            fence_required=False,
            idle_seconds=idle,
            wall_seconds=wall,
            fallback_policy=None,
        )

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

    if observation.scope_superseded and policy.cancel_if_superseded:
        return LifecycleDecision(
            state="superseded",
            action="request_cancel",
            reason="bounded scope is already covered with equivalent evidence",
            replacement_allowed=False,
            fence_required=observation.stage == "implementation" and observation.writable,
            idle_seconds=idle,
            wall_seconds=wall,
            fallback_policy=policy.fallback_policy,
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

    return LifecycleDecision(
        state="progressing" if observation.last_progress_at > observation.started_at or observation.in_flight else "running",
        action="continue",
        reason="worker remains non-terminal with an active progress lease",
        replacement_allowed=False,
        fence_required=False,
        idle_seconds=idle,
        wall_seconds=wall,
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
    parser.add_argument("--started-at", type=float, required=True)
    parser.add_argument("--last-progress-at", type=float, required=True)
    parser.add_argument("--now", type=float, required=True)
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
