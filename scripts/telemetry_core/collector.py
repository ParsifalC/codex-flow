"""Telemetry hook event collector, worker correlation, maintenance, and notifications."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from . import common as _common
from .app_server import (
    AppServer,
    apply_participant_metadata,
    enrich_run_metadata,
    find_session_transcript,
    merge_thread_metadata,
    merge_usage,
    quota_delta,
    quota_windows,
    session_index_metadata,
    transcript_turn_quota,
    transcript_turn_started_at,
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
    telemetry_writes_enabled,
)
from .turn_context import ReceiptError, load_receipt, receipt_digest, register_receipt, seal_receipt, validate_receipt
from .turn_result import extract_parent_final, parent_turn_completed_at
from .publication import GLOBAL_LOCK, PublicationResult, publish_late_worker, publish_parent_stop, update_run
from .activity import record_hook_activity
from .render import (
    aggregate_usage_value,
    render_summary,
    run_context,
)


_USAGE_NUMERIC_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "net_new_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "cache_write_input_tokens",
    "total_tokens",
    "estimated_credits_micros",
    "estimated_usd_micros",
)


def _worker_execution_records(worker: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Return distinct child executions, including the legacy single row."""
    result: dict[str, dict[str, Any]] = {}
    executions = worker.get("executions")
    if isinstance(executions, dict):
        for key, value in executions.items():
            if isinstance(value, dict):
                record = dict(value)
                record.setdefault("turn_id", key)
                result[str(key)] = record
    elif isinstance(executions, list):
        for value in executions:
            if not isinstance(value, dict) or value.get("turn_id") is None:
                continue
            result[str(value["turn_id"])] = dict(value)

    # Older runs only had one top-level worker turn. Preserve it as an
    # execution when upgrading the row so a later resumed turn cannot absorb
    # its usage or lifecycle into the new execution.
    legacy_turn = worker.get("turn_id")
    if legacy_turn is not None and str(legacy_turn) not in result:
        result[str(legacy_turn)] = {
            key: value
            for key, value in worker.items()
            if key not in {"executions", "service_usage_cumulative"}
        }
    return result


def _ensure_worker_execution_map(worker: dict[str, Any]) -> dict[str, dict[str, Any]]:
    executions = _worker_execution_records(worker)
    worker["executions"] = executions
    return executions


