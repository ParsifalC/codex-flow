#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CODEX_HOME="$TMP/home"
STATE="$TMP/latency.jsonl"

python3 - "$ROOT" "$STATE" <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
from telemetry_core.latency import LatencyError, latency_report, record_latency_event

state = Path(sys.argv[2])
base = {
    "event_id": "event-checkpoint",
    "task_id": "private-task-id",
    "worker_id": "private-worker-id",
    "work_unit_id": "src/private/module.py",
    "strategy": "efficient",
    "task_class": "routine",
    "stage": "implementation",
    "role": "implementer",
    "model": "gpt-5.6-luna",
    "rollout_mode": "shadow",
    "legacy_effort": "xhigh",
    "proposed_effort": "high",
    "selected_effort": "xhigh",
    "observed_effort": None,
    "boundary": "checkpoint",
    "outcome": None,
    "started_at": 1000,
    "finished_at": 1004,
    "repair_count": 1,
    "checkpoint_count": 1,
}
first = record_latency_event(base, state_file=state)
assert first["recorded"] and not first["deduplicated"], first
duplicate = record_latency_event(base, state_file=state)
assert duplicate["deduplicated"] and not duplicate["recorded"], duplicate

terminal = dict(base, event_id="event-terminal", boundary="terminal", outcome="completed", finished_at=1010, observed_effort="xhigh")
assert record_latency_event(terminal, state_file=state)["recorded"]
timeout = dict(terminal, event_id="event-timeout", worker_id="worker-timeout", outcome="timeout", finished_at=1099)
assert record_latency_event(timeout, state_file=state)["recorded"]
missing = dict(terminal, event_id="event-missing", worker_id="worker-missing", outcome="failed", finished_at=None)
assert record_latency_event(missing, state_file=state)["recorded"]

text = state.read_text(encoding="utf-8")
for secret in ("private-task-id", "private-worker-id", "src/private/module.py"):
    assert secret not in text, text
events = [json.loads(line) for line in text.splitlines()]
assert len(events) == 4, events
for event in events:
    for name in ("event_id", "task_id", "worker_id", "event_fingerprint"):
        assert len(event[name]) == 64 and set(event[name]) <= set("0123456789abcdef"), event
    assert not any(name in event for name in ("prompt", "transcript", "conclusion", "cwd", "path", "output", "tool_args")), event

report = latency_report(state_file=state)
assert report["n"] == 3, report
assert report["completed"] == 1 and report["success"] == 1 and report["failed"] == 1, report
assert report["censored"] == 1 and report["timeout"] == 1 and report["missing"] == 1, report
assert report["checkpoint_observations"] == 1, report
assert report["p50_seconds"] == report["p95_seconds"] == 10, report
assert report["eligible_for_tuning"] is False and report["policy_mutation"] is False, report

invalid = (
    dict(terminal, event_id="bad-unknown", prompt="do not persist me"),
    dict(terminal, event_id="bad-model", model="/private/tmp/model"),
    dict(terminal, event_id="bad-ms", started_at=1_700_000_000_000, finished_at=1_700_000_000_010),
    dict(terminal, event_id="bad-count", repair_count=True),
    dict(base, event_id="bad-checkpoint", outcome="completed"),
)
for event in invalid:
    try:
        record_latency_event(event, state_file=state)
    except LatencyError:
        pass
    else:
        raise AssertionError(f"invalid event accepted: {event}")

try:
    record_latency_event(dict(terminal, event_id="event-terminal", repair_count=9), state_file=state)
except LatencyError as exc:
    assert "different payload" in str(exc), exc
else:
    raise AssertionError("event id collision was accepted")
PY

# A homogeneous 20-sample cohort opens the advisory tuning gate and uses the
# deterministic nearest-rank definition (p50=10, p95=19 for values 1..20).
python3 - "$ROOT" "$TMP/twenty.jsonl" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
from telemetry_core.latency import latency_report, record_latency_event

