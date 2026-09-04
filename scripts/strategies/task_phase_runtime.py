#!/usr/bin/env python3
"""Phase-aware admission on top of the durable task-budget ledger.

The task ledger owns cumulative counters and the absolute task hard deadline.
This helper adds one missing scheduling invariant: an immutable initial
ExecutionPlan that already requires independent review must keep enough tail
time for that required completion stage.

For a new task the helper derives an effective ledger policy from the initial
budget plan. Its soft timeout is clamped to the earlier of the strategy soft
timeout and ``hard_timeout - review_stage.hard_timeout``. The raw ledger
therefore keeps its own atomic reservation/idempotency semantics while still
enforcing that required-completion reserve. Required completion may start
after that soft boundary and remains permitted until the absolute task hard
deadline.

A ledger created by the pre-phase runtime is grandfathered when its stored
fingerprint exactly matches the initial plan's original TaskBudgetPolicy. Such
a running task keeps its historical unclamped soft deadline; upgrades never
retroactively shorten its execution window or invent a review-tail reservation.

The helper does not schedule Workers. It initializes the ledger, reports
phase-aware admission, and wraps implementation reservations.
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


def _plan(value: Any) -> dict[str, Any]:
    if type(value) is not dict:
        raise LedgerError("ExecutionPlan must be an object")
    if value.get("task_budget") is None:
        raise LedgerError("ExecutionPlan has no task_budget")
    if type(value.get("task_budget")) is not dict:
        raise LedgerError("ExecutionPlan task_budget must be an object")
    _strict_int(value.get("reviewer_workers"), "reviewer_workers")
    review_stage = value.get("review_stage")
    if review_stage is not None and type(review_stage) is not dict:
        raise LedgerError("review_stage must be an object or null")
    return value


def _original_policy(plan: dict[str, Any]) -> TaskBudgetPolicy:
    try:
        return TaskBudgetPolicy.from_dict(plan["task_budget"])
    except (TypeError, ValueError) as exc:
        raise LedgerError(str(exc)) from None


def _review_reserve_seconds(plan: dict[str, Any]) -> int:
    reviewer_workers = _strict_int(plan.get("reviewer_workers"), "reviewer_workers")
    review_stage = plan.get("review_stage")
    if reviewer_workers <= 0 or review_stage is None:
        return 0
    hard = _strict_int(review_stage.get("hard_timeout_seconds"), "review_stage.hard_timeout_seconds")
    if hard <= 0:
        raise LedgerError("required review hard timeout must be positive")
    return hard


def _effective_policy(plan: dict[str, Any]) -> TaskBudgetPolicy:
    policy = _original_policy(plan)
    review_reserve = _review_reserve_seconds(plan)
    if review_reserve <= 0:
        return policy
    latest_general_work = policy.hard_timeout_seconds - review_reserve
    if latest_general_work < 1:
        raise LedgerError("task hard budget is too small to reserve the required review stage")
    effective_soft = min(policy.soft_timeout_seconds, latest_general_work)
    effective = TaskBudgetPolicy(
        soft_timeout_seconds=effective_soft,
        hard_timeout_seconds=policy.hard_timeout_seconds,
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


def _policy_mode(plan: dict[str, Any], ledger_value: dict[str, Any]) -> tuple[TaskBudgetPolicy, bool]:
    """Return the actual ledger policy and whether it is a grandfathered v1 ledger."""
    original = _original_policy(plan)
    effective = _effective_policy(plan)
    stored = ledger_value.get("policy_fingerprint")
    effective_fp = _policy_fingerprint(effective)
    original_fp = _policy_fingerprint(original)
    if stored == effective_fp:
        return effective, False
    if effective_fp != original_fp and stored == original_fp:
        return original, True
    raise LedgerError("task phase plan/policy mismatch; refusing to use a different budget plan")


def phase_decision(
    plan_value: Any,
    ledger_value: Any,
    phase: str,
    now: Any,
) -> dict[str, Any]:
    """Return phase-aware admission from an initial budget plan + ledger status."""
    if phase not in PHASES:
        raise LedgerError(f"invalid task phase: {phase}")
    plan = _plan(plan_value)
    if type(ledger_value) is not dict:
        raise LedgerError("ledger status must be an object")
    ledger_policy, legacy_unclamped = _policy_mode(plan, ledger_value)

    current_now = _strict_number(now, "now")
    started_at = _strict_number(ledger_value.get("started_at"), "started_at")
    soft_deadline = _strict_number(ledger_value.get("soft_deadline"), "soft_deadline")
    hard_deadline = _strict_number(ledger_value.get("hard_deadline"), "hard_deadline")
    if hard_deadline <= soft_deadline:
        raise LedgerError("hard_deadline must be after soft_deadline")
    if soft_deadline != started_at + ledger_policy.soft_timeout_seconds:
        raise LedgerError("task phase soft deadline does not match the initial budget plan")
    if hard_deadline != started_at + ledger_policy.hard_timeout_seconds:
        raise LedgerError("task phase hard deadline does not match the initial budget plan")
    closed = ledger_value.get("closed")
    if type(closed) is not bool:
        raise LedgerError("ledger closed must be boolean")

    # Do not retroactively reserve review tail for a task that was already
    # running before phase-aware admission existed.
    review_reserve = 0 if legacy_unclamped else _review_reserve_seconds(plan)
    general_work_deadline = soft_deadline
    hard_open = (not closed) and current_now < hard_deadline
    permits_required_completion = hard_open
    permits_general_work = hard_open and current_now < general_work_deadline

    if not hard_open:
        action = "stop"
    elif phase == "required_completion":
        action = "complete_required"
    elif permits_general_work:
        action = "continue"
    elif review_reserve > 0:
        action = "converge_for_required_completion"
    else:
        action = "converge"

    return {
        "phase": phase,
        "action": action,
        "permits_phase_start": permits_required_completion if phase == "required_completion" else permits_general_work,
        "permits_general_work": permits_general_work,
        "permits_required_completion": permits_required_completion,
        "required_completion_reserve_seconds": review_reserve,
        "general_work_deadline": general_work_deadline,
        "soft_deadline": soft_deadline,
        "hard_deadline": hard_deadline,
        "remaining_general_work_seconds": max(0.0, general_work_deadline - current_now),
        "remaining_hard_seconds": max(0.0, hard_deadline - current_now),
        "checkpoint_convergence_required": (
            phase == "implementation" and hard_open and current_now >= general_work_deadline
        ),
        "required_completion_handoff": (
            review_reserve > 0 and hard_open and current_now >= general_work_deadline
        ),
        "legacy_unclamped": legacy_unclamped,
    }


def init(
    state_file: str,
    task_id: str,
    plan: dict[str, Any],
    now: Any,
) -> dict[str, Any]:
    """Initialize a phase-aware ledger, or grandfather an existing pre-phase ledger."""
    plan = _plan(plan)
    effective_policy = _effective_policy(plan)
    try:
        result = init_ledger(state_file, task_id, effective_policy, now)
    except LedgerError as init_error:
        # An already-running task from the pre-phase runtime was initialized
        # with the original policy. Preserve it rather than shortening its soft
        # deadline during an update. Any other mismatch still fails closed.
        try:
            result = ledger_status(state_file, task_id, now)
            actual_policy, legacy_unclamped = _policy_mode(plan, result)
        except LedgerError:
            raise init_error
        if not legacy_unclamped:
            raise init_error
        result["initialized"] = False
        result["idempotent"] = True
        result.update(phase_decision(plan, result, "exploration", now))
        result["effective_task_budget"] = asdict(actual_policy)
        return result

    result.update(phase_decision(plan, result, "exploration", now))
    result["effective_task_budget"] = asdict(effective_policy)
    return result


def status(
    state_file: str,
    task_id: str,
    plan: dict[str, Any],
    phase: str,
    now: Any,
) -> dict[str, Any]:
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
    if kind not in IMPLEMENTATION_RESERVATION_KINDS:
        raise LedgerError(f"invalid implementation reservation kind: {kind}")
    # A phase-aware ledger already has the completion reserve encoded in its
    # soft deadline. A grandfathered ledger keeps its historical deadline. In
    # both cases the raw atomic reserve preserves limit/deadline checks and its
    # deliberate idempotent replay behavior after the deadline.
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
