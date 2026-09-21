from __future__ import annotations

import json
import socket
import threading
from pathlib import Path

import pytest

from scripts.telemetry_core import activity


def wire_event(
    event: str,
    *,
    session: str = "session-a",
    turn: str = "turn-1",
    sequence: int = 1,
    started: int = 1_000,
    timestamp: int | None = None,
    **extra: object,
) -> dict[str, object]:
    value: dict[str, object] = {
        "schema_version": 1,
        "event": event,
        "session_id": session,
        "turn_id": turn,
        "sequence": sequence,
        "timestamp_ms": started if timestamp is None else timestamp,
        "started_at_ms": started,
        "source": "test",
    }
    value.update(extra)
    return value


def test_activity_reducer_rejects_duplicates_old_turns_and_post_terminal_running() -> None:
    accepted, current = activity.reduce_event(None, wire_event("started"), now_ms=1_000)
    assert accepted and current["state"] == "running"

    accepted, current = activity.reduce_event(current, wire_event("running", sequence=1), now_ms=1_001)
    assert not accepted
    accepted, same = activity.reduce_event(current, wire_event("running", sequence=2), now_ms=1_002)
    assert accepted and same["sequence"] == 2

    accepted, current = activity.reduce_event(current, wire_event("succeeded", sequence=3), now_ms=1_003)
    assert accepted and current["terminal_event"] == "succeeded"
    accepted, current = activity.reduce_event(current, wire_event("running", sequence=4), now_ms=1_004)
    assert not accepted and current["state"] == "succeeded"

    accepted, current = activity.reduce_event(
        current,
        wire_event("started", session="session-b", turn="turn-2", sequence=1, started=900),
        now_ms=1_005,
    )
    assert not accepted and current["session_id"] == "session-a"


def test_activity_reducer_keeps_original_start_and_expires_idle() -> None:
    accepted, current = activity.reduce_event(None, wire_event("started", started=2_000), now_ms=2_000)
    assert accepted
    accepted, current = activity.reduce_event(
        current,
        wire_event("waiting", sequence=2, started=9_000, timestamp=2_100),
        now_ms=2_100,
    )
    assert accepted and current["started_at_ms"] == 2_000
    assert activity.expire_activity(current, now_ms=2_100 + activity.ACTIVITY_TTL_MS + 1) is None


def test_hook_mapping_waits_for_matching_tool_and_keeps_async_waiting() -> None:
    start = {"hook_event_name": "UserPromptSubmit", "session_id": "s", "turn_id": "t"}
    event = activity.event_from_hook(start, now_ms=100)
    assert event and event["event"] == "started"
    current = activity.reduce_event(None, event, now_ms=100)[1]

    permission = activity.event_from_hook(
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "s",
            "turn_id": "t",
            "tool_name": "exec_command",
            "tool_input": {"cmd": "pwd"},
        },
        current=current,
        now_ms=110,
    )
    assert permission and permission["event"] == "waiting"
    current = activity.reduce_event(current, permission, now_ms=110)[1]

    unrelated = activity.event_from_hook(
        {
            "hook_event_name": "PostToolUse",
            "session_id": "s",
            "turn_id": "t",
            "tool_name": "read_file",
            "tool_use_id": "other",
            "tool_input": {"path": "x"},
            "tool_response": {},
        },
        current=current,
        now_ms=120,
    )
    assert unrelated and unrelated["event"] == "waiting"
    assert unrelated["waiting_fingerprint"] == current["waiting_fingerprint"]

    async_request = activity.event_from_hook(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "turn_id": "t",
            "tool_name": "request_user_input_async",
            "tool_use_id": "async-1",
            "tool_input": {"question": "Continue?"},
        },
        current=current,
        now_ms=130,
    )
    assert async_request and async_request["event"] == "waiting"

    current = activity.reduce_event(current, async_request, now_ms=130)[1]
    unrelated_pre = activity.event_from_hook(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "turn_id": "t",
            "tool_name": "exec_command",
            "tool_use_id": "other",
            "tool_input": {"cmd": "pwd"},
        },
        current=current,
        now_ms=140,
    )
    assert unrelated_pre and unrelated_pre["event"] == "waiting"
    assert unrelated_pre["waiting_fingerprint"] == current["waiting_fingerprint"]
    current = activity.reduce_event(current, unrelated_pre, now_ms=140)[1]
    unrelated_post = activity.event_from_hook(
        {
            "hook_event_name": "PostToolUse",
            "session_id": "s",
            "turn_id": "t",
            "tool_name": "exec_command",
            "tool_use_id": "other",
            "tool_input": {"cmd": "pwd"},
            "tool_response": {},
        },
        current=current,
        now_ms=150,
    )
    assert unrelated_post and unrelated_post["event"] == "waiting"
    current = activity.reduce_event(current, unrelated_post, now_ms=150)[1]
    resumed = activity.event_from_hook(
        {
            "hook_event_name": "PostToolUse",
            "session_id": "s",
            "turn_id": "t",
            "tool_name": "request_user_input_async",
            "tool_use_id": "async-1",
            "tool_input": {"question": "Continue?"},
            "tool_response": {"status": "question_sent"},
        },
        current=current,
        now_ms=160,
    )
    assert resumed and resumed["event"] == "waiting"
    assert resumed["async_pending"] is True
    current = activity.reduce_event(current, resumed, now_ms=160)[1]
    answered = activity.event_from_hook(
        {"hook_event_name": "UserPromptSubmit", "session_id": "s", "turn_id": "t", "user_prompt": "yes"},
        current=current, now_ms=170,
    )
    assert answered and answered["event"] == "started"


