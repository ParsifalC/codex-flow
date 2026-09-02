#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CODEX_HOME="$TMP/.codex"
export FAKE_COUNTER="$TMP/counter"
export CODEX_FLOW_TELEMETRY_NOTIFICATIONS=false
export CODEX_FLOW_LANGUAGE=en

cat > "$TMP/fake-app-server.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
counter=Path(os.environ["FAKE_COUNTER"])
try: n=int(counter.read_text())+1
except Exception: n=1
counter.write_text(str(n))
for line in sys.stdin:
    msg=json.loads(line)
    if "id" not in msg: continue
    method=msg.get("method")
    if method=="initialize": result={"serverInfo":{"name":"fake","version":"1"}}
    elif method=="account/rateLimits/read":
        used=31 if n==1 else 34
        result={"rateLimits":{"primary":{"usedPercent":used,"windowDurationMins":300,"resetsAt":1},"secondary":{"usedPercent":18 if n==1 else 19,"windowDurationMins":10080,"resetsAt":2}}}
    elif method=="thread/read":
        tid=(msg.get("params") or {}).get("threadId")
        result={} if tid=="metadata-session" else {"thread":{"id":tid,"name":"Telemetry demo","preview":"do work","cwd":"/tmp/work","gitInfo":{"branch":"main"}}}
    elif method=="account/usage/read":
        tid=(msg.get("params") or {}).get("threadId")
        if tid=="parent-1":
            tokens=1000 if n==1 else 2500
            credits=1_000_000 if n==1 else 3_000_000
        else:
            tokens=800; credits=1_000_000
        thread_usage={"threadId":tid,"estimatedUsageCreditsMicros":credits,"estimatedUsageUsdMicros":None,"groups":[{"model":"gpt-test","reasoningEffort":"high","speed":"standard","estimatedUsageCreditsMicros":credits,"netNewInputTokens":tokens//2,"cachedInputTokens":tokens//4,"inputTokens":tokens*3//4,"outputTokens":tokens//4,"totalTokens":tokens}]}
        if os.environ.get("FAKE_THREAD_USAGE") == "none": thread_usage=None
        result={"summary":{},"dailyUsageBuckets":None,"threadUsage":thread_usage}
    else: result={}
    print(json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":result}), flush=True)
PY
chmod +x "$TMP/fake-app-server.py"
export CODEX_FLOW_APP_SERVER_COMMAND="python3 $TMP/fake-app-server.py"

hook() { printf '%s' "$1" | python3 "$ROOT_DIR/scripts/telemetry.py"; }
hook '{"hook_event_name":"UserPromptSubmit","session_id":"parent-1","turn_id":"turn-1","cwd":"/tmp/work","model":"gpt-parent","prompt":"do work"}'
hook '{"hook_event_name":"SubagentStart","session_id":"parent-1","turn_id":"turn-1","cwd":"/tmp/work","model":"gpt-worker","agent_id":"worker-1","agent_type":"worker-implementer"}'
hook '{"hook_event_name":"SubagentStop","session_id":"parent-1","turn_id":"turn-1","cwd":"/tmp/work","model":"gpt-worker","agent_id":"worker-1","agent_type":"worker-implementer","last_assistant_message":"Implemented worker telemetry output."}'
summary_json="$(hook '{"hook_event_name":"Stop","session_id":"parent-1","turn_id":"turn-1","cwd":"/tmp/work","model":"gpt-parent","last_assistant_message":"done"}')"
summary="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["systemMessage"], end="")' <<<"$summary_json")"
python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin)["systemMessage"], str)' <<<"$summary_json"
printf '%s\n' "$summary"
[[ "$summary" == *"FlowPilot Telemetry Summary"* ]]
[[ "$summary" == *"Session:        Telemetry demo"* ]]
[[ "$summary" == *"Project:        work · main"* ]]
[[ "$summary" == *"Started:"* ]]
[[ "$summary" == *"Finished:"* ]]
[[ "$summary" == *"Duration:"* ]]
[[ "$summary" == *"Resets:"* ]]
[[ "$summary" == *"1 parent + 1 worker"* ]]
[[ "$summary" == *"worker-implementer"* ]]
[[ "$summary" == *"Implemented worker telemetry output."* ]]
[[ "$summary" == *"2.3k tokens"* ]]
[[ "$summary" == *"3.000 credits"* ]]
[[ "$summary" == *"5h used 31% → 34% (+3 pp; 66% remaining)"* ]]
[[ "$summary" == *"7d used"* ]]
[[ "$summary" == *"18% → 19% (+1 pp; 81% remaining)"* ]]

last="$(python3 "$ROOT_DIR/scripts/telemetry.py" last)"
[[ "$last" == *"2.3k tokens"* ]]
json_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" last --json)"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["workers"]["worker-1"]["status"] == "completed"; assert d["workers"]["worker-1"]["conclusion"] == "Implemented worker telemetry output."; assert d["parent"]["usage_delta"]["total_tokens"] == 1500; assert d["thread"]["name"] == "Telemetry demo"; assert d["thread"]["gitInfo"]["branch"] == "main"' <<<"$json_out"

printf 'telemetry test passed\n'

# A newly-created Desktop thread may not be materialized for thread/read yet.
# The local session index supplies its title, while turn_context supplies the
# actual model and reasoning effort for the current turn.
cat > "$CODEX_HOME/session_index.jsonl" <<'EOF'
{"id":"metadata-session","thread_name":"Indexed task title"}
EOF
cat > "$TMP/effort.jsonl" <<'EOF'
{"type":"turn_context","payload":{"turn_id":"metadata-turn","model":"gpt-5.6-luna","effort":"max"}}
EOF
metadata_json="$(hook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"metadata-session\",\"turn_id\":\"metadata-turn\",\"transcript_path\":\"$TMP/effort.jsonl\",\"cwd\":\"/tmp/work\"}")"
metadata_json="$(hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"metadata-session\",\"turn_id\":\"metadata-turn\",\"transcript_path\":\"$TMP/effort.jsonl\",\"cwd\":\"/tmp/work\"}")"
metadata_summary="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["systemMessage"], end="")' <<<"$metadata_json")"
[[ "$metadata_summary" == *"Session:        Indexed task title"* ]]
[[ "$metadata_summary" == *"gpt-5.6-luna (max)"* ]]
metadata_last="$(python3 "$ROOT_DIR/scripts/telemetry.py" last --json)"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["thread"]["name"] == "Indexed task title"; assert d["parent"]["model"] == "gpt-5.6-luna"; assert d["parent"]["reasoning_effort"] == "max"' <<<"$metadata_last"
printf 'telemetry title/effort fallback test passed\n'

