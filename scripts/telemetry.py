#!/usr/bin/env python3
"""Deterministic codex-flow telemetry collector.

Consumes Codex command-hook JSON on stdin. It never calls a model. Usage and
quota data are read from `codex app-server`; lifecycle data comes from hooks.
"""
from __future__ import annotations

import json
import os
import queue
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any

CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
STATE_ROOT = CODEX_HOME / "codex-flow" / "telemetry"
RUNS_DIR = STATE_ROOT / "runs"
LAST_FILE = STATE_ROOT / "last.json"
WORKER_INDEX_FILE = STATE_ROOT / "worker-index.json"
SESSION_INDEX_FILE = CODEX_HOME / "session_index.jsonl"
TIMEOUT = float(os.environ.get("CODEX_FLOW_TELEMETRY_TIMEOUT", "3.0"))
LOCK_TIMEOUT = float(os.environ.get("CODEX_FLOW_TELEMETRY_LOCK_TIMEOUT", "2.0"))
DEFAULT_RETENTION_DAYS = 30


def policy_value(section_name: str, key_name: str) -> str | None:
    """Read one simple TOML scalar without adding a Python-version dependency."""
    path = CODEX_HOME / "codex-flow.toml"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    section: str | None = None
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section != section_name or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key != key_name:
            continue
        return value.strip().strip('"')
    return None


def policy_bool(section_name: str, key_name: str, default: bool) -> bool:
    value = policy_value(section_name, key_name)
    if value is None:
        return default
    normalized = value.lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    return default


def policy_int(section_name: str, key_name: str, default: int) -> int:
    value = policy_value(section_name, key_name)
    try:
        parsed = int(value) if value is not None else default
    except (TypeError, ValueError):
        return default
    return parsed if parsed > 0 else default


def telemetry_notifications_enabled() -> bool:
    value = os.environ.get("CODEX_FLOW_TELEMETRY_NOTIFICATIONS")
    if value is not None:
        normalized = value.strip().lower()
        if normalized in {"0", "false", "no", "off"}:
            return False
        if normalized in {"1", "true", "yes", "on"}:
            return True
    return policy_bool("telemetry", "notifications", True)


def telemetry_retention_days() -> int:
    value = os.environ.get("CODEX_FLOW_TELEMETRY_RETENTION_DAYS")
    if value is not None:
        try:
            parsed = int(value)
            if parsed > 0:
                return parsed
        except ValueError:
            pass
    return policy_int("telemetry", "retention_days", DEFAULT_RETENTION_DAYS)


def now_ms() -> int:
    return int(time.time() * 1000)


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


@contextmanager
def state_lock(key: str):
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    lock = STATE_ROOT / ("." + key.replace("/", "_") + ".lock")
    deadline = time.monotonic() + LOCK_TIMEOUT
    acquired = False
    while True:
        try:
            lock.mkdir()
            acquired = True
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                break
            time.sleep(0.025)
    try:
        # Callers must not enter a critical section unless this process owns
        # the lock.  A timeout is a normal fail-open outcome for telemetry,
        # not permission to proceed without serialization.
        yield acquired
    finally:
        if acquired:
            try:
                lock.rmdir()
            except OSError:
                pass


def read_json_object(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def session_index_metadata(session_id: Any) -> dict[str, Any] | None:
    """Read the local title index when app-server cannot materialize a thread.

    A UserPromptSubmit hook can run before ``thread/read`` is available for a
    newly-created Desktop thread.  The local session index is maintained by
    Codex itself and contains the same user-facing title without requiring a
    model or a best-effort title guess from the prompt.
    """
    if not session_id or not SESSION_INDEX_FILE.is_file():
        return None
    target = str(session_id)
    try:
        lines = SESSION_INDEX_FILE.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    for raw in reversed(lines):
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict):
            continue
        entry_id = entry.get("id") or entry.get("session_id")
        if str(entry_id or "") != target:
            continue
        metadata: dict[str, Any] = {"id": entry_id}
        name = entry.get("thread_name") or entry.get("name")
        if name is not None:
            metadata["name"] = name
        preview = entry.get("preview")
        if preview is not None:
            metadata["preview"] = preview
        return metadata
    return None


def merge_thread_metadata(*values: Any) -> dict[str, Any] | None:
    result: dict[str, Any] = {}
    for value in values:
        if not isinstance(value, dict):
            continue
        for key, item in value.items():
            if item is not None and item != "":
                result[key] = item
    return result or None


def numeric_ms(value: Any) -> int | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return int(value)
    return None


def safe_key_part(value: Any) -> str:
    return str(value).replace("/", "_").replace("\\", "_")


