"""Shared constants, policy configuration, locking, and formatting helpers."""

from __future__ import annotations

import json
import os
import tempfile
import time
import unicodedata
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


def display_width(s: str) -> int:
    """Calculate terminal display width considering fullwidth/CJK characters."""
    width = 0
    for ch in s:
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            width += 2
        else:
            width += 1
    return width


def truncate_display(s: str, max_width: int) -> str:
    """Truncate a string to fit max_width visual columns."""
    cur = 0
    res: list[str] = []
    for ch in s:
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if cur + w > max_width:
            break
        res.append(ch)
        cur += w
    return "".join(res)


def pad_display(s: str, target_width: int, align: str = "left") -> str:
    """Pad string to target display width."""
    w = display_width(s)
    pad = max(0, target_width - w)
    if align == "right":
        return (" " * pad) + s
    return s + (" " * pad)


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


def numeric_ms(value: Any) -> int | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return int(value)
    return None


def safe_key_part(value: Any) -> str:
    return str(value).replace("/", "_").replace("\\", "_")


def run_key(event: dict[str, Any]) -> str:
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
    agent_id: str,
    session_id: Any,
    parent_key: str,
    parent_turn_id: Any,
    started_at_ms: Any,
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


def text_value(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def compact_text(value: Any, limit: int = 52) -> str | None:
    if value is None:
        return None
    text = " ".join(str(value).split())
    if not text:
        return None
    if len(text) <= limit:
        return text
    return text[: max(1, limit - 1)] + "…"


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