# Subagent hooks carry the child turn id, while the final Stop hook carries the
# parent turn id. Correlate through the parent transcript and fall back to the
# exact rollout token_count events when app-server threadUsage is unavailable.
python3 - "$TMP/parent.jsonl" "$TMP/worker.jsonl" <<'PY'
import json
import sys

def event(kind, **payload):
    return {"type": "event_msg", "payload": {"type": kind, **payload}}

def usage(total, input_tokens, cached, output, reasoning=0):
    return event(
        "token_count",
        info={
            "total_token_usage": {
                "input_tokens": input_tokens,
                "cached_input_tokens": cached,
                "cache_write_input_tokens": 0,
                "output_tokens": output,
                "reasoning_output_tokens": reasoning,
                "total_tokens": total,
            }
        },
    )

parent = [
    event("task_started", turn_id="old-turn"),
    usage(100, 80, 40, 20, 5),
    event("task_complete", turn_id="old-turn"),
    event("task_started", turn_id="parent-2"),
    usage(175, 140, 90, 35, 10),
]
worker = [
    event("task_started", turn_id="child-2"),
    usage(200, 160, 100, 40, 12),
    event("task_complete", turn_id="child-2"),
]
for path, records in ((sys.argv[1], parent), (sys.argv[2], worker)):
    with open(path, "w", encoding="utf-8") as stream:
        for record in records:
            stream.write(json.dumps(record) + "\n")
