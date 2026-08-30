#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"
POLICY="$CODEX_HOME/codex-flow.toml"
DEFAULTS="$ROOT_DIR/policy/defaults.toml"
STAMP="$(date +%Y%m%d-%H%M%S)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

# Read release-time recommendations. The workflow itself never depends on these
# exact slugs; `auto` resolves to the current recommendation shipped by codex-flow.
eval "$(python3 - "$DEFAULTS" <<'PY'
import sys, tomllib
p = tomllib.load(open(sys.argv[1], 'rb'))
print(f'DEFAULT_WORKER_MODEL={p["models"]["worker_model"]!r}')
print(f'DEFAULT_PARENT_POLICY={p["models"]["parent_policy"]!r}')
print(f'DEFAULT_PARENT_MIN_MODEL={p["models"]["parent_min_model"]!r}')
print(f'DEFAULT_MAX_THREADS={str(p["runtime"]["max_concurrent_threads"])!r}')
print(f'DEFAULT_MAX_REPAIRS={str(p["runtime"]["max_repair_cycles"])!r}')
PY
)"

PARENT_MODEL_POLICY="${CODEX_FLOW_PARENT_MODEL_POLICY:-$DEFAULT_PARENT_POLICY}"
PARENT_MIN_MODEL="${CODEX_FLOW_PARENT_MIN_MODEL:-$DEFAULT_PARENT_MIN_MODEL}"
PARENT_MIN_EFFORT="${CODEX_FLOW_PARENT_MIN_EFFORT:-high}"
WORKER_MODEL_POLICY="${CODEX_FLOW_WORKER_MODEL_POLICY:-latest-efficient}"
WORKER_MODEL_REQUESTED="${CODEX_FLOW_WORKER_MODEL:-auto}"
WORKER_MODEL="$WORKER_MODEL_REQUESTED"
[[ "$WORKER_MODEL" == "auto" ]] && WORKER_MODEL="$DEFAULT_WORKER_MODEL"
WORKER_MIN_EFFORT="${CODEX_FLOW_WORKER_MIN_EFFORT:-high}"
MAX_THREADS="${CODEX_FLOW_MAX_THREADS:-$DEFAULT_MAX_THREADS}"
MAX_REPAIRS="${CODEX_FLOW_MAX_REPAIR_CYCLES:-$DEFAULT_MAX_REPAIRS}"

case "$PARENT_MIN_EFFORT" in high|xhigh|max) ;; *) echo "parent minimum effort must be high, xhigh, or max" >&2; exit 2 ;; esac
case "$WORKER_MIN_EFFORT" in high|xhigh|max) ;; *) echo "worker minimum effort must be high, xhigh, or max" >&2; exit 2 ;; esac

mkdir -p "$CODEX_HOME/agents" "$CODEX_HOME/skills/cost-aware-development"

if [[ -f "$CONFIG" ]]; then
  cp "$CONFIG" "$CONFIG.codex-flow.$STAMP.bak"
else
  touch "$CONFIG"
fi

# Keep a stable, economical baseline in Codex config. The Skill may request
# xhigh/max for a specific child when the current runtime supports per-spawn
# overrides; otherwise this high baseline remains safe and predictable.
python3 - "$CONFIG" "$WORKER_MODEL" "$WORKER_MIN_EFFORT" "$MAX_THREADS" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
worker_model, worker_effort, max_threads = sys.argv[2:5]
text = path.read_text() if path.exists() else ""
managed = {
    "enabled": "true",
    "max_concurrent_threads_per_session": max_threads,
    "default_subagent_model": f'"{worker_model}"',
    "default_subagent_reasoning_effort": f'"{worker_effort}"',
}
section_re = re.compile(r"(?ms)^\[agents\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)")
m = section_re.search(text)
if m:
    body = m.group(1)
    for key, value in managed.items():
        rx = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
        line = f"{key} = {value}"
        if rx.search(body): body = rx.sub(line, body)
        else:
            if body and not body.endswith("\n"): body += "\n"
            body += line + "\n"
    text = text[:m.start(1)] + body + text[m.end(1):]
else:
    if text and not text.endswith("\n"): text += "\n"
    if text and not text.endswith("\n\n"): text += "\n"
    text += "[agents]\n" + "".join(f"{k} = {v}\n" for k, v in managed.items())
path.write_text(text)
PY

cat > "$POLICY" <<EOF
schema_version = 2

[parent]
model_policy = "$PARENT_MODEL_POLICY"
min_model = "$PARENT_MIN_MODEL"
min_reasoning_effort = "$PARENT_MIN_EFFORT"
reasoning_policy = "adaptive"
routine_effort = "$PARENT_MIN_EFFORT"
complex_effort = "xhigh"
critical_effort = "max"

[worker]
model_policy = "$WORKER_MODEL_POLICY"
model = "$WORKER_MODEL_REQUESTED"
resolved_model = "$WORKER_MODEL"
min_reasoning_effort = "$WORKER_MIN_EFFORT"
reasoning_policy = "adaptive"
routine_effort = "$WORKER_MIN_EFFORT"
complex_effort = "xhigh"
critical_effort = "max"

[runtime]
max_concurrent_threads = $MAX_THREADS
max_repair_cycles = $MAX_REPAIRS
EOF

cp "$ROOT_DIR/templates/agents/worker-explorer.toml" "$CODEX_HOME/agents/worker-explorer.toml"
cp "$ROOT_DIR/templates/agents/worker-implementer.toml" "$CODEX_HOME/agents/worker-implementer.toml"
cp "$ROOT_DIR/templates/skills/cost-aware-development/SKILL.md" "$CODEX_HOME/skills/cost-aware-development/SKILL.md"
rm -f "$CODEX_HOME/agents/luna-explorer.toml" "$CODEX_HOME/agents/luna-implementer.toml"

cat <<EOF
codex-flow installed.

  config: $CONFIG
  policy: $POLICY
  parent: $PARENT_MODEL_POLICY / min=$PARENT_MIN_MODEL / reasoning >= $PARENT_MIN_EFFORT
  worker: $WORKER_MODEL_POLICY / requested=$WORKER_MODEL_REQUESTED / resolved=$WORKER_MODEL / reasoning >= $WORKER_MIN_EFFORT

Adaptive effort: high baseline -> xhigh for complex work -> max only for critical quality-first work.
Restart Codex, then use it normally.
Run: bash $ROOT_DIR/scripts/doctor
EOF
