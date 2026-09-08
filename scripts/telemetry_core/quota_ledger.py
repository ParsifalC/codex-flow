"""Deterministic weekly quota ledger engine using SQLite with WAL mode.

Maintains an immutable observation timeline, transaction-safe segment lifecycle,
late-arrival replacement transactions, and anti-regression derived cache exports.
"""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
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
