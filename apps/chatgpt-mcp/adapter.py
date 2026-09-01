"""Read-only adapter from FlowPilot telemetry to MCP tool/resource values.

This module deliberately uses the structured telemetry query helpers instead of
the telemetry CLI, hook collector, or app-server client.  It is safe to import
from a long-running process: importing it does not start any subprocesses or
write telemetry state.
"""

from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


TOOL_NAME = "flowpilot_get_telemetry"
RESOURCE_URI = "ui://flowpilot/telemetry-pip.html"
RESOURCE_MIME_TYPE = "text/html;profile=mcp-app"
WIDGET_FILENAME = "widget.html"
_MAX_WIDGET_BYTES = 1024 * 1024


# ``telemetry_core`` lives under scripts/ in the checkout.  Keep this import
# local to the repository layout so the service can be started from any cwd.
_MODULE_DIR = Path(__file__).resolve().parent
_REPOSITORY_ROOT = _MODULE_DIR.parents[1]
_SCRIPTS_DIR = _REPOSITORY_ROOT / "scripts"
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

_TELEMETRY_IMPORT_ERROR: Optional[BaseException] = None
try:
    from telemetry_core import (  # type: ignore
        fmt_duration_ms,
        fmt_local_timestamp,
        fmt_tokens,
        list_runs,
        load_run,
        resolve_run_target,
        run_context,
        run_key,
    )
except Exception as exc:  # pragma: no cover - only used by broken installs
    # The MCP process should remain a harmless, healthy local service even if
    # telemetry is unavailable in an incomplete checkout or installation.
    _TELEMETRY_IMPORT_ERROR = exc
    fmt_duration_ms = None  # type: ignore
    fmt_local_timestamp = None  # type: ignore
    fmt_tokens = None  # type: ignore
    list_runs = None  # type: ignore
    load_run = None  # type: ignore
    resolve_run_target = None  # type: ignore
    run_context = None  # type: ignore
    run_key = None  # type: ignore


class WidgetResourceError(IOError):
    """Raised when the one allowed MCP Apps resource cannot be read."""


def _is_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def _number(value: Any) -> Optional[float]:
    return float(value) if _is_number(value) else None


def _integer(value: Any) -> Optional[int]:
    if not _is_number(value):
        return None
    return int(value)


def _text(value: Any, limit: int = 128) -> Optional[str]:
    if value is None:
        return None
    value = " ".join(str(value).split())
    if not value:
        return None
    return value[:limit]


def _empty_quota() -> Dict[str, Any]:
    return {"used": [], "remaining": [], "windows": []}


def unavailable_telemetry() -> Dict[str, Any]:
    """Return the stable shape used when telemetry data is not available."""

    return {
        "run_id": None,
        "session": None,
        "project": None,
        "branch": None,
        "status": "unavailable",
        "started_at": None,
        "finished_at": None,
        "duration_seconds": None,
        "duration_text": None,
        "participants": [],
        "parent": {"model": None, "reasoning_effort": None, "total_tokens": None},
        "parent_model": None,
        "parent_reasoning_effort": None,
        "total_tokens": None,
        "quota": _empty_quota(),
    }


def _safe_context(run: Dict[str, Any]) -> Tuple[Optional[str], Optional[str], Optional[str]]:
    """Get display context without falling back to a thread preview.

    ``run_context`` is the canonical project/branch formatter, but its session
    fallback includes ``thread.preview``.  A preview can contain user text, so
    remove it before calling the shared helper.
    """

    if run_context is None:
        return None, None, None
    safe_run = dict(run)
    thread = run.get("thread")
    if isinstance(thread, dict):
        safe_thread = dict(thread)
        safe_thread.pop("preview", None)
        safe_run["thread"] = safe_thread
    try:
        return run_context(safe_run)
    except Exception:
        return None, None, None


def _run_identifier(run: Dict[str, Any]) -> Optional[str]:
    explicit = _text(run.get("run_id") or run.get("id"))
    if explicit:
        return explicit
    session_id = _text(run.get("session_id"))
    turn_id = _text(run.get("turn_id"))
    if session_id and turn_id:
        # This mirrors telemetry_core.run_key while avoiding a local path or
        # any other storage detail in the MCP response.
        if run_key is not None:
            try:
                return _text(run_key(run))
            except Exception:
                pass
        return "%s--%s" % (session_id.replace("/", "_"), turn_id.replace("/", "_"))
    return session_id or turn_id


def _status(run: Dict[str, Any]) -> str:
    value = _text(run.get("status"), limit=32)
    if value:
        return value
    return "completed" if _integer(run.get("finished_at_ms")) is not None else "running"


