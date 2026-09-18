"""Ordered, replay-safe publication of complete parent-turn snapshots.

Writers hold the turn lock before the global publication lock. Recovery holds
only the global lock, so no path ever acquires these locks in reverse order.
The run commit precedes last.json; recovery repairs that intentional crash gap.
"""
from __future__ import annotations

import copy
import json
import secrets
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping

from .common import STATE_ROOT, atomic_json, read_json_object, safe_key_part, state_lock, telemetry_writes_enabled
from .turn_context import ReceiptError, load_context, load_receipt, receipt_digest, seal_receipt

GLOBAL_LOCK = "global-publication"
_OBSERVED_FIELDS = {
    "cwd", "parent", "workers", "started_at_ms", "prompt_seen", "transcript_path",
    "thread", "quota_before", "quota_after", "quota_change_during_run",
    "skills_used", "tools_used", "trajectory", "logs", "is_system_task",
    "worker_sources", "worker_correlation", "status",
}


@dataclass(frozen=True)
class PublicationResult:
    published: bool
    changed: bool
    revision: int | None
    last_updated: bool
    notify: bool
    reason: str | None
    snapshot: dict[str, Any] | None


def _failure(reason: str) -> PublicationResult:
    return PublicationResult(False, False, None, False, False, reason, None)


def _identity(run: Mapping[str, Any]) -> tuple[Any, Any]:
    return run.get("session_id"), run.get("turn_id")


def turn_lock_key(run: Mapping[str, Any]) -> str:
    return "turn-" + receipt_digest(*_identity(run))


def _path(run_key: str, root: Path) -> Path:
    return root / "runs" / (safe_key_part(run_key) + ".json")


def _order(run: Mapping[str, Any] | None) -> tuple[int, str, str] | None:
    if not isinstance(run, Mapping):
        return None
    publication = run.get("publication")
    if not isinstance(publication, dict):
        return None
    completed, revision = publication.get("completed_at_ms"), publication.get("revision")
    if type(completed) is not int or type(revision) is not int or revision < 1:
        return None
    session, turn = _identity(run)
    if not isinstance(session, str) or not session or not isinstance(turn, str) or not turn:
        return None
    return completed, session, turn


def _fingerprint(run: dict[str, Any]) -> str:
    value = copy.deepcopy(run)
    if isinstance(value.get("publication"), dict):
        value["publication"].pop("revision", None)
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def merge_observed(current: dict[str, Any], observed: Mapping[str, Any], *, workers_only=False) -> dict[str, Any]:
    """Disk is authoritative; merge distinct worker executions without summing replays."""
    from .collector import merge_worker_values
    result = copy.deepcopy(current)
    allowed = {"workers", "worker_sources"} if workers_only else _OBSERVED_FIELDS
    for field in allowed:
        value = observed.get(field)
        if value is None:
            continue
        if field == "workers" and isinstance(value, dict):
            workers = result.setdefault("workers", {})
            for agent_id, worker in value.items():
                if isinstance(worker, dict):
                    workers[agent_id] = merge_worker_values(workers.get(agent_id), worker)
        elif field == "worker_sources" and isinstance(value, dict):
            sources = result.setdefault(field, {})
            for agent_id, keys in value.items():
                if isinstance(keys, list):
                    sources[agent_id] = sorted(set(sources.get(agent_id, [])) | set(keys))
        elif field == "parent" and isinstance(value, dict):
            result.setdefault(field, {}).update({key: copy.deepcopy(item) for key, item in value.items() if item is not None})
        elif field == "started_at_ms" and result.get(field) is not None:
            continue
        else:
            result[field] = copy.deepcopy(value)
    return result


def _commit_locked(path: Path, previous: dict[str, Any], run: dict[str, Any], root: Path,
                   *, first_stop=False) -> PublicationResult:
    """Caller owns both locks; never read transcripts or call external services here."""
    prior = previous.get("publication") if _order(previous) is not None else None
    revision = prior["revision"] if prior else 0
    changed = not prior or _fingerprint(previous) != _fingerprint(run)
    run["publication"]["revision"] = revision + int(changed)
    if changed:
        atomic_json(path, run)
    last_path = root / "last.json"
    last = read_json_object(last_path)
    last_order, new_order = _order(last), _order(run)
    last_updated = (last_order is None or new_order >= last_order) and last != run
    if last_updated:
        atomic_json(last_path, run)
    return PublicationResult(True, changed, run["publication"]["revision"], last_updated,
                             first_stop and last_updated, None, copy.deepcopy(run))