state = Path(sys.argv[2])
for index in range(1, 21):
    record_latency_event({
        "event_id": f"event-{index}", "task_id": f"task-{index}", "worker_id": f"worker-{index}",
        "strategy": "efficient", "task_class": "routine", "stage": "implementation", "role": "implementer",
        "model": "gpt-5.6-luna", "rollout_mode": "adaptive", "legacy_effort": "xhigh",
        "proposed_effort": "high", "selected_effort": "high", "observed_effort": "high",
        "boundary": "terminal", "outcome": "completed", "started_at": 1000, "duration_seconds": index,
        "repair_count": 0, "checkpoint_count": 0,
    }, state_file=state)
report = latency_report(state_file=state)
assert report["n"] == report["completed"] == report["success"] == 20, report
assert report["p50_seconds"] == 10 and report["p95_seconds"] == 19, report
assert report["eligible_for_tuning"] is True, report
assert len(report["groups"]) == 1 and report["groups"][0]["eligible_for_tuning"] is True, report

missing_observed = state.with_name("twenty-missing-observed.jsonl")
for index in range(1, 21):
    record_latency_event({
        "event_id": f"missing-{index}", "task_id": f"missing-task-{index}", "worker_id": f"missing-worker-{index}",
        "strategy": "efficient", "task_class": "routine", "stage": "implementation", "role": "implementer",
        "model": "gpt-5.6-luna", "rollout_mode": "adaptive", "legacy_effort": "xhigh",
        "proposed_effort": "high", "selected_effort": "high", "observed_effort": None,
        "boundary": "terminal", "outcome": "completed", "started_at": 1000, "duration_seconds": index,
        "repair_count": 0, "checkpoint_count": 0,
    }, state_file=missing_observed)
missing_report = latency_report(state_file=missing_observed)
assert missing_report["completed"] == 20 and missing_report["eligible_for_tuning"] is False, missing_report
PY

# Exercise the installed public CLI shape and its strict option handling.
event='{"event_id":"cli-event","task_id":"cli-task","worker_id":"cli-worker","strategy":"efficient","task_class":"complex","stage":"review","role":"reviewer","model":"gpt-5.6-luna","rollout_mode":"legacy","legacy_effort":"xhigh","proposed_effort":"xhigh","selected_effort":"xhigh","observed_effort":"xhigh","boundary":"terminal","outcome":"completed","started_at":2000,"finished_at":2005,"repair_count":0,"checkpoint_count":0}'
python3 "$ROOT/scripts/telemetry.py" latency record --state-file "$TMP/cli.jsonl" --event-json "$event" > "$TMP/record.json"
python3 "$ROOT/scripts/telemetry.py" latency report --state-file "$TMP/cli.jsonl" --json > "$TMP/report.json"
python3 - "$TMP/record.json" "$TMP/report.json" <<'PY'
import json, sys
record, report = (json.load(open(path)) for path in sys.argv[1:])
assert record["recorded"] is True, record
assert report["n"] == report["completed"] == 1 and report["p95_seconds"] == 5, report
PY
if python3 "$ROOT/scripts/telemetry.py" latency report --state-file "$TMP/cli.jsonl" --unknown >/dev/null 2>&1; then
  echo "unknown latency option was accepted" >&2
  exit 1
fi

# Concurrent writers must all survive and produce valid, distinct JSON lines.
for index in 1 2 3 4 5 6 7 8; do
  payload="${event/cli-event/concurrent-$index}"
  python3 "$ROOT/scripts/telemetry.py" latency record --state-file "$TMP/concurrent.jsonl" --event-json "$payload" >/dev/null &
done
wait
python3 - "$TMP/concurrent.jsonl" <<'PY'
import json, sys
events=[json.loads(line) for line in open(sys.argv[1])]
assert len(events) == 8, events
assert len({event["event_id"] for event in events}) == 8, events
PY

printf 'latency telemetry test passed\n'