def run_key(event: dict[str, Any]) -> str:
    """Return the event's native session/turn key.

    A child turn is intentionally not rewritten from transcript contents here.
    Codex documents transcript_path as a convenience field, and in practice a
    Subagent hook can expose the child rollout path or a transcript whose
    active parent turn has already changed. Worker correlation is handled by
    the durable agent index and run-window matching below.
    """
    session = safe_key_part(event.get("session_id") or "unknown")
    turn = safe_key_part(event.get("turn_id") or "unknown")
    return f"{session}--{turn}"


def run_path_for_key(key: str) -> Path:
    return RUNS_DIR / f"{safe_key_part(key)}.json"


def run_path(event: dict[str, Any]) -> Path:
    return run_path_for_key(run_key(event))


def load_run(event: dict[str, Any], key: str | None = None) -> dict[str, Any]:
    resolved_key = key or run_key(event)
    path = run_path_for_key(resolved_key)
    existing = read_json_object(path) if path.exists() else None
    if existing is not None:
        return existing
    return {
        "schema_version": 1,
        "session_id": event.get("session_id"),
        "turn_id": event.get("turn_id"),
        "cwd": event.get("cwd"),
        "parent": {"model": event.get("model")},
        "workers": {},
        "started_at_ms": now_ms(),
    }


def iter_run_files() -> list[Path]:
    try:
        return sorted(path for path in RUNS_DIR.glob("*.json") if path.is_file())
    except OSError:
        return []


def load_worker_index() -> dict[str, Any]:
    value = read_json_object(WORKER_INDEX_FILE)
    if value is None:
        return {"schema_version": 1, "workers": {}}
    workers = value.get("workers")
    if not isinstance(workers, dict):
        value["workers"] = {}
    return value


def worker_index_entry(agent_id: str, session_id: Any) -> dict[str, Any] | None:
    if not agent_id or agent_id == "unknown":
        return None
    index = load_worker_index()
    workers = index.get("workers")
    entry = workers.get(agent_id) if isinstance(workers, dict) else None
    if not isinstance(entry, dict):
        return None
    if str(entry.get("session_id") or "") != str(session_id or ""):
        return None
    key = entry.get("run_key")
    if not isinstance(key, str) or not run_path_for_key(key).is_file():
        return None
    return entry


def remember_worker_parent(
    agent_id: str, session_id: Any, parent_key: str, parent_turn_id: Any, started_at_ms: Any
) -> None:
    if not agent_id or agent_id == "unknown":
        return
    with state_lock("worker-index") as acquired:
        if not acquired:
            return
        index = load_worker_index()
        workers = index.setdefault("workers", {})
        if not isinstance(workers, dict):
            workers = {}
            index["workers"] = workers
        existing = workers.get(agent_id)
        old_started = (
            numeric_ms(existing.get("started_at_ms"))
            if isinstance(existing, dict)
            else None
        )
        new_started = numeric_ms(started_at_ms)
        if (
            isinstance(existing, dict)
            and str(existing.get("session_id") or "") == str(session_id or "")
            and old_started is not None
            and (new_started is None or old_started > new_started)
        ):
            return
        workers[agent_id] = {
            "agent_id": agent_id,
            "session_id": session_id,
            "parent_key": parent_key,
            "parent_turn_id": parent_turn_id,
            "run_key": parent_key,
            "started_at_ms": numeric_ms(started_at_ms),
            "updated_at_ms": now_ms(),
        }
        atomic_json(WORKER_INDEX_FILE, index)


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
    """Find the best persisted record for an agent when its index is absent."""
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

    # A Start normally arrives while its parent is active. Prefer that window
    # so a reused agent id cannot inherit a stale index entry.
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
        # There is no safe temporal match. Keep enriching the source record;
        # the next parent Stop can retry reconciliation with more evidence.
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
    """Repair orphan worker files using their persisted time windows.

    The source file is retained and marked as merged so the 30-day retention
    window still contains the original event record and merge provenance.
    """
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
    """Prune generated telemetry records and stale worker index entries."""
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


def app_server_command() -> list[str]:
    override = os.environ.get("CODEX_FLOW_APP_SERVER_COMMAND")
    if override:
        return shlex.split(override)
    return ["codex", "app-server"]


