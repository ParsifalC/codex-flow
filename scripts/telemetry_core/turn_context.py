"""Parent-turn receipts and atomic FlowPilot goal/ExecutionPlan sidecars.

Receipts enforce correct association, not an adversarial security boundary.
Host delivery is handled by host_transport only after a real local Desktop
probe passes. Explicit receipt APIs never infer turn identity or rewrite prompts.
"""
from __future__ import annotations

import hashlib
import json
import re
import secrets
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from typing import Any, Callable

from .common import (
    STATE_ROOT,
    atomic_json,
    now_ms,
    read_json_object,
    run_key,
    safe_key_part,
    state_lock,
    telemetry_writes_enabled,
)
from .turn_result import parent_turn_aborted


class ReceiptError(ValueError):
    """Stable, secret-free context CLI failure."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class TurnReceipt:
    schema_version: int
    session_id: str
    turn_id: str
    receipt_id: str
    role: str


def _identifier(value: Any) -> str:
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        raise ReceiptError("receipt_invalid")
    try:
        value.encode("utf-8")
    except UnicodeError:
        raise ReceiptError("receipt_invalid") from None
    return value


def _transcript_path(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        return None
    try:
        value.encode("utf-8")
    except UnicodeError:
        return None
    return value


def receipt_digest(session_id: str, turn_id: str) -> str:
    encoded = json.dumps(
        [_identifier(session_id), _identifier(turn_id)],
        ensure_ascii=False, separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def context_path(session_id: str, turn_id: str, state_root: Path = STATE_ROOT) -> Path:
    return Path(state_root) / "turn-context" / (receipt_digest(session_id, turn_id) + ".json")


def _receipt_path(session_id: str, turn_id: str, state_root: Path) -> Path:
    return Path(state_root) / "turn-receipts" / (receipt_digest(session_id, turn_id) + ".json")


def _read_utf8(path: Path, missing_code: str = "file_read_error") -> str:
    try:
        # read_text uses universal newlines; bytes preserves the supplied text.
        return Path(path).read_bytes().decode("utf-8")
    except FileNotFoundError:
        raise ReceiptError(missing_code) from None
    except UnicodeError:
        raise ReceiptError("invalid_utf8") from None
    except OSError:
        raise ReceiptError("file_read_error") from None


def _parse_json(text: str, code: str) -> Any:
    def invalid_constant(_value):
        raise ValueError("non-finite JSON number")

    try:
        return json.loads(text, parse_constant=invalid_constant)
    except (ValueError, RecursionError):
        raise ReceiptError(code) from None


def _parse_receipt(value: Any) -> TurnReceipt:
    if not isinstance(value, dict):
        raise ReceiptError("receipt_invalid")
    if value.get("role") != "parent":
        raise ReceiptError("receipt_role_forbidden")
    if type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        raise ReceiptError("receipt_invalid")
    return TurnReceipt(
        schema_version=1,
        session_id=_identifier(value.get("session_id")),
        turn_id=_identifier(value.get("turn_id")),
        receipt_id=_identifier(value.get("receipt_id")),
        role="parent",
    )


def load_receipt(path: Path) -> TurnReceipt:
    """Parse caller input only; this is not hook-side authorization."""
    return _parse_receipt(_parse_json(_read_utf8(path, "receipt_missing"), "receipt_invalid"))


def _registered(receipt: TurnReceipt, state_root: Path) -> dict[str, Any]:
    try:
        value = _parse_json(
            _read_utf8(_receipt_path(receipt.session_id, receipt.turn_id, state_root), "receipt_expired"),
            "receipt_expired",
        )
        registered = _parse_receipt(value)
    except ReceiptError as exc:
        if exc.code == "receipt_expired":
            raise
        raise ReceiptError("receipt_expired") from None
    if (registered.session_id, registered.turn_id) != (receipt.session_id, receipt.turn_id):
        raise ReceiptError("receipt_mismatch")
    if not secrets.compare_digest(registered.receipt_id.encode("utf-8"), receipt.receipt_id.encode("utf-8")):
        raise ReceiptError("receipt_expired")
    return value


def validate_receipt(receipt: TurnReceipt, *, state_root: Path = STATE_ROOT) -> None:
    """Validate registration while the caller holds the corresponding turn lock."""
    if not isinstance(receipt, TurnReceipt):
        raise ReceiptError("receipt_invalid")
    _parse_receipt(asdict(receipt))
    if _registered(receipt, state_root).get("state") != "active":
        raise ReceiptError("receipt_expired")


def register_receipt(event: dict[str, Any], *, state_root: Path = STATE_ROOT) -> TurnReceipt | None:
    """Register only an explicit parent UserPromptSubmit; never reopen a turn."""
    if not telemetry_writes_enabled():
        return None
    if (not isinstance(event, dict) or event.get("hook_event_name") != "UserPromptSubmit"
            or event.get("agent_id") or event.get("role", "parent") != "parent"):
        raise ReceiptError("receipt_role_forbidden")
    if event.get("session_id") is None or event.get("turn_id") is None:
        raise ReceiptError("receipt_missing")
    session_id, turn_id = _identifier(event["session_id"]), _identifier(event["turn_id"])
    digest = receipt_digest(session_id, turn_id)
    with state_lock("turn-" + digest, state_root=state_root) as acquired:
        if not acquired:
            raise ReceiptError("locked")
        path = _receipt_path(session_id, turn_id, state_root)
        if path.exists():
            if (read_json_object(path) or {}).get("state") == "sealed":
                raise ReceiptError("receipt_expired")
            receipt = load_receipt(path)
            if (receipt.session_id, receipt.turn_id) != (session_id, turn_id):
                raise ReceiptError("receipt_mismatch")
            validate_receipt(receipt, state_root=state_root)
            return receipt
        receipt = TurnReceipt(1, session_id, turn_id, secrets.token_urlsafe(32), "parent")
        registration = {**asdict(receipt), "state": "active"}
        transcript_path = _transcript_path(event.get("transcript_path"))
        if transcript_path is not None:
            registration["transcript_path"] = transcript_path
        atomic_json(path, registration)
        return receipt


def seal_receipt(receipt: TurnReceipt, *, state_root: Path = STATE_ROOT) -> None:
    """Seal under the caller's turn lock; duplicate Stop is idempotent."""
    if not telemetry_writes_enabled():
        return
    if not isinstance(receipt, TurnReceipt):
        raise ReceiptError("receipt_invalid")
    _parse_receipt(asdict(receipt))
    path = _receipt_path(receipt.session_id, receipt.turn_id, state_root)
    value = read_json_object(path)
    if value and value.get("state") == "sealed":
        atomic_json(path, {"schema_version": 1, "state": "sealed"})
        return
    value = _registered(receipt, state_root)
    if value.get("state") != "active":
        raise ReceiptError("receipt_expired")
    atomic_json(path, {"schema_version": 1, "state": "sealed"})


