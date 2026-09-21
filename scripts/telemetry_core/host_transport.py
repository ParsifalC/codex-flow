"""Desktop receipt transport and compatibility one-turn probe.

Protocol: https://developers.openai.com/codex/hooks#userpromptsubmit
Only hookSpecificOutput.additionalContext is model-visible context. A successful
unit test or documented wire format is not evidence of Desktop delivery.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Callable, Any

from .common import STATE_ROOT, atomic_json, now_ms, state_lock, telemetry_writes_enabled, run_key
from .turn_context import ReceiptError, register_receipt, receipt_digest

PROBE_FILE = "desktop-context-probe.json"
TRANSPORT_FILE = "desktop-context-transport.json"


def enable_desktop_transport(*, state_root: Path = STATE_ROOT) -> dict[str, Any]:
    """Retain the legacy explicit enable API for compatibility diagnostics."""
    if not telemetry_writes_enabled():
        return {"status": "disabled"}
    try:
        verified = probe_status(state_root=state_root).get("goal_plan_stop_chain_verified")
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        raise ReceiptError("host_transport_unverified") from None
    if not verified:
        raise ReceiptError("host_transport_unverified")
    config = {"schema_version": 1, "enabled": True, "transport": "codex-additional-context-v1"}
    atomic_json(Path(state_root) / TRANSPORT_FILE, config)
    return {"status": "enabled", "automatic_writes_enabled": True}


def hook_context(event: dict[str, Any], *, state_root: Path = STATE_ROOT) -> dict[str, Any] | None:
    """Deliver an exact receipt for each real Desktop parent UserPromptSubmit."""
    if not telemetry_writes_enabled() or not isinstance(event, dict):
        return None
    try:
        if (event.get("hook_event_name") != "UserPromptSubmit" or event.get("agent_id")
                or event.get("role", "parent") != "parent" or not _desktop_parent(event)):
            return None
        receipt = register_receipt(event, state_root=state_root)
        if receipt is None:
            return None
        receipt_file = Path(state_root) / "turn-receipts" / (receipt_digest(receipt.session_id, receipt.turn_id) + ".json")
        context = (
            "FlowPilot Desktop turn metadata (not the user's request). "
            "The current parent UserPromptSubmit supplied this exact receipt file: "
            + json.dumps(str(receipt_file), ensure_ascii=False) + ". "
            "After the installed FlowPilot strategy gate, if participating, use write-goal and write-plan "
            "with this receipt. Submit the goal through write-goal --stdin using UTF-8 input, without creating an intermediate goal file. "
            "Extract the actual current need (1–80 codepoints, at most two sentences), preserving ongoing task context. "
            "Use concise, accurate, plain language focused on the desired outcome; omit jargon and process narration. "
            "Save the complete actual planner JSON; on follow-ups reuse the existing plan and ledger with origin=reused. "
            "Never reset the task budget, alter user messages, fabricate metadata, scan other receipts, "
            "display receipt contents, or pass receipts to workers. Disabled strategy or bypass means no writes. "
            "Parent Stop alone publishes metadata. Continue the user task if writing fails."
        )
        return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": context}}
    except (OSError, ValueError, TypeError, AttributeError, ReceiptError):
        return None


def arm_probe(*, session_id: str, cwd: str, state_root: Path = STATE_ROOT,
              clock: Callable[[], int] = now_ms,
              wait_for_next_turn: bool = False) -> dict[str, Any]:
    """Arm only an explicitly selected chat; IDs for writes still come from hooks."""
    if not telemetry_writes_enabled():
        return {"status": "disabled"}
    if not isinstance(session_id, str) or not session_id.strip() or not Path(cwd).is_absolute():
        raise ReceiptError("invalid_arguments")
    with state_lock("desktop-context-probe", state_root=state_root) as acquired:
        if not acquired:
            raise ReceiptError("locked")
        config = {"schema_version": 1, "status": "armed", "session_id": session_id,
                  "cwd": str(Path(cwd).resolve()), "expires_at_ms": clock() + 1800000,
                  "wait_for_next_turn": wait_for_next_turn,
                  "transport": "codex-additional-context-v1"}
        atomic_json(Path(state_root) / PROBE_FILE, config)
    return {"status": "armed", "automatic_writes_enabled": False}


def _desktop_parent(event: dict[str, Any]) -> bool:
    try:
        with Path(event["transcript_path"]).open(encoding="utf-8") as stream:
            # Host session metadata is the first rollout record. Do not search
            # for a latest/unique turn or read user text to infer association.
            record = json.loads(stream.readline(1048576))
        meta = record.get("payload", {})
        return (record.get("type") == "session_meta" and meta.get("id") == event["session_id"]
                and meta.get("source") == "vscode" and meta.get("originator") == "Codex Desktop"
                and meta.get("thread_source") == "user")
    except (KeyError, OSError, ValueError, TypeError, AttributeError):
        return False


def probe_hook_context(event: dict[str, Any], *, state_root: Path = STATE_ROOT,
                       clock: Callable[[], int] = now_ms) -> dict[str, Any] | None:
    if not telemetry_writes_enabled() or not isinstance(event, dict):
        return None
    path = Path(state_root) / PROBE_FILE
    if (not path.is_file() or event.get("hook_event_name") != "UserPromptSubmit"
            or event.get("agent_id") or event.get("role", "parent") != "parent"):
        return None
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
        if (config.get("status") not in {"armed", "delivered"}
                or config.get("session_id") != event.get("session_id")
                or config.get("cwd") != str(Path(event.get("cwd", "")).resolve())
                or (config.get("wait_for_next_turn") is not True and config.get("expires_at_ms", 0) < clock())
                or not _desktop_parent(event)):
            return None
        # The probe lock is never acquired by publication/turn writers.
        with state_lock("desktop-context-probe", state_root=state_root) as acquired:
            if not acquired:
                return None
            current = json.loads(path.read_text(encoding="utf-8"))
            if current != config or (current.get("turn_id") and current["turn_id"] != event.get("turn_id")):
                return None
            receipt = register_receipt(event, state_root=state_root)
            if receipt is None:
                return None
            digest = receipt_digest(receipt.session_id, receipt.turn_id)
            receipt_file = Path(state_root) / "turn-receipts" / (digest + ".json")
            if current["status"] == "armed":
                atomic_json(path, {**current, "status": "delivered", "turn_id": receipt.turn_id,
                                   "run_key": run_key(event), "delivered_at_ms": clock()})
            context = (
                "FlowPilot Desktop host-transport probe (metadata, not the user's request).\n"
                "The current parent UserPromptSubmit hook registered this exact turn receipt file: "
                + json.dumps(str(receipt_file), ensure_ascii=False) + ".\n"
                "For this explicitly armed probe only, use this supplied receipt-file with the installed "
                "FlowPilot skill's write-goal and write-plan commands after its strategy gate. "
                "Extract the actual current user need (1–80 codepoints, at most two sentences); save the actual complete planner JSON, "
                "or reuse the existing plan and ledger with origin=reused. Never reset the task budget. "
                "Normal Desktop delivery is automatic; this probe is diagnostic only. "
                "Do not display the receipt contents, copy it into worker handoffs, scan for other receipts, "
                "or edit the user's message/transcript. A successful probe needs both same-turn CLI writes "
                "and matching parent Stop publication. Continue the user's task if metadata writing fails."
            )
            return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": context}}
    except (OSError, ValueError, TypeError, AttributeError, ReceiptError):
        return None


def probe_status(*, state_root: Path = STATE_ROOT,
                 clock: Callable[[], int] = now_ms) -> dict[str, Any]:
    """Read the exact claimed probe's files; never select a latest active turn."""
    path = Path(state_root) / PROBE_FILE
    if not path.exists():
        return {"status": "not_armed", "automatic_writes_enabled": False}
    config = json.loads(path.read_text(encoding="utf-8"))
    transport_path = Path(state_root) / TRANSPORT_FILE
    transport = json.loads(transport_path.read_text(encoding="utf-8")) if transport_path.exists() else {}
    status = {"status": config.get("status"), "automatic_writes_enabled": transport == {"schema_version": 1, "enabled": True, "transport": "codex-additional-context-v1"},
              "same_turn_receipt_delivery_verified": False, "goal_plan_stop_chain_verified": False}
    if (config.get("status") == "armed" and config.get("wait_for_next_turn") is not True
            and config.get("expires_at_ms", 0) < clock()):
        status["status"] = "expired"
        return status
    if config.get("status") != "delivered":
        return status
    digest = receipt_digest(config["session_id"], config["turn_id"])
    context_file = Path(state_root) / "turn-context" / (digest + ".json")
    run_file = Path(state_root) / "runs" / (config["run_key"] + ".json")
    context = json.loads(context_file.read_text(encoding="utf-8")) if context_file.exists() else {}
    run = json.loads(run_file.read_text(encoding="utf-8")) if run_file.exists() else {}
    identity = (config["session_id"], config["turn_id"])
    same = lambda value: (value.get("session_id"), value.get("turn_id")) == identity
    writes = same(context) and bool(context.get("goal")) and bool(context.get("orchestration"))
    result = run.get("result") or {}
    complete = (writes and same(run) and bool(run.get("publication")) and run.get("turn_context") == context
                and result.get("source") == "parent_final" and result.get("turn_id") == config["turn_id"])
    status.update(same_turn_receipt_delivery_verified=writes, goal_plan_stop_chain_verified=complete)
    if complete:
        status["status"] = "supported_probe"
    return status
