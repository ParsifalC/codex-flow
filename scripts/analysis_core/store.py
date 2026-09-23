"""Durable SQLite queue and atomic JSON snapshot for analysis-preview."""
from __future__ import annotations

import json
import os
import sqlite3
import tempfile
import time

from .model import normalize_skill
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


ANALYZER_VERSION = "analysis-v1"


def now_ms() -> int:
    return int(time.time() * 1000)


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _decode(value: Optional[str], default: Any) -> Any:
    if not value:
        return default
    try:
        return json.loads(value)
    except (ValueError, TypeError):
        return default


class AnalysisStore:
    """One session's queue, source projection and UI snapshot."""

    def __init__(self, state_dir: Path, session_id: Optional[str] = None):
        self.state_dir = Path(state_dir).expanduser().resolve()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.db_path = self.state_dir / "analysis.sqlite3"
        self.view_path = self.state_dir / "view.json"
        self._conn = sqlite3.connect(str(self.db_path), timeout=10, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA busy_timeout=10000")
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._create_schema()
        if session_id is not None:
            prior = self.get_meta("session_id")
            if prior is not None and prior != session_id:
                raise ValueError("state_session_mismatch")
            self.set_meta("session_id", session_id)
        self._ensure_defaults()

    def close(self) -> None:
        self._conn.close()

    @property
    def session_id(self) -> str:
        value = self.get_meta("session_id")
        if not isinstance(value, str) or not value:
            raise ValueError("session_not_configured")
        return value

    def _create_schema(self) -> None:
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                message_id TEXT PRIMARY KEY,
                turn_id TEXT NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                source_index INTEGER NOT NULL,
                raw_line INTEGER NOT NULL,
                create_time TEXT,
                phase TEXT,
                content_kinds TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_turn_order
                ON messages(turn_id, source_index);
            CREATE TABLE IF NOT EXISTS turns (
                turn_id TEXT PRIMARY KEY,
                sequence INTEGER NOT NULL,
                user_text TEXT NOT NULL DEFAULT '',
                user_message_id TEXT,
                user_source_index INTEGER,
                original_result TEXT,
                final_message_id TEXT,
                final_source_index INTEGER,
                requirement_status TEXT NOT NULL DEFAULT 'not_analyzed',
                requirement_text TEXT,
                requirement_revision INTEGER,
                requirement_job_id INTEGER,
                requirement_error TEXT,
                summary_status TEXT NOT NULL DEFAULT 'not_analyzed',
                summary_text TEXT,
                summary_job_id INTEGER,
                summary_error TEXT
            );
            CREATE TABLE IF NOT EXISTS jobs (
                job_id INTEGER PRIMARY KEY AUTOINCREMENT,
                job_key TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                session_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                source_index INTEGER NOT NULL,
                analyzer_version TEXT NOT NULL,
                status TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                max_attempts INTEGER NOT NULL DEFAULT 2,
                input_json TEXT NOT NULL,
                result_json TEXT,
                error TEXT,
                lease_until INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS jobs_ready
                ON jobs(status, lease_until, job_id);
            """
        )

    def _ensure_defaults(self) -> None:
        if self.get_meta("enabled") is None:
            self.set_meta("enabled", True)
        if self.get_meta("source") is None:
            self.set_meta("source", {"status": "unknown", "truncated": False})
        if self.get_meta("source_error") is None:
            self.set_meta("source_error", None)
        if self.get_meta("usage") is None:
            self.set_meta(
                "usage",
                {
                    "requirement_calls": 0,
                    "summary_calls": 0,
                    "skill_calls": 0,
                    "successful_calls": 0,
                    "failed_calls": 0,
                    "total_calls": 0,
                },
            )

    def get_meta(self, key: str, default: Any = None) -> Any:
        row = self._conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return _decode(row["value"], default) if row else default

    def set_meta(self, key: str, value: Any) -> None:
        self._conn.execute(
            "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, _json(value)),
        )
        self._conn.commit()

    def get_config(self) -> Dict[str, Any]:
        value = self.get_meta("config", {})
        return value if isinstance(value, dict) else {}

    def save_config(self, config: Dict[str, Any]) -> None:
        data = dict(config)
        self.set_meta("config", data)
        self._atomic_json(self.state_dir / "config.json", data)

    def set_enabled(self, enabled: bool) -> None:
        self.set_meta("enabled", bool(enabled))
        config = self.get_config()
        config["enabled"] = bool(enabled)
        self.set_meta("config", config)
        self._write_snapshot()

    def is_enabled(self) -> bool:
        return bool(self.get_meta("enabled", True))

    def set_source_state(self, state: Dict[str, Any], error: Optional[Dict[str, Any]] = None) -> None:
        self.set_meta("source", dict(state))
        self.set_meta("source_error", error)
        self._write_snapshot()

    def set_source_error(self, error: Dict[str, Any]) -> None:
        self.set_meta("source_error", dict(error))
        self._write_snapshot()

    def source_error(self) -> Optional[Dict[str, Any]]:
        value = self.get_meta("source_error")
        return value if isinstance(value, dict) else None

    def upsert_transcript(self, transcript: Any) -> Tuple[List[Any], bool]:
        """Merge source rows and return (new messages, bootstrap flag)."""
        before = self._conn.execute("SELECT COUNT(*) AS count FROM messages").fetchone()["count"]
        existing = {
            row["message_id"]
            for row in self._conn.execute("SELECT message_id FROM messages")
        }
        new_messages: List[Any] = []
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            self._reconcile_filtered_source(transcript)
            for message in transcript.messages:
                self._conn.execute(
                    """INSERT INTO messages
                    (message_id, turn_id, role, text, source_index, raw_line, create_time, phase, content_kinds)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(message_id) DO UPDATE SET text=excluded.text,
                    source_index=excluded.source_index, content_kinds=excluded.content_kinds""",
                    (
                        message.message_id,
                        message.turn_id,
                        message.role,
                        message.text,
                        message.source_index,
                        message.raw_line,
                        _json(message.create_time),
                        message.phase,
                        _json(list(message.content_kinds)),
                    ),
                )
                if message.message_id not in existing:
                    new_messages.append(message)
            for turn in transcript.turns:
                row = self._conn.execute(
                    "SELECT * FROM turns WHERE turn_id = ?", (turn.turn_id,)
                ).fetchone()
                values = (
                    turn.turn_id,
                    turn.sequence,
                    turn.user_text,
                    turn.user_message_id,
                    turn.user_source_index,
                    turn.original_result,
                    turn.final_message_id,
                    turn.final_source_index,
                )
                if row is None:
                    self._conn.execute(
                        """INSERT INTO turns
                        (turn_id, sequence, user_text, user_message_id, user_source_index,
                         original_result, final_message_id, final_source_index)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                        values,
                    )
                else:
                    self._conn.execute(
                        """UPDATE turns SET sequence = ?, user_text = ?, user_message_id = ?,
                           user_source_index = ?, original_result = ?, final_message_id = ?, final_source_index = ?
                        WHERE turn_id = ?""",
                        (
                            turn.sequence,
                            turn.user_text,
                            turn.user_message_id,
                            turn.user_source_index,
                            turn.original_result,
                            turn.final_message_id,
                            turn.final_source_index,
                            turn.turn_id,
                        ),
                    )
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise
        self._write_snapshot()
        return new_messages, before == 0

    def _reconcile_filtered_source(self, transcript: Any) -> None:
        """Migrate previously imported harness context in the source transaction.

        Keep unaffected results and usage. Retire affected jobs (rather than
        deleting them) so an in-flight old result cannot restore stale content.
        Only bootstrap's selected latest jobs are regenerated automatically.
        """
        old = {row["message_id"]: dict(row) for row in self._conn.execute("SELECT * FROM messages")}
        fresh = {message.message_id: message for message in transcript.messages}
        removed = set(transcript.excluded_message_ids) & set(old)
        changed = {identity for identity in fresh.keys() & old.keys() if fresh[identity].text != old[identity]["text"]}
        jobs = list(self._conn.execute("SELECT * FROM jobs WHERE status != 'superseded'"))
        outdated = set()
        for row in jobs:
            payload = _decode(row["input_json"], {})
            if (row["kind"] in ("requirement", "summary") and payload.get("format_version") != 6
                    and payload.get("coverage", {}).get("truncated")):
                outdated.add(row["job_id"])
        if not removed and not changed and not outdated:
            return
        earliest = min((old[identity]["source_index"] for identity in removed | changed), default=float("inf"))
        for row in jobs:
            affected = (row["job_id"] in outdated or row["source_id"] in removed | changed or
                        (row["kind"] != "summary" and row["source_index"] >= earliest))
            if affected:
                self._conn.execute("UPDATE jobs SET status='superseded', job_key=job_key || ':superseded:' || job_id, lease_until=NULL WHERE job_id=?", (row["job_id"],))
                if row["kind"] in ("requirement", "summary"):
                    prefix = row["kind"]
                    self._conn.execute(
                        "UPDATE turns SET {0}_status='not_analyzed', {0}_text=NULL, {0}_job_id=NULL, {0}_error=NULL WHERE {0}_job_id=?".format(prefix),
                        (row["job_id"],))
            elif row["source_id"] in fresh:
                self._conn.execute("UPDATE jobs SET source_index=? WHERE job_id=?", (fresh[row["source_id"]].source_index, row["job_id"]))
        for identity in removed:
            self._conn.execute("DELETE FROM messages WHERE message_id=?", (identity,))
        valid_turns = {message.turn_id for message in transcript.messages}
        for turn_id in {old[identity]["turn_id"] for identity in removed} - valid_turns:
            self._conn.execute("DELETE FROM turns WHERE turn_id=?", (turn_id,))
        boundary = self.get_meta("auto_boundary")
        if boundary is not None:
            # Imported history is already accounted for, even if it arrived
            # after the original bootstrap. Never charge to replay that history.
            boundary["index"] = max((fresh[identity].source_index for identity in fresh.keys() & old.keys()), default=0)
            boundary["selected"] = [message.message_id for message in
                                    (transcript.user_messages[-1:] + transcript.final_messages[-1:])]
            self._conn.execute("UPDATE meta SET value=? WHERE key='auto_boundary'", (_json(boundary),))

    def messages_before(self, source_index: int) -> List[Dict[str, Any]]:
        rows = self._conn.execute(
            "SELECT message_id, turn_id, role, text, source_index FROM messages WHERE source_index <= ? ORDER BY source_index",
            (source_index,),
        )
        return [dict(row) for row in rows]

    def turn(self, turn_id: str) -> Optional[Dict[str, Any]]:
        row = self._conn.execute("SELECT * FROM turns WHERE turn_id = ?", (turn_id,)).fetchone()
        return dict(row) if row else None

    def turns(self) -> List[Dict[str, Any]]:
        rows = self._conn.execute("SELECT * FROM turns ORDER BY sequence, turn_id")
        return [dict(row) for row in rows]

    def has_job(self, kind: str, source_id: str) -> bool:
        return self._conn.execute(
            "SELECT 1 FROM jobs WHERE kind=? AND session_id=? AND source_id=? AND status != 'superseded'",
            (kind, self.session_id, source_id)).fetchone() is not None

    def enqueue_job(
        self,
        kind: str,
        source_id: str,
        turn_id: str,
        source_index: int,
        input_snapshot: Dict[str, Any],
        *,
        analyzer_version: str = ANALYZER_VERSION,
        max_attempts: int = 2,
    ) -> Dict[str, Any]:
        if kind not in ("requirement", "summary", "skill"):
            raise ValueError("invalid_job_kind")
        if max_attempts < 1:
            raise ValueError("invalid_max_attempts")
        key = "%s:%s:%s:%s" % (kind, self.session_id, source_id, analyzer_version)
        timestamp = now_ms()
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            inserted = self._conn.execute(
                """INSERT OR IGNORE INTO jobs
                (job_key, kind, session_id, source_id, turn_id, source_index, analyzer_version,
                 status, attempts, max_attempts, input_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?, ?, ?)""",
                (key, kind, self.session_id, source_id, turn_id, source_index, analyzer_version,
                 max_attempts, _json(input_snapshot), timestamp, timestamp),
            )
            row = self._conn.execute("SELECT * FROM jobs WHERE job_key = ?", (key,)).fetchone()
            if kind in ("requirement", "summary") and (inserted.rowcount == 1 or row["status"] == "pending"):
                self._set_analysis_pending(kind, turn_id, source_index, row["job_id"])
            if input_snapshot.get("input_error") and (inserted.rowcount == 1 or row["status"] == "pending"):
                self._conn.execute("UPDATE jobs SET status='failed', error=? WHERE job_id=?",
                                   (input_snapshot["input_error"], row["job_id"]))
                row = self._conn.execute("SELECT * FROM jobs WHERE job_id=?", (row["job_id"],)).fetchone()
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise
        self._write_snapshot()
        return self._job_dict(row)

    def _set_analysis_pending(self, kind: str, turn_id: str, source_index: int, job_id: int) -> None:
        row = self._conn.execute(
            "SELECT user_source_index, final_source_index FROM turns WHERE turn_id = ?", (turn_id,)
        ).fetchone()
        if row is None:
            self._conn.execute(
                "INSERT INTO turns(turn_id, sequence) VALUES (?, COALESCE((SELECT MAX(sequence) + 1 FROM turns), 1))",
                (turn_id,),
            )
            row = {"user_source_index": None, "final_source_index": None}
        field_index = "user_source_index" if kind == "requirement" else "final_source_index"
        if row[field_index] is None or source_index >= row[field_index]:
            prefix = "requirement" if kind == "requirement" else "summary"
            self._conn.execute(
                "UPDATE turns SET %s_status='pending', %s_job_id=?, %s_error=NULL WHERE turn_id=?"
                % (prefix, prefix, prefix),
                (job_id, turn_id),
            )

    def set_turn_requirement(
        self,
        turn_id: str,
        source_id: str,
        revision: int,
        status: str,
        job_id: Any,
        error: Optional[str] = None,
    ) -> None:
        """Set a turn's visible requirement revision for store-level callers."""
        if status not in ("not_analyzed", "pending", "running", "succeeded", "failed"):
            raise ValueError("invalid_status")
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            row = self._conn.execute("SELECT turn_id FROM turns WHERE turn_id=?", (turn_id,)).fetchone()
            if row is None:
                self._conn.execute(
                    "INSERT INTO turns(turn_id, sequence, user_message_id, user_source_index) VALUES (?, COALESCE((SELECT MAX(sequence)+1 FROM turns), 1), ?, ?)",
                    (turn_id, source_id, revision),
                )
            else:
                self._conn.execute(
                    "UPDATE turns SET user_message_id=?, user_source_index=?, requirement_status=?, requirement_revision=?, requirement_job_id=?, requirement_error=? WHERE turn_id=?",
                    (source_id, revision, status, revision, job_id, error, turn_id),
                )
            if row is None:
                self._conn.execute(
                    "UPDATE turns SET requirement_status=?, requirement_revision=?, requirement_job_id=?, requirement_error=? WHERE turn_id=?",
                    (status, revision, job_id, error, turn_id),
                )
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise
        self._write_snapshot()

    def _job_dict(self, row: sqlite3.Row) -> Dict[str, Any]:
        value = dict(row)
        value["input"] = _decode(value.pop("input_json"), {})
        value["result"] = _decode(value.pop("result_json"), None)
        return value

    def get_job(self, job_id: Any) -> Optional[Dict[str, Any]]:
        row = self._conn.execute("SELECT * FROM jobs WHERE job_id = ?", (str(job_id),)).fetchone()
        return self._job_dict(row) if row else None

    def pending_count(self) -> int:
        return self._conn.execute(
            "SELECT COUNT(*) AS count FROM jobs WHERE status IN ('pending', 'running')"
        ).fetchone()["count"]

    def claim_job(self, lease_ms: int = 120000) -> Optional[Dict[str, Any]]:
        if not self.is_enabled():
            return None
        timestamp = now_ms()
        self._conn.execute("UPDATE jobs SET status='failed', error='interrupted', lease_until=NULL, updated_at=? WHERE status='running' AND lease_until < ? AND attempts >= max_attempts", (timestamp, timestamp))
        self._conn.commit()
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            row = self._conn.execute(
                """SELECT * FROM jobs
                   WHERE (status='pending' OR (status='running' AND lease_until < ?))
                     AND attempts < max_attempts
                   ORDER BY job_id LIMIT 1""",
                (timestamp,),
            ).fetchone()
            if row is None:
                self._conn.commit()
                return None
            attempts = row["attempts"] + 1
            self._conn.execute(
                "UPDATE jobs SET status='running', attempts=?, lease_until=?, updated_at=? WHERE job_id=?",
                (attempts, timestamp + lease_ms, timestamp, row["job_id"]),
            )
            self._conn.commit()
            row = self._conn.execute("SELECT * FROM jobs WHERE job_id = ?", (row["job_id"],)).fetchone()
        except Exception:
            self._conn.rollback()
            raise
        self._record_call(row["kind"])
        self._write_snapshot()
        return self._job_dict(row)

    def release_job(self, job_id: Any, *, preserve_attempts: bool = False) -> None:
        """Return a claimed job to the queue when disable wins the race to start."""
        attempts_sql = "attempts" if preserve_attempts else "MAX(attempts - 1, 0)"
        self._conn.execute(
            "UPDATE jobs SET status='pending', attempts=%s, lease_until=NULL, updated_at=? WHERE job_id=? AND status='running'" % attempts_sql,
            (now_ms(), str(job_id)),
        )
        if preserve_attempts:
            self._conn.execute("UPDATE jobs SET status='failed', error='interrupted' WHERE job_id=? AND status='pending' AND attempts>=max_attempts", (str(job_id),))
        self._conn.commit()
        self._write_snapshot()

    def _record_call(self, kind: str, success: Optional[bool] = None) -> None:
        usage = self.get_meta("usage", {})
        usage = dict(usage) if isinstance(usage, dict) else {}
        if success is None:
            usage["%s_calls" % kind] = int(usage.get("%s_calls" % kind, 0)) + 1
            usage["total_calls"] = int(usage.get("total_calls", 0)) + 1
        if success is not None:
            key = "successful_calls" if success else "failed_calls"
            usage[key] = int(usage.get(key, 0)) + 1
        self.set_meta("usage", usage)

    def _set_job_result(self, job_id: Any, status: str, result: Any, error: Optional[str]) -> Dict[str, Any]:
        timestamp = now_ms()
        row = self._conn.execute("SELECT * FROM jobs WHERE job_id = ?", (str(job_id),)).fetchone()
        if row is None:
            raise ValueError("job_not_found")
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            self._conn.execute(
                "UPDATE jobs SET status=?, result_json=?, error=?, lease_until=NULL, updated_at=? WHERE job_id=? AND status != 'superseded'",
                (status, _json(result) if result is not None else None, error, timestamp, str(job_id)),
            )
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise
        updated = self.get_job(job_id)
        if updated["status"] != "superseded":
            self._record_call(row["kind"], status == "succeeded")
        return updated

    def complete_job(self, job_id: Any, result: Dict[str, Any]) -> Dict[str, Any]:
        job = self.get_job(job_id)
        if job is None:
            raise ValueError("job_not_found")
        if job["status"] == "superseded":
            return job
        completed = self._set_job_result(job_id, "succeeded", result, None)
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            row = self._conn.execute("SELECT * FROM turns WHERE turn_id = ?", (job["turn_id"],)).fetchone()
            if row is not None and job["kind"] in ("requirement", "summary"):
                current_index = row["user_source_index"] if job["kind"] == "requirement" else row["final_source_index"]
                if (row[job["kind"] + "_job_id"] == job["job_id"] and
                        (current_index is None or job["source_index"] >= current_index)):
                    prefix = "requirement" if job["kind"] == "requirement" else "summary"
                    text = result.get("text") if isinstance(result, dict) else None
                    if not isinstance(text, str):
                        text = ""
                    if prefix == "requirement":
                        self._conn.execute(
                            "UPDATE turns SET requirement_status='succeeded', requirement_text=?, requirement_revision=?, requirement_job_id=?, requirement_error=NULL WHERE turn_id=?",
                            (text, job["source_index"], job["job_id"], job["turn_id"]),
                        )
                    else:
                        self._conn.execute(
                            "UPDATE turns SET summary_status='succeeded', summary_text=?, summary_job_id=?, summary_error=NULL WHERE turn_id=?",
                            (text, job["job_id"], job["turn_id"]),
                        )
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise
        self._write_snapshot()
        return completed

    def fail_job(self, job_id: Any, error: str) -> Dict[str, Any]:
        job = self.get_job(job_id)
        if job is None:
            raise ValueError("job_not_found")
        if job["status"] == "superseded":
            return job
        safe_error = str(error).replace("\n", " ")[:500]
        failed = self._set_job_result(job_id, "failed", None, safe_error)
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            row = self._conn.execute("SELECT * FROM turns WHERE turn_id = ?", (job["turn_id"],)).fetchone()
            if row is not None and job["kind"] in ("requirement", "summary"):
                current_index = row["user_source_index"] if job["kind"] == "requirement" else row["final_source_index"]
                if (row[job["kind"] + "_job_id"] == job["job_id"] and
                        (current_index is None or job["source_index"] >= current_index)):
                    prefix = "requirement" if job["kind"] == "requirement" else "summary"
                    self._conn.execute(
                        "UPDATE turns SET %s_status='failed', %s_job_id=?, %s_error=? WHERE turn_id=?"
                        % (prefix, prefix, prefix),
                        (job["job_id"], safe_error, job["turn_id"]),
                    )
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise
        self._write_snapshot()
        return failed

    def retry_job(self, job_id: Any) -> Dict[str, Any]:
        job = self.get_job(job_id)
        if job is None:
            raise ValueError("job_not_found")
        if job.get("input", {}).get("input_error"):
            raise ValueError(job["input"]["input_error"])
        if job["status"] != "failed":
            raise ValueError("job_not_failed")
        if job["attempts"] >= job["max_attempts"]:
            raise ValueError("retry_limit_reached")
        self._conn.execute(
            "UPDATE jobs SET status='pending', error=NULL, result_json=NULL, updated_at=? WHERE job_id=?",
            (now_ms(), str(job_id)),
        )
        if job["kind"] in ("requirement", "summary"):
            prefix = "requirement" if job["kind"] == "requirement" else "summary"
            self._conn.execute(
                "UPDATE turns SET %s_status='pending', %s_error=NULL WHERE turn_id=?" % (prefix, prefix),
                (job["turn_id"],),
            )
        self._conn.commit()
        self._write_snapshot()
        return self.get_job(job_id)  # type: ignore

    def jobs_for_turn(self, turn_id: str, kind: Optional[str] = None) -> List[Dict[str, Any]]:
        if kind:
            rows = self._conn.execute(
                "SELECT * FROM jobs WHERE turn_id=? AND kind=? ORDER BY job_id", (turn_id, kind)
            )
        else:
            rows = self._conn.execute("SELECT * FROM jobs WHERE turn_id=? ORDER BY job_id", (turn_id,))
        return [self._job_dict(row) for row in rows]

    def snapshot(self) -> Dict[str, Any]:
        source = self.get_meta("source", {})
        source_error = self.source_error()
        usage = self.get_meta("usage", {})
        turns: List[Dict[str, Any]] = []
        for row in self.turns():
            skills = []
            for job in self.jobs_for_turn(row["turn_id"], "skill"):
                if job["status"] == "superseded":
                    continue
                result = job.get("result") if isinstance(job.get("result"), dict) else {}
                if job["status"] == "succeeded":
                    result = normalize_skill(result)
                coverage = job.get("input", {}).get("coverage") if isinstance(job.get("input"), dict) else None
                skills.append(
                    {
                        "job_id": str(job["job_id"]),
                        "status": job["status"],
                        "name": result.get("name"),
                        "description": result.get("description"),
                        "markdown": result.get("markdown"),
                        "coverage": coverage,
                        "error": job.get("error"),
                        "caveats": result.get("caveats", []),
                    }
                )
            turns.append(
                {
                    "turn_id": row["turn_id"],
                    "sequence": row["sequence"],
                    "user_text": row["user_text"],
                    "requirement": self._analysis_state(row, "requirement"),
                    "summary": self._analysis_state(row, "summary"),
                    "original_result": row["original_result"],
                    "skills": skills,
                }
            )
        return {
            "schema_version": 1,
            "session_id": self.get_meta("session_id"),
            "enabled": self.is_enabled(),
            "source_error": source_error,
            "updated_at_ms": now_ms(),
            "source": source if isinstance(source, dict) else {},
            "usage": usage if isinstance(usage, dict) else {},
            "turns": turns,
        }

    def _analysis_state(self, row: Dict[str, Any], kind: str) -> Dict[str, Any]:
        job = self.get_job(row[kind + "_job_id"]) or {}
        expected = row["user_source_index" if kind == "requirement" else "final_source_index"]
        stale = bool(job and expected is not None and job["source_index"] < expected)
        status = "pending" if stale else job.get("status", row[kind + "_status"])
        result = job.get("result") or {}
        value = {
            "status": status,
            "text": result.get("text") if status == "succeeded" else None,
            "job_id": str(job["job_id"]) if job and not stale else None,
            "coverage": self._job_coverage(job.get("job_id")) if not stale else None,
            "error": job.get("error") if not stale else None,
            "caveats": result.get("caveats", []) if status == "succeeded" else [],
        }
        if kind == "requirement":
            value["revision"] = job.get("source_index") if status == "succeeded" else None
            for key in ("turn_goal", "better_prompt", "next_step", "evidence", "conflicts", "gaps"):
                value[key] = result.get(key) if status == "succeeded" else None
        return value

    def _job_coverage(self, job_id: Any) -> Optional[Dict[str, Any]]:
        if not job_id:
            return None
        job = self.get_job(job_id)
        if not job or not isinstance(job.get("input"), dict):
            return None
        coverage = job["input"].get("coverage")
        return coverage if isinstance(coverage, dict) else None

    def _atomic_json(self, path: Path, value: Dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(prefix=".%s." % path.name, dir=str(path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(value, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_name, str(path))
        finally:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass

    def _write_snapshot(self) -> None:
        self._atomic_json(self.view_path, self.snapshot())
