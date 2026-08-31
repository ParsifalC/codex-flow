#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CODEX_HOME="$TMP/.codex"
export FAKE_COUNTER="$TMP/counter"

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
    elif method=="account/usage/read":
        tid=(msg.get("params") or {}).get("threadId")
        if tid=="parent-1":
            tokens=1000 if n==1 else 2500
            credits=1_000_000 if n==1 else 3_000_000
        else:
            tokens=800; credits=1_000_000
        result={"summary":{},"dailyUsageBuckets":None,"threadUsage":{"threadId":tid,"estimatedUsageCreditsMicros":credits,"estimatedUsageUsdMicros":None,"groups":[{"model":"gpt-test","reasoningEffort":"high","speed":"standard","estimatedUsageCreditsMicros":credits,"netNewInputTokens":tokens//2,"cachedInputTokens":tokens//4,"inputTokens":tokens*3//4,"outputTokens":tokens//4,"totalTokens":tokens}]}}
    else: result={}
    print(json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":result}), flush=True)
PY
chmod +x "$TMP/fake-app-server.py"
export CODEX_FLOW_APP_SERVER_COMMAND="python3 $TMP/fake-app-server.py"

hook() { printf '%s' "$1" | python3 "$ROOT_DIR/scripts/telemetry.py"; }
hook '{"hook_event_name":"UserPromptSubmit","session_id":"parent-1","turn_id":"turn-1","cwd":"/tmp/work","model":"gpt-parent","prompt":"do work"}'
hook '{"hook_event_name":"SubagentStart","session_id":"parent-1","turn_id":"turn-1","cwd":"/tmp/work","model":"gpt-worker","agent_id":"worker-1","agent_type":"worker-implementer"}'
hook '{"hook_event_name":"SubagentStop","session_id":"parent-1","turn_id":"turn-1","cwd":"/tmp/work","model":"gpt-worker","agent_id":"worker-1","agent_type":"worker-implementer"}'
summary_json="$(hook '{"hook_event_name":"Stop","session_id":"parent-1","turn_id":"turn-1","cwd":"/tmp/work","model":"gpt-parent","last_assistant_message":"done"}')"
summary="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["systemMessage"], end="")' <<<"$summary_json")"
python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin)["systemMessage"], str)' <<<"$summary_json"
printf '%s\n' "$summary"
[[ "$summary" == *"FlowPilot summary"* ]]
[[ "$summary" == *"1 parent + 1 worker"* ]]
[[ "$summary" == *"worker-implementer"* ]]
[[ "$summary" == *"2.3k tokens"* ]]
[[ "$summary" == *"3.000 credits"* ]]
[[ "$summary" == *"5h 31%→34% (+3 pp)"* ]]
[[ "$summary" == *"7d 18%→19% (+1 pp)"* ]]

last="$(python3 "$ROOT_DIR/scripts/telemetry.py" last)"
[[ "$last" == *"2.3k tokens"* ]]
json_out="$(python3 "$ROOT_DIR/scripts/telemetry.py" last --json)"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["workers"]["worker-1"]["status"] == "completed"; assert d["parent"]["usage_delta"]["total_tokens"] == 1500' <<<"$json_out"

printf 'telemetry test passed\n'

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
assert "parent        gpt-parent  n/a tokens" in summary, summary
assert "worker        worker-implementer  gpt-worker  n/a tokens" in summary, summary
assert "attributed    n/a tokens" in summary, summary
assert "attributed    0 tokens" not in summary, summary
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
assert "parent        gpt-parent  12 tokens" in summary, summary
assert "attributed    n/a tokens" in summary, summary
assert "attributed    12 tokens" not in summary, summary

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
assert "parent        gpt-parent  0 tokens" in summary, summary
assert "worker        worker-implementer  gpt-worker  0 tokens" in summary, summary
assert "attributed    0 tokens" in summary, summary
assert "0.000 credits" in summary, summary
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
