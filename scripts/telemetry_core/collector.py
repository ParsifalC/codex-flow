"""Telemetry hook event collector, worker correlation, maintenance, and notifications."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from .app_server import (
    AppServer,
    apply_participant_metadata,
    merge_thread_metadata,
    merge_usage,
    quota_delta,
    quota_windows,
    session_index_metadata,
    transcript_turn_usage,
    usage_delta,
    usage_summary,
)
from .common import (
    LAST_FILE,
    WORKER_INDEX_FILE,
    atomic_json,
    fmt_duration_ms,
    fmt_tokens,
    iter_run_files,
    load_run,
    load_worker_index,
    now_ms,
    numeric_ms,
    policy_bool,
    read_json_object,
    remember_worker_parent,
    run_key,
    run_path_for_key,
    state_lock,
    telemetry_notifications_enabled,
    telemetry_retention_days,
    worker_index_entry,
)
from .render import (
    aggregate_usage_value,
    render_summary,
    run_context,
)


def resolve_merged_run_key(key: str) -> str:
    current = key
    seen: set[str] = set()
    for _ in range(8):
        if current in seen:
            break
        seen.add(current)
        run = read_json_object(run_path_for_key(current))
        target = run.get("merged_into") if isinstance(run, dict) else None
        if not isinstance(target, str) or not target or target == current:
            break
        if not run_path_for_key(target).is_file():
            break
        current = target
    return current


def find_worker_record(
    session_id: Any, agent_id: str
) -> tuple[str, Path, dict[str, Any], dict[str, Any]] | None:
    candidates: list[
        tuple[
            tuple[int, int, int, int],
            str,
            Path,
            dict[str, Any],
            dict[str, Any],
        ]
    ] = []
    for path in iter_run_files():
        run = read_json_object(path)
        if run is None or str(run.get("session_id") or "") != str(session_id or ""):
            continue
        workers = run.get("workers")
        worker = workers.get(agent_id) if isinstance(workers, dict) else None
        if not isinstance(worker, dict):
            continue
        merged_workers = run.get("merged_workers")
        if isinstance(merged_workers, dict) and agent_id in merged_workers:
            continue
        key = path.stem
        status = worker.get("status")
        status_score = 2 if status == "completed" else 1 if status else 0
        parent_score = 1 if run.get("prompt_seen") is True else 0
        finished = numeric_ms(worker.get("finished_at_ms")) or 0
        started = numeric_ms(worker.get("started_at_ms")) or numeric_ms(
            run.get("started_at_ms")
        ) or 0
        candidates.append(
            ((parent_score, status_score, finished, started), key, path, run, worker)
        )
    if not candidates:
        return None
    _, key, path, run, worker = max(candidates, key=lambda item: item[0])
    return key, path, run, worker


def parent_candidates(session_id: Any) -> list[tuple[str, Path, dict[str, Any]]]:
    result: list[tuple[str, Path, dict[str, Any]]] = []
    for path in iter_run_files():
        run = read_json_object(path)
        if run is None:
            continue
        if str(run.get("session_id") or "") != str(session_id or ""):
            continue
        if run.get("prompt_seen") is True:
            result.append((path.stem, path, run))
    return result


def worker_interval(
    source_run: dict[str, Any], worker: dict[str, Any], event_time_ms: int
) -> tuple[int | None, int]:
    started = numeric_ms(worker.get("started_at_ms"))
    if started is None:
        started = numeric_ms(source_run.get("started_at_ms"))
    finished = numeric_ms(worker.get("finished_at_ms")) or event_time_ms
    return started, finished


def parent_match_score(
    parent: dict[str, Any],
    event_time_ms: int,
    source_record: tuple[dict[str, Any], dict[str, Any]] | None = None,
) -> tuple[int, int, int]:
    parent_started = numeric_ms(parent.get("started_at_ms"))
    parent_finished = numeric_ms(parent.get("finished_at_ms"))
    active = (
        (parent_started is None or parent_started <= event_time_ms)
        and (parent_finished is None or event_time_ms <= parent_finished)
    )
    score = 0
    overlap = 0
    if active:
        score += 20_000_000

    if source_record is not None:
        source_run, worker = source_record
        worker_started, worker_finished = worker_interval(
            source_run, worker, event_time_ms
        )
        if worker_started is not None:
            start_inside = parent_started is None or (
                parent_started <= worker_started
                and (parent_finished is None or worker_started <= parent_finished)
            )
            if start_inside:
                score += 1_000_000_000
        if worker_finished is not None:
            finish_inside = parent_started is None or (
                parent_started <= worker_finished
                and (parent_finished is None or worker_finished <= parent_finished)
            )
            if finish_inside:
                score += 500_000_000
        if parent_started is not None and worker_started is not None:
            parent_end = parent_finished or max(event_time_ms, worker_finished)
            overlap = max(
                0,
                min(parent_end, worker_finished)
                - max(parent_started, worker_started),
            )
            if overlap:
                score += 100_000_000 + min(overlap, 86_400_000)
    elif active:
        score += 1_000_000_000

    return score, overlap, parent_started or 0


def find_parent_run_key(
    session_id: Any,
    event_time_ms: int | None = None,
    source_record: tuple[dict[str, Any], dict[str, Any]] | None = None,
) -> str | None:
    event_time_ms = event_time_ms or now_ms()
    candidates = parent_candidates(session_id)
    if not candidates:
        return None
    ranked = [
        (parent_match_score(run, event_time_ms, source_record), key)
        for key, _, run in candidates
    ]
    best = max(ranked, key=lambda item: (item[0], item[1]))
    return best[1] if best[0][0] > 0 else None


def worker_run_key(event: dict[str, Any]) -> str:
    agent_id = str(event.get("agent_id") or "unknown")
    session_id = event.get("session_id")
    kind = event.get("hook_event_name")
    event_time_ms = now_ms()

    if kind == "SubagentStart":
        active_parent = find_parent_run_key(session_id, event_time_ms)
        if active_parent is not None:
            return active_parent

    indexed = worker_index_entry(agent_id, session_id)
    if indexed is not None:
        return resolve_merged_run_key(str(indexed["run_key"]))

    source = find_worker_record(session_id, agent_id)
    if source is not None:
        source_key, _, source_run, _ = source
        merged = source_run.get("merged_into")
        if isinstance(merged, str) and run_path_for_key(merged).is_file():
            return resolve_merged_run_key(merged)
        if source_run.get("prompt_seen") is True:
            return source_key
        source_parent = find_parent_run_key(
            session_id,
            event_time_ms,
            (source_run, source[3]),
        )
        if source_parent is not None:
            return source_parent
        return source_key

    active_parent = find_parent_run_key(session_id, event_time_ms)
    return active_parent or run_key(event)


def merge_worker_values(
    existing: dict[str, Any] | None, incoming: dict[str, Any]
) -> dict[str, Any]:
    previous = dict(existing) if isinstance(existing, dict) else {}
    result = dict(previous)
    for key, value in incoming.items():
        if value is not None:
            result[key] = value
    started_values = [
        numeric_ms(previous.get("started_at_ms")),
        numeric_ms(incoming.get("started_at_ms")),
    ]
    started_values = [value for value in started_values if value is not None]
    if started_values:
        result["started_at_ms"] = min(started_values)
    finished_values = [
        numeric_ms(previous.get("finished_at_ms")),
        numeric_ms(incoming.get("finished_at_ms")),
    ]
    finished_values = [value for value in finished_values if value is not None]
    if finished_values:
        result["finished_at_ms"] = max(finished_values)
    statuses = [previous.get("status"), incoming.get("status")]
    status_order = {"running": 1, "observed": 2, "completed": 3}
    statuses = [status for status in statuses if status in status_order]
    if statuses:
        result["status"] = max(statuses, key=lambda status: status_order[status])
    if result.get("usage") is None and incoming.get("usage") is not None:
        result["usage"] = incoming["usage"]
    return result


def absorb_worker_source(
    run: dict[str, Any], target_key: str, session_id: Any, agent_id: str
) -> None:
    source = find_worker_record(session_id, agent_id)
    if source is None:
        return
    source_key, source_path, source_run, source_worker = source
    if source_key == target_key or source_run.get("prompt_seen") is True:
        return
    workers = run.setdefault("workers", {})
    workers[agent_id] = merge_worker_values(workers.get(agent_id), source_worker)
    provenance = run.setdefault("worker_sources", {})
    if not isinstance(provenance, dict):
        provenance = {}
        run["worker_sources"] = provenance
    sources = provenance.setdefault(agent_id, [])
    if not isinstance(sources, list):
        sources = []
        provenance[agent_id] = sources
    if source_key not in sources:
        sources.append(source_key)
    merged_workers = source_run.setdefault("merged_workers", {})
    if not isinstance(merged_workers, dict):
        merged_workers = {}
        source_run["merged_workers"] = merged_workers
    merged_workers[agent_id] = target_key
    source_worker_ids = set((source_run.get("workers") or {}).keys())
    if source_worker_ids and source_worker_ids.issubset(merged_workers.keys()):
        targets = set(str(value) for value in merged_workers.values())
        if len(targets) == 1:
            source_run["merged_into"] = target_key
    source_run["merged_at_ms"] = now_ms()
    source_run["merge_reason"] = "agent-index"
    atomic_json(source_path, source_run)


def reconcile_orphan_workers() -> set[str]:
    changed: set[str] = set()
    with state_lock("telemetry-reconcile") as acquired:
        if not acquired:
            return changed
        for source_path in iter_run_files():
            source_run = read_json_object(source_path)
            if source_run is None or source_run.get("prompt_seen") is True:
                continue
            if source_run.get("merged_into"):
                continue
            workers = source_run.get("workers")
            if not isinstance(workers, dict):
                continue
            merged_workers = source_run.get("merged_workers")
            if not isinstance(merged_workers, dict):
                merged_workers = {}
                source_run["merged_workers"] = merged_workers
            source_key = source_path.stem
            source_changed = False
            for agent_id, source_worker in list(workers.items()):
                if agent_id in merged_workers or not isinstance(source_worker, dict):
                    continue
                target_key = find_parent_run_key(
                    source_run.get("session_id"),
                    now_ms(),
                    (source_run, source_worker),
                )
                if target_key is None or target_key == source_key:
                    continue
                target_path = run_path_for_key(target_key)
                target_turn_id = None
                with state_lock(target_key) as target_acquired:
                    if not target_acquired:
                        continue
                    target_run = read_json_object(target_path)
                    if target_run is None or target_run.get("prompt_seen") is not True:
                        continue
                    target_turn_id = target_run.get("turn_id")
                    target_workers = target_run.setdefault("workers", {})
                    target_workers[agent_id] = merge_worker_values(
                        target_workers.get(agent_id), source_worker
                    )
                    if target_workers[agent_id].get("status") == "running":
                        target_workers[agent_id]["status"] = "observed"
                    provenance = target_run.setdefault("worker_sources", {})
                    if not isinstance(provenance, dict):
                        provenance = {}
                        target_run["worker_sources"] = provenance
                    sources = provenance.setdefault(agent_id, [])
                    if not isinstance(sources, list):
                        sources = []
                        provenance[agent_id] = sources
                    if source_key not in sources:
                        sources.append(source_key)
                    atomic_json(target_path, target_run)
                merged_workers[agent_id] = target_key
                source_changed = True
                changed.add(target_key)
                remember_worker_parent(
                    agent_id,
                    source_run.get("session_id"),
                    target_key,
                    target_turn_id,
                    source_worker.get("started_at_ms") or source_run.get("started_at_ms"),
                )
            source_worker_ids = set(workers.keys())
            if source_worker_ids and source_worker_ids.issubset(merged_workers.keys()):
                targets = set(str(value) for value in merged_workers.values())
                if len(targets) == 1:
                    source_run["merged_into"] = next(iter(targets))
                source_run["merged_at_ms"] = now_ms()
                source_run["merge_reason"] = "parent-time-window"
                source_changed = True
            if source_changed:
                atomic_json(source_path, source_run)
    return changed


def run_age_timestamp_ms(path: Path, run: dict[str, Any] | None) -> int | None:
    if isinstance(run, dict):
        for field in ("finished_at_ms", "started_at_ms", "merged_at_ms"):
            value = numeric_ms(run.get(field))
            if value is not None:
                return value
    try:
        return int(path.stat().st_mtime * 1000)
    except OSError:
        return None


def run_maintenance() -> None:
    with state_lock("telemetry-maintenance") as acquired:
        if not acquired:
            return
        cutoff = now_ms() - telemetry_retention_days() * 86_400_000
        for path in iter_run_files():
            run = read_json_object(path)
            timestamp = run_age_timestamp_ms(path, run)
            if timestamp is None or timestamp >= cutoff:
                continue
            try:
                path.unlink()
            except OSError:
                pass

        last = read_json_object(LAST_FILE)
        last_timestamp = run_age_timestamp_ms(LAST_FILE, last)
        if last_timestamp is not None and last_timestamp < cutoff:
            try:
                LAST_FILE.unlink()
            except OSError:
                pass

        if not WORKER_INDEX_FILE.exists():
            return
        with state_lock("worker-index") as index_acquired:
            if not index_acquired:
                return
            index = load_worker_index()
            workers = index.get("workers")
            if not isinstance(workers, dict):
                return
            stale = [
                agent_id
                for agent_id, entry in workers.items()
                if isinstance(entry, dict)
                and numeric_ms(entry.get("updated_at_ms")) is not None
                and numeric_ms(entry.get("updated_at_ms")) < cutoff
            ]
            if stale:
                for agent_id in stale:
                    workers.pop(agent_id, None)
                atomic_json(WORKER_INDEX_FILE, index)


def applescript_literal(value: Any) -> str:
    text = " ".join(str(value).split())
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notification_body(run: dict[str, Any]) -> str:
    session, project, branch = run_context(run)
    label = project or session or "Codex task"
    if branch and project:
        label = f"{label} · {branch}"
    workers = list((run.get("workers") or {}).values())
    parent = run.get("parent") or {}
    usages = [parent.get("usage_delta") if isinstance(parent, dict) else None]
    usages.extend(
        worker.get("usage") if isinstance(worker, dict) else None for worker in workers
    )
    total_tokens = aggregate_usage_value(usages, "total_tokens")
    worker_count = f"{len(workers)} worker{'s' if len(workers) != 1 else ''}"
    parts = [label, worker_count, f"{fmt_tokens(total_tokens)} tokens"]
    started = numeric_ms(run.get("started_at_ms"))
    finished = numeric_ms(run.get("finished_at_ms"))
    if started is not None and finished is not None:
        duration = fmt_duration_ms(finished - started)
        if duration:
            parts.append(duration)
    return " · ".join(parts)


def send_system_notification(run: dict[str, Any]) -> None:
    notify_overlay_if_active(run)
    telemetry_mod = sys.modules.get("telemetry")
    sub_mod = getattr(telemetry_mod, "subprocess", subprocess) if telemetry_mod else subprocess
    shutil_mod = getattr(telemetry_mod, "shutil", shutil) if telemetry_mod else shutil
    sys_mod = getattr(telemetry_mod, "sys", sys) if telemetry_mod else sys

    if not telemetry_notifications_enabled() or sys_mod.platform != "darwin":
        return
    executable = shutil_mod.which("osascript")
    if not executable:
        return
    script = (
        f"display notification {applescript_literal(notification_body(run))} "
        f"with title {applescript_literal('FlowPilot task finished')}"
    )
    try:
        sub_mod.run(
            [executable, "-e", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2.0,
            check=False,
        )
    except (OSError, Exception):
        return


def notify_overlay_if_active(run: dict[str, Any]) -> None:
    """Send immediate update event to macos-overlay daemon if running."""
    import socket
    codex_home = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
    sock_path = os.path.join(codex_home, "codex-flow", "overlay.sock")
    if not os.path.exists(sock_path):
        return
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(0.5)
        client.connect(sock_path)
        client.sendall(b"update\n")
        client.close()
    except Exception:
        pass


def is_same_run(left: dict[str, Any] | None, right: dict[str, Any]) -> bool:
    if not isinstance(left, dict):
        return False
    return (
        str(left.get("session_id") or "") == str(right.get("session_id") or "")
        and str(left.get("turn_id") or "") == str(right.get("turn_id") or "")
    )


def write_stop_output(text: str) -> None:
    if os.environ.get("CODEX_FLOW_TELEMETRY_TEST_PLAIN_OUTPUT") == "1":
        sys.stdout.write(text)
        return
    sys.stdout.write(
        json.dumps({"systemMessage": text}, ensure_ascii=False, separators=(",", ":"))
        + "\n"
    )


def collect_hook(event: dict[str, Any]) -> None:
    kind = event.get("hook_event_name")
    if kind not in {"UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop"}:
        return

    key = worker_run_key(event) if kind in {"SubagentStart", "SubagentStop"} else run_key(event)

    if kind == "UserPromptSubmit":
        with state_lock(key) as acquired:
            if not acquired:
                return
            run = load_run(event, key)
            path = run_path_for_key(key)
            run.update(
                {
                    "started_at_ms": now_ms(),
                    "cwd": event.get("cwd"),
                    "prompt_seen": True,
                    "transcript_path": event.get("transcript_path"),
                }
            )
            if event.get("model") is not None:
                run.setdefault("parent", {})["model"] = event.get("model")
            with AppServer() as server:
                run["quota_before"] = (
                    quota_windows(server.rate_limits()) if server.available else []
                )
                run.setdefault("parent", {})["usage_before"] = (
                    usage_summary(server.thread_usage(event.get("session_id")))
                    if server.available
                    else None
                )
                run["thread"] = merge_thread_metadata(
                    session_index_metadata(event.get("session_id")),
                    server.thread_metadata(event.get("session_id"))
                    if server.available
                    else None,
                )
            apply_participant_metadata(
                run.setdefault("parent", {}),
                event=event,
                transcript_path=run.get("transcript_path"),
                turn_id=run.get("turn_id"),
                usage=run["parent"].get("usage_before"),
            )
            atomic_json(path, run)
        return

    if kind in {"SubagentStart", "SubagentStop"}:
        agent_id = str(event.get("agent_id") or "unknown")
        with state_lock(key) as acquired:
            if not acquired:
                return
            run = load_run(event, key)
            path = run_path_for_key(key)
            if kind == "SubagentStop":
                absorb_worker_source(run, key, event.get("session_id"), agent_id)
            workers = run.setdefault("workers", {})
            worker = workers.setdefault(agent_id, {"agent_id": agent_id})
            worker["agent_id"] = agent_id
            if event.get("agent_type") is not None:
                worker["agent_type"] = event.get("agent_type")
            if event.get("model") is not None:
                worker["model"] = event.get("model")
            if event.get("turn_id") is not None:
                worker["turn_id"] = event.get("turn_id")
            if kind == "SubagentStart":
                worker.setdefault("started_at_ms", now_ms())
                worker["status"] = "running"
                if event.get("agent_transcript_path") is not None:
                    worker["transcript_path"] = event.get("agent_transcript_path")
            else:
                agent_transcript_path = event.get("agent_transcript_path")
                worker.update(
                    {
                        "finished_at_ms": now_ms(),
                        "status": "completed",
                    }
                )
                if agent_transcript_path is not None:
                    worker["transcript_path"] = agent_transcript_path
                last_message = event.get("last_assistant_message")
                if isinstance(last_message, str):
                    last_message = last_message.strip()
                    if last_message:
                        worker["conclusion"] = last_message[:4000]
                transcript_usage = transcript_turn_usage(
                    agent_transcript_path, event.get("turn_id")
                )
                with AppServer() as server:
                    service_usage = (
                        usage_summary(server.thread_usage(agent_id))
                        if server.available
                        else None
                    )
                merged_usage = merge_usage(transcript_usage, service_usage)
                if merged_usage is not None or worker.get("usage") is None:
                    worker["usage"] = merged_usage
            apply_participant_metadata(
                worker,
                event=event,
                transcript_path=worker.get("transcript_path"),
                turn_id=worker.get("turn_id"),
                usage=worker.get("usage"),
            )
            atomic_json(path, run)

            last = read_json_object(LAST_FILE)
            if kind == "SubagentStop" and is_same_run(last, run):
                atomic_json(LAST_FILE, run)
        remember_worker_parent(
            agent_id,
            event.get("session_id"),
            key,
            run.get("turn_id"),
            worker.get("started_at_ms"),
        )
        return

    with state_lock(key) as acquired:
        if not acquired:
            return
        run = load_run(event, key)
        path = run_path_for_key(key)
        run["finished_at_ms"] = now_ms()
        if event.get("model") is not None:
            run.setdefault("parent", {})["model"] = event.get("model")
        with AppServer() as server:
            run["thread"] = merge_thread_metadata(
                session_index_metadata(event.get("session_id")),
                run.get("thread"),
                server.thread_metadata(event.get("session_id"))
                if server.available
                else None,
            )
            quota_after = quota_windows(server.rate_limits()) if server.available else []
            parent_after = (
                usage_summary(server.thread_usage(event.get("session_id")))
                if server.available
                else None
            )
            run["quota_after"] = quota_after
            run["quota_change_during_run"] = quota_delta(
                run.get("quota_before", []), quota_after
            )
            run["parent"]["usage_after"] = parent_after
            service_delta = usage_delta(
                run["parent"].get("usage_before"), parent_after
            )
            transcript_usage = transcript_turn_usage(
                run.get("transcript_path") or event.get("transcript_path"),
                event.get("turn_id"),
            )
            run["parent"]["usage_delta"] = merge_usage(
                transcript_usage, service_delta
            )
            apply_participant_metadata(
                run["parent"],
                event=event,
                transcript_path=run.get("transcript_path") or event.get("transcript_path"),
                turn_id=event.get("turn_id"),
                usage=run["parent"].get("usage_delta"),
            )
            for agent_id, worker in run.get("workers", {}).items():
                if worker.get("usage") is None:
                    transcript_usage = transcript_turn_usage(
                        worker.get("transcript_path"),
                        worker.get("turn_id") or event.get("turn_id"),
                    )
                    service_usage = (
                        usage_summary(server.thread_usage(agent_id))
                        if server.available
                        else None
                    )
                    worker["usage"] = merge_usage(
                        transcript_usage, service_usage
                    )
                apply_participant_metadata(
                    worker,
                    transcript_path=worker.get("transcript_path"),
                    turn_id=worker.get("turn_id") or event.get("turn_id"),
                    usage=worker.get("usage"),
                )
                if worker.get("status") == "running":
                    worker["status"] = "observed"
        atomic_json(path, run)
        atomic_json(LAST_FILE, run)

    reconciled = reconcile_orphan_workers()
    if key in reconciled:
        refreshed = read_json_object(run_path_for_key(key))
        if refreshed is not None:
            run = refreshed
            atomic_json(LAST_FILE, run)
    run_maintenance()
    if policy_bool("telemetry", "summary", True):
        write_stop_output(render_summary(run))
    send_system_notification(run)
