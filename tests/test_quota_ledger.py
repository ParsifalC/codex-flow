"""Unit and integration tests for quota_ledger SQLite engine."""

import os
import sqlite3
import tempfile
from pathlib import Path

import pytest

from scripts.telemetry_core.quota_ledger import (
    compute_cycle_id,
    export_quota_summary,
    get_db,
    record_observation,
)


@pytest.fixture
def temp_db_path(tmp_path):
    return tmp_path / "test_quota_ledger.db"


@pytest.fixture
def conn(temp_db_path):
    connection = get_db(temp_db_path)
    yield connection
    connection.close()


def test_schema_and_constraints(conn):
    """Verify tables exist and check constraints enforce valid ranges."""
    cur = conn.execute("SELECT name FROM sqlite_master WHERE type='table';")
    tables = {row[0] for row in cur.fetchall()}
    assert "quota_observations" in tables
    assert "quota_segments" in tables
    assert "quota_allocations" in tables
    assert "quota_ledger_metadata" in tables

    # Constraint check: window duration must be 10080
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            """
            INSERT INTO quota_observations (
                observation_id, account_id, bucket_id, window_duration_mins,
                cycle_id, sampled_at_ms, used_percent, sample_source, created_at_ms
            ) VALUES ('test-1', 'acc-1', 'primary', 300, 'cycle-1', 1000, 10.0, 'test', 1000);
            """
        )

    # Constraint check: used_percent must be between 0 and 100
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            """
            INSERT INTO quota_observations (
                observation_id, account_id, bucket_id, window_duration_mins,
                cycle_id, sampled_at_ms, used_percent, sample_source, created_at_ms
            ) VALUES ('test-2', 'acc-1', 'primary', 10080, 'cycle-1', 1000, 105.0, 'test', 1000);
            """
        )


def test_cycle_isolation():
    """Verify cycle IDs isolate different accounts, resets, or generations."""
    c1 = compute_cycle_id("acc-1", "primary", 10080, 1700000000, 0)
    c2 = compute_cycle_id("acc-2", "primary", 10080, 1700000000, 0)
    assert c1 != c2

    # Different baseline generations within same reset
    c3 = compute_cycle_id("acc-1", "primary", 10080, 1700000000, 1)
    assert c1 != c3

    # Missing account receives isolated namespace, never lumped into shared 'unknown'
    c_anon1 = compute_cycle_id(None, None, 10080, 0, 0, isolated_key="task-a")
    c_anon2 = compute_cycle_id(None, None, 10080, 0, 0, isolated_key="task-b")
    assert c_anon1 != c_anon2


def test_forward_observations_and_segments(conn):
    """Test sequential forward observations creating consecutive segments."""
    # Baseline observation at t0: 3%
    res0 = record_observation(
        conn,
        account_id="acc-test",
        bucket_id="primary",
        used_percent=3.0,
        sampled_at_ms=1000,
        sample_source="turn_start",
    )
    assert res0["status"] == "success"
    assert len(res0["segments_created"]) == 0  # First point is baseline

    # Observation at t1: 6%
    res1 = record_observation(
        conn,
        account_id="acc-test",
        bucket_id="primary",
        used_percent=6.0,
        sampled_at_ms=2000,
        sample_source="turn_start",
    )
    assert res1["status"] == "success"
    assert len(res1["segments_created"]) == 1

    # Observation at t2: 27%
    res2 = record_observation(
        conn,
        account_id="acc-test",
        bucket_id="primary",
        used_percent=27.0,
        sampled_at_ms=3000,
        sample_source="turn_finish",
    )
    assert res2["status"] == "success"
    assert len(res2["segments_created"]) == 1

    # Check active segments in DB
    segs = conn.execute(
        "SELECT start_time_ms, end_time_ms, delta_pp, status FROM quota_segments WHERE status = 'active' ORDER BY start_time_ms;"
    ).fetchall()
    assert len(segs) == 2
    assert segs[0]["delta_pp"] == 3.0  # 6% - 3%
    assert segs[1]["delta_pp"] == 21.0  # 27% - 6%