def _usage(participant: Any) -> Optional[Dict[str, Any]]:
    if not isinstance(participant, dict):
        return None
    value = participant.get("usage_delta")
    if isinstance(value, dict):
        return value
    value = participant.get("usage")
    return value if isinstance(value, dict) else None


def _participant(
    participant: Any,
    role: str,
    participant_status: str,
) -> Dict[str, Any]:
    if not isinstance(participant, dict):
        participant = {}
    usage = _usage(participant)
    return {
        "role": role,
        "agent_id": _text(participant.get("agent_id")),
        "agent_type": _text(participant.get("agent_type")),
        "model": _text(participant.get("model")),
        "reasoning_effort": _text(
            participant.get("reasoning_effort") or participant.get("reasoningEffort")
        ),
        "status": _text(participant.get("status"), limit=32) or participant_status,
        "total_tokens": _integer(usage.get("total_tokens")) if usage else None,
    }


def _total_tokens(participants: List[Dict[str, Any]]) -> Optional[int]:
    """Sum tokens only when every participant has an exact total.

    A partial sum would look authoritative in a dashboard while hiding a
    missing worker measurement, so the adapter follows telemetry's
    all-participants aggregation semantics and returns null instead.
    """

    values = [item.get("total_tokens") for item in participants]
    if not values or any(not isinstance(value, int) for value in values):
        return None
    return sum(values)


def _quota(run: Dict[str, Any]) -> Dict[str, Any]:
    # quota_after is the current snapshot for a completed run.  An in-flight
    # run has only quota_before; exposing that snapshot is more useful than
    # inventing a current value, and the source is kept explicit in each item.
    source = run.get("quota_after")
    source_name = "after"
    if not isinstance(source, list) or not source:
        source = run.get("quota_before")
        source_name = "before"
    if not isinstance(source, list):
        source = []

    used: List[Dict[str, Any]] = []
    remaining: List[Dict[str, Any]] = []
    windows: List[Dict[str, Any]] = []
    for raw in source:
        if not isinstance(raw, dict):
            continue
        used_percent = _number(raw.get("used_percent"))
        remaining_percent = (
            max(0.0, 100.0 - used_percent) if used_percent is not None else None
        )
        duration = _integer(raw.get("window_duration_mins"))
        resets_at = raw.get("resets_at") if _is_number(raw.get("resets_at")) else None
        slot = _text(raw.get("slot"), limit=32)
        common = {
            "slot": slot,
            "window_duration_mins": duration,
            "resets_at": resets_at,
            "source": source_name,
        }
        used.append(dict(common, percent=used_percent))
        remaining.append(dict(common, percent=remaining_percent))
        windows.append(
            dict(
                common,
                used_percent=used_percent,
                remaining_percent=remaining_percent,
            )
        )
    return {"used": used, "remaining": remaining, "windows": windows}


def telemetry_for_target(target: str = "last") -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """Read one run through telemetry_core without invoking collection code."""

    if resolve_run_target is None:
        return None, "FlowPilot telemetry is unavailable."
    try:
        run, identifier = resolve_run_target(target or "last")
    except Exception:
        return None, "FlowPilot telemetry is unavailable."
    if not isinstance(run, dict):
        return None, _text(identifier) or "No FlowPilot telemetry run recorded yet."
    return run, _text(identifier)


def build_telemetry(run: Dict[str, Any], identifier: Optional[str] = None) -> Dict[str, Any]:
    """Convert one internal run record into the public, transcript-free shape."""

    status = _status(run)
    session, project, branch = _safe_context(run)
    if not session:
        session = _text(run.get("session_id"))

    started_ms = _integer(run.get("started_at_ms"))
    finished_ms = _integer(run.get("finished_at_ms"))
    duration_ms: Optional[int] = None
    if started_ms is not None and finished_ms is not None and finished_ms >= started_ms:
        duration_ms = finished_ms - started_ms

    parent = run.get("parent") if isinstance(run.get("parent"), dict) else {}
    parent_item = _participant(parent, "parent", status)
    participants = [parent_item]
    workers = run.get("workers")
    if isinstance(workers, dict):
        for worker in workers.values():
            if isinstance(worker, dict):
                participants.append(
                    _participant(worker, "worker", status)
                )

    parent_data = {
        "model": parent_item.get("model"),
        "reasoning_effort": parent_item.get("reasoning_effort"),
        "total_tokens": parent_item.get("total_tokens"),
    }
    result: Dict[str, Any] = {
        "run_id": _run_identifier(run) or identifier,
        "session": session,
        "project": project,
        "branch": branch,
        "status": status,
        "started_at": (
            fmt_local_timestamp(started_ms, milliseconds=True)
            if fmt_local_timestamp is not None
            else None
        ),
        "finished_at": (
            fmt_local_timestamp(finished_ms, milliseconds=True)
            if fmt_local_timestamp is not None
            else None
        ),
        "duration_seconds": (
            duration_ms / 1000.0 if duration_ms is not None else None
        ),
        "duration_text": (
            fmt_duration_ms(duration_ms)
            if duration_ms is not None and fmt_duration_ms is not None
            else None
        ),
        "participants": participants,
        "parent": parent_data,
        "parent_model": parent_data["model"],
        "parent_reasoning_effort": parent_data["reasoning_effort"],
        "total_tokens": _total_tokens(participants),
        "quota": _quota(run),
    }
    return result