PY
export FAKE_THREAD_USAGE=none
hook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"parent-2\",\"turn_id\":\"parent-2\",\"transcript_path\":\"$TMP/parent.jsonl\",\"cwd\":\"/tmp/work\",\"model\":\"gpt-parent\"}"
hook "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"parent-2\",\"turn_id\":\"child-2\",\"transcript_path\":\"$TMP/parent.jsonl\",\"cwd\":\"/tmp/work\",\"model\":\"gpt-worker\",\"agent_id\":\"worker-2\",\"agent_type\":\"worker-implementer\"}"
hook "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"parent-2\",\"turn_id\":\"child-2\",\"transcript_path\":\"$TMP/parent.jsonl\",\"agent_transcript_path\":\"$TMP/worker.jsonl\",\"cwd\":\"/tmp/work\",\"model\":\"gpt-worker\",\"agent_id\":\"worker-2\",\"agent_type\":\"worker-implementer\"}"
fallback_json="$(hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"parent-2\",\"turn_id\":\"parent-2\",\"transcript_path\":\"$TMP/parent.jsonl\",\"cwd\":\"/tmp/work\",\"model\":\"gpt-parent\"}")"
fallback_summary="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["systemMessage"], end="")' <<<"$fallback_json")"
[[ "$fallback_summary" == *"1 parent + 1 worker"* ]]
[[ "$fallback_summary" == *"275 tokens"* ]]
[[ "$fallback_summary" != *"credits"* ]]
[[ -f "$CODEX_HOME/codex-flow/telemetry/runs/parent-2--parent-2.json" ]]
[[ ! -f "$CODEX_HOME/codex-flow/telemetry/runs/parent-2--child-2.json" ]]
python3 - "$CODEX_HOME/codex-flow/telemetry/runs/parent-2--parent-2.json" <<'PY'
import json
import sys
d=json.load(open(sys.argv[1]))
assert d["parent"]["usage_delta"]["total_tokens"] == 75, d
assert d["parent"]["usage_delta"]["reasoning_output_tokens"] == 5, d
assert d["workers"]["worker-2"]["usage"]["total_tokens"] == 200, d
assert d["workers"]["worker-2"]["usage"]["source"] == "transcript", d
PY
unset FAKE_THREAD_USAGE
printf 'telemetry transcript fallback/correlation test passed\n'

# The agent index must survive a parent Stop and route a late SubagentStop to
# the completed parent instead of creating a child-only run.
hook '{"hook_event_name":"UserPromptSubmit","session_id":"late-parent","turn_id":"parent-turn","cwd":"/tmp/work","model":"gpt-parent"}'
hook '{"hook_event_name":"SubagentStart","session_id":"late-parent","turn_id":"child-turn","cwd":"/tmp/work","model":"gpt-worker","agent_id":"late-worker","agent_type":"worker-implementer"}'
hook '{"hook_event_name":"Stop","session_id":"late-parent","turn_id":"parent-turn","cwd":"/tmp/work","model":"gpt-parent"}'
hook '{"hook_event_name":"SubagentStop","session_id":"late-parent","turn_id":"child-turn","cwd":"/tmp/work","model":"gpt-worker","agent_id":"late-worker","agent_type":"worker-implementer"}'
python3 - "$CODEX_HOME/codex-flow/telemetry/runs/late-parent--parent-turn.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["workers"]["late-worker"]["status"] == "completed", d
PY
[[ ! -f "$CODEX_HOME/codex-flow/telemetry/runs/late-parent--child-turn.json" ]]
printf 'telemetry late-worker correlation test passed\n'