class AppServer:
    """Minimal stdio JSONL client for the Codex app-server.

    Codex intentionally omits the JSON-RPC `jsonrpc` header on the wire. A
    background reader thread is used instead of selectors so subprocess pipes
    work the same way on Unix and Windows.
    """

    def __init__(self) -> None:
        self.proc: subprocess.Popen[str] | None = None
        self.next_id = 1
        self.messages: queue.Queue[dict[str, Any] | None] = queue.Queue()
        self.reader: threading.Thread | None = None

    def __enter__(self) -> "AppServer":
        try:
            self.proc = subprocess.Popen(
                app_server_command(),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            self.reader = threading.Thread(target=self._pump_stdout, daemon=True)
            self.reader.start()
            response = self.request(
                "initialize",
                {
                    "clientInfo": {
                        "name": "codex-flow",
                        "title": "FlowPilot telemetry",
                        "version": "1",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            )
            if response is None:
                self.close()
                return self
            self.notify("initialized")
        except (OSError, ValueError):
            self.close()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    @property
    def available(self) -> bool:
        return (
            self.proc is not None
            and self.proc.poll() is None
            and self.proc.stdin is not None
            and self.proc.stdout is not None
        )

    def _pump_stdout(self) -> None:
        proc = self.proc
        if proc is None or proc.stdout is None:
            self.messages.put(None)
            return
        try:
            for line in proc.stdout:
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(message, dict):
                    self.messages.put(message)
        finally:
            self.messages.put(None)

    def close(self) -> None:
        proc = self.proc
        if proc is None:
            return
        try:
            proc.terminate()
            proc.wait(timeout=0.4)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        self.proc = None

    def _send(self, payload: dict[str, Any]) -> bool:
        if not self.available:
            return False
        try:
            assert self.proc is not None and self.proc.stdin is not None
            self.proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
            self.proc.stdin.flush()
            return True
        except (BrokenPipeError, OSError):
            return False

    def notify(self, method: str, params: Any | None = None) -> None:
        payload: dict[str, Any] = {"method": method}
        if params is not None:
            payload["params"] = params
        self._send(payload)

    def request(self, method: str, params: Any | None = None) -> dict[str, Any] | None:
        request_id = self.next_id
        self.next_id += 1
        payload: dict[str, Any] = {"id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        if not self._send(payload):
            return None
        return self._read_response(request_id)

    def _read_response(self, request_id: int) -> dict[str, Any] | None:
        deadline = time.monotonic() + TIMEOUT
        deferred: list[dict[str, Any]] = []
        try:
            while time.monotonic() < deadline:
                remaining = max(0.0, deadline - time.monotonic())
                try:
                    message = self.messages.get(timeout=remaining)
                except queue.Empty:
                    break
                if message is None:
                    break
                if message.get("id") != request_id:
                    deferred.append(message)
                    continue
                if "error" in message:
                    return None
                result = message.get("result")
                return result if isinstance(result, dict) else None
        finally:
            for message in deferred:
                self.messages.put(message)
        return None

    def rate_limits(self) -> dict[str, Any] | None:
        return self.request("account/rateLimits/read")

    def thread_usage(self, thread_id: str | None) -> dict[str, Any] | None:
        if not thread_id:
            return None
        response = self.request("account/usage/read", {"threadId": thread_id})
        if not response:
            return None
        usage = response.get("threadUsage")
        return usage if isinstance(usage, dict) else None

    def thread_metadata(self, thread_id: str | None) -> dict[str, Any] | None:
        """Read deterministic user-facing thread metadata without loading turns."""
        if not thread_id:
            return None
        response = self.request(
            "thread/read", {"threadId": thread_id, "includeTurns": False}
        )
        if not response:
            return None
        thread = response.get("thread")
        return thread if isinstance(thread, dict) else None


def quota_windows(snapshot: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not snapshot:
        return []
    rate_limits = snapshot.get("rateLimits")
    if not isinstance(rate_limits, dict):
        return []
    result: list[dict[str, Any]] = []
    for slot in ("primary", "secondary"):
        window = rate_limits.get(slot)
        if not isinstance(window, dict):
            continue
        result.append(
            {
                "slot": slot,
                "used_percent": window.get("usedPercent"),
                "window_duration_mins": window.get("windowDurationMins"),
                "resets_at": window.get("resetsAt"),
            }
        )
    return result


def usage_summary(usage: dict[str, Any] | None) -> dict[str, Any] | None:
    if not usage:
        return None
    groups = usage.get("groups") if isinstance(usage.get("groups"), list) else []
    estimated_credits = usage.get("estimatedUsageCreditsMicros")
    totals: dict[str, Any] = {
        "input_tokens": 0,
        "cached_input_tokens": 0,
        "net_new_input_tokens": 0,
        "output_tokens": 0,
        "total_tokens": 0,
        "estimated_credits_micros": (
            int(estimated_credits)
            if isinstance(estimated_credits, (int, float))
            else None
        ),
        "estimated_usd_micros": usage.get("estimatedUsageUsdMicros"),
    }
    normalized_groups = []
    mapping = {
        "inputTokens": "input_tokens",
        "cachedInputTokens": "cached_input_tokens",
        "netNewInputTokens": "net_new_input_tokens",
        "outputTokens": "output_tokens",
        "totalTokens": "total_tokens",
    }
    for group in groups:
        if not isinstance(group, dict):
            continue
        normalized: dict[str, Any] = {
            "model": group.get("model"),
            "reasoning_effort": group.get("reasoningEffort"),
            "speed": group.get("speed"),
            "estimated_credits_micros": (
                int(group["estimatedUsageCreditsMicros"])
                if isinstance(group.get("estimatedUsageCreditsMicros"), (int, float))
                else None
            ),
        }
        for source, target in mapping.items():
            value = group.get(source)
            normalized[target] = int(value) if isinstance(value, (int, float)) else None
            if normalized[target] is not None:
                totals[target] += normalized[target]
        normalized_groups.append(normalized)
    totals["groups"] = normalized_groups
    return totals


def usage_delta(before: dict[str, Any] | None, after: dict[str, Any] | None) -> dict[str, Any] | None:
    if not before or not after:
        return None
    numeric = [
        "input_tokens",
        "cached_input_tokens",
        "net_new_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "cache_write_input_tokens",
        "total_tokens",
        "estimated_credits_micros",
    ]
    result: dict[str, Any] = {}
    for key in numeric:
        end = after.get(key)
        start = before.get(key)
        if isinstance(end, (int, float)) and isinstance(start, (int, float)):
            result[key] = max(0, int(end - start))
    usd_after = after.get("estimated_usd_micros")
    usd_before = before.get("estimated_usd_micros")
    if isinstance(usd_after, (int, float)) and isinstance(usd_before, (int, float)):
        result["estimated_usd_micros"] = max(0, int(usd_after - usd_before))
    # Group totals are cumulative too.  Only subtract groups whose complete
    # stable identity exists in both snapshots; newly appearing groups have
    # no defensible baseline and must not be attributed to this run.
    identity_fields = ("model", "reasoning_effort", "speed")
    group_numeric = (
        "input_tokens",
        "cached_input_tokens",
        "net_new_input_tokens",
        "output_tokens",
        "total_tokens",
        "estimated_credits_micros",
        "estimated_usd_micros",
    )

    def group_identity(group: Any) -> tuple[Any, ...] | None:
        if not isinstance(group, dict):
            return None
        identity = tuple(group.get(field) for field in identity_fields)
        if any(value is None for value in identity):
            return None
        return identity

    before_groups: dict[tuple[Any, ...], dict[str, Any]] = {}
    duplicate_before: set[tuple[Any, ...]] = set()
    before_group_values = before.get("groups")
    if not isinstance(before_group_values, list):
        before_group_values = []
    for group in before_group_values:
        identity = group_identity(group)
        if identity is None:
            continue
        if identity in before_groups:
            duplicate_before.add(identity)
        else:
            before_groups[identity] = group

    delta_groups: list[dict[str, Any]] = []
    after_group_values = after.get("groups")
    if not isinstance(after_group_values, list):
        after_group_values = []
    for group in after_group_values:
        identity = group_identity(group)
        if identity is None or identity in duplicate_before:
            continue
        old = before_groups.get(identity)
        if old is None:
            continue
        delta_group: dict[str, Any] = {
            field: group[field] for field in identity_fields
        }
        comparable = False
        for key in group_numeric:
            end = group.get(key)
            start = old.get(key)
            if isinstance(end, (int, float)) and isinstance(start, (int, float)):
                delta_group[key] = max(0, int(end - start))
                comparable = True
        if comparable:
            delta_groups.append(delta_group)
    result["groups"] = delta_groups
    return result


def normalize_transcript_usage(value: Any) -> dict[str, Any] | None:
    """Normalize a Codex rollout token_count total_token_usage payload."""
    if not isinstance(value, dict):
        return None
    fields = (
        "input_tokens",
        "cached_input_tokens",
        "cache_write_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "total_tokens",
    )
    result: dict[str, Any] = {}
    for field in fields:
        raw = value.get(field)
        if isinstance(raw, (int, float)) and not isinstance(raw, bool):
            result[field] = int(raw)
    if not result:
        return None
    input_tokens = result.get("input_tokens")
    cached_tokens = result.get("cached_input_tokens")
    cache_write_tokens = result.get("cache_write_input_tokens", 0)
    if isinstance(input_tokens, int) and isinstance(cached_tokens, int):
        result["net_new_input_tokens"] = max(
            0, input_tokens - cached_tokens - cache_write_tokens
        )
    return result


def text_value(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def event_reasoning_effort(event: dict[str, Any] | None) -> str | None:
    """Read an effort value when a hook payload exposes one."""
    if not isinstance(event, dict):
        return None
    for key in (
        "reasoning_effort",
        "reasoningEffort",
        "effort",
        "model_reasoning_effort",
    ):
        value = text_value(event.get(key))
        if value:
            return value
    for key in ("thread_settings", "threadSettings", "settings"):
        settings = event.get(key)
        if not isinstance(settings, dict):
            continue
        for setting_key in (
            "reasoning_effort",
            "reasoningEffort",
            "effort",
            "model_reasoning_effort",
        ):
            value = text_value(settings.get(setting_key))
            if value:
                return value
    return None


def transcript_turn_metadata(path_value: Any, turn_id: Any) -> dict[str, Any] | None:
    """Read model and reasoning effort for one turn from a rollout transcript."""
    if not isinstance(path_value, str) or not path_value or not turn_id:
        return None
    path = Path(path_value)
    if not path.is_file():
        return None

    target_turn = str(turn_id)
    result: dict[str, Any] = {}
    try:
        with path.open("r", encoding="utf-8") as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict):
                    continue

                record_type = record.get("type")
                payload = record.get("payload")
                if not isinstance(payload, dict):
                    continue

                candidate: dict[str, Any] | None = None
                candidate_turn: Any = None
                if record_type == "turn_context":
                    candidate = payload
                    candidate_turn = payload.get("turn_id")
                elif record_type == "event_msg":
                    event_type = payload.get("type")
                    if event_type == "task_started":
                        candidate = payload
                        candidate_turn = payload.get("turn_id")
                    elif event_type == "thread_settings_applied":
                        candidate = payload.get("thread_settings")
                        candidate_turn = payload.get("turn_id")

                if candidate_turn is None or str(candidate_turn) != target_turn:
                    continue
                if not isinstance(candidate, dict):
                    continue
                model = text_value(candidate.get("model"))
                if model:
                    result["model"] = model
                effort = event_reasoning_effort(candidate)
                if effort:
                    result["reasoning_effort"] = effort
    except (OSError, UnicodeError):
        return None
    return result or None


def transcript_turn_usage(path_value: Any, turn_id: Any) -> dict[str, Any] | None:
    """Read exact per-turn token usage from the hook-provided rollout path.

    Rollout JSONL is explicitly a convenience rather than a stable hook API,
    so this parser only recognizes the narrow token_count/task lifecycle shape
    and fails open for every other shape.
    """
    if not isinstance(path_value, str) or not path_value or not turn_id:
        return None
    path = Path(path_value)
    if not path.is_file():
        return None

    target_turn = str(turn_id)
    current_turn: str | None = None
    latest_total: dict[str, Any] | None = None
    before: dict[str, Any] | None = None
    after: dict[str, Any] | None = None
    target_seen = False
    try:
        with path.open("r", encoding="utf-8") as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict) or record.get("type") != "event_msg":
                    continue
                payload = record.get("payload")
                if not isinstance(payload, dict):
                    continue
                kind = payload.get("type")
                event_turn = payload.get("turn_id")
                if kind == "task_started":
                    current_turn = str(event_turn) if event_turn is not None else None
                    if current_turn == target_turn:
                        target_seen = True
                        before = dict(latest_total) if latest_total is not None else None
                    continue
                if kind == "token_count":
                    info = payload.get("info")
                    usage = normalize_transcript_usage(
                        info.get("total_token_usage") if isinstance(info, dict) else None
                    )
                    if usage is not None:
                        latest_total = usage
                        if current_turn == target_turn:
                            after = usage
                    continue
                if kind in {"task_complete", "turn_aborted"}:
                    completed_turn = (
                        str(event_turn) if event_turn is not None else current_turn
                    )
                    if completed_turn == current_turn:
                        current_turn = None
    except (OSError, UnicodeError):
        return None

    if not target_seen or after is None:
        return None
    if before is None:
        result = dict(after)
        result["groups"] = []
    else:
        result = usage_delta(before, after)
        if result is None:
            return None
    result["source"] = "transcript"
    return result


def merge_usage(
    transcript_usage: dict[str, Any] | None,
    service_usage: dict[str, Any] | None,
) -> dict[str, Any] | None:
    """Prefer exact rollout tokens and add service-only billing fields."""
    if transcript_usage is None:
        if service_usage is not None:
            service_usage = dict(service_usage)
            service_usage["source"] = "app-server"
        return service_usage
    result = dict(transcript_usage)
    if service_usage is not None:
        for key in ("estimated_credits_micros", "estimated_usd_micros"):
            value = service_usage.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                result[key] = int(value)
        groups = service_usage.get("groups")
        if isinstance(groups, list):
            result["groups"] = groups
        result["source"] = "transcript+app-server"
    return result


def usage_group_identities(usage: dict[str, Any] | None) -> list[tuple[str | None, str | None]]:
    if not isinstance(usage, dict):
        return []
    groups = usage.get("groups")
    if not isinstance(groups, list):
        return []
    identities: list[tuple[str | None, str | None]] = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        model = text_value(group.get("model"))
        effort = text_value(group.get("reasoning_effort"))
        identity = (model, effort)
        if identity != (None, None) and identity not in identities:
            identities.append(identity)
    return identities


def apply_participant_metadata(
    participant: dict[str, Any],
    *,
    event: dict[str, Any] | None = None,
    transcript_path: Any = None,
    turn_id: Any = None,
    usage: dict[str, Any] | None = None,
) -> None:
    """Attach observed model/effort without inferring values from token counts."""
    if event is not None:
        model = text_value(event.get("model"))
        if model and not text_value(participant.get("model")):
            participant["model"] = model
        effort = event_reasoning_effort(event)
        if effort and not text_value(participant.get("reasoning_effort")):
            participant["reasoning_effort"] = effort

    metadata = transcript_turn_metadata(transcript_path, turn_id)
    if metadata is not None:
        model = text_value(metadata.get("model"))
        if model and not text_value(participant.get("model")):
            participant["model"] = model
        effort = text_value(metadata.get("reasoning_effort"))
        if effort and not text_value(participant.get("reasoning_effort")):
            participant["reasoning_effort"] = effort

    identities = usage_group_identities(usage)
    if not text_value(participant.get("model")):
        models = {model for model, _ in identities if model}
        if len(models) == 1:
            participant["model"] = next(iter(models))
    if not text_value(participant.get("reasoning_effort")):
        efforts = {effort for _, effort in identities if effort}
        if len(efforts) == 1:
            participant["reasoning_effort"] = next(iter(efforts))


def enrich_run_metadata(run: dict[str, Any]) -> None:
    """Backfill display metadata for records created by older collectors."""
    thread = merge_thread_metadata(
        session_index_metadata(run.get("session_id")), run.get("thread")
    )
    if thread is not None:
        run["thread"] = thread

    parent = run.get("parent")
    if isinstance(parent, dict):
        apply_participant_metadata(
            parent,
            transcript_path=run.get("transcript_path"),
            turn_id=run.get("turn_id"),
            usage=parent.get("usage_delta"),
        )
    workers = run.get("workers")
    if not isinstance(workers, dict):
        return
    for worker in workers.values():
        if not isinstance(worker, dict):
            continue
        apply_participant_metadata(
            worker,
            transcript_path=worker.get("transcript_path"),
            turn_id=worker.get("turn_id") or run.get("turn_id"),
            usage=worker.get("usage"),
        )


def quota_delta(before: list[dict[str, Any]], after: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_duration = {
        item.get("window_duration_mins"): item
        for item in before
        if item.get("window_duration_mins") is not None
    }
    result = []
    for item in after:
        old = by_duration.get(item.get("window_duration_mins"))
        delta = None
        if (
            old
            and isinstance(old.get("used_percent"), (int, float))
            and isinstance(item.get("used_percent"), (int, float))
        ):
            delta = item["used_percent"] - old["used_percent"]
        result.append({**item, "delta_percentage_points": delta})
    return result


def fmt_tokens(value: Any) -> str:
    if not isinstance(value, (int, float)):
        return "n/a"
    value = int(value)
    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f}m"
    if value >= 1_000:
        return f"{value / 1_000:.1f}k"
    return str(value)


def window_label(minutes: Any) -> str:
    if minutes == 300:
        return "5h"
    if minutes == 10080:
        return "7d"
    if isinstance(minutes, int) and minutes > 0:
        if minutes % 1440 == 0:
            return f"{minutes // 1440}d"
        return f"{minutes}m"
    return "quota"


def fmt_percent(value: Any) -> str | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return f"{value:g}"
    if value is None:
        return None
    return str(value)


def aggregate_usage_value(
    usages: list[dict[str, Any] | None], key: str
) -> int | None:
    """Return a complete participant aggregate, or None when any is unknown."""
    values: list[int] = []
    for usage in usages:
        if not isinstance(usage, dict):
            return None
        value = usage.get(key)
        if not isinstance(value, (int, float)):
            return None
        values.append(int(value))
    return sum(values) if values else None


def compact_text(value: Any, limit: int = 52) -> str | None:
    if value is None:
        return None
    text = " ".join(str(value).split())
    if not text:
        return None
    if len(text) <= limit:
        return text
    return text[: max(1, limit - 1)] + "…"


def participant_runtime_label(
    participant: dict[str, Any], usage: dict[str, Any] | None
) -> str:
    """Format the observed model and reasoning effort for a participant."""
    model = text_value(participant.get("model"))
    effort = text_value(participant.get("reasoning_effort"))
    identities = usage_group_identities(usage)
    if not model:
        models = {item_model for item_model, _ in identities if item_model}
        if len(models) == 1:
            model = next(iter(models))
    if not effort:
        efforts = {item_effort for _, item_effort in identities if item_effort}
        if len(efforts) == 1:
            effort = next(iter(efforts))

    model = compact_text(model, 32) or "unknown"
    effort = compact_text(effort, 16) or "effort n/a"
    return f"{model} ({effort})"


def fmt_local_timestamp(value: Any, *, milliseconds: bool = False) -> str | None:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    timestamp = float(value) / 1000 if milliseconds else float(value)
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(timestamp))
    except (OverflowError, OSError, ValueError):
        return None


def fmt_duration_ms(value: Any) -> str | None:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    total_seconds = max(0, int(round(float(value) / 1000)))
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def run_context(run: dict[str, Any]) -> tuple[str | None, str | None, str | None]:
    thread = run.get("thread") if isinstance(run.get("thread"), dict) else {}
    session = compact_text(
        thread.get("name") or thread.get("preview") or run.get("session_id")
    )
    cwd = thread.get("cwd") or run.get("cwd")
    project = None
    if cwd:
        try:
            project = Path(str(cwd)).name or str(cwd)
        except (OSError, ValueError):
            project = str(cwd)
    git_info = thread.get("gitInfo")
    branch = git_info.get("branch") if isinstance(git_info, dict) else None
    return session, compact_text(project), compact_text(branch)


def render_summary(run: dict[str, Any]) -> str:
    enrich_run_metadata(run)
    workers = list((run.get("workers") or {}).values())
    parent = run.get("parent") or {}
    parent_usage = parent.get("usage_delta") if isinstance(parent, dict) else None
    participant_usages = [parent_usage]
    participant_usages.extend(
        worker.get("usage") if isinstance(worker, dict) else None for worker in workers
    )

    p_count = f"1 parent + {len(workers)} worker{'s' if len(workers) != 1 else ''}"
    p_runtime = participant_runtime_label(parent, parent_usage)
    p_tokens = f"{fmt_tokens(parent_usage.get('total_tokens') if isinstance(parent_usage, dict) else None)} tokens"

    total_tokens = aggregate_usage_value(participant_usages, "total_tokens")
    credits = aggregate_usage_value(participant_usages, "estimated_credits_micros")
    attr_tokens = f"{fmt_tokens(total_tokens)} tokens"
    attr_credits = f" · {credits / 1_000_000:.3f} credits" if credits is not None else ""

    def pad_line(content: str, width: int = 68) -> str:
        pad = max(0, width - len(content))
        return f"  │  {content}{' ' * pad} │"

    def append_wrapped_line(content: str, continuation: str = "                 ") -> None:
        remaining = content
        first = True
        while remaining:
            prefix = "" if first else continuation
            available = max(1, 68 - len(prefix))
            if len(remaining) <= available:
                lines.append(pad_line(prefix + remaining))
                return
            split_at = remaining.rfind(" ", 0, available + 1)
            if split_at <= 0:
                split_at = available
            lines.append(pad_line(prefix + remaining[:split_at].rstrip()))
            remaining = remaining[split_at:].lstrip()
            first = False

    lines = ["", "📊 FlowPilot Telemetry Summary", ""]
    lines.append("  ╭─ Run Overview ────────────────────────────────────────────────────╮")

    session, project, branch = run_context(run)
    if session:
        lines.append(pad_line(f"• Session:        {session}"))
    if project:
        project_text = f"{project} · {branch}" if branch else project
        lines.append(pad_line(f"• Project:        {project_text}"))

    started = fmt_local_timestamp(run.get("started_at_ms"), milliseconds=True)
    finished = fmt_local_timestamp(run.get("finished_at_ms"), milliseconds=True)
    if started:
        lines.append(pad_line(f"• Started:        {started}"))
    if finished:
        lines.append(pad_line(f"• Finished:       {finished}"))
    started_ms = run.get("started_at_ms")
    finished_ms = run.get("finished_at_ms")
    if isinstance(started_ms, (int, float)) and isinstance(finished_ms, (int, float)):
        duration = fmt_duration_ms(finished_ms - started_ms)
        if duration:
            lines.append(pad_line(f"• Duration:       {duration}"))

    lines.append(pad_line(f"• Participants:   {p_count}"))
    lines.append(pad_line(f"• Parent:         {p_runtime} · {p_tokens}"))
    for worker in workers:
        usage = worker.get("usage") or {}
        state = worker.get("status") or "observed"
        w_type = worker.get("agent_type") or "worker"
        w_runtime = participant_runtime_label(worker, usage)
        w_tokens = f"{fmt_tokens(usage.get('total_tokens'))} tokens ({state})"
        label = f"• Worker [{w_type}]:"
        worker_line = f"{label} {w_runtime} · {w_tokens}"
        if len(worker_line) <= 68:
            lines.append(pad_line(worker_line))
        else:
            lines.append(pad_line(f"{label} {w_runtime}"))
            lines.append(pad_line(f"                 ↳ {w_tokens}"))
    lines.append(pad_line(f"• Attributed:     {attr_tokens}{attr_credits}"))

    windows = run.get("quota_change_during_run") or []
    if windows:
        pieces = []
        reset_pieces = []
        for window in windows:
            before_match = next(
                (
                    item
                    for item in run.get("quota_before", [])
                    if item.get("window_duration_mins") == window.get("window_duration_mins")
                ),
                None,
            )
            old = before_match.get("used_percent") if before_match else None
            new = window.get("used_percent")
            delta = window.get("delta_percentage_points")
            label = window_label(window.get("window_duration_mins"))
            if old is not None and new is not None:
                old_text = fmt_percent(old) or "n/a"
                new_text = fmt_percent(new) or "n/a"
                if delta is None:
                    delta_text = "n/a"
                elif delta == 0:
                    delta_text = "no change"
                else:
                    delta_text = f"{delta:+g} pp"
                remaining = (
                    f"; {fmt_percent(max(0, 100 - new))}% remaining"
                    if isinstance(new, (int, float)) and not isinstance(new, bool)
                    else ""
                )
                pieces.append(
                    f"{label} used {old_text}% → {new_text}% ({delta_text}{remaining})"
                )
            elif new is not None:
                new_text = fmt_percent(new) or "n/a"
                remaining = (
                    f"; {fmt_percent(max(0, 100 - new))}% remaining"
                    if isinstance(new, (int, float)) and not isinstance(new, bool)
                    else ""
                )
                suffix = f" ({remaining.lstrip('; ')})" if remaining else ""
                pieces.append(f"{label} used {new_text}%{suffix}")
            reset = fmt_local_timestamp(window.get("resets_at"))
            if reset:
                reset_pieces.append(f"{label} {reset}")
        if pieces:
            lines.append("  ├─ Quota & Windows ─────────────────────────────────────────────────┤")
            append_wrapped_line(f"• Account Quota:  {' | '.join(pieces)}")
            if reset_pieces:
                append_wrapped_line(f"• Resets:         {' | '.join(reset_pieces)}")
    lines.append("  ╰───────────────────────────────────────────────────────────────────╯")
    lines.append("  ℹ  Note: Times use the local timezone; quota delta is account-wide; attributed usage is thread-based.")
    lines.append("  💡 Tip: Run `codex-flow usage last` to review or `codex-flow doctor` to verify hooks.\n")
    return "\n".join(lines)


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


def applescript_literal(value: Any) -> str:
    text = " ".join(str(value).split())
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def send_system_notification(run: dict[str, Any]) -> None:
    """Send a short macOS Notification Center message, fail-open."""
    if not telemetry_notifications_enabled() or sys.platform != "darwin":
        return
    executable = shutil.which("osascript")
    if not executable:
        return
    script = (
        f"display notification {applescript_literal(notification_body(run))} "
        f"with title {applescript_literal('FlowPilot task finished')}"
    )
    try:
        subprocess.run(
            [executable, "-e", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2.0,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return


def is_same_run(left: dict[str, Any] | None, right: dict[str, Any]) -> bool:
    if not isinstance(left, dict):
        return False
    return (
        str(left.get("session_id") or "") == str(right.get("session_id") or "")
        and str(left.get("turn_id") or "") == str(right.get("turn_id") or "")
    )


def write_stop_output(text: str) -> None:
    # Codex command hooks consume JSON on stdout.  Keep a deliberately named
    # plain-text escape hatch for shell tests; production hooks always use the
    # supported systemMessage field so Desktop/UI can surface the summary.
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

            # A late SubagentStop must still enrich `usage last` when the
            # parent Stop already wrote the latest completed run.
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
                    # Some interrupted subagent paths can miss SubagentStop. Do
                    # not claim completion; retain that it participated.
                    worker["status"] = "observed"
        atomic_json(path, run)
        atomic_json(LAST_FILE, run)

    # Reconciliation runs after the parent file is durable, so old orphan
    # records and late child paths can be repaired without holding the parent
    # lock. Refresh the summary if this parent absorbed any workers.
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


def show_last(as_json: bool = False) -> int:
    if not LAST_FILE.exists():
        print(
            "No FlowPilot telemetry run has completed yet.\n"
            "💡 Tip: Run `codex-flow doctor` to verify hooks, or approve pending hooks with `/hooks` in Codex.",
            file=sys.stderr,
        )
        return 1
    try:
        run = json.loads(LAST_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Unable to read telemetry: {exc}", file=sys.stderr)
        return 1
    enrich_run_metadata(run)
    if as_json:
        print(json.dumps(run, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(render_summary(run), end="")
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "last":
        return show_last("--json" in sys.argv[2:])
    try:
        raw = sys.stdin.read()
        event = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return 0
    if isinstance(event, dict):
        try:
            collect_hook(event)
        except Exception:
            # Telemetry must never break or block a Codex turn.
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