def load_context(session_id: str, turn_id: str, state_root: Path = STATE_ROOT) -> dict[str, Any] | None:
    """Read historical sidecars without requiring telemetry to be enabled."""
    path = context_path(session_id, turn_id, state_root)
    if not path.exists():
        return None
    value = _parse_json(_read_utf8(path), "context_invalid")
    if not isinstance(value, dict) or type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        raise ReceiptError("context_invalid")
    if (value.get("session_id"), value.get("turn_id")) != (session_id, turn_id):
        raise ReceiptError("receipt_mismatch")
    return value


def _canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def validate_execution_plan(value: Any) -> dict[str, Any]:
    """Check the complete compiler contract, reusing stage and budget validators.

    Unknown top-level metadata is retained; all schema-v11 fields are required.
    No planner execution or task-ledger mutation happens during validation.
    """
    from strategy_runtime import (
        EFFORTS, FANOUT_MODES, QUALITY_INTENTS, REVIEW_MODES, STRATEGIES,
        RUNTIME_MAX_WORKER_IDLE_SECONDS, RUNTIME_MAX_WORKER_WALL_SECONDS,
        ExecutionPlan,
    )
    from strategies.base import ReasoningRolloutDecision, StagePolicy, TaskBudgetPolicy, WorkerBudget
    from strategies.task_phase_runtime import _plan as validate_task_budget_plan

    def require(condition):
        if not condition:
            raise ValueError("invalid plan field")

    def integer(item, minimum=0):
        require(type(item) is int and item >= minimum)

    def string(item):
        require(isinstance(item, str) and bool(item.strip()))

    def contract(cls, data):
        require(type(data) is dict)
        require({field.name for field in fields(cls)} == set(data))
        obj = cls(**data)
        obj.validate()
        return obj

    try:
        require(type(value) is dict)
        require(all(field.name in value for field in fields(ExecutionPlan)))
        require(type(value["schema_version"]) is int and value["schema_version"] == 11)
        _canonical_json(value).encode("utf-8")
        for key, choices in (
            ("strategy", STRATEGIES), ("routing", ("direct", "delegate")),
            ("review_modifier", REVIEW_MODES), ("fanout_modifier", FANOUT_MODES),
            ("quality_intent", QUALITY_INTENTS), ("parent_reasoning", EFFORTS),
            ("review_mode", ("parent", "independent+parent")),
            ("quota_pressure", ("unknown", "low", "medium", "high", "critical")),
            ("context_mode", ("compact-fresh",)),
        ):
            require(value[key] in choices)
        for key in ("parent_capability_policy", "parent_model_floor"):
            string(value[key])
        require(value["repo_policy"] is None or isinstance(value["repo_policy"], str))
        require(type(value["escalate_on_failure"]) is bool)
        require(type(value["notes"]) is list and all(isinstance(note, str) for note in value["notes"]))
        for key in ("exploration_workers", "implementation_workers", "reviewer_workers", "planned_worker_count", "max_repair_cycles"):
            integer(value[key])
        integer(value["max_concurrent_threads"], 1)
        budget = contract(WorkerBudget, value["worker_budget"])
        for key in ("max_explorers", "max_implementers", "max_reviewers", "max_total_workers"):
            integer(value["worker_budget"][key])
        if value["reasoning_rollout"] is not None:
            contract(ReasoningRolloutDecision, value["reasoning_rollout"])
        counts = []
        for count_key, stage_key, role, maximum in (
            ("exploration_workers", "exploration_stage", "explorer", budget.max_explorers),
            ("implementation_workers", "implementation_stage", "implementer", budget.max_implementers),
            ("reviewer_workers", "review_stage", "reviewer", budget.max_reviewers),
        ):
            count = value[count_key]
            counts.append(count)
            require(count <= maximum)
            if not count:
                require(value[stage_key] is None)
                require(all(value[role + "_" + suffix] is None for suffix in ("capability_policy", "model", "reasoning")))
                continue
            stage = contract(StagePolicy, value[stage_key])
            for boolean in ("cancel_if_superseded", "cancel_stragglers_after_quorum"):
                require(type(value[stage_key][boolean]) is bool)
            require(stage.min_successful_workers <= count)
            require(stage.idle_timeout_seconds <= RUNTIME_MAX_WORKER_IDLE_SECONDS)
            require(stage.hard_timeout_seconds <= RUNTIME_MAX_WORKER_WALL_SECONDS)
            string(value[role + "_capability_policy"])
            if value[role + "_model"] is None:
                # The compiler leaves the model unset when inheriting the parent.
                require(value["parent_model_floor"] == "auto")
                require(value[role + "_capability_policy"] == value["parent_capability_policy"])
            else:
                string(value[role + "_model"])
            require(value[role + "_reasoning"] in EFFORTS)
        require(sum(counts) == value["planned_worker_count"] <= budget.max_total_workers)
        require(value["max_concurrent_threads"] <= max(1, *counts))
        if value["routing"] == "direct":
            require(sum(counts) == 0 and value["task_budget"] is None)
            require(value["reasoning_rollout"] is None and value["review_mode"] == "parent")
        else:
            require(value["implementation_workers"] >= 1)
            TaskBudgetPolicy.from_dict(value["task_budget"])
            validate_task_budget_plan(value)
        require((value["reviewer_workers"] > 0) == (value["review_mode"] == "independent+parent"))
        return value
    except (TypeError, ValueError, KeyError, OverflowError, RecursionError):
        raise ReceiptError("invalid_execution_plan") from None