# A source record written by an older collector is retained but marked merged
# when the next parent Stop has enough lifecycle timing to identify its parent.
hook '{"hook_event_name":"UserPromptSubmit","session_id":"repair-session","turn_id":"parent-turn","cwd":"/tmp/work","model":"gpt-parent"}'
python3 - "$CODEX_HOME/codex-flow/telemetry/runs/repair-session--parent-turn.json" "$CODEX_HOME/codex-flow/telemetry/runs/repair-session--orphan-turn.json" <<'PY'
import json, sys
from pathlib import Path
parent_path, orphan_path = map(Path, sys.argv[1:])
parent = json.loads(parent_path.read_text())
start = parent["started_at_ms"] + 10
orphan = {
    "schema_version": 1,
    "session_id": "repair-session",
    "turn_id": "orphan-turn",
    "started_at_ms": start,
    "workers": {
        "repair-worker": {
            "agent_id": "repair-worker",
            "agent_type": "worker-implementer",
            "model": "gpt-worker",
            "started_at_ms": start,
            "finished_at_ms": start + 20,
            "status": "completed",
            "usage": {"total_tokens": 7, "estimated_credits_micros": 0},
        }
    },
}
orphan_path.write_text(json.dumps(orphan) + "\n")
PY
repair_summary_json="$(hook '{"hook_event_name":"Stop","session_id":"repair-session","turn_id":"parent-turn","cwd":"/tmp/work","model":"gpt-parent"}')"
repair_summary="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["systemMessage"], end="")' <<<"$repair_summary_json")"
[[ "$repair_summary" == *"1 parent + 1 worker"* ]]
python3 - "$CODEX_HOME/codex-flow/telemetry/runs/repair-session--parent-turn.json" "$CODEX_HOME/codex-flow/telemetry/runs/repair-session--orphan-turn.json" <<'PY'
import json, sys
parent = json.load(open(sys.argv[1]))
orphan = json.load(open(sys.argv[2]))
assert parent["workers"]["repair-worker"]["status"] == "completed", parent
assert orphan["merged_into"] == "repair-session--parent-turn", orphan
PY
printf 'telemetry orphan-worker repair test passed\n'

# The policy summary switch controls UI emission without disabling collection.
printf '[telemetry]\nsummary = false\n' > "$CODEX_HOME/codex-flow.toml"
hook '{"hook_event_name":"UserPromptSubmit","session_id":"summary-off","turn_id":"turn","cwd":"/tmp/work","model":"gpt-parent"}'
summary_off="$(hook '{"hook_event_name":"Stop","session_id":"summary-off","turn_id":"turn","cwd":"/tmp/work","model":"gpt-parent"}')"
[[ -z "$summary_off" ]]
[[ -f "$CODEX_HOME/codex-flow/telemetry/runs/summary-off--turn.json" ]]
rm "$CODEX_HOME/codex-flow.toml"
printf 'telemetry summary policy test passed\n'

# Missing thread usage must remain unavailable in both participant rows and
# the aggregate; an explicitly reported zero is still a real zero.
python3 - "$ROOT_DIR/scripts/telemetry.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("telemetry", sys.argv[1])
telemetry = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(telemetry)

unavailable = {
    "parent": {"model": "gpt-parent", "usage_delta": None},
    "workers": {
        "worker-1": {
            "agent_type": "worker-implementer",
            "model": "gpt-worker",
            "usage": None,
            "status": "completed",
        }
    },
}
summary = telemetry.render_summary(unavailable)
assert "gpt-parent" in summary and "n/a tokens" in summary, summary
assert "worker-implementer" in summary and "gpt-worker" in summary, summary
assert "• Attributed:     n/a tokens" in summary, summary
assert "• Attributed:     0 tokens" not in summary, summary
assert "credits" not in summary, summary

