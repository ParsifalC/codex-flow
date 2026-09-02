#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CODEX_HOME="$TMP/.codex"
export CODEX_FLOW_TELEMETRY_NOTIFICATIONS=false
export CODEX_FLOW_LANGUAGE=en
mkdir -p "$CODEX_HOME/codex-flow/telemetry/runs"

# Keep metadata enrichment deterministic and offline for repair tests.
cat > "$TMP/fake-app-server.py" <<'PY'
#!/usr/bin/env python3
import json
import sys
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    if "id" not in msg:
        continue
    method = msg.get("method")
    if method == "initialize":
        result = {"serverInfo": {"name": "repair-test", "version": "1"}}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}), flush=True)
PY
chmod +x "$TMP/fake-app-server.py"
export CODEX_FLOW_APP_SERVER_COMMAND="python3 $TMP/fake-app-server.py"

TRANSCRIPT="$TMP/test_transcript.jsonl"
cat > "$TRANSCRIPT" <<'EOF'
{"timestamp":1000,"type":"response_item","payload":{"type":"custom_tool_call","name":"mcp__github_search","input":"skills/my-skill cmd: search","call_id":"c1"}}
{"timestamp":1050,"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","exit_code":0,"stdout":"success"}}}
{"timestamp":1100,"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"<USER_REQUEST>Fix bug</USER_REQUEST>"}]}}
{"timestamp":1200,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"Bug fixed successfully."}]}}
EOF

# Core repair_run cases: recoverable transcript fields, preserve existing data,
# safe missing-transcript behavior, quota delta recovery, and impossible delta.
python3 - "$ROOT_DIR" "$TMP" "$TRANSCRIPT" <<'PY'
import os
import sys
root_dir, tmp, transcript_path = sys.argv[1:4]
sys.path.insert(0, os.path.join(root_dir, "scripts"))
from telemetry_core import repair_run

run1 = {"session_id": "sess-1", "turn_id": "turn-1", "transcript_path": transcript_path}
rep1 = {}
repair_run(run1, report=rep1)
assert run1["skills_used"] == [{"name": "my-skill", "count": 1}], run1
assert len(run1["tools_used"]) == 1 and run1["tools_used"][0]["name"] == "mcp__github_search", run1
assert len(run1["trajectory"]) == 1 and run1["trajectory"][0]["name"] == "mcp__github_search", run1
assert len(run1["logs"]) >= 1, run1
assert run1["summary_info"]["goal"] == "Fix bug", run1
assert run1["summary_info"]["conclusion"] == "Bug fixed successfully.", run1
assert rep1["task_summaries_restored"] is True, rep1
assert rep1["skills_tools_restored"] is True, rep1
assert rep1["trajectories_restored"] is True, rep1
assert rep1["logs_restored"] is True, rep1

run2 = {
    "session_id": "sess-2",
    "turn_id": "turn-2",
    "transcript_path": transcript_path,
    "skills_used": [{"name": "existing-skill", "count": 5}],
    "tools_used": [{"name": "existing-tool", "count": 3}],
    "trajectory": [{"type": "existing_step"}],
    "logs": [{"message": "existing log"}],
    "summary_info": {"goal": "existing goal", "conclusion": "existing conclusion"},
}
rep2 = {}
repair_run(run2, report=rep2)
assert run2["skills_used"] == [{"name": "existing-skill", "count": 5}], run2
assert run2["tools_used"] == [{"name": "existing-tool", "count": 3}], run2
assert run2["trajectory"] == [{"type": "existing_step"}], run2
assert run2["logs"] == [{"message": "existing log"}], run2
assert run2["summary_info"] == {"goal": "existing goal", "conclusion": "existing conclusion"}, run2
assert rep2["task_summaries_restored"] is False, rep2
assert rep2["skills_tools_restored"] is False, rep2
assert rep2["trajectories_restored"] is False, rep2
assert rep2["logs_restored"] is False, rep2

run3 = {
    "session_id": "sess-3",
    "turn_id": "turn-3",
    "transcript_path": os.path.join(tmp, "nonexistent.jsonl"),
}
rep3 = {}
repair_run(run3, report=rep3)
assert "skills_used" not in run3, run3
assert "tools_used" not in run3, run3
assert "trajectory" not in run3, run3
assert rep3["transcript_missing"] is True, rep3