def test_unknown_or_old_hooks_cannot_establish_a_new_parent_turn(tmp_path: Path) -> None:
    root = tmp_path / "telemetry"
    (root / "runs").mkdir(parents=True)
    (root / "runs" / "s--old.json").write_text(
        json.dumps({"session_id": "s", "turn_id": "old", "started_at_ms": 100}),
        encoding="utf-8",
    )
    current = activity.reduce_event(
        None,
        activity.event_from_hook(
            {"hook_event_name": "UserPromptSubmit", "session_id": "s", "turn_id": "new"},
            now_ms=200,
            state_root=root,
        ),
        now_ms=200,
    )[1]
    assert current
    assert activity.event_from_hook(
        {"hook_event_name": "PostToolUse", "session_id": "s", "turn_id": "old", "tool_name": "exec_command"},
        current=current,
        now_ms=210,
        state_root=root,
    ) is None
    assert activity.event_from_hook(
        {"hook_event_name": "Stop", "session_id": "s", "turn_id": "old"},
        current=current,
        now_ms=211,
        state_root=root,
    ) is None
    assert activity.event_from_hook(
        {"hook_event_name": "PostToolUse", "session_id": "s", "turn_id": "new", "agent_id": "child"},
        current=current,
        now_ms=212,
        state_root=root,
    ) is None
    assert activity.event_from_hook(
        {"hook_event_name": "SubagentStart", "session_id": "s", "turn_id": "child", "agent_id": "unknown", "agent_type": "worker-reviewer"},
        current=current,
        now_ms=213,
        state_root=root,
    ) is None


def test_explicit_terminal_result_survives_stop_and_ttl() -> None:
    accepted, current = activity.reduce_event(None, wire_event("started", timestamp=1_000), now_ms=1_000)
    assert accepted
    accepted, current = activity.reduce_event(current, wire_event("failed", sequence=2, timestamp=1_100), now_ms=1_100)
    assert accepted and current["event"] == "failed" and current["state"] == "failed"
    accepted, current = activity.reduce_event(current, wire_event("completed", sequence=3, timestamp=1_200), now_ms=1_200)
    assert accepted and current["event"] == "failed" and current["state"] == "failed"
    assert activity.expire_activity(current, now_ms=1_200 + activity.ACTIVITY_TTL_MS + 1) == current