partial = {
    "parent": {
        "model": "gpt-parent",
        "usage_delta": {"total_tokens": 12, "estimated_credits_micros": 100},
    },
    "workers": {
        "worker-1": {
            "agent_type": "worker-implementer",
            "model": "gpt-worker",
            "usage": None,
            "status": "completed",
        }
    },
}
summary = telemetry.render_summary(partial)
assert "gpt-parent" in summary and "12 tokens" in summary, summary
assert "• Attributed:     n/a tokens" in summary, summary
assert "• Attributed:     12 tokens" not in summary, summary

zero = {
    "parent": {
        "model": "gpt-parent",
        "usage_delta": {"total_tokens": 0, "estimated_credits_micros": 0},
    },
    "workers": {
        "worker-1": {
            "agent_type": "worker-implementer",
            "model": "gpt-worker",
            "usage": {"total_tokens": 0, "estimated_credits_micros": 0},
            "status": "completed",
        }
    },
}
summary = telemetry.render_summary(zero)
assert "gpt-parent" in summary and "0 tokens" in summary, summary
assert "worker-implementer" in summary and "gpt-worker" in summary, summary
assert "• Attributed:     0 tokens" in summary, summary
assert "0.000 credits" in summary, summary
merged = telemetry.merge_worker_values(
    {"started_at_ms": 10, "finished_at_ms": 30, "status": "completed"},
    {"started_at_ms": 20, "finished_at_ms": 25, "status": "running"},
)
assert merged["started_at_ms"] == 10 and merged["finished_at_ms"] == 30, merged
assert merged["status"] == "completed", merged

run = {
    "session_id": "session",
    "started_at_ms": 1_000,
    "finished_at_ms": 3_000,
    "thread": {"name": "Task", "cwd": "/tmp/work", "gitInfo": {"branch": "main"}},
    "parent": {"usage_delta": {"total_tokens": 1}},
    "workers": {"worker": {"usage": {"total_tokens": 2}}},
}
calls = []
telemetry.os.environ["CODEX_FLOW_TELEMETRY_NOTIFICATIONS"] = "true"
telemetry.sys.platform = "darwin"
telemetry.shutil.which = lambda name: "/usr/bin/osascript"
telemetry.subprocess.run = lambda *args, **kwargs: calls.append((args, kwargs))
telemetry.send_system_notification(run)
assert len(calls) == 1, calls
assert "work · main · 1 worker · 3 tokens · 2s" in calls[0][0][0][2], calls
assert "FlowPilot task finished" in calls[0][0][0][2], calls
PY

printf 'telemetry unavailable/zero regression test passed\n'

# A lock timeout must skip the event rather than entering an unlocked
# critical section or creating a run file.
mkdir -p "$CODEX_HOME/codex-flow/telemetry"
mkdir "$CODEX_HOME/codex-flow/telemetry/.locked--turn.lock"
export CODEX_FLOW_TELEMETRY_LOCK_TIMEOUT=0.01
locked_output="$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"locked","turn_id":"turn","cwd":"/tmp/work","model":"gpt-parent"}')"
[[ -z "$locked_output" ]]
[[ ! -e "$CODEX_HOME/codex-flow/telemetry/runs/locked--turn.json" ]]
rmdir "$CODEX_HOME/codex-flow/telemetry/.locked--turn.lock"
unset CODEX_FLOW_TELEMETRY_LOCK_TIMEOUT
printf 'telemetry lock-timeout regression test passed\n'

# Usage deltas require both snapshots. Group deltas use stable identity and
# never treat a newly appearing group as if its cumulative total were new.
python3 - "$ROOT_DIR/scripts/telemetry.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("telemetry", sys.argv[1])
telemetry = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(telemetry)

