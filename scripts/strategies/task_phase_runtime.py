#!/usr/bin/env python3
"""Phase-aware admission on top of the durable task-budget ledger.

The strategy ExecutionPlan owns the general-work soft boundary.  When the same
immutable plan requires independent review, this helper deterministically
extends only the effective task hard boundary so required read-only review and
Parent finalization have a real completion tail.  It never shortens the
strategy's general-work window.

There is intentionally no legacy-ledger migration path: this runtime has not
shipped with persisted task ledgers, so incompatible/mismatched state fails
closed instead of preserving obsolete semantics.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from dataclasses import asdict
from typing import Any

try:  # Package import.
    from .base import TaskBudgetPolicy
    from .task_budget_runtime import LedgerError, init_ledger, ledger_status, reserve
except ImportError:  # Direct invocation from installed strategies directory.
    from base import TaskBudgetPolicy
    from task_budget_runtime import LedgerError, init_ledger, ledger_status, reserve


PHASES = ("exploration", "implementation", "required_completion")
IMPLEMENTATION_RESERVATION_KINDS = (
    "work_unit",
    "implementation_attempt",
    "replan",
    "replacement",
)
PARENT_FINALIZATION_MIN_SECONDS = 120


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


def _review_reserve(plan: dict[str, Any]) -> tuple[int, int, int]:
    reviewer_workers = _strict_int(plan.get("reviewer_workers"), "reviewer_workers")
    review_stage = plan.get("review_stage")
    if reviewer_workers <= 0:
        if review_stage is not None:
            raise LedgerError("review_stage must be null when reviewer_workers is zero")
        return 0, 0, 0
    if type(review_stage) is not dict:
        raise LedgerError("review_stage is required when reviewer_workers is positive")
    review_hard = _strict_int(
        review_stage.get("hard_timeout_seconds"),
        "review_stage.hard_timeout_seconds",
    )
    review_idle = _strict_int(
        review_stage.get("idle_timeout_seconds"),
        "review_stage.idle_timeout_seconds",
    )
    if review_hard <= 0:
        raise LedgerError("required review hard timeout must be positive")
    if review_idle <= 0 or review_idle > review_hard:
        raise LedgerError("required review idle timeout must be positive and <= review hard timeout")
    parent_finalization = max(PARENT_FINALIZATION_MIN_SECONDS, review_idle)
    return review_hard, parent_finalization, review_hard + parent_finalization


def _plan(value: Any) -> dict[str, Any]:
    if type(value) is not dict:
        raise LedgerError("ExecutionPlan must be an object")
    if type(value.get("task_budget")) is not dict:
        raise LedgerError("ExecutionPlan task_budget must be an object")
    policy = _task_policy(value)
    implementation_workers = _strict_int(
        value.get("implementation_workers"),
        "implementation_workers",
    )
    _strict_int(value.get("reviewer_workers"), "reviewer_workers")
    implementation_stage = value.get("implementation_stage")
    if implementation_workers > 0:
        if type(implementation_stage) is not dict:
            raise LedgerError("implementation_stage is required when implementation_workers is positive")
        maximum_work_units = implementation_stage.get("maximum_work_units")
        if type(maximum_work_units) is not int or maximum_work_units < 1:
            raise LedgerError("implementation_stage.maximum_work_units must be a positive integer")
        if maximum_work_units != policy.max_work_units:
            raise LedgerError("task budget max_work_units must match implementation_stage maximum_work_units")
        if implementation_workers > maximum_work_units:
            raise LedgerError("implementation topology exceeds task budget max_work_units")
        if implementation_workers > policy.max_implementation_attempts:
            raise LedgerError("implementation topology exceeds task budget max_implementation_attempts")
        implementation_soft = implementation_stage.get("soft_timeout_seconds")
        if implementation_soft is not None:
            implementation_soft = _strict_int(
                implementation_soft,
                "implementation_stage.soft_timeout_seconds",
            )
            if policy.soft_timeout_seconds < implementation_soft:
                raise LedgerError(
                    "task soft timeout cannot be earlier than implementation soft checkpoint budget"
                )
    elif implementation_stage is not None:
        raise LedgerError("implementation_stage must be null when implementation_workers is zero")
    _review_reserve(value)
    return value


def _effective_policy(plan: dict[str, Any]) -> TaskBudgetPolicy:
    policy = _task_policy(plan)
    _review_hard, _parent_finalization, completion_reserve = _review_reserve(plan)
    if completion_reserve <= 0:
        return policy
    # Preserve the strategy's general-work soft target. Required completion is
    # additive: an explicit/strategy-required review may make the task longer,
    # but must never steal the implementation window it is meant to verify.
    effective_hard = max(
        policy.hard_timeout_seconds,
        policy.soft_timeout_seconds + completion_reserve,
    )
    effective = TaskBudgetPolicy(
        soft_timeout_seconds=policy.soft_timeout_seconds,
        hard_timeout_seconds=effective_hard,
        max_work_units=policy.max_work_units,
        max_implementation_attempts=policy.max_implementation_attempts,
        max_replans=policy.max_replans,
        max_replacements=policy.max_replacements,
    )
    effective.validate()
    return effective


def _policy_fingerprint(policy: TaskBudgetPolicy) -> str:
    encoded = json.dumps(
        asdict(policy),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _validate_ledger_identity(plan: dict[str, Any], ledger_value: dict[str, Any]) -> TaskBudgetPolicy:
    effective = _effective_policy(plan)
    if ledger_value.get("policy_fingerprint") != _policy_fingerprint(effective):
        raise LedgerError("task phase plan/policy mismatch; refusing to use a different budget plan")
    return effective


def phase_decision(
    plan_value: Any,
    ledger_value: Any,
    phase: str,
    now: Any,
) -> dict[str, Any]:
    if phase not in PHASES:
        raise LedgerError(f"invalid task phase: {phase}")
    plan = _plan(plan_value)
    if type(ledger_value) is not dict:
        raise LedgerError("ledger status must be an object")
    effective = _validate_ledger_identity(plan, ledger_value)

    current_now = _strict_number(now, "now")
    started_at = _strict_number(ledger_value.get("started_at"), "started_at")
    soft_deadline = _strict_number(ledger_value.get("soft_deadline"), "soft_deadline")
    hard_deadline = _strict_number(ledger_value.get("hard_deadline"), "hard_deadline")
    if soft_deadline != started_at + effective.soft_timeout_seconds:
        raise LedgerError("task phase soft deadline does not match effective task budget")
    if hard_deadline != started_at + effective.hard_timeout_seconds:
        raise LedgerError("task phase hard deadline does not match effective task budget")
    closed = ledger_value.get("closed")
    if type(closed) is not bool:
        raise LedgerError("ledger closed must be boolean")

    review_hard, parent_finalization, completion_reserve = _review_reserve(plan)
    if completion_reserve > 0 and hard_deadline - soft_deadline < completion_reserve:
        raise LedgerError("effective task budget does not reserve required completion tail")

    hard_open = (not closed) and current_now < hard_deadline
    permits_general_work = hard_open and current_now < soft_deadline
    permits_required_completion = hard_open

    if not hard_open:
        action = "stop"
    elif phase == "required_completion":
        action = "complete_required"
    elif permits_general_work:
        action = "continue"
    elif completion_reserve > 0:
        action = "converge_for_required_completion"
    else:
        action = "converge"

    base_policy = _task_policy(plan)
    return {
        "phase": phase,
        "action": action,
        "permits_phase_start": permits_required_completion if phase == "required_completion" else permits_general_work,
        "permits_general_work": permits_general_work,
        "permits_required_completion": permits_required_completion,
        "reviewer_reserve_seconds": review_hard,
        "parent_finalization_reserve_seconds": parent_finalization,
        "required_completion_reserve_seconds": completion_reserve,
        "general_work_deadline": soft_deadline,
        "soft_deadline": soft_deadline,
        "hard_deadline": hard_deadline,
        "remaining_general_work_seconds": max(0.0, soft_deadline - current_now),
        "remaining_hard_seconds": max(0.0, hard_deadline - current_now),
        "checkpoint_convergence_required": (
            phase == "implementation" and hard_open and current_now >= soft_deadline
        ),
        "required_completion_handoff": (
            completion_reserve > 0 and hard_open and current_now >= soft_deadline
        ),
        "hard_deadline_extended": effective.hard_timeout_seconds > base_policy.hard_timeout_seconds,
        "base_task_budget": asdict(base_policy),
        "effective_task_budget": asdict(effective),
    }


def init(
    state_file: str,
    task_id: str,
    plan: dict[str, Any],
    now: Any,
) -> dict[str, Any]:
    plan = _plan(plan)
    effective = _effective_policy(plan)
    result = init_ledger(state_file, task_id, effective, now)
    result.update(phase_decision(plan, result, "exploration", now))
    return result


def status(
    state_file: str,
    task_id: str,
    plan: dict[str, Any],
    phase: str,
    now: Any,
) -> dict[str, Any]:
    plan = _plan(plan)
    ledger = ledger_status(state_file, task_id, now)
    result = dict(ledger)
    result.update(phase_decision(plan, ledger, phase, now))
    return result


def reserve_implementation(
    state_file: str,
    task_id: str,
    plan: dict[str, Any],
    kind: str,
    reservation_id: str,
    fingerprint: str,
    now: Any,
) -> dict[str, Any]:
    plan = _plan(plan)
    if kind not in IMPLEMENTATION_RESERVATION_KINDS:
        raise LedgerError(f"invalid implementation reservation kind: {kind}")
    # The raw ledger's soft deadline is exactly the general-work cutoff, so its
    # atomic reserve path remains authoritative for implementation admission and
    # idempotent replay.
    result = reserve(
        state_file,
        task_id,
        kind,
        reservation_id,
        fingerprint,
        now,
    )
    result.update(phase_decision(plan, result, "implementation", now))
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
    parser = argparse.ArgumentParser(
        prog="task_phase_runtime.py",
        description="phase-aware admission for FlowPilot task budgets",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    init_cmd = commands.add_parser("init")
    _common(init_cmd)

    status_cmd = commands.add_parser("status")
    _common(status_cmd)
    status_cmd.add_argument("--phase", choices=PHASES, required=True)

    reserve_cmd = commands.add_parser("reserve")
    _common(reserve_cmd)
    reserve_cmd.add_argument("--kind", choices=IMPLEMENTATION_RESERVATION_KINDS, required=True)
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
            result = reserve_implementation(
                ns.state_file,
                ns.task_id,
                plan,
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