def test_late_arrival_replacement(conn):
    """Verify late-arrival observation revocates existing segment and creates two new subsegments."""
    # Step 1: Create A at t=1000 (used=5%)
    record_observation(conn, "acc-late", "primary", 5.0, 1000, "start")

    # Step 2: Create C at t=3000 (used=25%) -> segment A->C created with delta=20%
    record_observation(conn, "acc-late", "primary", 25.0, 3000, "finish")

    active_segs = conn.execute("SELECT * FROM quota_segments WHERE status = 'active';").fetchall()
    assert len(active_segs) == 1
    assert active_segs[0]["delta_pp"] == 20.0
    old_seg_id = active_segs[0]["segment_id"]

    # Step 3: Late observation B arrives at t=2000 (used=12%)
    res_late = record_observation(conn, "acc-late", "primary", 12.0, 2000, "late_start")
    assert res_late["status"] == "success"
    assert old_seg_id in res_late["segments_revoked"]
    assert len(res_late["segments_created"]) == 2

    # Step 4: Verify DB state: old segment revoked, two new segments active
    revoked = conn.execute("SELECT * FROM quota_segments WHERE status = 'revoked';").fetchall()
    assert len(revoked) == 1
    assert revoked[0]["segment_id"] == old_seg_id

    active = conn.execute(
        "SELECT * FROM quota_segments WHERE status = 'active' ORDER BY start_time_ms;"
    ).fetchall()
    assert len(active) == 2
    # Segment 1: t=1000 to 2000, delta = 12 - 5 = 7 pp
    assert active[0]["start_time_ms"] == 1000
    assert active[0]["end_time_ms"] == 2000
    assert active[0]["delta_pp"] == 7.0

    # Segment 2: t=2000 to 3000, delta = 25 - 12 = 13 pp
    assert active[1]["start_time_ms"] == 2000
    assert active[1]["end_time_ms"] == 3000
    assert active[1]["delta_pp"] == 13.0

    # Sum of new segments equals original delta (7 + 13 = 20 pp)
    assert active[0]["delta_pp"] + active[1]["delta_pp"] == 20.0


def test_anomaly_detection_unexplained_drop(conn):
    """Verify unexplained watermark drop triggers 'pending_investigation' without creating negative segment."""
    record_observation(conn, "acc-anomaly", "primary", 20.0, 1000, "start")

    # Drop to 15% without reset or cycle change
    res = record_observation(conn, "acc-anomaly", "primary", 15.0, 2000, "finish")
    assert res["status"] == "anomaly_detected"
    assert res["anomaly_status"] == "pending_investigation"

    # No segment should be created
    segs = conn.execute("SELECT * FROM quota_segments;").fetchall()
    assert len(segs) == 0

    # Anomaly observation is stored as invalid
    obs = conn.execute(
        "SELECT is_valid, anomaly_status FROM quota_observations WHERE sampled_at_ms = 2000;"
    ).fetchone()
    assert obs["is_valid"] == 0
    assert obs["anomaly_status"] == "pending_investigation"


def test_export_quota_summary_anti_regression(conn, tmp_path):
    """Verify summary export produces valid JSON and enforces anti-regression guard."""
    summary_path = tmp_path / "quota_summary.json"

    # Add data
    record_observation(conn, "acc-export", "primary", 10.0, 1000, "start")
    record_observation(conn, "acc-export", "primary", 15.0, 2000, "finish")

    res = export_quota_summary(conn, output_path=summary_path)
    assert res["status"] == "success"
    assert summary_path.is_file()

    import json
    data = json.loads(summary_path.read_text())
    assert data["revision"] >= 2
    assert len(data["cycle_summaries"]) == 1
    assert data["cycle_summaries"][0]["total_observed_pp"] == 5.0
    assert len(data["daily_usage"]) == 1
    assert data["daily_usage"][0]["observed_delta_pp"] == 5.0


def test_late_earliest_head_insertion(conn):
    """Verify late arrival before initial baseline creates head segment (delta not lost)."""
    # Baseline at t=2000: 10%
    record_observation(conn, "acc-head", "primary", 10.0, 2000, "start")
    # Forward at t=3000: 20%
    record_observation(conn, "acc-head", "primary", 20.0, 3000, "finish")

    # Late earliest arrival at t=1000: 3%
    res = record_observation(conn, "acc-head", "primary", 3.0, 1000, "late_start")
    assert res["status"] == "success"
    assert len(res["segments_created"]) == 1

    # Check active segments: [1000->2000: 7 pp], [2000->3000: 10 pp]
    segs = conn.execute(
        "SELECT start_time_ms, end_time_ms, delta_pp FROM quota_segments WHERE status = 'active' ORDER BY start_time_ms;"
    ).fetchall()
    assert len(segs) == 2
    assert segs[0]["start_time_ms"] == 1000
    assert segs[0]["end_time_ms"] == 2000
    assert segs[0]["delta_pp"] == 7.0
    assert segs[1]["start_time_ms"] == 2000
    assert segs[1]["end_time_ms"] == 3000
    assert segs[1]["delta_pp"] == 10.0

    total = conn.execute("SELECT SUM(delta_pp) FROM quota_segments WHERE status = 'active';").fetchone()[0]
    assert total == 17.0