before = {
    "total_tokens": 100,
    "estimated_credits_micros": 1_000,
    "groups": [
        {
            "model": "gpt-test",
            "reasoning_effort": "high",
            "speed": "standard",
            "total_tokens": 100,
            "estimated_credits_micros": 1_000,
        }
    ],
}
after = {
    "total_tokens": 175,
    "estimated_credits_micros": 1_750,
    "groups": [
        {
            "model": "gpt-test",
            "reasoning_effort": "high",
            "speed": "standard",
            "total_tokens": 175,
            "estimated_credits_micros": 1_750,
        },
        {
            "model": "new-model",
            "reasoning_effort": "low",
            "speed": "standard",
            "total_tokens": 999,
            "estimated_credits_micros": 999,
        },
    ],
}
delta = telemetry.usage_delta(before, after)
assert delta is not None
assert delta["total_tokens"] == 75
assert delta["estimated_credits_micros"] == 750
assert delta["groups"] == [
    {
        "model": "gpt-test",
        "reasoning_effort": "high",
        "speed": "standard",
        "total_tokens": 75,
        "estimated_credits_micros": 750,
    }
]
assert telemetry.usage_delta(None, after) is None
assert telemetry.usage_delta(before, None) is None
assert telemetry.usage_delta({}, after) is None

# A group without a stable identity or with no comparable numeric field is
# conservatively omitted.
partial_after = {
    "groups": [
        {"model": "gpt-test", "reasoning_effort": "high", "speed": "standard"},
        {"model": "gpt-test", "reasoning_effort": "high", "speed": None, "total_tokens": 3},
    ]
}
assert telemetry.usage_delta({"groups": before["groups"]}, partial_after)["groups"] == []
PY

printf 'telemetry usage-delta regression test passed\n'

# Per-run files are retained for 30 days and older generated records are
# pruned during the next completed parent run.
python3 - "$CODEX_HOME/codex-flow/telemetry/runs/old.json" "$CODEX_HOME/codex-flow/telemetry/runs/recent.json" <<'PY'
import json, sys, time
old_path, recent_path = sys.argv[1:]
old = int(time.time() * 1000) - 31 * 86_400_000
for path, timestamp in ((old_path, old), (recent_path, int(time.time() * 1000))):
    with open(path, "w") as stream:
        json.dump({"schema_version": 1, "started_at_ms": timestamp}, stream)
PY
hook '{"hook_event_name":"UserPromptSubmit","session_id":"retention","turn_id":"turn","cwd":"/tmp/work","model":"gpt-parent"}'
hook '{"hook_event_name":"Stop","session_id":"retention","turn_id":"turn","cwd":"/tmp/work","model":"gpt-parent"}' >/dev/null
[[ ! -e "$CODEX_HOME/codex-flow/telemetry/runs/old.json" ]]
[[ -e "$CODEX_HOME/codex-flow/telemetry/runs/recent.json" ]]
printf 'telemetry 30-day retention test passed\n'

# CLI list, show, and stats verification
list_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" list)"
[[ "$list_out" == *"FlowPilot Task Telemetry History"* ]]
[[ "$list_out" == *"work"* ]]

list_json="$(python3 "$ROOT_DIR/scripts/telemetry.py" list --json)"
python3 -c 'import json,sys; runs=json.load(sys.stdin); assert len(runs) >= 1, len(runs)' <<<"$list_json"

show_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" show 1)"
[[ "$show_out" == *"FlowPilot Telemetry Summary"* ]]

show_json="$(python3 "$ROOT_DIR/scripts/telemetry.py" show 1 --json)"
python3 -c 'import json,sys; r=json.load(sys.stdin); assert "parent" in r' <<<"$show_json"

stats_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" stats)"
[[ "$stats_out" == *"FlowPilot Telemetry Aggregation"* ]]
[[ "$stats_out" == *"Total Tasks:"* ]]

stats_json="$(python3 "$ROOT_DIR/scripts/telemetry.py" stats --project work --json)"
python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["project_filter"] == "work" and s["total_runs"] >= 1' <<<"$stats_json"
printf 'telemetry CLI query and project stats tests passed\n'

