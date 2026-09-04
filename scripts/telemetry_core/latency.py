"""Redacted Worker latency events and deterministic rollout reports.

This module deliberately has no transcript or prompt integration.  Callers
provide a small, already-decided lifecycle observation; the ledger stores only
validated enums/tokens, salted identifiers, and timing/counter facts.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import secrets
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from .common import STATE_ROOT

LATENCY_SCHEMA_VERSION = 1
LATENCY_FILE_NAME = "latency.jsonl"
LATENCY_SALT_FILE_NAME = ".latency-salt"
LATENCY_LOCK_FILE_NAME = ".latency.lock"
LOCK_TIMEOUT_SECONDS = 3.0
STALE_LOCK_SECONDS = 30.0

STRATEGIES = frozenset(("efficient", "balanced", "quality", "speed"))
TASK_CLASSES = frozenset(("small", "routine", "complex", "critical"))
STAGES = frozenset(("exploration", "implementation", "review"))
ROLES = frozenset(("explorer", "implementer", "reviewer"))
ROLLOUT_MODES = frozenset(("legacy", "shadow", "adaptive"))
EFFORTS = frozenset(("high", "xhigh", "max"))
OUTCOMES = frozenset(("completed", "failed", "cancelled", "timeout"))
BOUNDARIES = frozenset(("terminal", "checkpoint"))
MODEL_TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,127}$")
HASH_TOKEN = re.compile(r"^[0-9a-f]{64}$")

# Input aliases are intentionally finite.  Unknown prompt/transcript/path
# fields fail closed instead of being silently carried into telemetry.
_INPUT_FIELDS = frozenset(
    {
        "event_id",
        "task_id",
        "worker_id",
        "work_unit_id",
        "strategy",
        "task_class",
        "stage",
        "role",
        "model",
        "rollout_mode",
        "legacy_effort",
        "proposed_effort",
        "selected_effort",
        "observed_effort",
        "legacy_worker_reasoning",
        "proposed_worker_reasoning",
        "selected_worker_reasoning",
        "observed_worker_reasoning",
        "outcome",
        "boundary",
        "event_type",
        "started_at",
        "finished_at",
        "started",
        "finished",
        "duration_seconds",
        "repair_count",
        "repair_attempts",
        "checkpoint_count",
        "checkpoints",
    }
)


class LatencyError(ValueError):
    """A concise, user-actionable latency telemetry validation error."""


def latency_file(path: Path | str | None = None) -> Path:
    if path is not None:
        return Path(path)
    configured = os.environ.get("CODEX_FLOW_LATENCY_FILE")
    return Path(configured) if configured else STATE_ROOT / LATENCY_FILE_NAME


def _sidecar(path: Path, name: str) -> Path:
    return path.parent / name


def _ensure_parent(path: Path) -> None:
    if path.exists() and path.is_symlink():
        raise LatencyError(f"refusing symlink telemetry target: {path.name}")
    try:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            os.chmod(path, 0o700)
        except OSError:
            pass
    except OSError as exc:
        raise LatencyError(f"cannot prepare telemetry state: {exc}") from None


def _reject_symlink(path: Path, label: str) -> None:
    try:
        if path.is_symlink():
            raise LatencyError(f"refusing symlink {label}: {path.name}")
    except OSError as exc:
        raise LatencyError(f"cannot inspect {label}: {exc}") from None


@contextmanager
def _exclusive_lock(path: Path) -> Iterator[None]:
    _ensure_parent(path.parent)
    _reject_symlink(path, "latency lock")
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    fd: int | None = None
    while fd is None:
        _reject_symlink(path, "latency lock")
        try:
            fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.write(fd, f"{os.getpid()}\n".encode("ascii", "replace"))
            os.fsync(fd)
            os.close(fd)
            fd = -1
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise LatencyError("latency telemetry lock is busy") from None
            try:
                age = max(0.0, time.time() - path.stat().st_mtime)
                if age > STALE_LOCK_SECONDS:
                    path.unlink()
                    continue
            except FileNotFoundError:
                continue
            except OSError:
                pass
            time.sleep(0.015)
        except OSError as exc:
            if fd is not None and fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass
            raise LatencyError(f"cannot acquire latency telemetry lock: {exc}") from None
    try:
        yield
    finally:
        _reject_symlink(path, "latency lock")
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            # A lock leak is safer than deleting a replacement lock owned by a
            # concurrent process after an unusual filesystem race.
            pass


def _string(value: Any, name: str, *, required: bool = True, limit: int = 512) -> str | None:
    if value is None and not required:
        return None
    if type(value) is not str or not value.strip():
        raise LatencyError(f"{name} must be a non-empty string")
    value = value.strip()
    if len(value) > limit or any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        raise LatencyError(f"{name} contains invalid characters")
    return value


def _enum(value: Any, name: str, allowed: frozenset[str], *, required: bool = True) -> str | None:
    value = _string(value, name, required=required)
    if value is None:
        return None
    if value not in allowed:
        choices = ", ".join(sorted(allowed))
        raise LatencyError(f"{name} must be one of: {choices}")
    return value


def _timestamp(value: Any, name: str, *, required: bool = False) -> float | None:
    if value is None and not required:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise LatencyError(f"{name} must be finite Unix seconds")
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise LatencyError(f"{name} must be finite, non-negative Unix seconds")
    if result > 100_000_000_000:
        raise LatencyError(f"{name} looks like milliseconds; use Unix seconds")
    return int(result) if result.is_integer() else result


def _count(value: Any, name: str, *, default: int = 0) -> int:
    if value is None:
        return default
    if type(value) is not int or value < 0:
        raise LatencyError(f"{name} must be a non-negative integer")
    return value


def _duration(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise LatencyError("duration_seconds must be finite, non-negative seconds")
    result = float(value)
    if not math.isfinite(result) or result < 0 or result > 100_000_000_000:
        raise LatencyError("duration_seconds must be finite, non-negative seconds")
    return int(result) if result.is_integer() else result


def _first(event: dict[str, Any], *names: str) -> Any:
    for name in names:
        if name in event:
            return event[name]
    return None


def _normalize(event: Any) -> dict[str, Any]:
    if type(event) is not dict:
        raise LatencyError("latency event must be a JSON object")
    unknown = sorted(set(event).difference(_INPUT_FIELDS))
    if unknown:
        raise LatencyError(f"unknown latency event fields: {', '.join(unknown)}")

    model = _string(event.get("model"), "model", limit=128)
    if model is None or not MODEL_TOKEN.fullmatch(model):
        raise LatencyError("model must be a safe model token, not a path or free-form text")

    result: dict[str, Any] = {
        "event_id": _string(event.get("event_id"), "event_id"),
        "task_id": _string(event.get("task_id"), "task_id"),
        "worker_id": _string(event.get("worker_id"), "worker_id"),
        "work_unit_id": _string(event.get("work_unit_id"), "work_unit_id", required=False),
        "strategy": _enum(event.get("strategy"), "strategy", STRATEGIES),
        "task_class": _enum(event.get("task_class"), "task_class", TASK_CLASSES),
        "stage": _enum(event.get("stage"), "stage", STAGES),
        "role": _enum(event.get("role"), "role", ROLES),
        "model": model,
        "rollout_mode": _enum(event.get("rollout_mode"), "rollout_mode", ROLLOUT_MODES),
        "legacy_effort": _enum(
            _first(event, "legacy_effort", "legacy_worker_reasoning"),
            "legacy_effort",
            EFFORTS,
        ),
        "proposed_effort": _enum(
            _first(event, "proposed_effort", "proposed_worker_reasoning"),
            "proposed_effort",
            EFFORTS,
        ),
        "selected_effort": _enum(
            _first(event, "selected_effort", "selected_worker_reasoning"),
            "selected_effort",
            EFFORTS,
        ),
        "observed_effort": _enum(
            _first(event, "observed_effort", "observed_worker_reasoning"),
            "observed_effort",
            EFFORTS,
            required=False,
        ),
        "boundary": _enum(
            _first(event, "boundary", "event_type") or "terminal",
            "boundary",
            BOUNDARIES,
        ),
        "outcome": _enum(event.get("outcome"), "outcome", OUTCOMES, required=False),
        "started_at": _timestamp(_first(event, "started_at", "started"), "started_at", required=True),
        "finished_at": _timestamp(_first(event, "finished_at", "finished"), "finished_at"),
        "duration_seconds": _duration(event.get("duration_seconds")),
        "repair_count": _count(_first(event, "repair_count", "repair_attempts"), "repair_count"),
        "checkpoint_count": _count(_first(event, "checkpoint_count", "checkpoints"), "checkpoint_count"),
    }
    if result["boundary"] == "terminal" and result["outcome"] is None:
        raise LatencyError("terminal latency event requires outcome")
    if result["boundary"] == "checkpoint" and result["outcome"] is not None:
        raise LatencyError("checkpoint latency event must not carry a terminal outcome")
    started = result["started_at"]
    finished = result["finished_at"]
    if finished is not None and finished < started:
        raise LatencyError("finished_at cannot precede started_at")
    if finished is not None:
        derived = finished - started
        supplied = result["duration_seconds"]
        if supplied is not None and not math.isclose(float(supplied), float(derived), rel_tol=0.0, abs_tol=1e-6):
            raise LatencyError("duration_seconds must match finished_at - started_at")
        result["duration_seconds"] = int(derived) if float(derived).is_integer() else derived
    elif result["duration_seconds"] is not None:
        derived_finish = float(started) + float(result["duration_seconds"])
        result["finished_at"] = int(derived_finish) if derived_finish.is_integer() else derived_finish
    return result


def _salt(path: Path) -> str:
    _reject_symlink(path, "latency salt")
    if path.exists():
        try:
            value = path.read_text(encoding="ascii").strip()
        except (OSError, UnicodeError) as exc:
            raise LatencyError(f"cannot read latency salt: {exc}") from None
        if not re.fullmatch(r"[0-9a-f]{64}", value):
            raise LatencyError("latency salt is invalid")
        return value
    value = secrets.token_hex(32)
    try:
        fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write(value + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return value
    except FileExistsError:
        return _salt(path)
    except OSError as exc:
        raise LatencyError(f"cannot create latency salt: {exc}") from None


def _digest(salt: str, namespace: str, value: str) -> str:
    return hashlib.sha256((namespace + "\0" + salt + "\0" + value).encode("utf-8")).hexdigest()


def _fingerprint(salt: str, event: dict[str, Any]) -> str:
    encoded = json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(("event\0" + salt + "\0").encode("utf-8") + encoded).hexdigest()


def _redact(event: dict[str, Any], salt: str) -> dict[str, Any]:
    redacted = {
        "schema_version": LATENCY_SCHEMA_VERSION,
        "event_id": _digest(salt, "event-id", event["event_id"]),
        "task_id": _digest(salt, "task-id", event["task_id"]),
        "worker_id": _digest(salt, "worker-id", event["worker_id"]),
        "strategy": event["strategy"],
        "task_class": event["task_class"],
        "stage": event["stage"],
        "role": event["role"],
        "model": event["model"],
        "rollout_mode": event["rollout_mode"],
        "legacy_effort": event["legacy_effort"],
        "proposed_effort": event["proposed_effort"],
        "selected_effort": event["selected_effort"],
        "observed_effort": event["observed_effort"],
        "boundary": event["boundary"],
        "outcome": event["outcome"],
        "started_at": event["started_at"],
        "finished_at": event["finished_at"],
        "duration_seconds": event["duration_seconds"],
        "repair_count": event["repair_count"],
        "checkpoint_count": event["checkpoint_count"],
    }
    if event["work_unit_id"] is not None:
        redacted["work_unit_id"] = _digest(salt, "work-unit-id", event["work_unit_id"])
    redacted["event_fingerprint"] = _fingerprint(salt, event)
    return redacted


def _read_events(path: Path) -> list[dict[str, Any]]:
    _reject_symlink(path, "latency ledger")
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except (OSError, UnicodeError) as exc:
        raise LatencyError(f"cannot read latency ledger: {exc}") from None
    events: list[dict[str, Any]] = []
    for line_no, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            raise LatencyError(f"invalid latency ledger JSON at line {line_no}") from None
        if type(value) is not dict or value.get("schema_version") != LATENCY_SCHEMA_VERSION:
            raise LatencyError(f"invalid latency ledger event at line {line_no}")
        required = {
            "schema_version", "event_id", "task_id", "worker_id", "strategy",
            "task_class", "stage", "role", "model", "rollout_mode",
            "legacy_effort", "proposed_effort", "selected_effort",
            "observed_effort", "boundary", "outcome", "started_at",
            "finished_at", "duration_seconds", "repair_count",
            "checkpoint_count", "event_fingerprint",
        }
        if set(value) not in (required, required | {"work_unit_id"}):
            raise LatencyError(f"invalid latency ledger fields at line {line_no}")
        for hash_field in ("event_id", "task_id", "worker_id", "event_fingerprint"):
            if type(value.get(hash_field)) is not str or not HASH_TOKEN.fullmatch(value[hash_field]):
                raise LatencyError(f"invalid latency ledger {hash_field} at line {line_no}")
        if "work_unit_id" in value and (
            type(value["work_unit_id"]) is not str or not HASH_TOKEN.fullmatch(value["work_unit_id"])
        ):
            raise LatencyError(f"invalid latency ledger work_unit_id at line {line_no}")
        canonical = {
            name: value.get(name)
            for name in (
                "event_id", "task_id", "worker_id", "work_unit_id", "strategy",
                "task_class", "stage", "role", "model", "rollout_mode",
                "legacy_effort", "proposed_effort", "selected_effort",
                "observed_effort", "boundary", "outcome", "started_at",
                "finished_at", "duration_seconds", "repair_count", "checkpoint_count",
            )
        }
        try:
            _normalize(canonical)
        except LatencyError as exc:
            raise LatencyError(f"invalid latency ledger event at line {line_no}: {exc}") from None
        events.append(value)
    return events


def record_latency_event(
    event: Any,
    *,
    state_file: Path | str | None = None,
    salt_file: Path | str | None = None,
    lock_file: Path | str | None = None,
) -> dict[str, Any]:
    """Validate, redact, and append one event under a process lock."""
    normalized = _normalize(event)
    path = latency_file(state_file)
    _ensure_parent(path.parent)
    salt_path = Path(salt_file) if salt_file is not None else _sidecar(path, LATENCY_SALT_FILE_NAME)
    lock_path = Path(lock_file) if lock_file is not None else _sidecar(path, LATENCY_LOCK_FILE_NAME)
    with _exclusive_lock(lock_path):
        salt = _salt(salt_path)
        redacted = _redact(normalized, salt)
        existing = _read_events(path)
        for prior in existing:
            if prior.get("event_id") != redacted["event_id"]:
                continue
            if prior.get("event_fingerprint") != redacted["event_fingerprint"]:
                raise LatencyError("event_id was already recorded with a different payload")
            return {
                "recorded": False,
                "deduplicated": True,
                "event_id": redacted["event_id"],
            }
        _reject_symlink(path, "latency ledger")
        try:
            with path.open("a", encoding="utf-8", newline="\n") as handle:
                json.dump(redacted, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
        except OSError as exc:
            raise LatencyError(f"cannot append latency event: {exc}") from None
    return {"recorded": True, "deduplicated": False, "event_id": redacted["event_id"]}


def _nearest_rank(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    value = ordered[rank - 1]
    return int(value) if float(value).is_integer() else value


def _group_key(event: dict[str, Any]) -> tuple[Any, ...]:
    return (
        event.get("task_class"),
        event.get("stage"),
        event.get("model"),
        event.get("selected_effort"),
        event.get("observed_effort"),
        event.get("rollout_mode"),
    )


def _group_report(events: list[dict[str, Any]], key: tuple[Any, ...]) -> dict[str, Any]:
    terminal = [e for e in events if e.get("boundary") == "terminal"]
    observed = [e for e in terminal if e.get("duration_seconds") is not None]
    uncensored = [e for e in observed if e.get("outcome") in {"completed", "failed"}]
    durations = [float(e["duration_seconds"]) for e in uncensored]
    success = sum(1 for e in terminal if e.get("outcome") == "completed")
    failed = sum(1 for e in terminal if e.get("outcome") == "failed")
    cancelled = sum(1 for e in terminal if e.get("outcome") == "cancelled")
    timed_out = sum(1 for e in terminal if e.get("outcome") == "timeout")
    missing = sum(1 for e in terminal if e.get("outcome") in {"completed", "failed"} and e.get("duration_seconds") is None)
    censored = cancelled + timed_out
    result: dict[str, Any] = {
        "task_class": key[0],
        "stage": key[1],
        "model": key[2],
        "selected_effort": key[3],
        "observed_effort": key[4],
        "rollout_mode": key[5],
        "n": len(terminal),
        "completed": len(uncensored),
        "success": success,
        "successes": success,
        "failed": failed,
        "cancelled": cancelled,
        "timeout": timed_out,
        "censored": censored,
        "missing": missing,
        "p50_seconds": _nearest_rank(durations, 0.50),
        "p95_seconds": _nearest_rank(durations, 0.95),
        "eligible_for_tuning": len(uncensored) >= 20 and key[4] is not None,
    }
    return result


def latency_report(*, state_file: Path | str | None = None) -> dict[str, Any]:
    """Return a stable nearest-rank report; this function never mutates policy."""
    path = latency_file(state_file)
    lock_path = _sidecar(path, LATENCY_LOCK_FILE_NAME)
    with _exclusive_lock(lock_path):
        events = _read_events(path)
    grouped: dict[tuple[Any, ...], list[dict[str, Any]]] = {}
    for event in events:
        # Checkpoints are reported as a separate aggregate. They do not create
        # zero-sized latency cohorts or dilute a terminal cohort's sample gate.
        if event.get("boundary") != "terminal":
            continue
        grouped.setdefault(_group_key(event), []).append(event)
    groups = [_group_report(grouped[key], key) for key in sorted(grouped, key=lambda item: tuple("" if v is None else str(v) for v in item))]
    checkpoint_observations = sum(1 for e in events if e.get("boundary") == "checkpoint")
    terminal = [e for e in events if e.get("boundary") == "terminal"]
    observed = [e for e in terminal if e.get("duration_seconds") is not None]
    uncensored = [e for e in observed if e.get("outcome") in {"completed", "failed"}]
    total_durations = [float(e["duration_seconds"]) for e in uncensored]
    success = sum(1 for e in terminal if e.get("outcome") == "completed")
    failed = sum(1 for e in terminal if e.get("outcome") == "failed")
    cancelled = sum(1 for e in terminal if e.get("outcome") == "cancelled")
    timed_out = sum(1 for e in terminal if e.get("outcome") == "timeout")
    missing = sum(1 for e in terminal if e.get("outcome") in {"completed", "failed"} and e.get("duration_seconds") is None)
    censored = cancelled + timed_out
    return {
        "schema_version": LATENCY_SCHEMA_VERSION,
        "n": len(terminal),
        "completed": len(uncensored),
        "success": success,
        "successes": success,
        "failed": failed,
        "cancelled": cancelled,
        "timeout": timed_out,
        "censored": censored,
        "missing": missing,
        "checkpoint_observations": checkpoint_observations,
        "p50_seconds": _nearest_rank(total_durations, 0.50),
        "p95_seconds": _nearest_rank(total_durations, 0.95),
        "eligible_for_tuning": any(group["eligible_for_tuning"] for group in groups),
        "advisory": True,
        "policy_mutation": False,
        "groups": groups,
    }


def format_latency_report(report: dict[str, Any]) -> str:
    """Compact deterministic text for humans; JSON remains the machine API."""
    def seconds(value: Any) -> str:
        return "missing" if value is None else f"{value}s"

    lines = [
        f"n={report['n']} completed={report['completed']} censored={report['censored']} missing={report['missing']} "
        f"success={report['success']} p50={seconds(report['p50_seconds'])} p95={seconds(report['p95_seconds'])} "
        f"eligible_for_tuning={'true' if report['eligible_for_tuning'] else 'false'}",
    ]
    for group in report["groups"]:
        lines.append(
            f"{group['task_class']}/{group['stage']}/{group['model']}/selected={group['selected_effort']}/"
            f"observed={group['observed_effort'] or 'missing'}/mode={group['rollout_mode']}: "
            f"n={group['n']} p50={seconds(group['p50_seconds'])} p95={seconds(group['p95_seconds'])}"
        )
    return "\n".join(lines)


__all__ = [
    "LATENCY_SCHEMA_VERSION",
    "LATENCY_FILE_NAME",
    "LatencyError",
    "latency_file",
    "record_latency_event",
    "latency_report",
    "format_latency_report",
]
