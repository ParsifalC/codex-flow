#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"
POLICY="$CODEX_HOME/codex-flow.toml"
HOOKS="$CODEX_HOME/hooks.json"
DEFAULTS="$ROOT_DIR/policy/defaults.toml"
STATE_DIR="$CODEX_HOME/codex-flow"
BIN_DIR="${CODEX_FLOW_BIN_DIR:-$HOME/.local/bin}"
SHELL_VALUE="${CODEX_FLOW_SHELL:-${SHELL:-}}"
SHELL_NAME="${SHELL_VALUE##*/}"
SHELL_CONFIG_DIR="${CODEX_FLOW_SHELL_CONFIG_DIR:-$HOME}"
STAMP="$(date +%Y%m%d-%H%M%S)"
VERSION="$(cat "$ROOT_DIR/VERSION" 2>/dev/null || echo dev)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

read_toml_value() {
  local section="$1" key="$2" file="$3"
  awk -v section="[$section]" -v key="$key" '
    $0 == section { in_section=1; next }
    /^\[/ { in_section=0 }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      value=$0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
      print value
      found=1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

read_default() {
  local section="$1" key="$2" value
  if ! value="$(read_toml_value "$section" "$key" "$DEFAULTS")" || [[ -z "$value" ]]; then
    printf 'missing [%s].%s in %s\n' "$section" "$key" "$DEFAULTS" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}

DEFAULT_WORKER_MODEL="$(read_default models worker_model)"
DEFAULT_PARENT_POLICY="$(read_default models parent_policy)"
DEFAULT_PARENT_MIN_MODEL="$(read_default models parent_min_model)"
DEFAULT_MAX_THREADS="$(read_default runtime max_concurrent_threads)"
DEFAULT_MAX_REPAIRS="$(read_default runtime max_repair_cycles)"

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
TELEMETRY_ENABLED="${CODEX_FLOW_TELEMETRY_ENABLED:-true}"

case "$PARENT_MIN_EFFORT" in high|xhigh|max) ;; *) echo "parent minimum effort must be high, xhigh, or max" >&2; exit 2 ;; esac
case "$WORKER_MIN_EFFORT" in high|xhigh|max) ;; *) echo "worker minimum effort must be high, xhigh, or max" >&2; exit 2 ;; esac
case "$TELEMETRY_ENABLED" in true|false) ;; *) echo "CODEX_FLOW_TELEMETRY_ENABLED must be true or false" >&2; exit 2 ;; esac

mkdir -p "$CODEX_HOME/agents" "$CODEX_HOME/skills/flow-pilot" "$STATE_DIR" "$BIN_DIR"

if [[ -f "$CONFIG" ]]; then
  cp "$CONFIG" "$CONFIG.codex-flow.$STAMP.bak"
else
  touch "$CONFIG"
fi

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
schema_version = 3

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

[telemetry]
enabled = $TELEMETRY_ENABLED
summary = true
source = "hooks+app-server"
EOF

cp "$ROOT_DIR/templates/agents/worker-explorer.toml" "$CODEX_HOME/agents/worker-explorer.toml"
cp "$ROOT_DIR/templates/agents/worker-implementer.toml" "$CODEX_HOME/agents/worker-implementer.toml"
cp "$ROOT_DIR/templates/skills/flow-pilot/SKILL.md" "$CODEX_HOME/skills/flow-pilot/SKILL.md"
rm -rf "$CODEX_HOME/skills/cost-aware-development"
rm -f "$CODEX_HOME/agents/luna-explorer.toml" "$CODEX_HOME/agents/luna-implementer.toml"

printf '%s\n' "$ROOT_DIR" > "$STATE_DIR/source"
printf '%s\n' "$VERSION" > "$STATE_DIR/version"
cp "$ROOT_DIR/bin/codex-flow" "$BIN_DIR/codex-flow"
chmod +x "$BIN_DIR/codex-flow"
cp "$ROOT_DIR/scripts/telemetry.py" "$STATE_DIR/telemetry.py"
cp "$ROOT_DIR/scripts/manage-hooks.py" "$STATE_DIR/manage-hooks.py"
chmod +x "$STATE_DIR/telemetry.py" "$STATE_DIR/manage-hooks.py"

if [[ "$TELEMETRY_ENABLED" == "true" ]]; then
  python3 "$STATE_DIR/manage-hooks.py" install --hooks "$HOOKS" --script "$STATE_DIR/telemetry.py"
else
  python3 "$STATE_DIR/manage-hooks.py" uninstall --hooks "$HOOKS"
fi

if [[ "$SHELL_NAME" == "bash" || "$SHELL_NAME" == "zsh" ]]; then
  mkdir -p "$STATE_DIR/shell"
  cp "$ROOT_DIR/scripts/manage-shell.py" "$STATE_DIR/shell/manage-shell.py"
  cp "$ROOT_DIR/completions/codex-flow.$SHELL_NAME" "$STATE_DIR/shell/codex-flow.$SHELL_NAME"
  python3 "$STATE_DIR/shell/manage-shell.py" install --state-dir "$STATE_DIR" --shell "$SHELL_NAME" --config-dir "$SHELL_CONFIG_DIR" --bin-dir "$BIN_DIR"
fi

cat <<EOF
codex-flow $VERSION installed.

  config:    $CONFIG
  policy:    $POLICY
  cli:       $BIN_DIR/codex-flow
  skill:     FlowPilot (flow-pilot)
  parent:    $PARENT_MODEL_POLICY / min=$PARENT_MIN_MODEL / reasoning >= $PARENT_MIN_EFFORT
  worker:    $WORKER_MODEL_POLICY / requested=$WORKER_MODEL_REQUESTED / resolved=$WORKER_MODEL / reasoning >= $WORKER_MIN_EFFORT
  telemetry: $TELEMETRY_ENABLED (deterministic hooks + app-server; no model call)

Adaptive effort: high baseline -> xhigh for complex work -> max only for critical quality-first work.
Restart Codex, then use it normally.
EOF

if [[ "$TELEMETRY_ENABLED" == "true" ]]; then
  printf '\nCodex may ask once to trust the new command hooks. If prompted, review/approve them with /hooks.\n'
fi

if [[ "$SHELL_NAME" == "bash" || "$SHELL_NAME" == "zsh" ]]; then
  printf '\nShell integration installed for %s.\n' "$SHELL_NAME"
  printf 'Activate completion in this terminal now:\n  source %q\n' "$SHELL_CONFIG_DIR/.${SHELL_NAME}rc"
  printf 'Or open a new terminal.\n'
else
  case ":${PATH}:" in
    *":$BIN_DIR:"*) printf 'Run: codex-flow status\n' ;;
    *) printf 'Add %s to PATH to use: codex-flow status\n' "$BIN_DIR" ;;
  esac
fi
