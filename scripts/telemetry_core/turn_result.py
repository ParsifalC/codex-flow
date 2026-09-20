"""Read a proven parent final from one exact Desktop transcript turn.

Only the sanitized, observed Desktop format is accepted. This proves transcript
attribution; it does not establish a supported host receipt transport.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .app_server import _transcript_timestamp_ms


def _identifier(value: Any) -> str | None:
    return value if isinstance(value, str) and value.strip() else None


def _parent_record(payload: dict[str, Any]) -> bool:
    return not (
        payload.get("agent_id")
        or payload.get("thread_source") not in (None, "user")
        or isinstance(payload.get("source"), dict)
    )


def _scan(path: str | None, turn_id: str | None, session_id: str):
    if not _identifier(path) or not _identifier(turn_id) or not _identifier(session_id):
        return None, None, False
    proven = False
    current_turn = None
    fragments: list[str] = []
    truncated = False
    completed = None
    aborted = False
    try:
        with Path(path).open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    current_turn = None
                    continue
                if not isinstance(record, dict) or not isinstance(record.get("payload"), dict):
                    continue
                payload = record["payload"]
                kind = record.get("type")
                if kind == "session_meta":
                    if not (
                        payload.get("id") == session_id
                        and payload.get("source") == "vscode"
                        and payload.get("originator") == "Codex Desktop"
                        and payload.get("thread_source") == "user"
                    ):
                        return None, None, False
                    proven = True
                    continue
                if not proven:
                    continue
                explicit = _identifier(payload.get("turn_id")) or _identifier(record.get("turn_id"))
                if kind == "turn_context" or (kind == "event_msg" and payload.get("type") == "task_started"):
                    if _parent_record(payload) and _parent_record(record):
                        current_turn = explicit
                    continue
                if kind == "event_msg" and payload.get("type") in {"task_complete", "turn_aborted"}:
                    parent_terminal = _parent_record(payload) and _parent_record(record)
                    if parent_terminal:
                        if (explicit or current_turn) == turn_id:
                            if payload.get("type") == "task_complete":
                                completed = completed or _transcript_timestamp_ms(record.get("timestamp"))
                            else:
                                aborted = True
                        current_turn = None
                    continue
                if (
                    kind != "response_item" or (explicit or current_turn) != turn_id
                    or payload.get("type") != "message" or payload.get("role") != "assistant"
                    or payload.get("phase") != "final_answer"
                    or not _parent_record(payload) or not _parent_record(record)
                ):
                    continue
                content = payload.get("content")
                if not isinstance(content, list):
                    continue
                text = "".join(
                    block["text"] for block in content
                    if isinstance(block, dict) and block.get("type") == "output_text"
                    and isinstance(block.get("text"), str)
                )
                if text.strip():
                    fragments.append(text)
                    truncated |= payload.get("truncated") is True or record.get("truncated") is True
    except (OSError, UnicodeError, ValueError, OverflowError):
        return None, None, False
    result = None
    if fragments:
        result = {"text": "\n\n".join(fragments), "source": "parent_final", "turn_id": turn_id, "truncated": truncated}
    return result, completed, aborted


def extract_parent_final(transcript_path: str | None, turn_id: str | None,
                         *, session_id: str, max_chars: int = 0) -> dict[str, Any] | None:
    result, _, _ = _scan(transcript_path, turn_id, session_id)
    if result is not None and max_chars > 0 and len(result["text"]) > max_chars:
        result["text"] = result["text"][:max_chars]
        result["truncated"] = True
    return result


def parent_turn_completed_at(transcript_path: str | None, turn_id: str | None,
                             *, session_id: str) -> int | None:
    """Use the same parent proof and boundaries for immutable Stop ordering."""
    return _scan(transcript_path, turn_id, session_id)[1]


def parent_turn_aborted(transcript_path: str | None, turn_id: str | None,
                        *, session_id: str) -> bool:
    """Return whether one exact Desktop parent turn has an abort event."""
    return _scan(transcript_path, turn_id, session_id)[2]