# -------------------------------------------------------------
# Telemetry repair and backfill test suite (cases 1-5 + idempotency)
# -------------------------------------------------------------
python3 - "$ROOT_DIR" "$TMP" <<'PY'
import json, os, sys
from pathlib import Path
root_dir, tmp = sys.argv[1:3]
sys.path.insert(0, os.path.join(root_dir, "scripts"))
from telemetry_core import repair_run, repair_history

transcript_path = os.path.join(tmp, "sample_transcript.jsonl")
with open(transcript_path, "w", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": 1000,
        "type": "response_item",
        "payload": {
            "type": "custom_tool_call",
            "name": "mcp__github_search",
            "input": "skills/my-skill cmd: search",
            "call_id": "c1",
        }
    }) + "\n")
    f.write(json.dumps({
        "timestamp": 1050,
        "type": "event_msg",
        "payload": {
            "type": "item_completed",
            "item": {
                "type": "CommandExecution",
                "exit_code": 0,
                "stdout": "success",
            }
        }
    }) + "\n")
    f.write(json.dumps({
        "timestamp": 1100,
        "type": "response_item",
        "payload": {
            "type": "message",
            "role": "user",
            "content": [{"text": "<USER_REQUEST>Fix bug</USER_REQUEST>"}]
        }
    }) + "\n")
    f.write(json.dumps({
        "timestamp": 1200,
        "type": "response_item",
        "payload": {
            "type": "message",
            "role": "assistant",
            "content": [{"text": "Bug fixed successfully."}]
        }
    }) + "\n")

# Case 1: Old run missing tools/trajectory/logs + transcript exists -> backfilled
run1 = {
    "session_id": "sess-1",
    "turn_id": "turn-1",
    "transcript_path": transcript_path,
}
rep1 = {}
repaired1 = repair_run(run1, report=rep1)
assert run1["skills_used"] == [{"name": "my-skill", "count": 1}], run1.get("skills_used")
assert len(run1["tools_used"]) == 1 and run1["tools_used"][0]["name"] == "mcp__github_search"
assert len(run1["trajectory"]) == 1 and run1["trajectory"][0]["name"] == "mcp__github_search"
assert len(run1["logs"]) >= 1
assert run1["summary_info"]["goal"] == "Fix bug"
assert run1["summary_info"]["conclusion"] == "Bug fixed successfully."
assert rep1["task_summaries_restored"] is True
assert rep1["skills_tools_restored"] is True
assert rep1["trajectories_restored"] is True
assert rep1["logs_restored"] is True

# Case 2: Old run already has these fields -> does not overwrite
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
assert run2["skills_used"] == [{"name": "existing-skill", "count": 5}]
assert run2["tools_used"] == [{"name": "existing-tool", "count": 3}]
assert run2["trajectory"] == [{"type": "existing_step"}]
assert run2["logs"] == [{"message": "existing log"}]
assert run2["summary_info"]["goal"] == "existing goal"
assert run2["summary_info"]["conclusion"] == "existing conclusion"
assert rep2["task_summaries_restored"] is False
assert rep2["skills_tools_restored"] is False
assert rep2["trajectories_restored"] is False
assert rep2["logs_restored"] is False

# Case 3: transcript_path does not exist -> safely skip transcript insights
run3 = {
    "session_id": "sess-3",
    "turn_id": "turn-3",
    "transcript_path": os.path.join(tmp, "nonexistent.jsonl"),
}
rep3 = {}
repair_run(run3, report=rep3)
assert "skills_used" not in run3
assert "tools_used" not in run3
assert "trajectory" not in run3
assert rep3["transcript_missing"] is True