def test_anomaly_blocks_subsequent_segments(conn, tmp_path):
    """Verify unresolved anomaly blocks active segment generation and reports gap in summary."""
    # t=1000: 20%
    record_observation(conn, "acc-gap", "primary", 20.0, 1000, "start")
    # t=2000: 15% (unexplained drop)
    res_drop = record_observation(conn, "acc-gap", "primary", 15.0, 2000, "anomaly")
    assert res_drop["status"] == "anomaly_detected"

    # t=3000: 25% (rebound)
    res_reb = record_observation(conn, "acc-gap", "primary", 25.0, 3000, "rebound")
    assert res_reb["status"] == "success"

    # Active segments should be 0 (blocked by anomaly)
    active_segs = conn.execute("SELECT * FROM quota_segments WHERE status = 'active';").fetchall()
    assert len(active_segs) == 0

    # Blocked segment exists with status pending_investigation
    blocked_segs = conn.execute("SELECT * FROM quota_segments WHERE status = 'pending_investigation';").fetchall()
    assert len(blocked_segs) == 1
    assert blocked_segs[0]["reason_code"] == "blocked_by_anomaly"

    summary_file = tmp_path / "summary_anomaly.json"
    export_quota_summary(conn, summary_file)
    import json
    data = json.loads(summary_file.read_text())
    assert len(data["cycle_summaries"]) == 1
    cycle = data["cycle_summaries"][0]
    assert cycle["total_observed_pp"] == 0.0
    assert len(cycle["gaps"]) >= 1
    gap_statuses = [g["status"] for g in cycle["gaps"]]
    assert "pending_investigation" in gap_statuses


def test_cross_midnight_pending_pp(conn, tmp_path):
    """Verify segments crossing midnight set cross_midnight_pending_pp and coverage_status."""
    from datetime import datetime
    t1 = int(datetime(2026, 9, 8, 23, 59).timestamp() * 1000)
    t2 = int(datetime(2026, 9, 9, 0, 1).timestamp() * 1000)

    record_observation(conn, "acc-mid", "primary", 10.0, t1, "start")
    record_observation(conn, "acc-mid", "primary", 20.0, t2, "finish")

    summary_file = tmp_path / "summary_midnight.json"
    export_quota_summary(conn, summary_file)
    import json
    data = json.loads(summary_file.read_text())
    cycle = data["cycle_summaries"][0]
    assert cycle["cross_midnight_pending_pp"] == 10.0

    # Daily usage should have cross_midnight_pending_pp and not 10 pp lumped entirely into day 1
    assert len(data["daily_usage"]) == 2
    for d in data["daily_usage"]:
        assert d["observed_delta_pp"] == 0.0
        assert d["cross_midnight_pending_pp"] == 10.0
        assert d["coverage_status"] == "has_cross_midnight_pending"


def test_concurrent_writes_produce_no_overlapping_segments(tmp_path):
    """Verify concurrent writes protected by write transaction do not create overlapping segments."""
    from concurrent.futures import ThreadPoolExecutor
    db_path = tmp_path / "concurrent_ledger.db"
    c0 = get_db(db_path)
    record_observation(c0, "acc-conc", "secondary", 0.0, 1000, "baseline")
    c0.close()

    def append_worker(t, p):
        c = get_db(db_path)
        try:
            return record_observation(c, "acc-conc", "secondary", p, t, "concurrent")
        finally:
            c.close()

    with ThreadPoolExecutor(max_workers=2) as pool:
        f1 = pool.submit(append_worker, 2000, 10.0)
        f2 = pool.submit(append_worker, 3000, 20.0)
        res1 = f1.result()
        res2 = f2.result()

    assert res1["status"] == "success"
    assert res2["status"] == "success"

    c_check = get_db(db_path)
    segs = c_check.execute(
        "SELECT start_time_ms, end_time_ms, delta_pp, status FROM quota_segments WHERE status='active' ORDER BY start_time_ms;"
    ).fetchall()
    total = c_check.execute("SELECT SUM(delta_pp) FROM quota_segments WHERE status='active';").fetchone()[0]
    c_check.close()

    assert len(segs) == 2
    assert total == 20.0
    # Overcount would have been 30.0 (0->10 and 0->20); serialized execution ensures 20.0