def publish_parent_stop(*, run_key: str, observed: Mapping[str, Any],
                        result: Mapping[str, Any] | None, completed_at_ms: int,
                        state_root: Path = STATE_ROOT) -> PublicationResult:
    if not telemetry_writes_enabled():
        return _failure("disabled")
    root = Path(state_root)
    try:
        lock_key = turn_lock_key(observed)
    except ReceiptError:
        return _failure("run_identity_mismatch")
    path = _path(run_key, root)
    with state_lock(lock_key, state_root=root) as acquired:
        if not acquired:
            return _failure("locked")
        current = read_json_object(path)
        if current is not None and _identity(current) != _identity(observed):
            return _failure("run_identity_mismatch")
        current = current or {"schema_version": 1, "session_id": observed["session_id"], "turn_id": observed["turn_id"], "publication_required": True, "parent": {}, "workers": {}}
        with state_lock(GLOBAL_LOCK, state_root=root) as global_acquired:
            if not global_acquired:
                return _failure("locked")
            run = merge_observed(current, observed)
            first = _order(current) is None
            completed = completed_at_ms if first else current["publication"]["completed_at_ms"]
            if type(completed) is not int:
                return _failure("invalid_completion_time")
            if first:
                receipt_path = root / "turn-receipts" / (lock_key[5:] + ".json")
                if not receipt_path.exists():
                    # A Stop may be the first observed hook. Retain a sealed
                    # local tombstone so a delayed prompt cannot reopen it.
                    atomic_json(receipt_path, {"schema_version": 1, "session_id": run["session_id"],
                        "turn_id": run["turn_id"], "role": "parent", "receipt_id": secrets.token_urlsafe(32), "state": "sealed"})
                try:
                    receipt = load_receipt(receipt_path)
                    if (receipt.session_id, receipt.turn_id) == _identity(run):
                        seal_receipt(receipt, state_root=root)
                except ReceiptError:
                    pass  # Stop can publish without an unverified host receipt transport.
                try:
                    context = load_context(*_identity(run), state_root=root)
                except ReceiptError:
                    context = None
                if context is not None:
                    run["turn_context"] = {key: copy.deepcopy(context[key]) for key in ("schema_version", "session_id", "turn_id", "goal", "orchestration") if key in context}
            if (isinstance(result, Mapping) and result.get("source") == "parent_final"
                    and result.get("turn_id") == run["turn_id"]
                    and isinstance(result.get("text"), str) and result["text"].strip()):
                run["result"] = {"text": result["text"], "source": "parent_final", "turn_id": run["turn_id"], "truncated": result.get("truncated") is True}
            run["finished_at_ms"] = completed
            run["publication"] = {"completed_at_ms": completed}
            return _commit_locked(path, current, run, root, first_stop=first)


def update_run(*, run_key: str, identity: Mapping[str, Any],
               transform: Callable[[dict[str, Any]], dict[str, Any]],
               state_root: Path = STATE_ROOT) -> PublicationResult:
    """Shared worker/repair writer; an unpublished run stays unpublished.

    The small pure transform receives a fresh disk value under the turn lock.
    It must not perform external reads, acquire locks, or publish a new turn.
    """
    if not telemetry_writes_enabled():
        return _failure("disabled")
    root = Path(state_root)
    try:
        lock_key = turn_lock_key(identity)
    except ReceiptError:
        return _failure("run_identity_mismatch")
    path = _path(run_key, root)
    with state_lock(lock_key, state_root=root) as acquired:
        if not acquired:
            return _failure("locked")
        current = read_json_object(path)
        if current is not None and _identity(current) != _identity(identity):
            return _failure("run_identity_mismatch")
        current = current or {"schema_version": 1, "session_id": identity["session_id"], "turn_id": identity["turn_id"], "publication_required": True, "parent": {}, "workers": {}}
        run = transform(copy.deepcopy(current))
        for key in ("session_id", "turn_id", "publication", "turn_context", "result"):
            if key in current:
                run[key] = copy.deepcopy(current[key])
            else:
                run.pop(key, None)
        if _order(current) is not None:
            run["finished_at_ms"] = current["publication"]["completed_at_ms"]
            with state_lock(GLOBAL_LOCK, state_root=root) as global_acquired:
                if not global_acquired:
                    return _failure("locked")
                return _commit_locked(path, current, run, root)
        changed = current != run
        if type(current.get("finished_at_ms")) is int and not current.get("publication_required"):
            # Preserve an already completed legacy last record without inventing
            # a parent Stop or publication for pre-publication history.
            with state_lock(GLOBAL_LOCK, state_root=root) as global_acquired:
                if not global_acquired:
                    return _failure("locked")
                if changed:
                    atomic_json(path, run)
                last_path = root / "last.json"
                last = read_json_object(last_path)
                refresh = (last is not None and "publication" not in last
                           and not last.get("publication_required") and _identity(last) == _identity(run) and last != run)
                if refresh:
                    atomic_json(last_path, run)
                return PublicationResult(False, changed, None, refresh, False, "legacy", copy.deepcopy(run))
        if changed:
            atomic_json(path, run)
        return PublicationResult(False, changed, None, False, False, "unpublished", copy.deepcopy(run))


def publish_late_worker(*, run_key: str, observed: Mapping[str, Any],
                        state_root: Path = STATE_ROOT) -> PublicationResult:
    def merge(current):
        run = merge_observed(current, observed, workers_only=True)
        if _order(current) is None:
            for field in _OBSERVED_FIELDS - {"workers", "worker_sources"}:
                if not run.get(field) and observed.get(field) is not None:
                    run[field] = copy.deepcopy(observed[field])
        return run
    return update_run(run_key=run_key, identity=observed, state_root=state_root,
                      transform=merge)


def recover_last(*, state_root: Path = STATE_ROOT) -> PublicationResult:
    if not telemetry_writes_enabled():
        return _failure("disabled")
    root = Path(state_root)
    with state_lock(GLOBAL_LOCK, state_root=root) as acquired:
        if not acquired:
            return _failure("locked")
        newest = None
        for path in sorted((root / "runs").glob("*.json")):
            candidate = read_json_object(path)
            order = _order(candidate)
            if order is not None and (newest is None or order > _order(newest)):
                newest = candidate
        if newest is None:
            return _failure("no_published_runs")
        last_path = root / "last.json"
        changed = read_json_object(last_path) != newest
        if changed:
            atomic_json(last_path, newest)
        return PublicationResult(True, changed, newest["publication"]["revision"], changed, False, None, newest)
