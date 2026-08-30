#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"
POLICY="$CODEX_HOME/codex-flow.toml"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Policy defaults. Override any of these at install time.
PARENT_MODEL_POLICY="${CODEX_FLOW_PARENT_MODEL_POLICY:-latest-capable}"
PARENT_MIN_MODEL="${CODEX_FLOW_PARENT_MIN_MODEL:-auto}"
PARENT_MIN_EFFORT="${CODEX_FLOW_PARENT_MIN_EFFORT:-high}"
WORKER_MODEL="${CODEX_FLOW_WORKER_MODEL:-gpt-5.6-luna}"
WORKER_EFFORT="${CODEX_FLOW_WORKER_EFFORT:-high}"
MAX_THREADS="${CODEX_FLOW_MAX_THREADS:-4}"

mkdir -p "$CODEX_HOME/agents" "$CODEX_HOME/skills/cost-aware-development"

if [[ -f "$CONFIG" ]]; then
  cp "$CONFIG" "$CONFIG.codex-flow.$STAMP.bak"
else
  touch "$CONFIG"
fi

python3 - "$CONFIG" "$WORKER_MODEL" "$WORKER_EFFORT" "$MAX_THREADS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
worker_model, worker_effort, max_threads = sys.argv[2:5]
text = path.read_text() if path.exists() else ""
managed = {
    "enabled": "true",
    "max_concurrent_threads_per_session": max_threads,
    "default_subagent_model": repr(worker_model).replace("'", '"'),
    "default_subagent_reasoning_effort": repr(worker_effort).replace("'", '"'),
}
section_re = re.compile(r"(?ms)^\[agents\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)")
match = section_re.search(text)
if match:
    body = match.group(1)
    for key, value in managed.items():
        key_re = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
        line = f"{key} = {value}"
        if key_re.search(body):
            body = key_re.sub(line, body)
        else:
            if body and not body.endswith("\n"):
                body += "\n"
            body += line + "\n"
    text = text[:match.start(1)] + body + text[match.end(1):]
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += "[agents]\n"
    for key, value in managed.items():
        text += f"{key} = {value}\n"
path.write_text(text)
PY

cat > "$POLICY" <<EOF
[parent]
model_policy = "$PARENT_MODEL_POLICY"
min_model = "$PARENT_MIN_MODEL"
min_reasoning_effort = "$PARENT_MIN_EFFORT"

[worker]
model = "$WORKER_MODEL"
reasoning_effort = "$WORKER_EFFORT"

[runtime]
max_concurrent_threads = $MAX_THREADS
EOF

cp "$ROOT_DIR/templates/agents/worker-explorer.toml" "$CODEX_HOME/agents/worker-explorer.toml"
cp "$ROOT_DIR/templates/agents/worker-implementer.toml" "$CODEX_HOME/agents/worker-implementer.toml"
cp "$ROOT_DIR/templates/skills/cost-aware-development/SKILL.md" "$CODEX_HOME/skills/cost-aware-development/SKILL.md"
rm -f "$CODEX_HOME/agents/luna-explorer.toml" "$CODEX_HOME/agents/luna-implementer.toml"

cat <<EOF
codex-flow installed.

  config: $CONFIG
  policy: $POLICY
  agents: $CODEX_HOME/agents
  skill:  $CODEX_HOME/skills/cost-aware-development

Parent policy: $PARENT_MODEL_POLICY, minimum model: $PARENT_MIN_MODEL, reasoning >= $PARENT_MIN_EFFORT
Worker: $WORKER_MODEL / $WORKER_EFFORT

Restart Codex, then use it normally.
Run: bash $ROOT_DIR/scripts/doctor
EOF