def _current_context(receipt: TurnReceipt, state_root: Path) -> dict[str, Any]:
    validate_receipt(receipt, state_root=state_root)
    return load_context(receipt.session_id, receipt.turn_id, state_root) or {
        "schema_version": 1, "session_id": receipt.session_id, "turn_id": receipt.turn_id,
    }


def _legacy_transcript_path(receipt: TurnReceipt, state_root: Path) -> str | None:
    key = run_key({"session_id": receipt.session_id, "turn_id": receipt.turn_id})
    path = Path(state_root) / "runs" / (safe_key_part(key) + ".json")
    run = read_json_object(path)
    if not isinstance(run, dict):
        return None
    if (run.get("session_id"), run.get("turn_id")) != (receipt.session_id, receipt.turn_id):
        return None
    return _transcript_path(run.get("transcript_path"))


def _transcript_version(path: str | None) -> tuple[int, ...] | None:
    if path is None:
        return None
    try:
        stat = Path(path).stat()
    except OSError:
        return None
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns


def _write_receipt(path: Path, state_root: Path) -> tuple[TurnReceipt, str | None, tuple[int, ...] | None]:
    receipt = load_receipt(path)
    # A rejection-only preflight prevents unknown receipts from creating lock
    # directories. The authoritative active check is repeated under the lock.
    registration = _registered(receipt, state_root)
    if registration.get("state") != "active":
        raise ReceiptError("receipt_expired")
    transcript_path = _transcript_path(registration.get("transcript_path"))
    if transcript_path is None:
        transcript_path = _legacy_transcript_path(receipt, state_root)
    version = _transcript_version(transcript_path)
    if transcript_path is not None and parent_turn_aborted(
        transcript_path, receipt.turn_id, session_id=receipt.session_id
    ):
        digest = receipt_digest(receipt.session_id, receipt.turn_id)
        with state_lock("turn-" + digest, state_root=state_root) as acquired:
            if not acquired:
                raise ReceiptError("locked")
            if _registered(receipt, state_root).get("state") != "active":
                raise ReceiptError("receipt_expired")
            seal_receipt(receipt, state_root=state_root)
        raise ReceiptError("receipt_expired")
    return receipt, transcript_path, version


