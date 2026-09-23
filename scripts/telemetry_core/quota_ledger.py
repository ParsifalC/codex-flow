"""Deterministic weekly quota ledger engine using SQLite with WAL mode.

Maintains an immutable observation timeline, transaction-safe segment lifecycle,
late-arrival replacement transactions, and anti-regression derived cache exports.
"""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
from contextlib import contextmanager
from decimal import Decimal
from datetime import datetime
from pathlib import Path
from typing import Any

from .common import (
    CODEX_HOME,
    STATE_ROOT,
    atomic_json,
    now_ms,
    read_json_object,
    state_lock,
)

WEEKLY_WINDOW_MINS = 10080
QUOTA_LEDGER_DB = STATE_ROOT / "quota_ledger.db"
QUOTA_SUMMARY_FILE = STATE_ROOT / "quota_summary.json"
QUOTA_LOCK_KEY = "quota_ledger"
ALLOCATION_METHOD = "token_weight"


def get_db(db_path: Path = QUOTA_LEDGER_DB) -> sqlite3.Connection:
    """Open or create the SQLite ledger database with WAL mode and foreign keys enabled."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path), timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA foreign_keys = ON;")
    conn.execute("PRAGMA busy_timeout = 5000;")
    init_db(conn)
    return conn


@contextmanager
def db_session(db_path: Path = QUOTA_LEDGER_DB):
    """Open a ledger connection, commit its work, and always release it."""
    conn = get_db(db_path)
    try:
        with conn:
            yield conn
    finally:
        conn.close()


def init_db(conn: sqlite3.Connection) -> None:
    """Initialize SQLite schema if not already present."""
    with conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS quota_observations (
                observation_id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                bucket_id TEXT NOT NULL,
                window_duration_mins INTEGER NOT NULL CHECK (window_duration_mins = 10080),
                resets_at_ms INTEGER,
                baseline_generation INTEGER NOT NULL DEFAULT 0,
                cycle_id TEXT NOT NULL,
                sampled_at_ms INTEGER NOT NULL,
                used_percent REAL NOT NULL CHECK (used_percent >= 0.0 AND used_percent <= 100.0),
                sample_source TEXT NOT NULL,
                run_id TEXT,
                is_valid BOOLEAN NOT NULL DEFAULT 1,
                anomaly_status TEXT NOT NULL DEFAULT 'normal',
                created_at_ms INTEGER NOT NULL
            );
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_obs_cycle_time
            ON quota_observations(cycle_id, sampled_at_ms);
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS quota_segments (
                segment_id TEXT PRIMARY KEY,
                cycle_id TEXT NOT NULL,
                start_obs_id TEXT NOT NULL REFERENCES quota_observations(observation_id),
                end_obs_id TEXT NOT NULL REFERENCES quota_observations(observation_id),
                start_time_ms INTEGER NOT NULL,
                end_time_ms INTEGER NOT NULL CHECK (end_time_ms >= start_time_ms),
                delta_pp REAL NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('active', 'revoked', 'pending_investigation')),
                attribution_status TEXT NOT NULL CHECK (attribution_status IN ('fully_attributed', 'partially_attributed', 'unattributed', 'waiting_weights')),
                unattributed_pp REAL NOT NULL DEFAULT 0.0 CHECK (unattributed_pp >= 0.0),
                reason_code TEXT,
                has_cross_midnight BOOLEAN NOT NULL DEFAULT 0,
                created_revision INTEGER NOT NULL,
                revoked_revision INTEGER
            );
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_seg_cycle_active
            ON quota_segments(cycle_id, status, start_time_ms);
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS quota_allocations (
                allocation_id TEXT PRIMARY KEY,
                segment_id TEXT NOT NULL REFERENCES quota_segments(segment_id),
                run_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                allocated_pp REAL NOT NULL CHECK (allocated_pp >= 0.0),
                token_weight INTEGER NOT NULL CHECK (token_weight >= 0),
                weight_share REAL NOT NULL CHECK (weight_share >= 0.0 AND weight_share <= 1.0),
                attribution_method TEXT NOT NULL,
                assumption TEXT,
                status TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
                revision INTEGER NOT NULL
            );
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_alloc_run
            ON quota_allocations(run_id, status);
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_alloc_session
            ON quota_allocations(session_id, status);
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS quota_ledger_metadata (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                current_revision INTEGER NOT NULL,
                last_rebuilt_at_ms INTEGER NOT NULL
            );
            """
        )
        cur = conn.execute("SELECT id FROM quota_ledger_metadata WHERE id = 1;")
        if cur.fetchone() is None:
            conn.execute(
                """
                INSERT INTO quota_ledger_metadata (id, current_revision, last_rebuilt_at_ms)
                VALUES (1, 1, ?);
                """,
                (now_ms(),),
            )


