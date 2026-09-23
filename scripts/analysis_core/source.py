"""Strict, read-only parsing of a selected Codex Desktop transcript.

The Desktop transcript is an append-only JSONL stream.  The parser keeps only
parent user text and parent final answers, while retaining the exact message
IDs and turn metadata needed for idempotent queueing.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


WRAPPER_KINDS = frozenset(
    (
        "plugins.recommendations",
        "recommended_plugins",
        "agents_md.instructions",
        "AGENTS.md",
        "environments.environment_context",
        "environment_context",
        "goal.internal_context",
    )
)


class SourceError(ValueError):
    """A stable, displayable source validation failure."""

    def __init__(self, code: str, message: Optional[str] = None, *, line: Optional[int] = None):
        self.code = code
        self.line = line
        self.message = message or code
        super().__init__(self.message)


@dataclass(frozen=True)
class TranscriptMessage:
    message_id: str
    turn_id: str
    role: str
    text: str
    source_index: int
    raw_line: int
    create_time: Any = None
    phase: Optional[str] = None
    content_kinds: Tuple[str, ...] = ()


@dataclass
class TranscriptTurn:
    turn_id: str
    sequence: int
    user_messages: List[TranscriptMessage] = field(default_factory=list)
    final_messages: List[TranscriptMessage] = field(default_factory=list)

    @property
    def user_text(self) -> str:
        return self.user_messages[-1].text if self.user_messages else ""

    @property
    def user_message_id(self) -> Optional[str]:
        return self.user_messages[-1].message_id if self.user_messages else None

    @property
    def user_source_index(self) -> Optional[int]:
        return self.user_messages[-1].source_index if self.user_messages else None

    @property
    def original_result(self) -> Optional[str]:
        return self.final_messages[-1].text if self.final_messages else None

    @property
    def final_message_id(self) -> Optional[str]:
        return self.final_messages[-1].message_id if self.final_messages else None

    @property
    def final_source_index(self) -> Optional[int]:
        return self.final_messages[-1].source_index if self.final_messages else None


@dataclass
class Transcript:
    session_id: str
    messages: List[TranscriptMessage]
    turns: List[TranscriptTurn]
    coverage: Dict[str, Any]
    excluded_message_ids: Tuple[str, ...] = ()

    @property
    def user_messages(self) -> List[TranscriptMessage]:
        return [message for message in self.messages if message.role == "user"]

    @property
    def final_messages(self) -> List[TranscriptMessage]:
        return [message for message in self.messages if message.role == "assistant"]


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip()) and "\x00" not in value


def _metadata(payload: Dict[str, Any]) -> Dict[str, Any]:
    value = payload.get("internal_chat_message_metadata_passthrough")
    if value is None:
        value = payload.get("internalChatMessageMetadataPassthrough")
    if not isinstance(value, dict):
        raise SourceError("missing_message_metadata")
    return value


def _content_kinds(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []
    kinds: List[str] = []
    for item in value:
        if isinstance(item, str):
            kinds.append(item)
        elif isinstance(item, dict):
            candidate = item.get("kind", item.get("type"))
            kinds.append(candidate if isinstance(candidate, str) else "")
        else:
            kinds.append("")
    return kinds


def _block_text(block: Any) -> str:
    if isinstance(block, str):
        return block
    if not isinstance(block, dict):
        return ""
    for key in ("text", "value", "answer", "content"):
        value = block.get(key)
        if isinstance(value, str):
            return value
        if isinstance(value, list):
            pieces = [_block_text(item) for item in value]
            return "".join(piece for piece in pieces if piece)
    return ""


def _content_text(payload: Dict[str, Any], role: str, kinds: Sequence[str]) -> str:
    content = payload.get("content")
    if not isinstance(content, list):
        fallback = payload.get("text")
        return fallback if isinstance(fallback, str) else ""
    pieces: List[str] = []
    for index, block in enumerate(content):
        kind = kinds[index] if index < len(kinds) else ""
        block_type = block.get("type") if isinstance(block, dict) else ""
        if kind in WRAPPER_KINDS or block_type in WRAPPER_KINDS:
            continue
        # Metadata is authoritative when present. Unknown kinds are retained
        # because normal user text may quote a wrapper's literal wording.
        if role == "user" and kind and kind.startswith("tool."):
            continue
        text = _block_text(block)
        if text:
            pieces.append(text)
    return "\n".join(pieces)


def _answer_text(payload: Dict[str, Any]) -> str:
    answers = payload.get("answers")
    if isinstance(answers, list):
        pieces: List[str] = []
        for answer in answers:
            if isinstance(answer, dict):
                value = answer.get("answer", answer.get("text", answer.get("value")))
            else:
                value = answer
            if isinstance(value, str) and value:
                question = answer.get("question") if isinstance(answer, dict) else None
                pieces.append("问题：%s\n回答：%s" % (question, value) if question else value)
        if pieces:
            return "\n".join(pieces)
    for key in ("answer", "response", "text"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def _question_reply_text(text: str) -> Optional[str]:
    """Decode the host's serialized question reply when it is the full block."""
    match = re.fullmatch(
        r"\s*<send_user_message_question_reply>\s*(.*?)\s*</send_user_message_question_reply>\s*",
        text,
        flags=re.DOTALL,
    )
    if not match:
        return None
    try:
        value = json.loads(match.group(1))
    except (TypeError, ValueError, RecursionError):
        return None
    if isinstance(value, dict):
        value = value.get("answers", value.get("responses", value))
    if not isinstance(value, list):
        return None
    pieces: List[str] = []
    for answer in value:
        if isinstance(answer, dict):
            candidate = answer.get("answer", answer.get("text", answer.get("value")))
        else:
            candidate = answer
        if isinstance(candidate, str) and candidate:
            question = answer.get("question") if isinstance(answer, dict) else None
            pieces.append("问题：%s\n回答：%s" % (question, candidate) if question else candidate)
    return "\n".join(pieces) if pieces else None