def write_goal(*, receipt_file: Path, text_file: Path | None = None, text: str | None = None,
               state_root: Path = STATE_ROOT,
               clock: Callable[[], int] = now_ms) -> dict[str, Any]:
    if not telemetry_writes_enabled():
        return {"status": "disabled"}
    if (text_file is None) == (text is None):
        raise ReceiptError("invalid_arguments")
    receipt, transcript_path, version = _write_receipt(receipt_file, state_root)
    if text_file is not None:
        text = _read_utf8(text_file)
    if not isinstance(text, str):
        raise ReceiptError("invalid_arguments")
    try:
        text.encode("utf-8")
    except UnicodeError:
        raise ReceiptError("invalid_utf8") from None
    if not text.strip():
        raise ReceiptError("goal_empty")
    if len(text) > 80:
        raise ReceiptError("goal_too_long")
    # Sentence-final punctuation; dots within decimals/versions do not split.
    sentences = [part for part in re.split(r'[。！？!?]+|\.(?=\s|$)', text)
                 if part.strip().strip('"\'”’」』').strip()]
    if len(sentences) > 2:
        raise ReceiptError("goal_too_many_sentences")
    with state_lock("turn-" + receipt_digest(receipt.session_id, receipt.turn_id), state_root=state_root) as acquired:
        if not acquired:
            raise ReceiptError("locked")
        # Retry changed transcripts without parsing history under the write lock.
        if _transcript_version(transcript_path) != version:
            raise ReceiptError("locked")
        context = _current_context(receipt, state_root)
        if "goal" in context:
            existing = context["goal"]
            if not isinstance(existing, dict) or not isinstance(existing.get("text"), str):
                raise ReceiptError("context_invalid")
            if existing["text"] != text:
                raise ReceiptError("goal_conflict")
            return context
        context["goal"] = {"text": text, "source": "flow-pilot", "recorded_at_ms": clock()}
        atomic_json(context_path(receipt.session_id, receipt.turn_id, state_root), context)
        return context


def write_plan(*, receipt_file: Path, plan_file: Path, origin: str, state_root: Path = STATE_ROOT,
               clock: Callable[[], int] = now_ms) -> dict[str, Any]:
    if not telemetry_writes_enabled():
        return {"status": "disabled"}
    if origin not in {"compiled", "reused", "replanned"}:
        raise ReceiptError("invalid_origin")
    receipt, transcript_path, version = _write_receipt(receipt_file, state_root)
    plan = validate_execution_plan(_parse_json(_read_utf8(plan_file), "invalid_execution_plan"))
    with state_lock("turn-" + receipt_digest(receipt.session_id, receipt.turn_id), state_root=state_root) as acquired:
        if not acquired:
            raise ReceiptError("locked")
        if _transcript_version(transcript_path) != version:
            raise ReceiptError("locked")
        context = _current_context(receipt, state_root)
        revision = 1
        if "orchestration" in context:
            existing = context["orchestration"]
            if (not isinstance(existing, dict) or type(existing.get("revision")) is not int
                    or existing["revision"] < 1 or not isinstance(existing.get("execution_plan"), dict)):
                raise ReceiptError("context_invalid")
            if _canonical_json(existing["execution_plan"]) == _canonical_json(plan):
                return context
            revision = existing["revision"] + 1
        context["orchestration"] = {
            "origin": origin, "revision": revision, "recorded_at_ms": clock(), "execution_plan": plan,
        }
        atomic_json(context_path(receipt.session_id, receipt.turn_id, state_root), context)
        return context
