#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CODEX_HOME="$TMP/.codex"
export FAKE_COUNTER="$TMP/counter"
export CODEX_FLOW_TELEMETRY_STDOUT=1

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
summary="$(hook '{"hook_event_name":"Stop","session_id":"parent-1","turn_id":"turn-1","cwd":"/tmp/work","model":"gpt-parent","last_assistant_message":"done"}')"
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