run4 = {
    "quota_before": [{"window_duration_mins": 300, "used_percent": 10}],
    "quota_after": [{"window_duration_mins": 300, "used_percent": 15}],
}
rep4 = {}
repair_run(run4, report=rep4)
assert run4["quota_change_during_run"][0]["delta_percentage_points"] == 5, run4
assert rep4["quota_deltas_restored"] is True, rep4
assert rep4["quota_deltas_impossible"] is False, rep4

run5 = {"quota_after": [{"window_duration_mins": 300, "used_percent": 15}]}
rep5 = {}
repair_run(run5, report=rep5)
assert "quota_change_during_run" not in run5, run5
assert rep5["quota_deltas_restored"] is False, rep5
assert rep5["quota_deltas_impossible"] is True, rep5
PY
printf 'telemetry repair unit cases 1-5 passed\n'

# Parse a human summary by metric name rather than coupling functional tests to
# presentation column width.
assert_metric() {
  local output="$1"
  local label="$2"
  local expected="$3"
  printf '%s\n' "$output" | awk -v label="$label" -v expected="$expected" '
    index($0, label ":") == 1 {
      value=$0
      sub("^" label ":[[:space:]]*", "", value)
      if (value == expected) found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

# Isolated history fixtures for dry-run, write, last.json sync, idempotency,
# JSON reporting, and the public codex-flow telemetry CLI path.
REPAIR_HOME="$TMP/repair-home"
export CODEX_HOME="$REPAIR_HOME/.codex"
mkdir -p "$CODEX_HOME/codex-flow/telemetry/runs"
cat > "$CODEX_HOME/codex-flow/telemetry/runs/sess-a--turn-1.json" <<EOF
{
  "schema_version": 1,
  "session_id": "sess-a",
  "turn_id": "turn-1",
  "transcript_path": "$TRANSCRIPT",
  "quota_before": [{"window_duration_mins": 300, "used_percent": 20}],
  "quota_after": [{"window_duration_mins": 300, "used_percent": 25}]
}
EOF
cat > "$CODEX_HOME/codex-flow/telemetry/runs/sess-b--turn-1.json" <<EOF
{
  "schema_version": 1,
  "session_id": "sess-b",
  "turn_id": "turn-1",
  "transcript_path": "$TRANSCRIPT",
  "quota_after": [{"window_duration_mins": 300, "used_percent": 40}]
}
EOF
cat > "$CODEX_HOME/codex-flow/telemetry/last.json" <<EOF
{
  "schema_version": 1,
  "session_id": "sess-b",
  "turn_id": "turn-1",
  "transcript_path": "$TRANSCRIPT",
  "quota_after": [{"window_duration_mins": 300, "used_percent": 40}]
}
EOF

dry_run_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" repair --dry-run)"
[[ "$dry_run_out" == *"Telemetry repair complete"* ]]
assert_metric "$dry_run_out" repaired 2
python3 -c "import json; d=json.load(open('$CODEX_HOME/codex-flow/telemetry/runs/sess-a--turn-1.json')); assert 'skills_used' not in d"

repair_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" repair)"
[[ "$repair_out" == *"Telemetry repair complete"* ]]
assert_metric "$repair_out" repaired 2
assert_metric "$repair_out" "quota deltas restored" 1
assert_metric "$repair_out" "quota deltas impossible" 1
python3 -c "import json; d=json.load(open('$CODEX_HOME/codex-flow/telemetry/runs/sess-a--turn-1.json')); assert d['skills_used'] == [{'name': 'my-skill', 'count': 1}]; assert d['quota_change_during_run'][0]['delta_percentage_points'] == 5"
python3 -c "import json; d=json.load(open('$CODEX_HOME/codex-flow/telemetry/last.json')); assert d['skills_used'] == [{'name': 'my-skill', 'count': 1}]"

repeat_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" repair --dry-run)"
assert_metric "$repeat_out" repaired 0
assert_metric "$repeat_out" unchanged 2

repair_json="$(python3 "$ROOT_DIR/scripts/telemetry.py" repair --json)"
python3 -c "import json,sys; d=json.load(sys.stdin); assert d['repaired'] == 0; assert d['scanned'] == 2; assert d['unchanged'] == 2" <<<"$repair_json"

cli_out="$(bash "$ROOT_DIR/bin/codex-flow" telemetry repair --dry-run)"
[[ "$cli_out" == *"Telemetry repair complete"* ]]
assert_metric "$cli_out" repaired 0

printf 'telemetry repair CLI and idempotency tests passed\n'