def get_telemetry(arguments: Optional[Dict[str, Any]] = None) -> Tuple[Dict[str, Any], str, bool]:
    """Return ``(structured_content, text, is_error)`` for tools/call."""

    args = arguments if isinstance(arguments, dict) else {}
    target = args.get("target")
    if target is None:
        target = args.get("run_id")
    if isinstance(target, dict):
        target = target.get("run_id") or target.get("target")
    if target is None or target == "":
        target = "last"
    if not isinstance(target, str):
        return unavailable_telemetry(), "Telemetry target must be a run id or 'last'.", True

    run, message = telemetry_for_target(target)
    if run is None:
        text = message or "No FlowPilot telemetry run recorded yet."
        return unavailable_telemetry(), text, False

    structured = build_telemetry(run, message)
    status = structured.get("status") or "unavailable"
    project = structured.get("project") or "unknown project"
    tokens = structured.get("total_tokens")
    token_text = str(tokens) if isinstance(tokens, int) else "token usage unavailable"
    text = "FlowPilot run %s: %s · %s · %s tokens." % (
        structured.get("run_id") or "unknown",
        status,
        project,
        token_text,
    )
    return structured, text, False


def tool_result(arguments: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Build an MCP tool result with both human-readable and structured data."""

    try:
        structured, text, is_error = get_telemetry(arguments)
    except Exception:
        structured = unavailable_telemetry()
        text = "FlowPilot telemetry is temporarily unavailable."
        is_error = True
    result: Dict[str, Any] = {
        "content": [{"type": "text", "text": text}],
        "structuredContent": structured,
    }
    if is_error:
        result["isError"] = True
    return result


def read_widget() -> str:
    """Read exactly the fixed widget resource and reject symlink escapes."""

    module_dir = os.path.realpath(str(_MODULE_DIR))
    widget_path = os.path.join(module_dir, WIDGET_FILENAME)
    if os.path.realpath(widget_path) != widget_path:
        raise WidgetResourceError("The telemetry widget resource is invalid.")
    try:
        with open(widget_path, "rb") as stream:
            data = stream.read(_MAX_WIDGET_BYTES + 1)
    except OSError as exc:
        raise WidgetResourceError("The telemetry widget resource is unavailable.") from exc
    if len(data) > _MAX_WIDGET_BYTES:
        raise WidgetResourceError("The telemetry widget resource is too large.")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise WidgetResourceError("The telemetry widget resource is not valid UTF-8.") from exc


def resource_descriptor() -> Dict[str, Any]:
    return {
        "uri": RESOURCE_URI,
        "name": "flowpilot-telemetry-pip",
        "title": "FlowPilot telemetry",
        "description": "Read-only FlowPilot run telemetry dashboard.",
        "mimeType": RESOURCE_MIME_TYPE,
    }


def tool_descriptor() -> Dict[str, Any]:
    return {
        "name": TOOL_NAME,
        "title": "FlowPilot telemetry",
        "description": (
            "Read the latest FlowPilot telemetry run, or a run by run_id. "
            "This tool is read-only and never starts an app-server."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {
                    "type": "string",
                    "description": "Optional run id; omit or use 'last' for the latest run.",
                },
                "run_id": {
                    "type": "string",
                    "description": "Optional alias for target when selecting a run.",
                },
            },
            "additionalProperties": False,
        },
        "_meta": {"ui": {"resourceUri": RESOURCE_URI}},
    }


__all__ = [
    "RESOURCE_MIME_TYPE",
    "RESOURCE_URI",
    "TOOL_NAME",
    "WidgetResourceError",
    "build_telemetry",
    "get_telemetry",
    "read_widget",
    "resource_descriptor",
    "tool_descriptor",
    "tool_result",
    "unavailable_telemetry",
]
