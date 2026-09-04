#!/usr/bin/env python3
"""Durable task-level budget ledger for FlowPilot.

General implementation reservations close at the task soft deadline. Read-only
`review_attempt` reservations belong to required completion and remain open
until the absolute hard deadline. All reservations are atomic, idempotent, and
persisted across processes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import stat
import sys
import time
import uuid
from contextlib import contextmanager
from dataclasses import asdict
from pathlib import Path
from typing import Any, Iterator

try:
    from .base import TaskBudgetPolicy
except ImportError:
    from base import TaskBudgetPolicy


SCHEMA_VERSION = 2
GENERAL_RESERVATION_KINDS = (
    "work_unit",
    "implementation_attempt",
    "replan",
    "replacement",
)
REQUIRED_COMPLETION_RESERVATION_KINDS = ("review_attempt",)
RESERVATION_KINDS = GENERAL_RESERVATION_KINDS + REQUIRED_COMPLETION_RESERVATION_KINDS
POLICY_LIMIT_FIELDS = {
    "work_unit": "max_work_units",
    "implementation_attempt": "max_implementation_attempts",
    "replan": "max_replans",
    "replacement": "max_replacements",
    "review_attempt": "max_review_attempts",
}
STATE_FIELDS = {
    "schema_version",
    "task_id",
    "policy_fingerprint",
    "started_at",
    "soft_deadline",
    "hard_deadline",
    "closed",
    "outcome",
    "limits",
    "reservations",
}
RESERVATION_FIELDS = {"reservation_id", "fingerprint", "reserved_at"}
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
SAFE_OUTCOME_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")
EPOCH_MILLISECONDS_THRESHOLD = 100_000_000_000
LOCK_TIMEOUT_SECONDS = 10.0
LOCK_RETRY_SECONDS = 0.025
STALE_LOCK_SECONDS = 30.0


class LedgerError(ValueError):
    pass


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _strict_string(value: Any, label: str) -> str:
    if type(value) is not str:
        raise LedgerError(f"{label} must be a string")
    result = value.strip()
    if not result:
        raise LedgerError(f"{label} must be non-empty")
    if "\x00" in result:
        raise LedgerError(f"{label} must not contain NUL")
    return result


def _seconds(value: Any, label: str) -> float:
    if isinstance(value, bool):
        raise LedgerError(f"{label} must be finite seconds")
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise LedgerError(f"{label} must be finite seconds") from None
    if not math.isfinite(number):
        raise LedgerError(f"{label} must be finite seconds")
    if number < 0:
        raise LedgerError(f"{label} cannot be negative")
    if number > EPOCH_MILLISECONDS_THRESHOLD:
        raise LedgerError(f"{label} must use Unix seconds, not milliseconds")
    return number


def _now(value: Any) -> float:
    return _seconds(value, "now")


def _policy(value: Any) -> TaskBudgetPolicy:
    try:
        return TaskBudgetPolicy.from_dict(value)
    except (TypeError, ValueError) as exc:
        raise LedgerError(str(exc)) from None


def _policy_fingerprint(policy: TaskBudgetPolicy) -> str:
    encoded = json.dumps(
        asdict(policy),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _task_hash(task_id: Any) -> str:
    return _sha256(_strict_string(task_id, "task_id"))


def _reservation_hash(value: Any, label: str = "reservation_id") -> str:
    return _sha256(_strict_string(value, label))


def _fingerprint_hash(value: Any) -> str:
    return _sha256(_strict_string(value, "fingerprint"))


def _state_path(value: Any) -> Path:
    raw = _strict_string(value, "state_file")
    path = Path(raw)
    return path if path.is_absolute() else Path.cwd() / path


def _reject_symlink(path: Path, label: str) -> None:
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        return
    except OSError as exc:
        raise LedgerError(f"cannot inspect {label}: {exc}") from None
    if stat.S_ISLNK(mode):
        raise LedgerError(f"{label} must not be a symlink")


def _ensure_parent(path: Path) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise LedgerError(f"cannot create state parent: {exc}") from None
    if not path.parent.is_dir():
        raise LedgerError("state-file parent is not a directory")


def _ensure_regular_state(path: Path) -> None:
    _reject_symlink(path, "state file")
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        return
    except OSError as exc:
        raise LedgerError(f"cannot inspect state file: {exc}") from None
    if not stat.S_ISREG(mode):
        raise LedgerError("state file must be a regular file")


def _lock_path(path: Path) -> Path:
    return Path(f"{path}.lock")


def _lock_is_stale(path: Path) -> bool:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise LedgerError(f"cannot inspect lock file: {exc}") from None
    if stat.S_ISLNK(info.st_mode):
        raise LedgerError("lock file must not be a symlink")
    if not stat.S_ISREG(info.st_mode):
        raise LedgerError("lock file must be a regular file")
    return max(0.0, time.time() - info.st_mtime) > STALE_LOCK_SECONDS


@contextmanager
def _ledger_lock(path: Path) -> Iterator[None]:
    _ensure_parent(path)
    _ensure_regular_state(path)
    lock = _lock_path(path)
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    while True:
        _reject_symlink(lock, "lock file")
        try:
            flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
            if hasattr(os, "O_BINARY"):
                flags |= os.O_BINARY
            fd = os.open(lock, flags, 0o600)
            try:
                os.write(fd, f"pid={os.getpid()}\n".encode("ascii"))
                os.fsync(fd)
            finally:
                os.close(fd)
            break
        except FileExistsError:
            if _lock_is_stale(lock):
                _reject_symlink(lock, "lock file")
                try:
                    os.unlink(lock)
                except FileNotFoundError:
                    pass
                continue
            if time.monotonic() >= deadline:
                raise LedgerError("timed out waiting for task budget lock")
            time.sleep(LOCK_RETRY_SECONDS)
        except OSError as exc:
            raise LedgerError(f"cannot acquire task budget lock: {exc}") from None
    try:
        yield
    finally:
        _reject_symlink(lock, "lock file")
        try:
            os.unlink(lock)
        except FileNotFoundError:
            pass
        except OSError as exc:
            raise LedgerError(f"cannot remove task budget lock: {exc}") from None


def _atomic_write(path: Path, data: dict[str, Any]) -> None:
    _reject_symlink(path, "state file")
    encoded = (json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    fd: int | None = None
    try:
        flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
        if hasattr(os, "O_BINARY"):
            flags |= os.O_BINARY
        fd = os.open(temporary, flags, 0o600)
        offset = 0
        while offset < len(encoded):
            written = os.write(fd, encoded[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(fd)
        os.close(fd)
        fd = None
        _reject_symlink(path, "state file")
        os.replace(temporary, path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        if hasattr(os, "O_DIRECTORY"):
            try:
                parent_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            except OSError:
                parent_fd = None
            if parent_fd is not None:
                try:
                    os.fsync(parent_fd)
                finally:
                    os.close(parent_fd)
    except OSError as exc:
        raise LedgerError(f"cannot write task budget state: {exc}") from None
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        except OSError:
            pass


def _read_state(path: Path) -> dict[str, Any]:
    _ensure_regular_state(path)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise LedgerError("task budget state does not exist; run init first") from None
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LedgerError(f"invalid task budget state: {exc}") from None
    _validate_state(value)
    return value


def _validate_hash(value: Any, label: str) -> str:
    if type(value) is not str or not HASH_RE.fullmatch(value):
        raise LedgerError(f"invalid {label}")
    return value


def _validate_state(value: Any) -> None:
    if type(value) is not dict:
        raise LedgerError("task budget state must be an object")
    if set(value) != STATE_FIELDS:
        missing = sorted(STATE_FIELDS.difference(value))
        unknown = sorted(set(value).difference(STATE_FIELDS))
        details = []
        if missing:
            details.append(f"missing fields: {missing}")
        if unknown:
            details.append(f"unknown fields: {unknown}")
        raise LedgerError("invalid task budget state (" + "; ".join(details) + ")")
    if type(value["schema_version"]) is not int or value["schema_version"] != SCHEMA_VERSION:
        raise LedgerError("unsupported task budget state schema")
    _validate_hash(value["task_id"], "task id hash")
    _validate_hash(value["policy_fingerprint"], "policy fingerprint")
    started = _seconds(value["started_at"], "started_at")
    soft = _seconds(value["soft_deadline"], "soft_deadline")
    hard = _seconds(value["hard_deadline"], "hard_deadline")
    if soft <= started:
        raise LedgerError("soft_deadline must be after started_at")
    if hard <= soft:
        raise LedgerError("hard_deadline must be after soft_deadline")
    if type(value["closed"]) is not bool:
        raise LedgerError("closed must be boolean")
    outcome = value["outcome"]
    if outcome is not None and (type(outcome) is not str or not SAFE_OUTCOME_RE.fullmatch(outcome)):
        raise LedgerError("outcome must be a short status token or null")
    if value["closed"] and outcome is None:
        raise LedgerError("closed state requires an outcome")
    if not value["closed"] and outcome is not None:
        raise LedgerError("open state cannot have an outcome")

    limits = value["limits"]
    if type(limits) is not dict or set(limits) != set(RESERVATION_KINDS):
        raise LedgerError("invalid task budget limits")
    for kind in RESERVATION_KINDS:
        limit = limits[kind]
        if type(limit) is not int or limit < 0:
            raise LedgerError(f"invalid limit for {kind}")
        if kind in {"work_unit", "implementation_attempt"} and limit == 0:
            raise LedgerError(f"limit for {kind} must be positive")

    reservations = value["reservations"]
    if type(reservations) is not dict or set(reservations) != set(RESERVATION_KINDS):
        raise LedgerError("invalid task budget reservations")
    for kind in RESERVATION_KINDS:
        entries = reservations[kind]
        if type(entries) is not list:
            raise LedgerError(f"reservations.{kind} must be a list")
        if len(entries) > limits[kind]:
            raise LedgerError(f"reservations.{kind} exceeds its limit")
        seen: set[str] = set()
        latest = started
        for entry in entries:
            if type(entry) is not dict or set(entry) != RESERVATION_FIELDS:
                raise LedgerError(f"invalid {kind} reservation")
            reservation_id = _validate_hash(entry["reservation_id"], f"{kind} reservation id")
            _validate_hash(entry["fingerprint"], f"{kind} fingerprint")
            if reservation_id in seen:
                raise LedgerError(f"duplicate {kind} reservation id")
            seen.add(reservation_id)
            reserved_at = _seconds(entry["reserved_at"], f"{kind}.reserved_at")
            if reserved_at < started:
                raise LedgerError(f"{kind}.reserved_at cannot precede started_at")
            if reserved_at < latest:
                raise LedgerError("reservation timestamps must be non-decreasing")
            latest = reserved_at


def _latest_timestamp(state: dict[str, Any]) -> float:
    latest = _seconds(state["started_at"], "started_at")
    for kind in RESERVATION_KINDS:
        for entry in state["reservations"][kind]:
            latest = max(latest, _seconds(entry["reserved_at"], "reserved_at"))
    return latest


def _check_now(state: dict[str, Any], now: float) -> None:
    if now < _latest_timestamp(state):
        raise LedgerError("now must be non-decreasing")


def _new_state(task_hash: str, policy: TaskBudgetPolicy, now: float) -> dict[str, Any]:
    limits = {
        kind: getattr(policy, POLICY_LIMIT_FIELDS[kind])
        for kind in RESERVATION_KINDS
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": task_hash,
        "policy_fingerprint": _policy_fingerprint(policy),
        "started_at": now,
        "soft_deadline": now + policy.soft_timeout_seconds,
        "hard_deadline": now + policy.hard_timeout_seconds,
        "closed": False,
        "outcome": None,
        "limits": limits,
        "reservations": {kind: [] for kind in RESERVATION_KINDS},
    }


def _counters(state: dict[str, Any]) -> dict[str, int]:
    return {kind: len(state["reservations"][kind]) for kind in RESERVATION_KINDS}


def _status(state: dict[str, Any], now: float) -> dict[str, Any]:
    _check_now(state, now)
    closed = state["closed"]
    if closed:
        action = "stop"
    elif now < state["soft_deadline"]:
        action = "continue"
    elif now < state["hard_deadline"]:
        action = "converge"
    else:
        action = "stop"
    remaining_hard = max(0.0, float(state["hard_deadline"]) - now)
    counters = _counters(state)
    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": state["task_id"],
        "policy_fingerprint": state["policy_fingerprint"],
        "started_at": state["started_at"],
        "soft_deadline": state["soft_deadline"],
        "hard_deadline": state["hard_deadline"],
        "closed": closed,
        "outcome": state["outcome"],
        "action": action,
        "remaining_seconds": remaining_hard,
        "remaining_soft_seconds": max(0.0, float(state["soft_deadline"]) - now),
        "remaining_hard_seconds": remaining_hard,
        "counters": counters,
        "limits": dict(state["limits"]),
        "permits_new_work": action == "continue",
        "permits_new_review": (
            not closed
            and now < state["hard_deadline"]
            and counters["review_attempt"] < state["limits"]["review_attempt"]
        ),
        "cancel_required": action == "stop" and not closed and now >= state["hard_deadline"],
    }


def init_ledger(state_file: str | Path, task_id: str, policy: TaskBudgetPolicy, now: Any) -> dict[str, Any]:
    path = _state_path(state_file)
    task_hash = _task_hash(task_id)
    policy.validate()
    current_now = _now(now)
    expected_policy = _policy_fingerprint(policy)
    with _ledger_lock(path):
        if os.path.lexists(path):
            state = _read_state(path)
            _check_now(state, current_now)
            if state["task_id"] != task_hash:
                raise LedgerError("task budget task_id mismatch; refusing to reuse ledger")
            if state["policy_fingerprint"] != expected_policy:
                raise LedgerError("task budget policy mismatch; refusing to reset ledger")
            result = _status(state, current_now)
            result["initialized"] = False
            result["idempotent"] = True
            return result
        state = _new_state(task_hash, policy, current_now)
        _validate_state(state)
        _atomic_write(path, state)
        result = _status(state, current_now)
        result["initialized"] = True
        result["idempotent"] = False
        return result


def ledger_status(state_file: str | Path, task_id: str, now: Any) -> dict[str, Any]:
    path = _state_path(state_file)
    task_hash = _task_hash(task_id)
    current_now = _now(now)
    with _ledger_lock(path):
        state = _read_state(path)
        _check_now(state, current_now)
        if state["task_id"] != task_hash:
            raise LedgerError("task budget task_id mismatch")
        return _status(state, current_now)


def reserve(
    state_file: str | Path,
    task_id: str,
    kind: str,
    reservation_id: str,
    fingerprint: str,
    now: Any,
) -> dict[str, Any]:
    path = _state_path(state_file)
    task_hash = _task_hash(task_id)
    current_now = _now(now)
    if kind not in RESERVATION_KINDS:
        raise LedgerError(f"invalid reservation kind: {kind}")
    reservation_hash = _reservation_hash(reservation_id)
    fp_hash = _fingerprint_hash(fingerprint)
    with _ledger_lock(path):
        state = _read_state(path)
        _check_now(state, current_now)
        if state["task_id"] != task_hash:
            raise LedgerError("task budget task_id mismatch")
        if state["closed"]:
            raise LedgerError("task budget is closed")
        entries = state["reservations"][kind]
        for entry in entries:
            if entry["reservation_id"] == reservation_hash:
                if entry["fingerprint"] != fp_hash:
                    raise LedgerError("reservation id already used with a different fingerprint")
                result = _status(state, current_now)
                result.update({
                    "kind": kind,
                    "reservation_id": reservation_hash,
                    "fingerprint": fp_hash,
                    "reserved": True,
                    "idempotent": True,
                })
                return result
        if current_now >= state["hard_deadline"]:
            raise LedgerError("task hard deadline reached; new reservations are not permitted")
        if kind in GENERAL_RESERVATION_KINDS and current_now >= state["soft_deadline"]:
            raise LedgerError("task soft deadline reached; new general-work reservations are not permitted")
        limit = state["limits"][kind]
        if len(entries) >= limit:
            raise LedgerError(f"{kind} reservation limit reached")
        entries.append({
            "reservation_id": reservation_hash,
            "fingerprint": fp_hash,
            "reserved_at": current_now,
        })
        _validate_state(state)
        _atomic_write(path, state)
        result = _status(state, current_now)
        result.update({
            "kind": kind,
            "reservation_id": reservation_hash,
            "fingerprint": fp_hash,
            "reserved": True,
            "idempotent": False,
        })
        return result


def finish(state_file: str | Path, task_id: str, outcome: str, now: Any) -> dict[str, Any]:
    path = _state_path(state_file)
    task_hash = _task_hash(task_id)
    current_now = _now(now)
    outcome_value = _strict_string(outcome, "outcome")
    if not SAFE_OUTCOME_RE.fullmatch(outcome_value):
        raise LedgerError("outcome must be a short status token")
    with _ledger_lock(path):
        state = _read_state(path)
        _check_now(state, current_now)
        if state["task_id"] != task_hash:
            raise LedgerError("task budget task_id mismatch")
        if state["closed"]:
            if state["outcome"] != outcome_value:
                raise LedgerError("task budget is already closed with a different outcome")
            result = _status(state, current_now)
            result["finished"] = False
            result["idempotent"] = True
            return result
        state["closed"] = True
        state["outcome"] = outcome_value
        _validate_state(state)
        _atomic_write(path, state)
        result = _status(state, current_now)
        result["finished"] = True
        result["idempotent"] = False
        return result


def _json_argument(raw: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise LedgerError(f"invalid policy JSON: {exc.msg}") from None


def _common_args(command: argparse.ArgumentParser) -> None:
    command.add_argument("--state-file", required=True)
    command.add_argument("--task-id", required=True)
    command.add_argument("--now", required=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="task_budget_runtime.py",
        description="durable FlowPilot task budget ledger",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    init_cmd = commands.add_parser("init")
    _common_args(init_cmd)
    init_cmd.add_argument("--policy-json", required=True)

    status_cmd = commands.add_parser("status")
    _common_args(status_cmd)

    reserve_cmd = commands.add_parser("reserve")
    _common_args(reserve_cmd)
    reserve_cmd.add_argument("--kind", choices=RESERVATION_KINDS, required=True)
    reserve_cmd.add_argument("--reservation-id", required=True)
    reserve_cmd.add_argument("--fingerprint", required=True)

    finish_cmd = commands.add_parser("finish")
    _common_args(finish_cmd)
    finish_cmd.add_argument("--outcome", default="success")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    ns = parser.parse_args(argv)
    try:
        if ns.command == "init":
            result = init_ledger(ns.state_file, ns.task_id, _policy(_json_argument(ns.policy_json)), ns.now)
        elif ns.command == "status":
            result = ledger_status(ns.state_file, ns.task_id, ns.now)
        elif ns.command == "reserve":
            result = reserve(ns.state_file, ns.task_id, ns.kind, ns.reservation_id, ns.fingerprint, ns.now)
        elif ns.command == "finish":
            result = finish(ns.state_file, ns.task_id, ns.outcome, ns.now)
        else:  # pragma: no cover
            raise LedgerError(f"unsupported command: {ns.command}")
    except (LedgerError, ValueError, OSError) as exc:
        print(f"task-budget: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
