#!/usr/bin/env python3
"""Phase-aware admission for the canonical ExecutionPlan task budget.

The compiler emits one self-consistent task budget. Its soft deadline is the
end of general writable work. If independent review is planned, its hard
deadline already includes the review-stage hard window plus an explicit Parent
finalization reserve. This helper validates that contract and performs
phase-aware reservations; it never derives a second budget.

Required completion has two admission windows:
- review may start from the general-work cutoff until ``review_deadline``;
- Parent finalization retains the remaining tail until the absolute hard stop.

A reviewer retry therefore cannot consume the Parent finalization reserve.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from dataclasses import asdict
from typing import Any

try:
    from .base import TaskBudgetPolicy
    from .task_budget_runtime import (
        GENERAL_RESERVATION_KINDS,
        LedgerError,
        init_ledger,
        ledger_status,
        reserve,
    )
except ImportError:
    from base import TaskBudgetPolicy
    from task_budget_runtime import (
        GENERAL_RESERVATION_KINDS,
        LedgerError,
        init_ledger,
        ledger_status,
        reserve,
    )

PHASES = ("exploration", "implementation", "required_completion")
RESERVATION_PHASE = {
    "work_unit": "implementation",
    "implementation_attempt": "implementation",
    "replan": "implementation",
    "replacement": "implementation",
    "review_attempt": "required_completion",
}


def _strict_number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise LedgerError(f"{label} must be a finite number")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise LedgerError(f"{label} must be a finite non-negative number")
    return number


def _cli_now(value: Any) -> float:
    if isinstance(value, bool):
        raise LedgerError("now must be finite seconds")
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise LedgerError("now must be finite seconds") from None
    if not math.isfinite(number) or number < 0:
        raise LedgerError("now must be finite non-negative seconds")
    return number


def _strict_int(value: Any, label: str) -> int:
    if type(value) is not int or value < 0:
        raise LedgerError(f"{label} must be a non-negative integer")
    return value


def _task_policy(plan: dict[str, Any]) -> TaskBudgetPolicy:
    try:
        return TaskBudgetPolicy.from_dict(plan["task_budget"])
    except (TypeError, ValueError) as exc:
        raise LedgerError(str(exc)) from None


def _policy_fingerprint(policy: TaskBudgetPolicy) -> str:
    encoded = json.dumps(asdict(policy), ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _completion_reserve(plan: dict[str, Any], policy: TaskBudgetPolicy) -> tuple[int, int, int]:
    reviewer_workers = _strict_int(plan.get("reviewer_workers"), "reviewer_workers")
    review_stage = plan.get("review_stage")
    if reviewer_workers == 0:
        if review_stage is not None:
            raise LedgerError("review_stage must be null when reviewer_workers is zero")
        if policy.max_review_attempts != 0:
            raise LedgerError("max_review_attempts must be zero when reviewer_workers is zero")
        return 0, 0, 0
    if type(review_stage) is not dict:
        raise LedgerError("review_stage is required when reviewer_workers is positive")
    if policy.max_review_attempts < reviewer_workers:
        raise LedgerError("review topology exceeds task budget max_review_attempts")
    review_hard = _strict_int(review_stage.get("hard_timeout_seconds"), "review_stage.hard_timeout_seconds")
    if review_hard < 1:
        raise LedgerError("review_stage.hard_timeout_seconds must be positive")
    parent_finalization = policy.parent_finalization_seconds
    return review_hard, parent_finalization, review_hard + parent_finalization


def _plan(value: Any) -> dict[str, Any]:
    if type(value) is not dict:
        raise LedgerError("ExecutionPlan must be an object")
    if value.get("schema_version") != 11:
        raise LedgerError("task phase runtime requires ExecutionPlan schema v11")
    if type(value.get("task_budget")) is not dict:
        raise LedgerError("ExecutionPlan task_budget must be an object")
    policy = _task_policy(value)
    implementation_workers = _strict_int(value.get("implementation_workers"), "implementation_workers")
    implementation_stage = value.get("implementation_stage")
    if implementation_workers > 0:
        if type(implementation_stage) is not dict:
            raise LedgerError("implementation_stage is required when implementation_workers is positive")
        maximum_work_units = implementation_stage.get("maximum_work_units")
        if type(maximum_work_units) is not int or maximum_work_units < 1:
            raise LedgerError("implementation_stage.maximum_work_units must be a positive integer")
        if maximum_work_units != policy.max_work_units:
            raise LedgerError("task budget max_work_units must match implementation_stage maximum_work_units")
        if implementation_workers > policy.max_work_units:
            raise LedgerError("implementation topology exceeds task budget max_work_units")
        if implementation_workers > policy.max_implementation_attempts:
            raise LedgerError("implementation topology exceeds task budget max_implementation_attempts")
        implementation_soft = implementation_stage.get("soft_timeout_seconds")
        if type(implementation_soft) is not int or implementation_soft < 1:
            raise LedgerError("implementation_stage.soft_timeout_seconds must be a positive integer")
        if policy.soft_timeout_seconds < implementation_soft:
            raise LedgerError("task soft timeout cannot precede implementation soft checkpoint budget")
    elif implementation_stage is not None:
        raise LedgerError("implementation_stage must be null when implementation_workers is zero")

    _review_hard, _parent_finalization, reserve_seconds = _completion_reserve(value, policy)
    if reserve_seconds > 0 and policy.hard_timeout_seconds - policy.soft_timeout_seconds < reserve_seconds:
        raise LedgerError("task budget does not reserve the full required-completion tail")
    return value


def _validate_ledger_identity(plan: dict[str, Any], ledger: dict[str, Any]) -> TaskBudgetPolicy:
    policy = _task_policy(plan)
    if ledger.get("policy_fingerprint") != _policy_fingerprint(policy):
        raise LedgerError("task phase plan/policy mismatch; refusing to use a different budget plan")
    return policy


def phase_decision(plan_value: Any, ledger_value: Any, phase: str, now: Any) -> dict[str, Any]:
    if phase not in PHASES:
        raise LedgerError(f"invalid task phase: {phase}")
    plan = _plan(plan_value)
    if type(ledger_value) is not dict:
        raise LedgerError("ledger status must be an object")
    policy = _validate_ledger_identity(plan, ledger_value)
    current_now = _strict_number(now, "now")
    started_at = _strict_number(ledger_value.get("started_at"), "started_at")
    soft_deadline = _strict_number(ledger_value.get("soft_deadline"), "soft_deadline")
    hard_deadline = _strict_number(ledger_value.get("hard_deadline"), "hard_deadline")
    if soft_deadline != started_at + policy.soft_timeout_seconds:
        raise LedgerError("task phase soft deadline does not match ExecutionPlan task budget")
    if hard_deadline != started_at + policy.hard_timeout_seconds:
        raise LedgerError("task phase hard deadline does not match ExecutionPlan task budget")
    closed = ledger_value.get("closed")
    if type(closed) is not bool:
        raise LedgerError("ledger closed must be boolean")

    review_hard, parent_finalization, reserve_seconds = _completion_reserve(plan, policy)
    hard_open = (not closed) and current_now < hard_deadline
    permits_general_work = hard_open and current_now < soft_deadline
    permits_required_completion = hard_open and reserve_seconds > 0
    review_deadline = hard_deadline - parent_finalization if reserve_seconds > 0 else None
    permits_review_start = permits_required_completion and review_deadline is not None and current_now < review_deadline
    permits_parent_finalization = hard_open

    if not hard_open:
        action = "stop"
    elif phase == "required_completion":
        if not permits_required_completion:
            action = "stop"
        elif permits_review_start:
            action = "complete_required"
        else:
            action = "finalize_parent"
    elif permits_general_work:
        action = "continue"
    elif reserve_seconds > 0:
        action = "converge_for_required_completion"
    else:
        action = "converge"

    return {
        "phase": phase,
        "action": action,
        "permits_phase_start": permits_required_completion if phase == "required_completion" else permits_general_work,
        "permits_general_work": permits_general_work,
        "permits_required_completion": permits_required_completion,
        "permits_review_start": permits_review_start,
        "permits_parent_finalization": permits_parent_finalization,
        "reviewer_reserve_seconds": review_hard,
        "parent_finalization_reserve_seconds": parent_finalization,
        "required_completion_reserve_seconds": reserve_seconds,
        "general_work_deadline": soft_deadline,
        "review_deadline": review_deadline,
        "soft_deadline": soft_deadline,
        "hard_deadline": hard_deadline,
        "remaining_general_work_seconds": max(0.0, soft_deadline - current_now),
        "remaining_review_seconds": 0.0 if review_deadline is None else max(0.0, review_deadline - current_now),
        "remaining_hard_seconds": max(0.0, hard_deadline - current_now),
        "checkpoint_convergence_required": phase == "implementation" and hard_open and current_now >= soft_deadline,
        "required_completion_handoff": reserve_seconds > 0 and hard_open and current_now >= soft_deadline,
        "task_budget": asdict(policy),
    }


def init(state_file: str, task_id: str, plan: dict[str, Any], now: Any) -> dict[str, Any]:
    plan = _plan(plan)
    policy = _task_policy(plan)
    result = init_ledger(state_file, task_id, policy, now)
    result.update(phase_decision(plan, result, "exploration", now))
    return result


def status(state_file: str, task_id: str, plan: dict[str, Any], phase: str, now: Any) -> dict[str, Any]:
    plan = _plan(plan)
    ledger = ledger_status(state_file, task_id, now)
    result = dict(ledger)
    result.update(phase_decision(plan, ledger, phase, now))
    return result


def reserve_phase(
    state_file: str,
    task_id: str,
    plan: dict[str, Any],
    phase: str,
    kind: str,
    reservation_id: str,
    fingerprint: str,
    now: Any,
) -> dict[str, Any]:
    plan = _plan(plan)
    if phase not in PHASES:
        raise LedgerError(f"invalid task phase: {phase}")
    expected_phase = RESERVATION_PHASE.get(kind)
    if expected_phase is None:
        raise LedgerError(f"unsupported task phase reservation kind: {kind}")
    if phase != expected_phase:
        raise LedgerError(f"{kind} reservations require phase={expected_phase}")
    if phase == "implementation" and kind not in GENERAL_RESERVATION_KINDS:
        raise LedgerError("implementation phase only accepts general-work reservations")

    if kind == "review_attempt":
        decision = status(state_file, task_id, plan, phase, now)
        if not decision["permits_review_start"]:
            raise LedgerError("review admission deadline reached; Parent finalization reserve is protected")
        result = reserve(state_file, task_id, kind, reservation_id, fingerprint, now)
    else:
        result = reserve(state_file, task_id, kind, reservation_id, fingerprint, now)
    result.update(phase_decision(plan, result, phase, now))
    return result


def _json(raw: str, label: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise LedgerError(f"invalid {label} JSON: {exc.msg}") from None


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--plan-json", required=True)
    parser.add_argument("--now", required=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="task_phase_runtime.py", description="phase-aware admission for FlowPilot task budgets")
    commands = parser.add_subparsers(dest="command", required=True)
    init_cmd = commands.add_parser("init")
    _common(init_cmd)
    status_cmd = commands.add_parser("status")
    _common(status_cmd)
    status_cmd.add_argument("--phase", choices=PHASES, required=True)
    reserve_cmd = commands.add_parser("reserve")
    _common(reserve_cmd)
    reserve_cmd.add_argument("--phase", choices=PHASES, required=True)
    reserve_cmd.add_argument("--kind", choices=tuple(RESERVATION_PHASE), required=True)
    reserve_cmd.add_argument("--reservation-id", required=True)
    reserve_cmd.add_argument("--fingerprint", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    ns = parser.parse_args(argv)
    try:
        plan = _plan(_json(ns.plan_json, "plan"))
        current_now = _cli_now(ns.now)
        if ns.command == "init":
            result = init(ns.state_file, ns.task_id, plan, current_now)
        elif ns.command == "status":
            result = status(ns.state_file, ns.task_id, plan, ns.phase, current_now)
        else:
            result = reserve_phase(
                ns.state_file,
                ns.task_id,
                plan,
                ns.phase,
                ns.kind,
                ns.reservation_id,
                ns.fingerprint,
                current_now,
            )
    except LedgerError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
