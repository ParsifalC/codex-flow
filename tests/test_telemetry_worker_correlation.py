from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import telemetry_core.app_server as app_server
import telemetry_core.collector as collector
import telemetry_core.common as common


def _configure_state(monkeypatch, tmp_path):
    codex_home = tmp_path / ".codex"
    state_root = codex_home / "codex-flow" / "telemetry"
    runs_dir = state_root / "runs"
    runs_dir.mkdir(parents=True)
    monkeypatch.setenv("CODEX_HOME", str(codex_home))
    monkeypatch.setenv("CODEX_FLOW_APP_SERVER_COMMAND", "false")
    monkeypatch.setenv("CODEX_FLOW_TELEMETRY_NOTIFICATIONS", "false")
    monkeypatch.setattr(common, "CODEX_HOME", codex_home)
    monkeypatch.setattr(common, "STATE_ROOT", state_root)
    monkeypatch.setattr(common, "RUNS_DIR", runs_dir)
    monkeypatch.setattr(common, "LAST_FILE", state_root / "last.json")
    monkeypatch.setattr(common, "WORKER_INDEX_FILE", state_root / "worker-index.json")
    monkeypatch.setattr(app_server, "SESSION_INDEX_FILE", codex_home / "session_index.jsonl")
    monkeypatch.setattr(collector, "LAST_FILE", state_root / "last.json")
    monkeypatch.setattr(collector, "WORKER_INDEX_FILE", state_root / "worker-index.json")
    return runs_dir


def _hook(kind, session, turn, **extra):
    event = {
        "hook_event_name": kind,
        "session_id": session,
        "turn_id": turn,
        "cwd": "/tmp/work",
    }
    event.update(extra)
    collector.collect_hook(event)


def _transcript(path: Path, turn: str, total: int, started_at: float | None = None):
    started_at = started_at if started_at is not None else time.time()
    started = datetime.fromtimestamp(started_at, timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )
    records = [
        {
            "timestamp": started,
            "type": "event_msg",
            "payload": {"type": "task_started", "turn_id": turn},
        },
        {
            "timestamp": started,
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "turn_id": turn,
                "info": {
                    "last_token_usage": {
                        "input_tokens": total,
                        "total_tokens": total,
                    }
                },
            },
        },
        {
            "timestamp": started,
            "type": "event_msg",
            "payload": {"type": "task_complete", "turn_id": turn},
        },
    ]
    path.write_text("".join(json.dumps(record) + "\n" for record in records))


def _run(runs_dir, session, turn):
    return json.loads((runs_dir / f"{session}--{turn}.json").read_text())


def test_resume_without_start_routes_by_child_timestamp_and_preserves_usage(
    monkeypatch, tmp_path
):
    runs_dir = _configure_state(monkeypatch, tmp_path)
    session = "resume-session"
    _hook("UserPromptSubmit", session, "parent-1")
    first_transcript = tmp_path / "worker-1.jsonl"
    _hook(
        "SubagentStart",
        session,
        "child-1",
        agent_id="reused-worker",
        model="gpt-worker",
    )
    _transcript(first_transcript, "child-1", 11)
    # Parent-1 finishes before the worker stop is delivered.
    _hook("Stop", session, "parent-1")

    _hook("UserPromptSubmit", session, "parent-2")
    # The delayed stop still resolves to parent-1 by its exact child turn.
    _hook(
        "SubagentStop",
        session,
        "child-1",
        agent_id="reused-worker",
        agent_transcript_path=str(first_transcript),
    )
    second_transcript = tmp_path / "worker-2.jsonl"
    second_started = time.time()
    _transcript(second_transcript, "child-2", 22, second_started)
    # The resumed worker emits Stop without a new Start. The transcript start
    # falls inside parent-2 even though the agent index still has parent-1.
    _hook(
        "SubagentStop",
        session,
        "child-2",
        agent_id="reused-worker",
        agent_transcript_path=str(second_transcript),
    )
    _hook("Stop", session, "parent-2")

    first = _run(runs_dir, session, "parent-1")
    second = _run(runs_dir, session, "parent-2")
    first_worker = first["workers"]["reused-worker"]
    second_worker = second["workers"]["reused-worker"]
    assert first_worker["executions"]["child-1"]["usage"]["total_tokens"] == 11
    assert second_worker["executions"]["child-2"]["usage"]["total_tokens"] == 22
    assert second_worker["usage"]["total_tokens"] == 22
    assert "child-2" not in first_worker["executions"]
    indexed = common.worker_index_entry("reused-worker", session, "child-1")
    assert indexed is not None
    assert indexed["run_key"] == f"{session}--parent-1"


def test_duplicate_and_out_of_order_stop_are_idempotent(monkeypatch, tmp_path):
    runs_dir = _configure_state(monkeypatch, tmp_path)
    session = "duplicate-session"
    _hook("UserPromptSubmit", session, "parent")
    transcript = tmp_path / "worker.jsonl"
    _hook("SubagentStart", session, "child", agent_id="worker")
    _transcript(transcript, "child", 17)
    _hook(
        "SubagentStop",
        session,
        "child",
        agent_id="worker",
        agent_transcript_path=str(transcript),
    )
    _hook(
        "SubagentStart",
        session,
        "child",
        agent_id="worker",
    )
    _hook(
        "SubagentStop",
        session,
        "child",
        agent_id="worker",
        agent_transcript_path=str(transcript),
    )
    run = _run(runs_dir, session, "parent")
    worker = run["workers"]["worker"]
    assert list(worker["executions"]) == ["child"]
    assert worker["executions"]["child"]["usage"]["total_tokens"] == 17
    assert worker["usage"]["total_tokens"] == 17
    assert worker["status"] == "completed"