def test_resolve_account_id_resolution(tmp_path, monkeypatch):
    """Verify resolve_account_id prioritizes argument, then auth.json, and never uses installation_id."""
    from scripts.telemetry_core.quota_ledger import resolve_account_id
    import scripts.telemetry_core.quota_ledger as ql

    # 1. Direct argument has highest priority
    assert resolve_account_id("my-acc") == "my-acc"

    # 2. Fallback to auth.json in CODEX_HOME
    fake_home = tmp_path / "fake_codex"
    fake_home.mkdir()
    monkeypatch.setattr(ql, "CODEX_HOME", fake_home)

    auth_file = fake_home / "auth.json"
    auth_file.write_text('{"tokens": {"account_id": "auth-account-123"}}')
    assert resolve_account_id(None) == "auth-account-123"

    # 3. installation_id MUST NOT be used as account identity
    auth_file.unlink()
    inst_file = fake_home / "installation_id"
    inst_file.write_text("inst-456")
    assert resolve_account_id(None) is None

    # 4. Neither exists
    inst_file.unlink()
    assert resolve_account_id(None) is None


def test_late_anomaly_suspends_covering_segment(conn):
    """Verify that an out-of-order anomaly observation suspends covering segments."""
    # 1. Normal segment 1000 (20%) -> 3000 (25%) -> +5 pp
    record_observation(conn, "acc", "secondary", 20.0, 1000, "test", resets_at_ms=1800000000)
    res_normal = record_observation(conn, "acc", "secondary", 25.0, 3000, "test", resets_at_ms=1800000000)
    assert len(res_normal["segments_created"]) == 1

    active_segs = conn.execute("SELECT segment_id FROM quota_segments WHERE status='active'").fetchall()
    assert len(active_segs) == 1

    # 2. Late anomaly observation arrives at 2000 with 15% (which is < 20% at 1000)
    res_anomaly = record_observation(conn, "acc", "secondary", 15.0, 2000, "test", resets_at_ms=1800000000)
    assert res_anomaly["status"] == "anomaly_detected"

    # 3. Covering segment [1000, 3000] should now be suspended to pending_investigation
    active_after = conn.execute("SELECT segment_id FROM quota_segments WHERE status='active'").fetchall()
    assert len(active_after) == 0

    suspended = conn.execute(
        "SELECT status, reason_code FROM quota_segments WHERE start_time_ms=1000 AND end_time_ms=3000"
    ).fetchone()
    assert suspended[0] == "pending_investigation"
    assert suspended[1] == "blocked_by_anomaly"


def test_daily_usage_grouped_by_account(conn, tmp_path):
    """Verify daily usage separates accounts and includes active_account_id."""
    summary_path = tmp_path / "quota_summary.json"
    record_observation(conn, "account_A", "secondary", 10.0, 1788840001000, "test", resets_at_ms=1800000000)
    record_observation(conn, "account_A", "secondary", 20.0, 1788840002000, "test", resets_at_ms=1800000000)

    record_observation(conn, "account_B", "secondary", 50.0, 1788840003000, "test", resets_at_ms=1800000000)
    record_observation(conn, "account_B", "secondary", 70.0, 1788840004000, "test", resets_at_ms=1800000000)

    export_quota_summary(conn, output_path=summary_path)
    import json
    data = json.loads(summary_path.read_text())
    daily = data.get("daily_usage", [])
    assert len(daily) == 2

    daily_a = next(d for d in daily if d["account_id"] == "account_A")
    daily_b = next(d for d in daily if d["account_id"] == "account_B")
    assert daily_a["observed_delta_pp"] == 10.0
    assert daily_b["observed_delta_pp"] == 20.0


def test_anomaly_arrival_order_invariance(tmp_path):
    """Verify all 6 permutations of (1000, 20%), (2000, 15%), (3000, 25%) yield 0 active delta."""
    import itertools
    for p in itertools.permutations([(1000, 20.0), (2000, 15.0), (3000, 25.0)]):
        db_path = tmp_path / f"test_{hash(p)}.db"
        c = get_db(db_path)
        for t, val in p:
            record_observation(c, "acc", "secondary", val, t, "test", resets_at_ms=1800000000)
        active_segs = c.execute("SELECT segment_id, delta_pp FROM quota_segments WHERE status='active'").fetchall()
        total_active = sum(s["delta_pp"] for s in active_segs)
        c.close()
        assert len(active_segs) == 0, f"Permutation {p} produced active segments: {active_segs}"
        assert total_active == 0.0, f"Permutation {p} produced active delta: {total_active}"