def _validate_session_meta(payload: Any, session_id: str) -> None:
    if not isinstance(payload, dict):
        raise SourceError("invalid_session_meta")
    if payload.get("thread_source") != "user":
        raise SourceError("child_source")
    if payload.get("id") != session_id:
        raise SourceError("session_mismatch")
    if payload.get("source") != "vscode":
        raise SourceError("unsupported_source")
    if payload.get("originator") != "Codex Desktop":
        raise SourceError("unsupported_originator")


def _parse_message(row: Dict[str, Any], raw_line: int, source_index: int) -> Optional[TranscriptMessage]:
    payload = row.get("payload")
    if not isinstance(payload, dict):
        return None
    payload_type = payload.get("type")
    if payload_type not in ("message", "send_user_message_question_reply"):
        return None
    for carrier in (row, payload):
        if carrier.get("agent_id") or carrier.get("agentId"):
            return None
        thread_source = carrier.get("thread_source")
        if thread_source and thread_source != "user":
            return None
        source = carrier.get("source")
        if isinstance(source, dict) and any(key in source for key in ("subagent", "agent_id", "agentId")):
            return None
        if isinstance(source, str) and source in ("subagent", "worker", "background-analysis"):
            return None
    message_id = payload.get("id")
    if not _nonempty_string(message_id):
        raise SourceError("missing_message_id", line=raw_line)
    metadata = _metadata(payload)
    turn_id = metadata.get("turn_id")
    if not _nonempty_string(turn_id):
        raise SourceError("missing_turn_id", line=raw_line)
    kinds = _content_kinds(metadata.get("content_item_kinds"))
    role = payload.get("role") or "user"
    if payload_type == "send_user_message_question_reply":
        role = "user"
        text = _answer_text(payload) or _content_text(payload, role, kinds)
        phase = None
    elif role == "user":
        text = _content_text(payload, role, kinds)
        text = _question_reply_text(text) or text
        phase = payload.get("phase") if isinstance(payload.get("phase"), str) else None
    elif role == "assistant":
        if payload.get("phase") != "final_answer":
            return None
        text = _content_text(payload, role, kinds)
        phase = "final_answer"
    else:
        return None
    if not isinstance(text, str) or not text:
        return None
    return TranscriptMessage(
        message_id=message_id,
        turn_id=turn_id,
        role=role,
        text=text,
        source_index=source_index,
        raw_line=raw_line,
        create_time=metadata.get("create_time"),
        phase=phase,
        content_kinds=tuple(kinds),
    )