def _sum_usage_values(usages: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not usages:
        return None
    result: dict[str, Any] = {}
    for field in _USAGE_NUMERIC_FIELDS:
        values = [
            value.get(field)
            for value in usages
            if isinstance(value.get(field), (int, float))
            and not isinstance(value.get(field), bool)
        ]
        if values:
            result[field] = int(sum(values))
    groups: list[dict[str, Any]] = []
    for usage in usages:
        value = usage.get("groups")
        if isinstance(value, list):
            groups.extend(group for group in value if isinstance(group, dict))
    result["groups"] = groups
    sources = {str(value.get("source")) for value in usages if value.get("source")}
    if sources:
        result["source"] = next(iter(sources)) if len(sources) == 1 else "+".join(sorted(sources))
    return result


def _rebuild_worker_usage(worker: dict[str, Any]) -> None:
    executions = _worker_execution_records(worker)
    usages = [
        execution["usage"]
        for execution in executions.values()
        if isinstance(execution.get("usage"), dict)
    ]
    aggregate = _sum_usage_values(usages)
    if aggregate is not None:
        worker["usage"] = aggregate
    elif not usages and not isinstance(worker.get("usage"), dict):
        worker["usage"] = None


def _refresh_worker_lifecycle(worker: dict[str, Any]) -> None:
    executions = _worker_execution_records(worker)
    statuses = [
        execution.get("status")
        for execution in executions.values()
        if execution.get("status") in {"running", "observed", "completed"}
    ]
    if statuses:
        order = {"running": 1, "observed": 2, "completed": 3}
        # An execution still running keeps the UI row live. Otherwise expose
        # the strongest terminal state seen for the distinct executions.
        worker["status"] = (
            "running"
            if "running" in statuses
            else max(statuses, key=lambda status: order[status])
        )
    elif worker.get("status") == "running":
        worker["status"] = "observed"
    started = [
        numeric_ms(execution.get("started_at_ms"))
        for execution in executions.values()
        if numeric_ms(execution.get("started_at_ms")) is not None
    ]
    if started:
        worker["started_at_ms"] = min(started)
    finished = [
        numeric_ms(execution.get("finished_at_ms"))
        for execution in executions.values()
        if numeric_ms(execution.get("finished_at_ms")) is not None
    ]
    if finished:
        worker["finished_at_ms"] = max(finished)


def _merge_execution_usage(
    existing: dict[str, Any] | None, incoming: dict[str, Any] | None
) -> dict[str, Any] | None:
    if incoming is None:
        return existing
    if existing is None:
        return dict(incoming)
    existing_source = str(existing.get("source") or "")
    incoming_source = str(incoming.get("source") or "")
    if incoming_source.startswith("transcript") and existing_source == "app-server":
        # A delayed stop can provide exact per-turn transcript usage after a
        # parent stop filled the running execution from cumulative service
        # usage. Prefer the exact turn evidence even when its total is lower.
        return dict(incoming)
    old_total = existing.get("total_tokens")
    new_total = incoming.get("total_tokens")
    if (
        isinstance(old_total, (int, float))
        and isinstance(new_total, (int, float))
        and not isinstance(old_total, bool)
        and not isinstance(new_total, bool)
        and int(new_total) <= int(old_total)
    ):
        return existing
    return dict(incoming)


def _record_time(record: dict[str, Any]) -> int:
    return max((numeric_ms(record.get(field)) or 0 for field in ("updated_at_ms", "finished_at_ms", "started_at_ms")), default=0)


def _merge_execution_values(
    existing: dict[str, Any] | None, incoming: dict[str, Any]
) -> dict[str, Any]:
    previous = dict(existing) if isinstance(existing, dict) else {}
    result = dict(previous)
    for key, value in incoming.items():
        if value is not None and (previous.get(key) is None or _record_time(incoming) >= _record_time(previous)):
            result[key] = value
    for field, reducer in (
        ("started_at_ms", min),
        ("finished_at_ms", max),
    ):
        values = [
            numeric_ms(previous.get(field)),
            numeric_ms(incoming.get(field)),
        ]
        values = [value for value in values if value is not None]
        if values:
            result[field] = reducer(values)
    statuses = [previous.get("status"), incoming.get("status")]
    status_order = {"running": 1, "observed": 2, "completed": 3}
    valid_statuses = [status for status in statuses if status in status_order]
    if valid_statuses:
        result["status"] = max(valid_statuses, key=lambda status: status_order[status])
    result["usage"] = _merge_execution_usage(
        existing.get("usage") if isinstance(existing, dict) else None,
        incoming.get("usage"),
    )
    if previous.get("service_usage_finalized") is True:
        result["service_usage_finalized"] = True
    if result.get("service_usage_cumulative") is None and incoming.get("service_usage_cumulative") is not None:
        result["service_usage_cumulative"] = incoming["service_usage_cumulative"]
    return result


def _service_usage_delta(
    worker: dict[str, Any],
    execution: dict[str, Any],
    service_usage: dict[str, Any] | None,
    execution_count: int,
    session_id: Any = None,
    agent_id: str | None = None,
) -> dict[str, Any] | None:
    if service_usage is None:
        return None
    if execution.get("service_usage_finalized"):
        return None
    if execution.get("service_usage_from_zero"):
        return service_usage
    previous = execution.get("service_usage_baseline")
    if not isinstance(previous, dict):
        current_turn = str(execution.get("turn_id") or "")
        snapshots = [
            item.get("service_usage_cumulative")
            for item in _worker_execution_records(worker).values()
            if str(item.get("turn_id") or "") != current_turn
            and isinstance(item.get("service_usage_cumulative"), dict)
        ]
        if snapshots:
            previous = snapshots[-1]
    prior_execution_seen = False
    if (
        not isinstance(previous, dict)
        and session_id is not None
        and agent_id
        and agent_id != "unknown"
    ):
        historical: list[dict[str, Any]] = []
        current_turn = str(execution.get("turn_id") or "")
        for path in iter_run_files():
            run = read_json_object(path)
            if run is None or str(run.get("session_id") or "") != str(session_id or ""):
                continue
            workers = run.get("workers")
            candidate = workers.get(agent_id) if isinstance(workers, dict) else None
            if not isinstance(candidate, dict):
                continue
            for item in _worker_execution_records(candidate).values():
                if str(item.get("turn_id") or "") == current_turn:
                    continue
                prior_execution_seen = True
                snapshot = item.get("service_usage_cumulative")
                if isinstance(snapshot, dict):
                    historical.append(item)
        if historical:
            historical.sort(
                key=lambda item: max(
                    numeric_ms(item.get("updated_at_ms")) or 0,
                    numeric_ms(item.get("finished_at_ms")) or 0,
                    numeric_ms(item.get("started_at_ms")) or 0,
                )
            )
            previous = historical[-1].get("service_usage_cumulative")
    if isinstance(previous, dict):
        execution["service_usage_baseline"] = dict(previous)
        return usage_delta(previous, service_usage)
    # Once this agent has more than one execution, a cumulative service value
    # cannot be attributed to the current turn without a prior snapshot.
    if execution_count > 1 or prior_execution_seen:
        return None
    execution["service_usage_from_zero"] = True
    return service_usage


def _execution_match(
    session_id: Any, agent_id: str, worker_turn_id: Any
) -> str | None:
    if worker_turn_id is None:
        return None
    target = str(worker_turn_id)
    matches: set[str] = set()
    for path in iter_run_files():
        run = read_json_object(path)
        if run is None or str(run.get("session_id") or "") != str(session_id or ""):
            continue
        workers = run.get("workers")
        worker = workers.get(agent_id) if isinstance(workers, dict) else None
        if not isinstance(worker, dict):
            continue
        executions = _worker_execution_records(worker)
        if target in executions:
            key = path.stem
            merged = run.get("merged_into")
            if isinstance(merged, str) and run_path_for_key(merged).is_file():
                key = resolve_merged_run_key(merged)
            matches.add(key)
    return next(iter(matches)) if len(matches) == 1 else None


def _transcript_worker_started_at(event: dict[str, Any]) -> int | None:
    turn_id = event.get("turn_id")
    if turn_id is None:
        return None
    for field in ("agent_transcript_path", "transcript_path"):
        started = transcript_turn_started_at(event.get(field), turn_id)
        if started is not None:
            return started
    for field in ("task_started_at_ms", "worker_started_at_ms"):
        value = numeric_ms(event.get(field))
        if value is not None:
            return value
    return None


def _parent_key_for_worker_timestamp(session_id: Any, started_at_ms: int) -> str | None:
    matches: list[str] = []
    for key, _, parent in parent_candidates(session_id):
        parent_started = numeric_ms(parent.get("started_at_ms"))
        parent_finished = numeric_ms(parent.get("finished_at_ms"))
        if parent_started is not None and started_at_ms < parent_started:
            continue
        if parent_finished is not None and started_at_ms > parent_finished:
            continue
        matches.append(key)
    return matches[0] if len(matches) == 1 else None


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

    # A child turn id is the stable identity for a resumed execution. Resolve
    # it before consulting the legacy agent-only index, which otherwise points
    # every later stop at the first parent that used this agent.
    exact = _execution_match(session_id, agent_id, event.get("turn_id"))
    if exact is not None:
        return exact

    # If the stop has a transcript, its exact task_started timestamp can place
    # it in one parent interval even when the corresponding Start hook was
    # absent. Require a unique interval; overlapping parents are ambiguous.
    if kind == "SubagentStop":
        started_at_ms = _transcript_worker_started_at(event)
        if started_at_ms is not None:
            timestamp_parent = _parent_key_for_worker_timestamp(session_id, started_at_ms)
            if timestamp_parent is not None:
                return timestamp_parent

        # No exact execution or timestamp evidence means we cannot safely
        # reassign this stop to the currently active parent. Keep it in its
        # child-keyed run so later repair can make an evidence-based choice.
        return run_key(event)

    active_parent = find_parent_run_key(session_id, event_time_ms)
    return active_parent or run_key(event)


def merge_worker_values(
    existing: dict[str, Any] | None, incoming: dict[str, Any]
) -> dict[str, Any]:
    previous = dict(existing) if isinstance(existing, dict) else {}
    result = dict(previous)
    previous_time = max([_record_time(previous), *(_record_time(item) for item in _worker_execution_records(previous).values())])
    incoming_time = max([_record_time(incoming), *(_record_time(item) for item in _worker_execution_records(incoming).values())])
    for key, value in incoming.items():
        if value is not None and (previous.get(key) is None or incoming_time >= previous_time):
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
    existing_executions = _worker_execution_records(previous)
    incoming_executions = _worker_execution_records(incoming)
    if existing_executions or incoming_executions:
        merged_executions: dict[str, dict[str, Any]] = {}
        for execution_id in set(existing_executions) | set(incoming_executions):
            merged_executions[execution_id] = _merge_execution_values(
                existing_executions.get(execution_id),
                incoming_executions.get(execution_id)
                or {"turn_id": execution_id},
            )
        result["executions"] = merged_executions
        _rebuild_worker_usage(result)
        _refresh_worker_lifecycle(result)
    else:
        result["usage"] = _merge_execution_usage(previous.get("usage"), incoming.get("usage"))
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
    _mark_worker_source(source_key, source_run)


def _mark_worker_source(key: str, observed: dict[str, Any]) -> None:
    def mark(current):
        merged = current.setdefault("merged_workers", {})
        merged.update(observed.get("merged_workers") or {})
        worker_ids = set((current.get("workers") or {}).keys())
        if worker_ids and worker_ids.issubset(merged):
            targets = {merged[agent_id] for agent_id in worker_ids}
            if len(targets) == 1:
                current["merged_into"] = next(iter(targets))
        current.setdefault("merged_at_ms", observed.get("merged_at_ms"))
        current["merge_reason"] = observed.get("merge_reason")
        return current
    publication = update_run(run_key=key, identity=observed, transform=mark, state_root=_common.STATE_ROOT)
    _emit_publication(publication)


def reconcile_orphan_workers() -> set[str]:
    changed: set[str] = set()
    with state_lock("telemetry-reconcile") as acquired:
        if not acquired:
            return changed
        for source_path in iter_run_files():
            source_run = read_json_object(source_path)
            if source_run is None or source_run.get("prompt_seen") is True:
                continue
            if source_run.get("worker_correlation") == "unresolved":
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
                publication = publish_late_worker(run_key=target_key, observed=target_run, state_root=_common.STATE_ROOT)
                if publication.snapshot is None:
                    continue
                _emit_publication(publication)
                merged_workers[agent_id] = target_key
                source_changed = True
                changed.add(target_key)
                remember_worker_parent(
                    agent_id,
                    source_run.get("session_id"),
                    target_key,
                    target_turn_id,
                    source_worker.get("started_at_ms") or source_run.get("started_at_ms"),
                    source_worker.get("turn_id"),
                    source_worker.get("finished_at_ms"),
                    source_worker.get("transcript_path"),
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
                _mark_worker_source(source_key, source_run)
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
            digest = None
            if isinstance(run, dict):
                try:
                    digest = receipt_digest(run.get("session_id"), run.get("turn_id"))
                except ReceiptError:
                    pass
            if digest is not None:
                with state_lock("turn-" + digest) as turn_acquired:
                    if not turn_acquired:
                        continue
                    with state_lock(GLOBAL_LOCK) as global_acquired:
                        if not global_acquired:
                            continue
                        # Recheck under both locks so recovery cannot select a
                        # run while retention removes that publication.
                        current = read_json_object(path)
                        timestamp = run_age_timestamp_ms(path, current)
                        if timestamp is None or timestamp >= cutoff:
                            continue
                        try:
                            receipt = load_receipt(_common.STATE_ROOT / "turn-receipts" / (digest + ".json"))
                            if (receipt.session_id, receipt.turn_id) == (run.get("session_id"), run.get("turn_id")):
                                seal_receipt(receipt, state_root=_common.STATE_ROOT)
                        except ReceiptError:
                            pass
                        sidecar_path = _common.STATE_ROOT / "turn-context" / (digest + ".json")
                        try:
                            sidecar_path.unlink()
                        except FileNotFoundError:
                            pass
                        except OSError:
                            # Keep the run so a later maintenance pass can
                            # retry cleanup without orphaning its sidecar.
                            continue
                        try:
                            path.unlink()
                        except OSError:
                            pass
                continue
            try:
                path.unlink()
            except OSError:
                pass

        # Upgrade old sealed registrations, including receipts whose runs were
        # already removed by an older collector. Expire orphan active receipts
        # using their own age; preserve recent active registrations.
        for receipt_path in (_common.STATE_ROOT / "turn-receipts").glob("*.json"):
            digest = receipt_path.stem
            if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                continue
            with state_lock("turn-" + digest) as acquired_receipt:
                if not acquired_receipt:
                    continue
                value = read_json_object(receipt_path)
                if not value or value == {"schema_version": 1, "state": "sealed"}:
                    continue
                sealed = value.get("state") == "sealed"
                stamp = run_age_timestamp_ms(receipt_path, None)
                run = read_json_object(run_path_for_key(run_key(value)))
                run_stamp = run_age_timestamp_ms(run_path_for_key(run_key(value)), run) if run else None
                expired = stamp is not None and stamp < cutoff and (run_stamp is None or run_stamp < cutoff)
                if not sealed and not expired:
                    continue
                atomic_json(receipt_path, {"schema_version": 1, "state": "sealed"})
                if expired:
                    try:
                        (_common.STATE_ROOT / "turn-context" / (digest + ".json")).unlink()
                    except OSError:
                        pass

        with state_lock(GLOBAL_LOCK) as global_acquired:
            if global_acquired:
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
    if not telemetry_writes_enabled():
        return
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


def notify_overlay_if_active(run: dict[str, Any], *, notify: bool = False) -> None:
    """Send a quiet refresh or completion update to macos-overlay if running."""
    if not telemetry_writes_enabled():
        return
    import socket
    codex_home = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
    sock_path = os.path.join(codex_home, "codex-flow", "overlay.sock")
    if not os.path.exists(sock_path):
        return
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(0.5)
        client.connect(sock_path)
        if notify:
            # A completion can arrive after another turn has won last.json.
            # Carry the persisted run path so the overlay loads the triggering
            # completion instead of whichever turn is globally latest.
            command = "update " + str(run_path_for_key(run_key(run)).resolve())
        else:
            command = "refresh"
        client.sendall(command.encode() + b"\n")
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


@contextmanager
def _parent_turn_lock(event: dict[str, Any], key: str, digest: str):
    receipt = None
    if event.get("hook_event_name") == "UserPromptSubmit":
        try:
            # register_receipt takes and releases this same turn lock itself.
            receipt = register_receipt(event, state_root=_common.STATE_ROOT)
        except ReceiptError:
            yield False
            return
    with state_lock("turn-" + digest) as acquired:
        if not acquired:
            yield False
            return
        if event.get("hook_event_name") == "UserPromptSubmit":
            try:
                validate_receipt(receipt, state_root=_common.STATE_ROOT)
            except ReceiptError:
                yield False
                return
        yield True


def _emit_publication(publication: PublicationResult, *, summary=False) -> None:
    if publication.snapshot is None:
        return
    if publication.notify:
        # Completion notifications are independent from whether this turn is
        # the globally latest snapshot.  Quiet refreshes remain latest-only.
        notify_overlay_if_active(publication.snapshot, notify=True)
    elif publication.last_updated:
        notify_overlay_if_active(publication.snapshot, notify=publication.notify)
    if publication.notify:
        send_system_notification(publication.snapshot)
    if summary and publication.published and policy_bool("telemetry", "summary", True):
        write_stop_output(render_summary(publication.snapshot))


def _refresh_quota_allocations(run: dict[str, Any], key: str) -> dict[str, Any]:
    """Recompute SQLite attribution and apply affected run fields via publication."""
    try:
        from .quota_ledger import allocate_quota_segments, get_db
        with get_db() as db_conn:
            updates = allocate_quota_segments(db_conn, runs={key: run}, state_root=_common.STATE_ROOT)
        own = updates.get(key)
        if own:
            own_values = dict(own)
            own_clear = own_values.pop("clear", False)
            _apply_quota_fields(run, own_values, own_clear)
        for run_key_value, fields in updates.items():
            candidate = run if run_key_value == key else read_json_object(run_path_for_key(run_key_value))
            if not isinstance(candidate, dict):
                continue
            identity = {"session_id": candidate.get("session_id"), "turn_id": candidate.get("turn_id")}
            values = dict(fields)
            clear = values.pop("clear", False)
            candidate_snapshot = dict(candidate)
            publication = update_run(
                run_key=run_key_value, identity=identity,
                transform=lambda current, values=values, clear=clear, snapshot=candidate_snapshot: _apply_quota_fields({**current, **snapshot}, values, clear),
                state_root=_common.STATE_ROOT,
            )
            _emit_publication(publication)
    except Exception:
        pass
    return run


def _apply_quota_fields(current: dict[str, Any], values: dict[str, Any], clear: bool) -> dict[str, Any]:
    if clear:
        current.pop("allocated_quota_pp", None)
        current.pop("quota_allocation", None)
    current.update(values)
    return current


def collect_hook(event: dict[str, Any]) -> None:
    if not telemetry_writes_enabled():
        return
    kind = event.get("hook_event_name")
    # Live pet activity is a bounded, local reducer.  Record it before the
    # publication path and keep fast hook events free of app-server/transcript
    # reads.  Fail closed: activity must never interfere with publication.
    if kind in {"PermissionRequest", "PreToolUse", "PostToolUse", "Interrupt"}:
        try:
            record_hook_activity(event)
        except Exception:
            pass
        return
    if kind in {"UserPromptSubmit", "Stop"}:
        try:
            record_hook_activity(event)
        except Exception:
            pass
    if kind not in {"UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop"}:
        return

    key = worker_run_key(event) if kind in {"SubagentStart", "SubagentStop"} else run_key(event)
    if kind in {"UserPromptSubmit", "Stop"}:
        if event.get("agent_id") or event.get("role", "parent") != "parent":
            return
        try:
            digest = receipt_digest(event.get("session_id"), event.get("turn_id"))
        except ReceiptError:
            return

    if kind == "UserPromptSubmit":
        with _parent_turn_lock(event, key, digest) as acquired:
            if not acquired:
                return
            run = load_run(event, key)
            if (run.get("session_id"), run.get("turn_id")) != (event.get("session_id"), event.get("turn_id")):
                return
            if run.get("prompt_seen"):
                # Supplemental user input in the same host turn preserves its
                # original start and quota baseline rather than creating a turn.
                return
            path = run_path_for_key(key)
            transcript_path = event.get("transcript_path")
            if not transcript_path:
                transcript_path = find_session_transcript(event.get("session_id"))

            is_system = False
            cwd = event.get("cwd")
            if cwd == "/":
                is_system = True
            prompt_text = str(event.get("user_prompt") or event.get("prompt") or "")
            if (
                "safety and compliance standards for Codex ambient" in prompt_text
                or "hyperpersonalized suggestions" in prompt_text
            ):
                is_system = True

            run_updates: dict[str, Any] = {
                "started_at_ms": now_ms(),
                "cwd": cwd,
                "prompt_seen": True,
                "transcript_path": transcript_path,
            }
            if is_system:
                run_updates["is_system_task"] = True
            if prompt_text and not run.get("summary"):
                run_updates["summary"] = prompt_text[:200].strip()
            run.update(run_updates)
            if event.get("model") is not None:
                run.setdefault("parent", {})["model"] = event.get("model")
            with AppServer() as server:
                sample_time_before = now_ms()
                raw_before = quota_windows(server.rate_limits()) if server.available else []
                run["quota_before"] = [
                    {**w, "sampled_at_ms": sample_time_before} for w in raw_before
                ]
                try:
                    from .quota_ledger import get_db, record_observation, resolve_account_id
                    resolved_account = resolve_account_id(event.get("account_id"))
                    for w in run["quota_before"]:
                        if w.get("window_duration_mins") == 10080 and isinstance(w.get("used_percent"), (int, float)):
                            with get_db() as db_conn:
                                record_observation(
                                    conn=db_conn,
                                    account_id=resolved_account,
                                    bucket_id=w.get("slot") or "primary",
                                    used_percent=float(w["used_percent"]),
                                    sampled_at_ms=sample_time_before,
                                    sample_source="turn_start",
                                    resets_at_ms=w.get("resets_at"),
                                    run_id=key,
                                )
                except Exception:
                    pass
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
            if not run.get("transcript_path"):
                thread_path = (
                    run.get("thread", {}).get("path")
                    if isinstance(run.get("thread"), dict)
                    else None
                )
                if thread_path and Path(thread_path).is_file():
                    run["transcript_path"] = thread_path
                else:
                    resolved = find_session_transcript(event.get("session_id"))
                    if resolved:
                        run["transcript_path"] = resolved
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
        # Observe outside the write lock; publication merges fresh disk workers.
        run = load_run(event, key)
        path = run_path_for_key(key)
        if kind == "SubagentStop":
            absorb_worker_source(run, key, event.get("session_id"), agent_id)
        workers = run.setdefault("workers", {})
        worker = workers.setdefault(agent_id, {"agent_id": agent_id})
        executions = _ensure_worker_execution_map(worker)
        worker_turn_id = event.get("turn_id")
        execution = None
        if worker_turn_id is not None:
            execution_id = str(worker_turn_id)
            execution = executions.setdefault(
                execution_id, {"turn_id": worker_turn_id}
            )
        elif kind == "SubagentStop" and len(executions) == 1:
            execution = next(iter(executions.values()))
        worker["agent_id"] = agent_id
        if event.get("agent_type") is not None:
            worker["agent_type"] = event.get("agent_type")
        if event.get("model") is not None:
            worker["model"] = event.get("model")
        if event.get("turn_id") is not None:
            worker["turn_id"] = event.get("turn_id")
        if kind == "SubagentStart":
            started_at_ms = _transcript_worker_started_at(event) or now_ms()
            previous_started = numeric_ms(worker.get("started_at_ms"))
            worker["started_at_ms"] = (
                started_at_ms
                if previous_started is None
                else min(previous_started, started_at_ms)
            )
            if worker.get("status") != "completed":
                worker["status"] = "running"
            if execution is not None:
                execution["agent_id"] = agent_id
                execution["started_at_ms"] = min(
                    value
                    for value in (
                        numeric_ms(execution.get("started_at_ms")),
                        started_at_ms,
                    )
                    if value is not None
                )
                execution["status"] = (
                    "completed"
                    if execution.get("status") == "completed"
                    else "running"
                )
            if event.get("agent_transcript_path") is not None:
                worker["transcript_path"] = event.get("agent_transcript_path")
                if execution is not None:
                    execution["transcript_path"] = event.get("agent_transcript_path")
        else:
            agent_transcript_path = event.get("agent_transcript_path")
            finished_at_ms = numeric_ms(execution.get("finished_at_ms")) if execution is not None else numeric_ms(worker.get("finished_at_ms"))
            finished_at_ms = finished_at_ms or now_ms()
            worker["finished_at_ms"] = max(
                value
                for value in (
                    numeric_ms(worker.get("finished_at_ms")),
                    finished_at_ms,
                )
                if value is not None
            )
            worker["status"] = "completed"
            if agent_transcript_path is not None:
                worker["transcript_path"] = agent_transcript_path
            if execution is not None:
                execution["agent_id"] = agent_id
                execution_started = _transcript_worker_started_at(event)
                if execution_started is None:
                    execution_started = numeric_ms(execution.get("started_at_ms"))
                if execution_started is None:
                    execution_started = finished_at_ms
                execution["started_at_ms"] = execution_started
                execution["finished_at_ms"] = max(
                    value
                    for value in (
                        numeric_ms(execution.get("finished_at_ms")),
                        finished_at_ms,
                    )
                    if value is not None
                )
                execution["status"] = "completed"
                if agent_transcript_path is not None:
                    execution["transcript_path"] = agent_transcript_path
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
            if execution is not None:
                service_delta = _service_usage_delta(
                    worker,
                    execution,
                    service_usage,
                    len(executions),
                    event.get("session_id"),
                    agent_id,
                )
                if service_usage is not None and not execution.get("service_usage_finalized"):
                    execution["service_usage_cumulative"] = service_usage
                merged_usage = merge_usage(transcript_usage, service_delta)
                if service_usage is not None:
                    execution["service_usage_finalized"] = True
                execution["usage"] = _merge_execution_usage(
                    execution.get("usage"), merged_usage
                )
            else:
                merged_usage = merge_usage(transcript_usage, service_usage)
                if merged_usage is not None or worker.get("usage") is None:
                    worker["usage"] = merged_usage
            _rebuild_worker_usage(worker)
            if not run.get("prompt_seen"):
                run["worker_correlation"] = "unresolved"
        _refresh_worker_lifecycle(worker)
        apply_participant_metadata(
            worker,
            event=event,
            transcript_path=worker.get("transcript_path"),
            turn_id=worker.get("turn_id"),
            usage=worker.get("usage"),
        )
        publication = publish_late_worker(run_key=key, observed=run, state_root=_common.STATE_ROOT)
        if publication.snapshot is None:
            return
        run = publication.snapshot
        worker = run["workers"][agent_id]
        _refresh_quota_allocations(run, key)
        _emit_publication(publication)
        remember_worker_parent(
            agent_id,
            event.get("session_id"),
            key,
            run.get("turn_id"),
            worker.get("started_at_ms"),
            worker_turn_id,
            worker.get("finished_at_ms") if kind == "SubagentStop" else None,
            worker.get("transcript_path"),
        )
        # Resolve the exact child execution before emitting reviewer activity.
        # A first SubagentStart has no worker-index entry on arrival.
        try:
            record_hook_activity(event)
        except Exception:
            pass
        return

    if kind == "Stop":
        run = load_run(event, key)
        if (run.get("session_id"), run.get("turn_id")) != (event.get("session_id"), event.get("turn_id")):
            return
        if isinstance(run.get("publication"), dict):
            # A replay must not charge a later turn's cumulative usage or quota
            # to this already completed parent. Exact final evidence may arrive later.
            _refresh_quota_allocations(run, key)
            try:
                from .quota_ledger import export_quota_summary, get_db
                with get_db() as db_conn:
                    export_quota_summary(db_conn)
            except Exception:
                pass
            publication = publish_parent_stop(run_key=key, observed=run,
                result=extract_parent_final(run.get("transcript_path"), run.get("turn_id"), session_id=run["session_id"]),
                completed_at_ms=run["publication"]["completed_at_ms"], state_root=_common.STATE_ROOT)
            _emit_publication(publication, summary=True)
            return
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
            sample_time_after = now_ms()
            raw_after = quota_windows(server.rate_limits()) if server.available else []
            quota_after = [
                {**w, "sampled_at_ms": sample_time_after} for w in raw_after
            ]
            parent_after = (
                usage_summary(server.thread_usage(event.get("session_id")))
                if server.available
                else None
            )
            transcript_path = run.get("transcript_path") or event.get("transcript_path")
            if not transcript_path or not Path(transcript_path).is_file():
                thread_path = (
                    run.get("thread", {}).get("path")
                    if isinstance(run.get("thread"), dict)
                    else None
                )
                if thread_path and Path(thread_path).is_file():
                    transcript_path = thread_path
                else:
                    resolved = find_session_transcript(event.get("session_id"))
                    if resolved:
                        transcript_path = resolved
            if transcript_path:
                run["transcript_path"] = transcript_path
            if not quota_after:
                transcript_quota = transcript_turn_quota(
                    transcript_path,
                    event.get("turn_id"),
                )
                if transcript_quota:
                    quota_after = transcript_quota
                    run["quota_after_source"] = "transcript_estimate"
                else:
                    run.pop("quota_after_source", None)
            else:
                run.pop("quota_after_source", None)
            run["quota_after"] = quota_after
            run["quota_change_during_run"] = quota_delta(
                run.get("quota_before", []), quota_after
            )
            try:
                from .quota_ledger import get_db, record_observation, export_quota_summary, resolve_account_id
                resolved_account = resolve_account_id(event.get("account_id"))
                for w in quota_after if run.get("quota_after_source") != "transcript_estimate" else []:
                    if w.get("window_duration_mins") == 10080 and isinstance(w.get("used_percent"), (int, float)):
                        with get_db() as db_conn:
                            record_observation(
                                conn=db_conn,
                                account_id=resolved_account,
                                bucket_id=w.get("slot") or "primary",
                                used_percent=float(w["used_percent"]),
                                sampled_at_ms=sample_time_after,
                                sample_source="turn_finish",
                                resets_at_ms=w.get("resets_at"),
                                run_id=key,
                            )
            except Exception:
                pass
            run["parent"]["usage_after"] = parent_after
            service_delta = usage_delta(
                run["parent"].get("usage_before"), parent_after
            )
            if transcript_path:
                run["transcript_path"] = transcript_path

            transcript_usage = transcript_turn_usage(
                transcript_path,
                event.get("turn_id"),
            )
            run["parent"]["usage_delta"] = merge_usage(
                transcript_usage, service_delta
            )
            apply_participant_metadata(
                run["parent"],
                event=event,
                transcript_path=run.get("transcript_path"),
                turn_id=event.get("turn_id"),
                usage=run["parent"].get("usage_delta"),
            )
            for agent_id, worker in run.get("workers", {}).items():
                if not isinstance(worker, dict):
                    continue
                executions = _ensure_worker_execution_map(worker)
                service_usage = (
                    usage_summary(server.thread_usage(agent_id))
                    if server.available
                    else None
                )
                for execution in executions.values():
                    if not isinstance(execution, dict):
                        continue
                    if execution.get("usage") is None:
                        execution_path = execution.get("transcript_path") or worker.get(
                            "transcript_path"
                        )
                        execution_turn = execution.get("turn_id") or worker.get("turn_id")
                        transcript_usage = transcript_turn_usage(
                            execution_path,
                            execution_turn,
                        )
                        service_delta = _service_usage_delta(
                            worker,
                            execution,
                            service_usage,
                            len(executions),
                            event.get("session_id"),
                            agent_id,
                        )
                        if service_usage is not None and not execution.get("service_usage_finalized"):
                            execution["service_usage_cumulative"] = service_usage
                        execution["usage"] = _merge_execution_usage(
                            execution.get("usage"),
                            merge_usage(transcript_usage, service_delta),
                        )
                _rebuild_worker_usage(worker)
                if any(
                    execution.get("status") == "running"
                    for execution in executions.values()
                    if isinstance(execution, dict)
                ):
                    for execution in executions.values():
                        if isinstance(execution, dict) and execution.get("status") == "running":
                            execution["status"] = "observed"
                _refresh_worker_lifecycle(worker)
                apply_participant_metadata(
                    worker,
                    transcript_path=worker.get("transcript_path"),
                    turn_id=worker.get("turn_id") or event.get("turn_id"),
                    usage=worker.get("usage"),
                )
        enrich_run_metadata(run)
        result = extract_parent_final(run.get("transcript_path"), run.get("turn_id"), session_id=run["session_id"])
        completed = parent_turn_completed_at(run.get("transcript_path"), run.get("turn_id"), session_id=run["session_id"])
        reconcile_orphan_workers()
        run["finished_at_ms"] = completed if completed is not None else now_ms()
        _refresh_quota_allocations(run, key)
        try:
            from .quota_ledger import export_quota_summary, get_db
            with get_db() as db_conn:
                export_quota_summary(db_conn)
        except Exception:
            pass
        publication = publish_parent_stop(run_key=key, observed=run, result=result,
            completed_at_ms=run["finished_at_ms"], state_root=_common.STATE_ROOT)
    run_maintenance()
    _emit_publication(publication, summary=True)