@pytest.mark.parametrize("values, expected_total", [
    ([20, 15, 25, 30], 5.0),
    ([10, 20, 15, 25], 10.0),
    ([20, 15, 17, 25, 30], 5.0),
    ([3, 6, 19, 30], 27.0),
])
def test_full_timeline_and_daily_summary_ignore_arrival_order(tmp_path, values, expected_total):
    """Recovery, healthy prefixes and multiple drops converge for every permutation."""
    import itertools
    import json

    base = 1788840000000
    points = [(base + (i + 1) * 1000, value) for i, value in enumerate(values)]
    expected = None
    for index, order in enumerate(itertools.permutations(points)):
        c = get_db(tmp_path / f"order-{index}.db")
        try:
            for timestamp, value in order:
                record_observation(c, "acc", "secondary", value, timestamp, "test",
                                   resets_at_ms=1800000000000)
            observations = [tuple(r) for r in c.execute(
                "SELECT sampled_at_ms, used_percent, is_valid, anomaly_status "
                "FROM quota_observations ORDER BY sampled_at_ms"
            )]
            segments = [tuple(r) for r in c.execute(
                "SELECT start_time_ms, end_time_ms, delta_pp, status "
                "FROM quota_segments WHERE status != 'revoked' ORDER BY start_time_ms"
            )]
            output = tmp_path / f"summary-{index}.json"
            export_quota_summary(c, output)
            summary = json.loads(output.read_text())
            cycle = summary["cycle_summaries"][0]
            semantic_state = (observations, segments, summary["daily_usage"],
                              cycle["baseline_used_percent"], cycle["total_observed_pp"])
            assert cycle["total_observed_pp"] == expected_total
            if expected is None:
                expected = semantic_state
            assert semantic_state == expected, f"Arrival order: {order}"
        finally:
            c.close()


def _seed_allocated_timeline(conn):
    for timestamp, value in [(2000, 15), (3000, 25), (4000, 30)]:
        record_observation(conn, "acc", "secondary", value, timestamp, "test")
    segments = conn.execute("SELECT * FROM quota_segments ORDER BY start_time_ms").fetchall()
    with conn:
        for i, segment in enumerate(segments):
            conn.execute(
                "INSERT INTO quota_allocations (allocation_id, segment_id, run_id, session_id, "
                "allocated_pp, token_weight, weight_share, attribution_method, status, revision) "
                "VALUES (?, ?, 'run', 'session', ?, 100, 1, 'token_weight', 'active', ?)",
                (f"allocation-{i}", segment["segment_id"], segment["delta_pp"], segment["created_revision"]),
            )
            conn.execute("UPDATE quota_segments SET unattributed_pp = 0, "
                         "attribution_status = 'fully_attributed' WHERE segment_id = ?",
                         (segment["segment_id"],))
    return segments


def test_late_conflict_preserves_healthy_allocations(conn):
    segments = _seed_allocated_timeline(conn)
    revision_before = conn.execute("SELECT current_revision FROM quota_ledger_metadata").fetchone()[0]
    record_observation(conn, "acc", "secondary", 20, 1000, "late")
    allocations = dict(conn.execute("SELECT allocation_id, status FROM quota_allocations"))
    assert allocations == {"allocation-0": "revoked", "allocation-1": "active"}
    healthy = conn.execute("SELECT * FROM quota_segments WHERE status = 'active'").fetchone()
    assert healthy["segment_id"] == segments[1]["segment_id"]
    assert healthy["delta_pp"] == 5
    assert healthy["unattributed_pp"] == 0
    assert healthy["attribution_status"] == "fully_attributed"
    revision_after = conn.execute("SELECT current_revision FROM quota_ledger_metadata").fetchone()[0]
    assert revision_after == revision_before + 1
    duplicate = record_observation(conn, "acc", "secondary", 20, 1000, "late")
    assert duplicate["status"] == "idempotent_duplicate"
    assert conn.execute("SELECT current_revision FROM quota_ledger_metadata").fetchone()[0] == revision_after


def test_reconciliation_failure_rolls_back_observations_segments_and_allocations(conn):
    _seed_allocated_timeline(conn)
    tables = ["quota_observations", "quota_segments", "quota_allocations", "quota_ledger_metadata"]
    before = {table: [tuple(r) for r in conn.execute(f"SELECT * FROM {table}")] for table in tables}
    conn.execute("CREATE TEMP TRIGGER reject_pending BEFORE INSERT ON quota_segments "
                 "WHEN NEW.status = 'pending_investigation' "
                 "BEGIN SELECT RAISE(ABORT, 'injected reconciliation failure'); END")
    with pytest.raises(sqlite3.IntegrityError, match="injected reconciliation failure"):
        record_observation(conn, "acc", "secondary", 20, 1000, "late")
    after = {table: [tuple(r) for r in conn.execute(f"SELECT * FROM {table}")] for table in tables}
    assert after == before
