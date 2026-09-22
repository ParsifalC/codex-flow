"""Bounded live activity state for the native pet consumer.

Activity is deliberately kept separate from completed telemetry publication.
Hook events are reduced into a small, expiring snapshot and optionally sent to
the already-running overlay over the local Unix socket.  No app-server read,
transcript read, or result inference happens on this path.
"""

from __future__ import annotations

import hashlib
import json
import os
import socket
from pathlib import Path
from typing import Any

from . import common as _common
from .common import atomic_json, now_ms, read_json_object, state_lock, telemetry_writes_enabled
from .turn_context import ReceiptError, load_receipt, receipt_digest, validate_receipt


ACTIVITY_SCHEMA_VERSION = 1
ACTIVITY_TTL_MS = 120_000
MAX_ACTIVITY_SNAPSHOT_BYTES = 64 * 1024
ACTIVITY_EVENTS = frozenset(
    {"started", "running", "waiting", "review", "succeeded", "failed", "completed", "aborted"}
)
HOOK_EVENTS = frozenset(
    {"UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop", "Stop", "Interrupt"}
)
REVIEWER_AGENT_TYPES = frozenset({"reviewer", "worker-reviewer"})


class ActivityError(ValueError):
    """Secret-free activity validation or receipt failure."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def activity_directory(state_root: Path | None = None) -> Path:
    root = _common.STATE_ROOT if state_root is None else Path(state_root)
    return root / "activity"


def activity_state_path(state_root: Path | None = None) -> Path:
    return activity_directory(state_root) / "state.json"


def _bounded_json(path: Path) -> dict[str, Any] | None:
    try:
        if path.stat().st_size > MAX_ACTIVITY_SNAPSHOT_BYTES:
            return None
    except OSError:
        return None
    value = read_json_object(path)
    return value if isinstance(value, dict) else None


def load_activity(state_root: Path | None = None) -> dict[str, Any] | None:
    return _bounded_json(activity_state_path(state_root))


def _string(value: Any, *, code: str = "invalid_event") -> str:
    if not isinstance(value, str) or not value or "\x00" in value or len(value) > 512:
        raise ActivityError(code)
    try:
        value.encode("utf-8")
    except UnicodeError:
        raise ActivityError(code) from None
    return value


def _integer(value: Any, *, code: str = "invalid_event") -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ActivityError(code)
    return value


def validate_event(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("schema_version") != ACTIVITY_SCHEMA_VERSION:
        raise ActivityError("invalid_event")
    event = _string(value.get("event"))
    if event not in ACTIVITY_EVENTS:
        raise ActivityError("invalid_event")
    result = {
        "schema_version": ACTIVITY_SCHEMA_VERSION,
        "event": event,
        "session_id": _string(value.get("session_id")),
        "turn_id": _string(value.get("turn_id")),
        "sequence": _integer(value.get("sequence")),
        "timestamp_ms": _integer(value.get("timestamp_ms")),
        "started_at_ms": _integer(value.get("started_at_ms")),
        "source": _string(value.get("source")),
    }
    if result["sequence"] < 1 or result["timestamp_ms"] < 0 or result["started_at_ms"] < 0:
        raise ActivityError("invalid_event")
    for key in ("waiting_key", "waiting_fingerprint", "reviewer_key"):
        raw = value.get(key)
        if raw is not None:
            result[key] = _string(raw)
    if "async_pending" in value:
        result["async_pending"] = bool(value["async_pending"])
    if "reviewers" in value:
        reviewers = value["reviewers"]
        if not isinstance(reviewers, list) or any(not isinstance(item, str) for item in reviewers):
            raise ActivityError("invalid_event")
        result["reviewers"] = reviewers[:16]
    return result


def _same_identity(current: dict[str, Any] | None, event: dict[str, Any]) -> bool:
    return bool(
        isinstance(current, dict)
        and current.get("session_id") == event.get("session_id")
        and current.get("turn_id") == event.get("turn_id")
    )


def _terminal_event(value: Any) -> str | None:
    return value if value in {"succeeded", "failed", "completed", "aborted"} else None


def _state_for_event(name: str) -> str:
    return "running" if name in {"started", "running"} else name


def reduce_event(
    current: dict[str, Any] | None,
    raw_event: dict[str, Any],
    *,
    now_ms: int | None = None,
) -> tuple[bool, dict[str, Any] | None]:
    """Apply one normalized event, returning ``(accepted, snapshot)``."""

    event = validate_event(raw_event)
    clock = _common.now_ms() if now_ms is None else now_ms
    if clock - event["timestamp_ms"] > ACTIVITY_TTL_MS:
        return False, current
    if current is not None and not _same_identity(current, event):
        old_started = current.get("started_at_ms")
        if isinstance(old_started, int) and event["started_at_ms"] <= old_started:
            return False, current
        current = None
    if current is not None:
        previous_sequence = current.get("sequence")
        if not isinstance(previous_sequence, int) or event["sequence"] <= previous_sequence:
            return False, current
        previous_terminal = _terminal_event(current.get("terminal_event"))
        if previous_terminal and event["event"] != "completed":
            return False, current

    snapshot = dict(current or {})
    prior_terminal = _terminal_event(snapshot.get("terminal_event"))
    snapshot.update(
        {
            "schema_version": ACTIVITY_SCHEMA_VERSION,
            "session_id": event["session_id"],
            "turn_id": event["turn_id"],
            "sequence": event["sequence"],
            "timestamp_ms": event["timestamp_ms"],
            "started_at_ms": snapshot.get("started_at_ms", event["started_at_ms"]),
            "state": snapshot.get("state") if event["event"] == "completed" and prior_terminal else _state_for_event(event["event"]),
            "event": snapshot.get("event") if event["event"] == "completed" and prior_terminal else event["event"],
            "source": event["source"],
            "updated_at_ms": clock,
        }
    )
    if event["event"] in {"succeeded", "failed", "completed", "aborted"}:
        snapshot.setdefault("terminal_event", event["event"])
    if event["event"] == "waiting":
        snapshot["waiting_key"] = event.get("waiting_key")
        snapshot["waiting_fingerprint"] = event.get("waiting_fingerprint")
        snapshot["async_pending"] = bool(event.get("async_pending", False))
    elif event["event"] in {"running", "started"}:
        snapshot.pop("waiting_key", None)
        snapshot.pop("waiting_fingerprint", None)
        snapshot.pop("async_pending", None)
    if event["event"] == "review":
        snapshot["reviewers"] = list(event.get("reviewers", snapshot.get("reviewers", [])))
    elif event["event"] in {"running", "started", "completed", "aborted"}:
        snapshot.pop("reviewers", None)
    return True, snapshot


def expire_activity(current: dict[str, Any] | None, *, now_ms: int | None = None) -> dict[str, Any] | None:
    if not isinstance(current, dict):
        return None
    if _terminal_event(current.get("terminal_event")) is not None:
        return current
    clock = _common.now_ms() if now_ms is None else now_ms
    timestamp = current.get("timestamp_ms")
    if not isinstance(timestamp, int) or clock - timestamp > ACTIVITY_TTL_MS:
        return None
    return current


def _fingerprint(value: Any) -> str:
    try:
        encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError, RecursionError):
        encoded = repr(value).encode("utf-8", "replace")
    return hashlib.sha256(encoded).hexdigest()[:24]


def _tool_keys(hook: dict[str, Any]) -> tuple[str | None, str | None]:
    tool_name = hook.get("tool_name") if isinstance(hook.get("tool_name"), str) else "tool"
    tool_input = hook.get("tool_input")
    fingerprint = f"{tool_name}:{_fingerprint(tool_input)}"
    tool_use_id = hook.get("tool_use_id")
    return (f"id:{tool_use_id}" if isinstance(tool_use_id, str) and tool_use_id else None, fingerprint)


def _parent_for_reviewer(hook: dict[str, Any], state_root: Path) -> dict[str, Any] | None:
    if hook.get("agent_type") not in REVIEWER_AGENT_TYPES:
        return None
    agent_id = hook.get("agent_id")
    child_turn = hook.get("turn_id")
    session = hook.get("session_id")
    if not isinstance(agent_id, str) or not agent_id or not isinstance(child_turn, str) or not isinstance(session, str):
        return None
    index = read_json_object(Path(state_root) / "worker-index.json")
    workers = index.get("workers") if isinstance(index, dict) else None
    entry = workers.get(agent_id) if isinstance(workers, dict) else None
    executions = entry.get("executions") if isinstance(entry, dict) else None
    execution = executions.get(child_turn) if isinstance(executions, dict) else None
    run_key = execution.get("run_key") if isinstance(execution, dict) else None
    parent_turn = execution.get("parent_turn_id") if isinstance(execution, dict) else None
    if not isinstance(run_key, str) or not isinstance(parent_turn, str):
        return None
    parent = read_json_object(Path(state_root) / "runs" / f"{run_key}.json")
    if not isinstance(parent, dict) or str(parent.get("session_id") or "") != session or parent.get("turn_id") != parent_turn:
        return None
    return {"turn_id": parent_turn, "agent_id": agent_id, "child_turn": child_turn}


def _known_turn_started(session: str, turn: str, state_root: Path) -> int | None:
    key = _common.safe_key_part(f"{session}--{turn}")
    run = read_json_object(Path(state_root) / "runs" / f"{key}.json")
    if not isinstance(run, dict) or run.get("session_id") != session or run.get("turn_id") != turn:
        return None
    value = run.get("started_at_ms")
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def event_from_hook(
    hook: dict[str, Any],
    *,
    current: dict[str, Any] | None = None,
    now_ms: int | None = None,
    state_root: Path | None = None,
) -> dict[str, Any] | None:
    kind = hook.get("hook_event_name")
    if kind not in HOOK_EVENTS:
        return None
    # Parent live state is established only by the parent prompt hook.  A
    # delayed Stop/Tool event from another turn must never create a synthetic
    # new turn, and child hook payloads cannot claim the parent activity row.
    if kind not in {"SubagentStart", "SubagentStop"}:
        if hook.get("agent_id") or hook.get("role", "parent") != "parent":
            return None
    session = hook.get("session_id")
    turn = hook.get("turn_id")
    if not isinstance(session, str) or not session or not isinstance(turn, str) or not turn:
        return None
    clock = _common.now_ms() if now_ms is None else now_ms
    root = _common.STATE_ROOT if state_root is None else Path(state_root)
    reviewer = _parent_for_reviewer(hook, root) if kind in {"SubagentStart", "SubagentStop"} else None
    if kind in {"SubagentStart", "SubagentStop"} and reviewer is None:
        return None
    if reviewer is not None:
        turn = reviewer["turn_id"]
    if current is None and kind != "UserPromptSubmit":
        return None
    if current is not None and not _same_identity(current, {"session_id": session, "turn_id": turn}) and kind != "UserPromptSubmit":
        return None
    same = _same_identity(current, {"session_id": session, "turn_id": turn})
    sequence = int(current.get("sequence", 0)) + 1 if same else 1
    if same and isinstance(current.get("started_at_ms"), int):
        started = int(current["started_at_ms"])
    elif kind == "UserPromptSubmit":
        known_started = _known_turn_started(session, turn, root)
        if known_started is not None and current is not None:
            current_started = current.get("started_at_ms")
            if isinstance(current_started, int) and known_started <= current_started:
                return None
        started = known_started if known_started is not None else clock
    else:
        return None
    result: dict[str, Any] = {
        "schema_version": ACTIVITY_SCHEMA_VERSION,
        "event": "running",
        "session_id": session,
        "turn_id": turn,
        "sequence": sequence,
        "timestamp_ms": clock,
        "started_at_ms": started,
        "source": f"hook:{kind}",
    }
    if kind == "UserPromptSubmit":
        result["event"] = "started"
    elif kind == "PermissionRequest":
        result["event"] = "waiting"
    elif kind == "PreToolUse":
        tool_name = hook.get("tool_name")
        if tool_name not in {"request_user_input", "request_user_input_async"}:
            result["event"] = current.get("state", "running") if same and current and current.get("state") in {"waiting", "review"} else "running"
        else:
            result["event"] = "waiting"
    elif kind == "PostToolUse":
        if same and current and current.get("state") == "review":
            result["event"] = "review"
            result["reviewers"] = list(current.get("reviewers", []))
        elif same and current and current.get("state") == "waiting":
            key, fingerprint = _tool_keys(hook)
            matches = {key, fingerprint} & {current.get("waiting_key"), current.get("waiting_fingerprint")}
            # Async tools return immediately after publishing the question.
            # Only later user input or an explicit semantic report can resume.
            result["event"] = "waiting" if current.get("async_pending") or not matches else "running"
            if result["event"] == "waiting":
                result["waiting_key"] = current.get("waiting_key")
                result["waiting_fingerprint"] = current.get("waiting_fingerprint")
                result["async_pending"] = bool(current.get("async_pending", False))
        else:
            result["event"] = "running"
    elif kind == "SubagentStart":
        result["event"] = "review"
        result["reviewer_key"] = reviewer["child_turn"]
        reviewers = set(current.get("reviewers", [])) if same and current else set()
        reviewers.add(reviewer["child_turn"])
        result["reviewers"] = sorted(reviewers)
    elif kind == "SubagentStop":
        reviewers = set(current.get("reviewers", [])) if same and current else set()
        reviewers.discard(reviewer["child_turn"])
        if reviewers:
            result["event"] = "review"
            result["reviewers"] = sorted(reviewers)
        else:
            result["event"] = "running"
    elif kind == "Stop":
        result["event"] = "completed"
    elif kind == "Interrupt":
        result["event"] = "aborted"
    if result["event"] == "waiting":
        preserve_waiting = (
            same and current and current.get("state") == "waiting"
            and (kind == "PostToolUse" or (kind == "PreToolUse" and hook.get("tool_name") not in {"request_user_input", "request_user_input_async"}))
        )
        if preserve_waiting:
            result["waiting_key"] = current.get("waiting_key")
            result["waiting_fingerprint"] = current.get("waiting_fingerprint")
            result["async_pending"] = bool(current.get("async_pending", False))
        else:
            key, fingerprint = _tool_keys(hook)
            result["waiting_key"] = key
            result["waiting_fingerprint"] = fingerprint
            result["async_pending"] = hook.get("tool_name") == "request_user_input_async"
    return validate_event(result)


def _send_native(event: dict[str, Any], socket_path: Path | None) -> str:
    if socket_path is None:
        home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
        socket_path = home / "codex-flow" / "overlay.sock"
    if not socket_path.exists() or socket_path.is_symlink():
        return "unavailable"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.5)
            client.connect(str(socket_path))
            payload = json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            client.sendall(b"pet event " + payload.encode("utf-8") + b"\n")
            response = client.recv(4096)
        value = json.loads(response.decode("utf-8-sig").strip()) if response else {}
        return "accepted" if isinstance(value, dict) and value.get("ok") is True else "rejected"
    except (OSError, TimeoutError, UnicodeError, json.JSONDecodeError):
        return "unavailable"


def _persist_event_locked(
    event: dict[str, Any],
    *,
    state_root: Path,
    now_ms: int | None,
) -> dict[str, Any]:
    current = load_activity(state_root)
    accepted, snapshot = reduce_event(current, event, now_ms=now_ms)
    if not accepted or snapshot is None:
        return {"accepted": False, "status": "stale", "event": event.get("event")}
    encoded = json.dumps(snapshot, ensure_ascii=False, sort_keys=True).encode("utf-8")
    if len(encoded) > MAX_ACTIVITY_SNAPSHOT_BYTES:
        return {"accepted": False, "status": "too_large"}
    atomic_json(activity_state_path(state_root), snapshot)
    return {"accepted": True, "status": "saved", "event": event}


def record_activity(
    event: dict[str, Any],
    *,
    state_root: Path | None = None,
    socket_path: Path | None = None,
    now_ms: int | None = None,
) -> dict[str, Any]:
    if not telemetry_writes_enabled():
        return {"accepted": False, "status": "disabled"}
    root = _common.STATE_ROOT if state_root is None else Path(state_root)
    directory = activity_directory(root)
    canonical = validate_event(event)
    with state_lock("activity", state_root=directory) as acquired:
        if not acquired:
            return {"accepted": False, "status": "locked"}
        result = _persist_event_locked(canonical, state_root=root, now_ms=now_ms)
    if not result["accepted"]:
        return result
    result["native"] = _send_native(canonical, socket_path)
    return result


def record_hook_activity(
    hook: dict[str, Any],
    *,
    state_root: Path | None = None,
    socket_path: Path | None = None,
    now_ms: int | None = None,
) -> dict[str, Any]:
    if not telemetry_writes_enabled():
        return {"accepted": False, "status": "disabled"}
    root = _common.STATE_ROOT if state_root is None else Path(state_root)
    directory = activity_directory(root)
    with state_lock("activity", state_root=directory) as acquired:
        if not acquired:
            return {"accepted": False, "status": "locked"}
        current = load_activity(root)
        event = event_from_hook(hook, current=current, now_ms=now_ms, state_root=root)
        if event is None:
            return {"accepted": False, "status": "ignored"}
        canonical = validate_event(event)
        result = _persist_event_locked(canonical, state_root=root, now_ms=now_ms)
    if not result["accepted"]:
        return result
    result["native"] = _send_native(canonical, socket_path)
    return result


def record_receipt_activity(
    status: str,
    receipt_file: Path,
    *,
    state_root: Path | None = None,
    socket_path: Path | None = None,
    now_ms: int | None = None,
) -> dict[str, Any]:
    if status not in {"running", "waiting", "review", "succeeded", "failed"}:
        raise ActivityError("invalid_status")
    if not telemetry_writes_enabled():
        return {"accepted": False, "status": "disabled"}
    root = _common.STATE_ROOT if state_root is None else Path(state_root)
    receipt = load_receipt(Path(receipt_file))
    digest = receipt_digest(receipt.session_id, receipt.turn_id)
    event: dict[str, Any] | None = None
    with state_lock("turn-" + digest, state_root=root) as acquired:
        if not acquired:
            raise ReceiptError("locked")
        validate_receipt(receipt, state_root=root)
        directory = activity_directory(root)
        with state_lock("activity", state_root=directory) as activity_acquired:
            if not activity_acquired:
                return {"accepted": False, "status": "locked"}
            current = load_activity(root)
            clock = _common.now_ms() if now_ms is None else now_ms
            same = _same_identity(current, {"session_id": receipt.session_id, "turn_id": receipt.turn_id})
            sequence = int(current.get("sequence", 0)) + 1 if same and current else 1
            known_started = _known_turn_started(receipt.session_id, receipt.turn_id, root)
            started = (
                int(current["started_at_ms"])
                if same and current and isinstance(current.get("started_at_ms"), int)
                else known_started if known_started is not None else clock
            )
            event = validate_event(
                {
                    "schema_version": ACTIVITY_SCHEMA_VERSION,
                    "event": status,
                    "session_id": receipt.session_id,
                    "turn_id": receipt.turn_id,
                    "sequence": sequence,
                    "timestamp_ms": clock,
                    "started_at_ms": started,
                    "source": "activity-cli",
                }
            )
            result = _persist_event_locked(event, state_root=root, now_ms=clock)
    if not result["accepted"]:
        return result
    result["native"] = _send_native(event, socket_path)
    return result