# Case 4: quota_before + quota_after exist but delta missing -> backfill quota_change_during_run
run4 = {
    "quota_before": [{"window_duration_mins": 300, "used_percent": 10}],
    "quota_after": [{"window_duration_mins": 300, "used_percent": 15}],
}
rep4 = {}
repair_run(run4, report=rep4)
assert run4.get("quota_change_during_run") is not None
assert run4["quota_change_during_run"][0]["delta_percentage_points"] == 5
assert rep4["quota_deltas_restored"] is True
assert rep4["quota_deltas_impossible"] is False

# Case 5: Only quota_after -> do not generate delta
run5 = {
    "quota_after": [{"window_duration_mins": 300, "used_percent": 15}],
}
rep5 = {}
repair_run(run5, report=rep5)
assert "quota_change_during_run" not in run5
assert rep5["quota_deltas_restored"] is False
assert rep5["quota_deltas_impossible"] is True
PY
printf 'telemetry repair unit cases 1-5 passed\n'

# Set up test runs in isolated CODEX_HOME
REPAIR_TMP="$(mktemp -d)"
export CODEX_HOME="$REPAIR_TMP/.codex"
mkdir -p "$CODEX_HOME/codex-flow/telemetry/runs"
TRANSCRIPT="$REPAIR_TMP/test_transcript.jsonl"
cat > "$TRANSCRIPT" <<'EOF'
{"timestamp":1,"type":"response_item","payload":{"type":"custom_tool_call","name":"tool_a","input":"skills/test_skill","call_id":"c1"}}
{"timestamp":2,"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"<USER_REQUEST>Test prompt</USER_REQUEST>"}]}}
{"timestamp":3,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"Test conclusion."}]}}
EOF

# Run A: needs transcript insights and quota delta
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

# Run B: matches last.json, only quota_after (delta impossible)
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

# 1. Test dry-run: prints stats, does NOT write to disk
dry_run_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" repair --dry-run)"
[[ "$dry_run_out" == *"Telemetry repair complete"* ]]
[[ "$dry_run_out" == *"repaired:                2"* ]]
python3 -c "import json, sys; d=json.load(open('$CODEX_HOME/codex-flow/telemetry/runs/sess-a--turn-1.json')); assert 'skills_used' not in d"

# 2. Test repair: writes to disk and updates last.json for matching session/turn
repair_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" repair)"
[[ "$repair_out" == *"Telemetry repair complete"* ]]
[[ "$repair_out" == *"repaired:                2"* ]]
[[ "$repair_out" == *"quota deltas restored:    1"* ]]
[[ "$repair_out" == *"quota deltas impossible: 1"* ]]
python3 -c "import json, sys; d=json.load(open('$CODEX_HOME/codex-flow/telemetry/runs/sess-a--turn-1.json')); assert d['skills_used'] == [{'name': 'test_skill', 'count': 1}]; assert d['quota_change_during_run'][0]['delta_percentage_points'] == 5"
python3 -c "import json, sys; last=json.load(open('$CODEX_HOME/codex-flow/telemetry/last.json')); assert last['skills_used'] == [{'name': 'test_skill', 'count': 1}]"

# 3. Test idempotency: repeat repair --dry-run must report repaired: 0
repeat_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" repair --dry-run)"
[[ "$repeat_out" == *"repaired:                0"* ]]
[[ "$repeat_out" == *"unchanged:               2"* ]]

# 4. Test JSON output
repair_json="$(python3 "$ROOT_DIR/scripts/telemetry.py" repair --json)"
python3 -c "import json, sys; d=json.load(sys.stdin); assert d['repaired'] == 0; assert d['scanned'] == 2; assert d['unchanged'] == 2" <<<"$repair_json"

# 5. Test CLI command via bin/codex-flow
cli_out="$(bash "$ROOT_DIR/bin/codex-flow" telemetry repair --dry-run)"
[[ "$cli_out" == *"Telemetry repair complete"* ]]
[[ "$cli_out" == *"repaired:                0"* ]]

rm -rf "$REPAIR_TMP"
printf 'telemetry repair CLI and idempotency tests passed\n'