def resolve_account_id(account_id: str | None = None) -> str | None:
    """Resolve stable account identifier from argument or auth.json.

    Prevents concurrent tasks from falling into isolated cycles when account_id
    is omitted in telemetry events. Returns None if unauthenticated (never falls back
    to installation_id).
    """
    if account_id and str(account_id).strip():
        return str(account_id).strip()
    try:
        auth_file = CODEX_HOME / "auth.json"
        if auth_file.is_file():
            data = json.loads(auth_file.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                tokens = data.get("tokens")
                if isinstance(tokens, dict) and tokens.get("account_id"):
                    return str(tokens["account_id"]).strip()
                if data.get("account_id"):
                    return str(data["account_id"]).strip()
    except Exception:
        pass
    return None


def compute_cycle_id(
    account_id: str | None,
    bucket_id: str | None,
    window_duration_mins: int,
    resets_at_ms: int | None,
    baseline_generation: int = 0,
    isolated_key: str | None = None,
) -> str:
    """Construct deterministic cycle identifier.

    Missing identity is NEVER lumped into a single shared 'unknown' account;
    it receives an isolated namespace to prevent cross-account contamination.
    """
    acc = (account_id or "").strip()
    bkt = (bucket_id or "primary").strip()
    if not acc:
        acc = f"isolated_{isolated_key}" if isolated_key else "isolated_anonymous"
    reset_part = resets_at_ms if resets_at_ms is not None else 0
    return f"{acc}:{bkt}:{window_duration_mins}:{reset_part}:{baseline_generation}"


def record_observation(
    conn: sqlite3.Connection,
    account_id: str | None,
    bucket_id: str | None,
    used_percent: float,
    sampled_at_ms: int,
    sample_source: str,
    window_duration_mins: int = WEEKLY_WINDOW_MINS,
    resets_at_ms: int | None = None,
    baseline_generation: int = 0,
    run_id: str | None = None,
) -> dict[str, Any]:
    """Insert immutable sample evidence and reconcile its cycle in one transaction.

    Validity is derived from sample time, never arrival order: a value below the
    last accepted watermark is pending until the watermark recovers. The interval
    spanning that recovery remains pending; subsequent clean intervals can settle.
    """
    if window_duration_mins != WEEKLY_WINDOW_MINS:
        return {
            "status": "ignored_non_weekly",
            "reason": f"Only window_duration_mins={WEEKLY_WINDOW_MINS} is tracked",
        }
    if not (0.0 <= used_percent <= 100.0):
        return {"status": "rejected_out_of_range", "used_percent": used_percent}

    resolved_account = resolve_account_id(account_id)
    cycle_id = compute_cycle_id(
        resolved_account, bucket_id, window_duration_mins, resets_at_ms,
        baseline_generation, isolated_key=run_id,
    )
    with conn:
        if not conn.in_transaction:
            conn.execute("BEGIN IMMEDIATE;")
        existing = conn.execute(
            """SELECT observation_id, used_percent, anomaly_status
               FROM quota_observations WHERE cycle_id = ? AND sampled_at_ms = ?;""",
            (cycle_id, sampled_at_ms),
        ).fetchone()
        if existing is not None:
            return {
                "status": "idempotent_duplicate",
                "observation_id": existing["observation_id"],
                "used_percent": existing["used_percent"],
                "anomaly_status": existing["anomaly_status"],
            }

        obs_id = str(uuid.uuid4())
        created_at = now_ms()
        conn.execute(
            """INSERT INTO quota_observations (
                observation_id, account_id, bucket_id, window_duration_mins,
                resets_at_ms, baseline_generation, cycle_id, sampled_at_ms,
                used_percent, sample_source, run_id, created_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);""",
            (obs_id, resolved_account or "isolated", bucket_id or "primary",
             window_duration_mins, resets_at_ms, baseline_generation, cycle_id,
             sampled_at_ms, used_percent, sample_source, run_id, created_at),
        )
        revision = conn.execute(
            "SELECT current_revision FROM quota_ledger_metadata WHERE id = 1;"
        ).fetchone()[0] + 1
        created, revoked, invalid = _reconcile_cycle(conn, cycle_id, revision)
        conn.execute(
            """UPDATE quota_ledger_metadata
               SET current_revision = ?, last_rebuilt_at_ms = ? WHERE id = 1;""",
            (revision, created_at),
        )

    result = {
        "status": "anomaly_detected" if obs_id in invalid else "success",
        "observation_id": obs_id,
        "cycle_id": cycle_id,
        "segments_created": created,
        "segments_revoked": revoked,
    }
    if obs_id in invalid:
        result["anomaly_status"] = "pending_investigation"
        result["reason"] = "Watermark below the preceding accepted sample"
    return result


def backfill_historical_observations(
    conn: sqlite3.Connection,
    runs: dict[str, dict[str, Any]],
) -> dict[str, int]:
    """Seed immutable weekly observations from completed historical run JSON.

    Only host/app-server snapshots are evidence here: transcript estimates are
    intentionally excluded.  Snapshot timestamps win; lifecycle timestamps are
    used only when a snapshot omitted ``sampled_at_ms``.
    """
    seeded = 0
    duplicates = 0
    skipped = 0
    for run_id in sorted(runs):
        run = runs[run_id]
        if not isinstance(run, dict):
            continue
        account_default = run.get("account_id") or resolve_account_id()
        for phase, fallback_field in (("quota_before", "started_at_ms"), ("quota_after", "finished_at_ms")):
            if phase == "quota_after" and run.get("quota_after_source") == "transcript_estimate":
                skipped += 1
                continue
            windows = run.get(phase)
            if not isinstance(windows, list):
                continue
            fallback = run.get(fallback_field)
            for window in windows:
                if not isinstance(window, dict) or window.get("window_duration_mins") != WEEKLY_WINDOW_MINS:
                    continue
                used = window.get("used_percent")
                if not isinstance(used, (int, float)) or isinstance(used, bool):
                    skipped += 1
                    continue
                sampled_at = window.get("sampled_at_ms")
                if not isinstance(sampled_at, (int, float)):
                    sampled_at = fallback
                if not isinstance(sampled_at, (int, float)):
                    skipped += 1
                    continue
                account = window.get("account_id") or account_default
                result = record_observation(
                    conn=conn,
                    account_id=account,
                    bucket_id=window.get("slot") or window.get("bucket_id") or "primary",
                    used_percent=float(used),
                    sampled_at_ms=int(sampled_at),
                    sample_source="historical_repair",
                    resets_at_ms=window.get("resets_at"),
                    baseline_generation=int(window.get("baseline_generation") or 0),
                    run_id=run_id,
                )
                if result.get("status") == "idempotent_duplicate":
                    duplicates += 1
                elif result.get("status") in {"success", "anomaly_detected"}:
                    seeded += 1
                else:
                    skipped += 1
    return {"seeded": seeded, "duplicates": duplicates, "skipped": skipped}


def _reconcile_cycle(
    conn: sqlite3.Connection, cycle_id: str, revision: int,
) -> tuple[list[str], list[str], set[str]]:
    """Derive the canonical timeline from raw evidence, retaining unchanged edges.

    The caller owns the write transaction. Observation payloads are immutable;
    only their derived validity flags can change when earlier evidence arrives.
    Removed/changed edges invalidate allocations in the same revision. Unchanged
    edges keep their IDs and allocations, including healthy edges after a gap.
    """
    observations = conn.execute(
        """SELECT observation_id, sampled_at_ms, used_percent, is_valid, anomaly_status
           FROM quota_observations WHERE cycle_id = ? ORDER BY sampled_at_ms;""",
        (cycle_id,),
    ).fetchall()
    desired = {}
    invalid = set()
    previous = None
    crosses_anomaly = False
    for obs in observations:
        is_valid = previous is None or obs["used_percent"] >= previous["used_percent"]
        anomaly_status = "normal" if is_valid else "pending_investigation"
        if obs["is_valid"] != int(is_valid) or obs["anomaly_status"] != anomaly_status:
            conn.execute(
                """UPDATE quota_observations SET is_valid = ?, anomaly_status = ?
                   WHERE observation_id = ?;""",
                (int(is_valid), anomaly_status, obs["observation_id"]),
            )
        if not is_valid:
            invalid.add(obs["observation_id"])
            crosses_anomaly = True
            continue
        if previous is not None:
            key = (previous["observation_id"], obs["observation_id"])
            status = "pending_investigation" if crosses_anomaly else "active"
            desired[key] = (previous, obs, status)
        previous = obs
        crosses_anomaly = False

    current = conn.execute(
        """SELECT * FROM quota_segments
           WHERE cycle_id = ? AND status != 'revoked' ORDER BY start_time_ms;""",
        (cycle_id,),
    ).fetchall()
    created, revoked = [], []
    for segment in current:
        sid = segment["segment_id"]
        key = (segment["start_obs_id"], segment["end_obs_id"])
        target = desired.pop(key, None)
        if target is None:
            conn.execute(
                """UPDATE quota_segments SET status = 'revoked', revoked_revision = ?
                   WHERE segment_id = ?;""", (revision, sid),
            )
            revoked.append(sid)
        elif segment["status"] == target[2]:
            continue
        else:
            status = target[2]
            reason = "blocked_by_anomaly" if status == "pending_investigation" else "waiting_attribution"
            conn.execute(
                """UPDATE quota_segments SET status = ?, reason_code = ?,
                   attribution_status = 'waiting_weights', unattributed_pp = delta_pp
                   WHERE segment_id = ?;""", (status, reason, sid),
            )
        conn.execute(
            "UPDATE quota_allocations SET status = 'revoked' WHERE segment_id = ?;",
            (sid,),
        )

    for start, end, status in desired.values():
        sid = str(uuid.uuid4())
        delta = end["used_percent"] - start["used_percent"]
        reason = "blocked_by_anomaly" if status == "pending_investigation" else "waiting_attribution"
        conn.execute(
            """INSERT INTO quota_segments (
                segment_id, cycle_id, start_obs_id, end_obs_id,
                start_time_ms, end_time_ms, delta_pp, status,
                attribution_status, unattributed_pp, reason_code,
                has_cross_midnight, created_revision
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'waiting_weights', ?, ?, ?, ?);""",
            (sid, cycle_id, start["observation_id"], end["observation_id"],
             start["sampled_at_ms"], end["sampled_at_ms"], delta, status, delta,
             reason, _crosses_midnight(start["sampled_at_ms"], end["sampled_at_ms"]), revision),
        )
        created.append(sid)
    return created, revoked, invalid


def _crosses_midnight(start_ms: int, end_ms: int) -> bool:
    """Determine if interval crosses local calendar midnight."""
    d1 = datetime.fromtimestamp(start_ms / 1000.0)
    d2 = datetime.fromtimestamp(end_ms / 1000.0)
    return d1.date() != d2.date()


def _run_token_weight(run: dict[str, Any]) -> int | None:
    """Return strict participant total tokens, preserving explicit zeroes.

    Every participant present in the finalized run must have a numeric total.
    This prevents partial snapshots from silently receiving a proportional share.
    """
    participants: list[dict[str, Any]] = []
    parent = run.get("parent")
    if isinstance(parent, dict):
        participants.append(parent)
    workers = run.get("workers")
    if isinstance(workers, dict):
        participants.extend(worker for worker in workers.values() if isinstance(worker, dict))
    if not participants:
        return None
    values: list[int] = []
    for participant in participants:
        usage = participant.get("usage_delta") if participant is parent else participant.get("usage")
        value = usage.get("total_tokens") if isinstance(usage, dict) else None
        if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
            return None
        values.append(int(value))
    return sum(values)


def allocate_quota_segments(
    conn: sqlite3.Connection,
    *,
    runs: dict[str, dict[str, Any]] | None = None,
    state_root: Path = STATE_ROOT,
    now: int | None = None,
) -> dict[str, dict[str, Any]]:
    """Allocate active weekly segments over overlapping runs by token weight.

    Allocation IDs are deterministic ``segment_id:run_id`` keys, so replaying
    the collector updates the same rows rather than charging quota twice.  The
    SQLite transaction also updates segment attribution state atomically.
    """
    root = Path(state_root)
    snapshot: dict[str, dict[str, Any]] = {}
    try:
        from .common import iter_run_files, read_json_object
        for path in iter_run_files() if root == STATE_ROOT else sorted((root / "runs").glob("*.json")):
            value = read_json_object(path)
            if isinstance(value, dict):
                snapshot[path.stem] = value
    except Exception:
        pass
    if runs:
        snapshot.update({str(key): value for key, value in runs.items() if isinstance(value, dict)})
    clock = now if now is not None else int(time.time() * 1000)
    result: dict[str, dict[str, Any]] = {}
    with conn:
        meta = conn.execute("SELECT current_revision FROM quota_ledger_metadata WHERE id = 1").fetchone()
        old_revision = int(meta[0]) if meta else 1
        segments = conn.execute("SELECT * FROM quota_segments WHERE status = 'active' ORDER BY segment_id").fetchall()
        old_active = conn.execute("SELECT * FROM quota_allocations WHERE status = 'active' ORDER BY allocation_id").fetchall()
        old_by_id = {str(row["allocation_id"]): row for row in old_active}
        desired_rows: dict[str, tuple[Any, ...]] = {}
        desired_segments: dict[str, tuple[str, float]] = {}
        old_runs = {str(row["run_id"]) for row in conn.execute("SELECT DISTINCT run_id FROM quota_allocations").fetchall()}
        for segment in segments:
            cycle_runs = {
                str(row["run_id"])
                for row in conn.execute(
                    "SELECT DISTINCT run_id FROM quota_observations WHERE cycle_id=? AND run_id IS NOT NULL",
                    (segment["cycle_id"],),
                ).fetchall()
            }
            candidates: list[tuple[str, dict[str, Any], int | None]] = []
            for run_id in sorted(cycle_runs):
                run = snapshot.get(run_id)
                if not isinstance(run, dict) or not isinstance(run.get("finished_at_ms"), (int, float)):
                    continue
                started = run.get("started_at_ms")
                if not isinstance(started, (int, float)) or started > segment["end_time_ms"] or run["finished_at_ms"] < segment["start_time_ms"]:
                    continue
                candidates.append((run_id, run, _run_token_weight(run)))
            # Any missing participant weight blocks the entire segment. Explicit
            # zero weights remain candidates and all-zero totals stay waiting.
            blocked = any(weight is None for _, _, weight in candidates)
            total = sum(weight or 0 for _, _, weight in candidates)
            if not candidates or blocked or total <= 0:
                desired_segments[segment["segment_id"]] = ("waiting_weights", float(segment["delta_pp"]))
                continue
            remaining = Decimal(str(segment["delta_pp"]))
            ids: set[str] = set()
            for index, (run_id, run, weight) in enumerate(candidates):
                allocation_id = f"{segment['segment_id']}:{run_id}"
                value = remaining if index == len(candidates) - 1 else (Decimal(str(segment["delta_pp"])) * int(weight) / total).quantize(Decimal("0.000000000001"))
                remaining -= value
                ids.add(allocation_id)
                desired_rows[allocation_id] = (segment["segment_id"], run_id, str(run.get("session_id") or ""), float(value), int(weight), int(weight) / total)
            desired_segments[segment["segment_id"]] = ("fully_attributed", 0.0)
        semantic_changed = set(old_by_id) != set(desired_rows)
        for allocation_id, row in desired_rows.items():
            old = old_by_id.get(allocation_id)
            if old is None or any(old[key] != value for key, value in (("segment_id", row[0]), ("run_id", row[1]), ("session_id", row[2]), ("allocated_pp", row[3]), ("token_weight", row[4]), ("weight_share", row[5]))):
                semantic_changed = True
        for segment_id, (status, unattributed) in desired_segments.items():
            current = conn.execute("SELECT attribution_status, unattributed_pp FROM quota_segments WHERE segment_id=?", (segment_id,)).fetchone()
            if current and (current["attribution_status"] != status or float(current["unattributed_pp"]) != unattributed):
                semantic_changed = True
        revision = old_revision + 1 if semantic_changed else old_revision
        if semantic_changed:
            conn.execute("UPDATE quota_ledger_metadata SET current_revision=?, last_rebuilt_at_ms=? WHERE id=1", (revision, clock))
        for allocation_id in set(old_by_id) - set(desired_rows):
            conn.execute("UPDATE quota_allocations SET status='revoked', revision=? WHERE allocation_id=?", (revision, allocation_id))
        for allocation_id, row in desired_rows.items():
            conn.execute(
                "INSERT INTO quota_allocations (allocation_id,segment_id,run_id,session_id,allocated_pp,token_weight,weight_share,attribution_method,assumption,status,revision) VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(allocation_id) DO UPDATE SET allocated_pp=excluded.allocated_pp, token_weight=excluded.token_weight, weight_share=excluded.weight_share, session_id=excluded.session_id, status='active', revision=excluded.revision",
                (allocation_id, row[0], row[1], row[2], row[3], row[4], row[5], ALLOCATION_METHOD, None, "active", revision),
            )
        for segment_id, (status, unattributed) in desired_segments.items():
            conn.execute("UPDATE quota_segments SET attribution_status=?, unattributed_pp=?, reason_code=? WHERE segment_id=?", (status, unattributed, None if status == "fully_attributed" else "waiting_attribution", segment_id))
        active = conn.execute("SELECT * FROM quota_allocations WHERE status='active' ORDER BY allocation_id").fetchall()
        aggregate: dict[str, list[sqlite3.Row]] = {}
        for row in active:
            aggregate.setdefault(str(row["run_id"]), []).append(row)
        all_runs = old_runs | set(aggregate)
        for run_id in sorted(all_runs):
            rows = aggregate.get(run_id, [])
            if not rows:
                result[run_id] = {"clear": True}
                continue
            total_pp = sum(float(row["allocated_pp"]) for row in rows)
            total_weight = sum(int(row["token_weight"]) for row in rows)
            ids = sorted(str(row["allocation_id"]) for row in rows)
            result[run_id] = {"allocated_quota_pp": total_pp, "quota_allocation": {"allocation_id": ids[0] if len(ids) == 1 else None, "allocated_pp": total_pp, "token_weight": total_weight, "attribution_method": ALLOCATION_METHOD, "status": "active"}}
    return result


def export_quota_summary(
    conn: sqlite3.Connection,
    output_path: Path = QUOTA_SUMMARY_FILE,
) -> dict[str, Any]:
    """Export derived quota summary JSON protected by single-writer lock and anti-regression guard."""
    with state_lock(QUOTA_LOCK_KEY) as acquired:
        if not acquired:
            return {"status": "lock_failed"}

        # Read state inside a single SQLite transaction with snapshot isolation
        with conn:
            if not getattr(conn, "in_transaction", False):
                try:
                    conn.execute("BEGIN;")
                except sqlite3.OperationalError:
                    pass

            meta = conn.execute(
                "SELECT current_revision, last_rebuilt_at_ms FROM quota_ledger_metadata WHERE id = 1;"
            ).fetchone()
            current_rev = meta["current_revision"] if meta else 1

            # Check existing cache to strictly prohibit revision regression
            existing_cache = read_json_object(output_path)
            if existing_cache and isinstance(existing_cache.get("revision"), int):
                if existing_cache["revision"] > current_rev:
                    return {
                        "status": "skipped_anti_regression",
                        "existing_revision": existing_cache["revision"],
                        "current_db_revision": current_rev,
                    }

            # Query all distinct cycles in observations
            cycle_ids_rows = conn.execute(
                """
                SELECT DISTINCT cycle_id FROM quota_observations
                ORDER BY cycle_id ASC;
                """
            ).fetchall()

            cycle_summaries = []
            for c_row in cycle_ids_rows:
                cid = c_row["cycle_id"]
                seg_stats = conn.execute(
                    """
                    SELECT MIN(start_time_ms) as min_start,
                           MAX(end_time_ms) as max_end,
                           SUM(delta_pp) as total_observed,
                           SUM(unattributed_pp) as total_unattributed
                    FROM quota_segments
                    WHERE cycle_id = ? AND status = 'active';
                    """,
                    (cid,),
                ).fetchone()

                base_obs = conn.execute(
                    """
                    SELECT used_percent
                    FROM quota_observations
                    WHERE cycle_id = ? AND is_valid = 1
                    ORDER BY sampled_at_ms ASC
                    LIMIT 1;
                    """,
                    (cid,),
                ).fetchone()
                base_val = base_obs["used_percent"] if base_obs else 0.0

                cm_row = conn.execute(
                    """
                    SELECT SUM(delta_pp) as cross_midnight_total
                    FROM quota_segments
                    WHERE cycle_id = ? AND status = 'active' AND has_cross_midnight = 1;
                    """,
                    (cid,),
                ).fetchone()
                cm_val = cm_row["cross_midnight_total"] if cm_row and cm_row["cross_midnight_total"] else 0.0

                gap_obs = conn.execute(
                    """
                    SELECT observation_id, sampled_at_ms, used_percent, anomaly_status
                    FROM quota_observations
                    WHERE cycle_id = ? AND anomaly_status != 'normal'
                    ORDER BY sampled_at_ms ASC;
                    """,
                    (cid,),
                ).fetchall()
                gap_segs = conn.execute(
                    """
                    SELECT segment_id, start_time_ms, end_time_ms, delta_pp, reason_code
                    FROM quota_segments
                    WHERE cycle_id = ? AND status = 'pending_investigation'
                    ORDER BY start_time_ms ASC;
                    """,
                    (cid,),
                ).fetchall()
                gaps = []
                for o in gap_obs:
                    gaps.append({
                        "observation_id": o["observation_id"],
                        "start_time_ms": o["sampled_at_ms"],
                        "end_time_ms": o["sampled_at_ms"],
                        "used_percent": o["used_percent"],
                        "status": o["anomaly_status"],
                        "reason": "anomaly_detected",
                    })
                for s in gap_segs:
                    gaps.append({
                        "segment_id": s["segment_id"],
                        "start_time_ms": s["start_time_ms"],
                        "end_time_ms": s["end_time_ms"],
                        "delta_pp": s["delta_pp"],
                        "status": "pending_investigation",
                        "reason": s["reason_code"] or "blocked_by_anomaly",
                    })

                tot_obs = seg_stats["total_observed"] if seg_stats and seg_stats["total_observed"] else 0.0
                tot_unattr = seg_stats["total_unattributed"] if seg_stats and seg_stats["total_unattributed"] else 0.0

                cycle_summaries.append(
                    {
                        "cycle_id": cid,
                        "baseline_used_percent": round(base_val, 2),
                        "total_observed_pp": round(tot_obs, 2),
                        "total_allocated_pp": round(tot_obs - tot_unattr, 2),
                        "total_unattributed_pp": round(tot_unattr, 2),
                        "coverage_start_ms": seg_stats["min_start"] if seg_stats else None,
                        "coverage_end_ms": seg_stats["max_end"] if seg_stats else None,
                        "gaps": gaps,
                        "cross_midnight_pending_pp": round(cm_val, 2),
                    }
                )

            # Daily usage aggregation based on active segments of canonical (non-isolated) cycles
            # Retain account and bucket dimensions
            segments = conn.execute(
                """
                SELECT s.start_time_ms, s.end_time_ms, s.delta_pp, s.unattributed_pp, s.has_cross_midnight,
                       o.account_id, o.bucket_id
                FROM quota_segments s
                JOIN quota_observations o ON s.start_obs_id = o.observation_id
                WHERE s.status = 'active' AND s.cycle_id NOT LIKE 'isolated_%'
                ORDER BY s.start_time_ms ASC;
                """
            ).fetchall()

            daily_map: dict[tuple[str, str, str], dict[str, Any]] = {}
            for seg in segments:
                acc = seg["account_id"]
                bkt = seg["bucket_id"]
                if seg["has_cross_midnight"]:
                    d_start = datetime.fromtimestamp(seg["start_time_ms"] / 1000.0).strftime("%Y-%m-%d")
                    d_end = datetime.fromtimestamp(seg["end_time_ms"] / 1000.0).strftime("%Y-%m-%d")
                    for d_str in (d_start, d_end):
                        key = (acc, bkt, d_str)
                        if key not in daily_map:
                            daily_map[key] = {
                                "account_id": acc,
                                "bucket_id": bkt,
                                "date": d_str,
                                "observed_delta_pp": 0.0,
                                "unattributed_pp": 0.0,
                                "cross_midnight_pending_pp": 0.0,
                                "coverage_status": "has_cross_midnight_pending",
                            }
                        daily_map[key]["cross_midnight_pending_pp"] += seg["delta_pp"]
                        daily_map[key]["coverage_status"] = "has_cross_midnight_pending"
                else:
                    dt = datetime.fromtimestamp(seg["start_time_ms"] / 1000.0)
                    date_str = dt.strftime("%Y-%m-%d")
                    key = (acc, bkt, date_str)
                    if key not in daily_map:
                        daily_map[key] = {
                            "account_id": acc,
                            "bucket_id": bkt,
                            "date": date_str,
                            "observed_delta_pp": 0.0,
                            "unattributed_pp": 0.0,
                            "cross_midnight_pending_pp": 0.0,
                            "coverage_status": "partial_day_observed",
                        }
                    daily_map[key]["observed_delta_pp"] += seg["delta_pp"]
                    daily_map[key]["unattributed_pp"] += seg["unattributed_pp"]

            daily_list = [
                {
                    "account_id": d["account_id"],
                    "bucket_id": d["bucket_id"],
                    "date": d["date"],
                    "observed_delta_pp": round(d["observed_delta_pp"], 1),
                    "unattributed_pp": round(d["unattributed_pp"], 1),
                    "cross_midnight_pending_pp": round(d["cross_midnight_pending_pp"], 1),
                    "coverage_status": d["coverage_status"],
                }
                for d in sorted(daily_map.values(), key=lambda x: (x["account_id"], x["date"]))
            ]

            # Query session allocations
            session_rows = conn.execute(
                """
                SELECT session_id,
                       SUM(allocated_pp) as total_allocated,
                       attribution_method
                FROM quota_allocations
                WHERE status = 'active'
                GROUP BY session_id;
                """
            ).fetchall()

            session_allocations = {}
            for s in session_rows:
                session_allocations[s["session_id"]] = {
                    "allocated_pp": round(s["total_allocated"], 1),
                    "attribution_status": "fully_attributed",
                    "method": s["attribution_method"],
                }

            payload = {
                "revision": current_rev,
                "exported_at_ms": now_ms(),
                "timezone": time.tzname[0],
                "active_account_id": resolve_account_id(),
                "cycle_summaries": cycle_summaries,
                "daily_usage": daily_list,
                "session_allocations": session_allocations,
            }

            atomic_json(output_path, payload)
            return {"status": "success", "revision": current_rev}