def parse_transcript(path: Path, session_id: str) -> Transcript:
    """Parse one explicitly selected transcript and fail closed on identity."""
    if not isinstance(path, Path):
        path = Path(path)
    if not _nonempty_string(session_id):
        raise SourceError("invalid_session_id")
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        raise SourceError("source_missing") from None
    except OSError:
        raise SourceError("source_read_error") from None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise SourceError("invalid_utf8") from None

    messages: List[TranscriptMessage] = []
    turn_by_id: Dict[str, TranscriptTurn] = {}
    session_seen = False
    automatic_turns = set()
    excluded_ids = set()
    partial = False
    parsed_lines = 0
    lines = text.splitlines(keepends=True)
    if text and (not lines or not lines[-1].endswith(("\n", "\r"))):
        final_line_is_unterminated = True
    else:
        final_line_is_unterminated = False
    byte_offset = 0
    for raw_line_number, line in enumerate(lines, 1):
        encoded_line = line.encode("utf-8")
        byte_offset += len(encoded_line)
        stripped = line.strip()
        if not stripped:
            continue
        try:
            row = json.loads(stripped)
        except (ValueError, RecursionError):
            if raw_line_number == len(lines) and final_line_is_unterminated:
                partial = True
                break
            raise SourceError("malformed_json", line=raw_line_number) from None
        if not isinstance(row, dict):
            raise SourceError("invalid_record", line=raw_line_number)
        record_type = row.get("type")
        if record_type == "session_meta":
            if session_seen:
                raise SourceError("duplicate_session_meta", line=raw_line_number)
            _validate_session_meta(row.get("payload"), session_id)
            session_seen = True
            parsed_lines += 1
            continue
        if record_type != "response_item":
            # Event and tool records are context for the host, not model input.
            parsed_lines += 1
            continue
        if not session_seen:
            raise SourceError("missing_session_meta", line=raw_line_number)
        candidate = _parse_message(row, raw_line_number, len(messages) + 1)
        parsed_lines += 1
        if candidate is None:
            payload = row.get("payload", {})
            if not isinstance(payload, dict):
                continue
            meta = payload.get("internal_chat_message_metadata_passthrough", payload.get("internalChatMessageMetadataPassthrough", {}))
            if (isinstance(meta, dict) and payload.get("role") == "user" and "goal.internal_context" in WRAPPER_KINDS
                    and _nonempty_string(payload.get("id")) and _nonempty_string(meta.get("turn_id"))
                    and "goal.internal_context" in _content_kinds(meta.get("content_item_kinds"))):
                automatic_turns.add(meta.get("turn_id"))
                excluded_ids.add(payload.get("id"))
            continue
        if candidate.message_id in {message.message_id for message in messages}:
            continue
        messages.append(candidate)
    if not session_seen:
        raise SourceError("missing_session_meta")
    real_user_turns = {message.turn_id for message in messages if message.role == "user"}
    automatic_turns -= real_user_turns
    excluded_ids.update(message.message_id for message in messages if message.turn_id in automatic_turns)
    messages = [replace(message, source_index=index) for index, message in enumerate(
        (message for message in messages if message.turn_id not in automatic_turns), 1)]
    turn_by_id = {}
    for message in messages:
        turn = turn_by_id.setdefault(message.turn_id, TranscriptTurn(message.turn_id, len(turn_by_id) + 1))
        (turn.user_messages if message.role == "user" else turn.final_messages).append(message)
    coverage = {
        "status": "partial" if partial else "complete",
        "excluded_turn_ids": sorted(automatic_turns),
        "truncated": partial,
        "line_count": len(lines),
        "parsed_lines": parsed_lines,
        "bytes": len(raw),
        "last_offset": byte_offset,
    }
    return Transcript(session_id, messages, list(turn_by_id.values()), coverage, tuple(sorted(excluded_ids)))