def test_activity_cli_requires_registered_receipt_and_preserves_identity(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    from scripts import telemetry
    from telemetry_core import activity as runtime_activity
    from telemetry_core.turn_context import receipt_digest as runtime_receipt_digest, register_receipt as runtime_register_receipt

    root = tmp_path / "telemetry"
    monkeypatch.setattr(runtime_activity._common, "STATE_ROOT", root)
    monkeypatch.setattr(telemetry, "telemetry_writes_enabled", lambda: True)
    receipt = runtime_register_receipt(
        {"hook_event_name": "UserPromptSubmit", "session_id": "cli-session", "turn_id": "cli-turn"},
        state_root=root,
    )
    assert receipt is not None
    receipt_file = root / "turn-receipts" / f"{runtime_receipt_digest(receipt.session_id, receipt.turn_id)}.json"
    assert telemetry._activity_cli(["activity", "succeeded", "--receipt-file", str(receipt_file)]) == 0
    result = json.loads(capsys.readouterr().out)
    assert result["accepted"] is True
    snapshot = runtime_activity.load_activity(root)
    assert snapshot and snapshot["event"] == "succeeded"


def test_reviewer_requires_exact_child_parent_index_and_concurrent_posts_do_not_clear_review(tmp_path: Path) -> None:
    root = tmp_path / "telemetry"
    (root / "runs").mkdir(parents=True)
    parent_key = "parent-key"
    (root / "runs" / f"{parent_key}.json").write_text(
        json.dumps({"session_id": "s", "turn_id": "parent", "prompt_seen": True}),
        encoding="utf-8",
    )
    (root / "worker-index.json").write_text(
        json.dumps(
            {
                "workers": {
                    "agent-1": {
                        "session_id": "s",
                        "executions": {
                            "child-1": {"run_key": parent_key, "parent_turn_id": "parent"}
                        },
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    start = {"hook_event_name": "UserPromptSubmit", "session_id": "s", "turn_id": "parent"}
    current = activity.reduce_event(None, activity.event_from_hook(start, now_ms=100), now_ms=100)[1]
    review = activity.event_from_hook(
        {
            "hook_event_name": "SubagentStart",
            "session_id": "s",
            "turn_id": "child-1",
            "agent_id": "agent-1",
            "agent_type": "worker-reviewer",
        },
        current=current,
        now_ms=110,
        state_root=root,
    )
    assert review and review["event"] == "review"
    current = activity.reduce_event(current, review, now_ms=110)[1]
    unrelated = activity.event_from_hook(
        {
            "hook_event_name": "PostToolUse",
            "session_id": "s",
            "turn_id": "parent",
            "tool_name": "read_file",
            "tool_use_id": "other",
            "tool_input": {},
            "tool_response": {},
        },
        current=current,
        now_ms=120,
    )
    assert unrelated and unrelated["event"] == "review"

    wrong_child = activity.event_from_hook(
        {
            "hook_event_name": "SubagentStart",
            "session_id": "s",
            "turn_id": "child-2",
            "agent_id": "agent-1",
            "agent_type": "worker-reviewer",
        },
        current=current,
        now_ms=130,
        state_root=root,
    )
    assert wrong_child is None


def test_record_activity_writes_bounded_snapshot_and_sends_real_socket_event(tmp_path: Path) -> None:
    root = tmp_path / "telemetry"
    socket_path = Path("/tmp/flow-pet-event.sock")
    socket_path.unlink(missing_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    server.listen(1)
    received: list[str] = []

    def serve() -> None:
        conn, _ = server.accept()
        with conn:
            received.append(conn.recv(4096).decode())
            conn.sendall(b'{"ok":true}\n')
        server.close()

    thread = threading.Thread(target=serve)
    thread.start()
    result = activity.record_activity(wire_event("running"), state_root=root, socket_path=socket_path, now_ms=1_000)
    thread.join(timeout=2)

    assert result["accepted"] is True
    snapshot = json.loads((root / "activity" / "state.json").read_text(encoding="utf-8"))
    assert snapshot["state"] == "running"
    assert json.loads(received[0].strip().removeprefix("pet event "))["event"] == "running"


def test_record_activity_disabled_does_not_create_state_or_socket(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    root = tmp_path / "telemetry"
    monkeypatch.setattr(activity, "telemetry_writes_enabled", lambda: False)
    result = activity.record_activity(wire_event("running"), state_root=root, socket_path=tmp_path / "overlay.sock", now_ms=1_000)
    assert result == {"accepted": False, "status": "disabled"}
    assert not root.exists()


def test_concurrent_hook_mapping_allocates_distinct_sequences_under_activity_lock(tmp_path: Path) -> None:
    root = tmp_path / "telemetry"
    first = activity.record_activity(wire_event("started"), state_root=root, socket_path=tmp_path / "overlay.sock", now_ms=1_000)
    assert first["accepted"]
    hooks = [
        {
            "hook_event_name": "PostToolUse",
            "session_id": "session-a",
            "turn_id": "turn-1",
            "tool_name": "exec_command",
            "tool_use_id": "tool-1",
            "tool_input": {"cmd": "one"},
            "tool_response": {},
        },
        {
            "hook_event_name": "PostToolUse",
            "session_id": "session-a",
            "turn_id": "turn-1",
            "tool_name": "read_file",
            "tool_use_id": "tool-2",
            "tool_input": {"path": "two"},
            "tool_response": {},
        },
    ]
    results: list[dict[str, object]] = []

    def submit(value: dict[str, object], timestamp: int) -> None:
        results.append(activity.record_hook_activity(value, state_root=root, socket_path=tmp_path / "overlay.sock", now_ms=timestamp))

    threads = [threading.Thread(target=submit, args=(hook, timestamp)) for hook, timestamp in zip(hooks, (1_001, 1_002))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=2)
    assert len(results) == 2 and all(result["accepted"] for result in results)
    snapshot = activity.load_activity(root)
    assert snapshot and snapshot["sequence"] == 3


def test_receipt_activity_uses_original_run_start_and_rejects_old_turn(tmp_path: Path) -> None:
    from scripts.telemetry_core.turn_context import receipt_digest, register_receipt

    root = tmp_path / "telemetry"
    (root / "runs").mkdir(parents=True)
    (root / "runs" / "s--old.json").write_text(
        json.dumps({"session_id": "s", "turn_id": "old", "started_at_ms": 900}),
        encoding="utf-8",
    )
    current = activity.record_activity(
        wire_event("started", session="s", turn="new", started=1_000),
        state_root=root,
        socket_path=tmp_path / "overlay.sock",
        now_ms=1_000,
    )
    assert current["accepted"]
    receipt = register_receipt(
        {"hook_event_name": "UserPromptSubmit", "session_id": "s", "turn_id": "old"},
        state_root=root,
    )
    assert receipt is not None
    receipt_file = root / "turn-receipts" / f"{receipt_digest(receipt.session_id, receipt.turn_id)}.json"
    result = activity.record_receipt_activity(
        "failed",
        receipt_file,
        state_root=root,
        socket_path=tmp_path / "overlay.sock",
        now_ms=2_000,
    )
    assert result["accepted"] is False and result["status"] == "stale"
    snapshot = activity.load_activity(root)
    assert snapshot and snapshot["turn_id"] == "new"


@pytest.mark.parametrize("outcome", ["succeeded", "failed"])
def test_late_interrupt_preserves_explicit_terminal_outcome(outcome: str) -> None:
    _, current = activity.reduce_event(None, wire_event("started"), now_ms=1_000)
    _, current = activity.reduce_event(current, wire_event(outcome, sequence=2, timestamp=1_100), now_ms=1_100)
    accepted, after = activity.reduce_event(current, wire_event("aborted", sequence=3, timestamp=1_200), now_ms=1_200)
    assert not accepted and after == current


@pytest.mark.parametrize("outcome", ["succeeded", "failed", "completed", "aborted"])
@pytest.mark.parametrize("late", ["succeeded", "failed", "aborted"])
def test_terminal_outcome_is_immutable(outcome: str, late: str) -> None:
    _, current = activity.reduce_event(None, wire_event(outcome), now_ms=1_000)
    accepted, after = activity.reduce_event(current, wire_event(late, sequence=2, timestamp=1_100), now_ms=1_100)
    assert not accepted and after == current