def test_no_evidence_does_not_reassign_active_parent(monkeypatch, tmp_path):
    runs_dir = _configure_state(monkeypatch, tmp_path)
    session = "no-evidence"
    _hook("UserPromptSubmit", session, "parent-1")
    _hook("Stop", session, "parent-1")
    _hook("UserPromptSubmit", session, "parent-2")
    _hook("SubagentStop", session, "unknown-child", agent_id="worker")
    _hook("Stop", session, "parent-2")

    second = _run(runs_dir, session, "parent-2")
    child = _run(runs_dir, session, "unknown-child")
    assert "worker" not in second["workers"]
    assert child["worker_correlation"] == "unresolved"


def test_repeated_execution_usage_is_aggregated_and_cumulative_service_isolated():
    assert collector._merge_execution_usage(
        {"total_tokens": 100, "source": "app-server"},
        {"total_tokens": 11, "source": "transcript"},
    )["total_tokens"] == 11
    worker = {
        "executions": {
            "child-1": {
                "turn_id": "child-1",
                "service_usage_cumulative": {"total_tokens": 100},
                "usage": {"total_tokens": 100},
            },
            "child-2": {"turn_id": "child-2", "usage": {"total_tokens": 50}},
        }
    }
    assert collector._service_usage_delta(
        worker,
        worker["executions"]["child-2"],
        {"total_tokens": 150},
        2,
    )["total_tokens"] == 50
    assert collector._service_usage_delta(
        {"executions": {"child-2": {"turn_id": "child-2"}}},
        {"turn_id": "child-2"},
        {"total_tokens": 150},
        2,
    ) is None


def test_reused_worker_service_usage_is_delta_isolated_across_parents(
    monkeypatch, tmp_path
):
    runs_dir = _configure_state(monkeypatch, tmp_path)

    class FakeServer:
        available = True
        worker_calls = 0

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def rate_limits(self):
            return None

        def thread_metadata(self, _session_id):
            return None

        def thread_usage(self, thread_id):
            if thread_id != "reused-worker":
                return None
            FakeServer.worker_calls += 1
            total = 100 if FakeServer.worker_calls == 1 else 150
            return {
                "estimatedUsageCreditsMicros": total,
                "groups": [{"model": "gpt-worker", "totalTokens": total}],
            }

    monkeypatch.setattr(collector, "AppServer", FakeServer)
    session = "service-resume"
    _hook("UserPromptSubmit", session, "parent-1")
    _hook("SubagentStart", session, "child-1", agent_id="reused-worker")
    _hook("SubagentStop", session, "child-1", agent_id="reused-worker")
    _hook("Stop", session, "parent-1")
    _hook("UserPromptSubmit", session, "parent-2")
    _hook("SubagentStart", session, "child-2", agent_id="reused-worker")
    _hook("SubagentStop", session, "child-2", agent_id="reused-worker")
    _hook("Stop", session, "parent-2")

    first = _run(runs_dir, session, "parent-1")
    second = _run(runs_dir, session, "parent-2")
    assert first["workers"]["reused-worker"]["usage"]["total_tokens"] == 100
    assert second["workers"]["reused-worker"]["usage"]["total_tokens"] == 50


def test_execution_service_baseline_does_not_move_with_samples():
    first = {"turn_id": "first"}
    worker = {"executions": {"first": first}}
    assert collector._service_usage_delta(worker, first, {"total_tokens": 100}, 1)["total_tokens"] == 100
    first["service_usage_cumulative"] = {"total_tokens": 100}
    assert collector._service_usage_delta(worker, first, {"total_tokens": 150}, 1)["total_tokens"] == 150
    first["service_usage_cumulative"] = {"total_tokens": 150}
    second = {"turn_id": "second"}
    worker["executions"]["second"] = second
    assert collector._service_usage_delta(worker, second, {"total_tokens": 200}, 2)["total_tokens"] == 50
    second["service_usage_cumulative"] = {"total_tokens": 200}
    assert collector._service_usage_delta(worker, second, {"total_tokens": 250}, 2)["total_tokens"] == 100
    second["service_usage_finalized"] = True
    assert collector._service_usage_delta(worker, second, {"total_tokens": 999}, 2) is None


def test_delayed_duplicate_start_preserves_original_parent(monkeypatch, tmp_path):
    runs_dir = _configure_state(monkeypatch, tmp_path)
    session = "delayed-start"
    _hook("UserPromptSubmit", session, "parent-1")
    _hook("SubagentStart", session, "child", agent_id="worker")
    _hook("SubagentStop", session, "child", agent_id="worker")
    _hook("Stop", session, "parent-1")
    _hook("UserPromptSubmit", session, "parent-2")
    _hook("SubagentStart", session, "child", agent_id="worker")
    assert _run(runs_dir, session, "parent-1")["workers"]["worker"]["status"] == "completed"
    assert _run(runs_dir, session, "parent-2")["workers"] == {}
