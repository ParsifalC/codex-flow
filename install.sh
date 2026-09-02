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
LOCALIZATION="$ROOT_DIR/scripts/localization.py"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

read_toml_value() {
  local section="$1" key="$2" file="$3"
  awk -v section="[$section]" -v key="$key" '
    $0 == section { in_section=1; next }
    /^\[/ { in_section=0 }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
      print value; found=1; exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}
read_default() {
  local section="$1" key="$2" value
  if ! value="$(read_toml_value "$section" "$key" "$DEFAULTS")" || [[ -z "$value" ]]; then
    printf 'missing [%s].%s in %s\n' "$section" "$key" "$DEFAULTS" >&2; exit 1
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
WORKER_MODEL="$WORKER_MODEL_REQUESTED"; [[ "$WORKER_MODEL" == "auto" ]] && WORKER_MODEL="$DEFAULT_WORKER_MODEL"
WORKER_MIN_EFFORT="${CODEX_FLOW_WORKER_MIN_EFFORT:-high}"
MAX_THREADS="${CODEX_FLOW_MAX_THREADS:-$DEFAULT_MAX_THREADS}"
MAX_REPAIRS="${CODEX_FLOW_MAX_REPAIR_CYCLES:-$DEFAULT_MAX_REPAIRS}"
TELEMETRY_ENABLED="${CODEX_FLOW_TELEMETRY_ENABLED:-true}"
TELEMETRY_NOTIFICATIONS="${CODEX_FLOW_TELEMETRY_NOTIFICATIONS:-true}"
TELEMETRY_RETENTION_DAYS="${CODEX_FLOW_TELEMETRY_RETENTION_DAYS:-30}"
UI_LANGUAGE="auto"
if [[ -f "$POLICY" ]]; then UI_LANGUAGE="$(python3 "$LOCALIZATION" --policy "$POLICY" --configured 2>/dev/null || echo auto)"; fi
UI_LANGUAGE="$(python3 "$LOCALIZATION" --normalize "$UI_LANGUAGE")"

case "$PARENT_MIN_EFFORT" in high|xhigh|max) ;; *) echo "parent minimum effort must be high, xhigh, or max" >&2; exit 2 ;; esac
case "$WORKER_MIN_EFFORT" in high|xhigh|max) ;; *) echo "worker minimum effort must be high, xhigh, or max" >&2; exit 2 ;; esac
case "$TELEMETRY_ENABLED" in true|false) ;; *) echo "CODEX_FLOW_TELEMETRY_ENABLED must be true or false" >&2; exit 2 ;; esac
case "$TELEMETRY_NOTIFICATIONS" in true|false) ;; *) echo "CODEX_FLOW_TELEMETRY_NOTIFICATIONS must be true or false" >&2; exit 2 ;; esac
[[ "$TELEMETRY_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "CODEX_FLOW_TELEMETRY_RETENTION_DAYS must be a positive integer" >&2; exit 2; }

mkdir -p "$CODEX_HOME/agents" "$CODEX_HOME/skills/flow-pilot" "$STATE_DIR" "$BIN_DIR"
if [[ -f "$CONFIG" ]]; then cp "$CONFIG" "$CONFIG.codex-flow.$STAMP.bak"; else touch "$CONFIG"; fi

python3 - "$CONFIG" "$WORKER_MODEL" "$WORKER_MIN_EFFORT" "$MAX_THREADS" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1]); worker_model, worker_effort, max_threads = sys.argv[2:5]
text = path.read_text() if path.exists() else ""
managed = {"enabled":"true","max_concurrent_threads_per_session":max_threads,"default_subagent_model":f'"{worker_model}"',"default_subagent_reasoning_effort":f'"{worker_effort}"'}
section_re = re.compile(r"(?ms)^\[agents\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)")
m = section_re.search(text)
if m:
    body=m.group(1)
    for key,value in managed.items():
        rx=re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$"); line=f"{key} = {value}"
        if rx.search(body): body=rx.sub(line,body)
        else:
            if body and not body.endswith("\n"): body += "\n"
            body += line + "\n"
    text=text[:m.start(1)] + body + text[m.end(1):]
else:
    if text and not text.endswith("\n"): text += "\n"
    if text and not text.endswith("\n\n"): text += "\n"
    text += "[agents]\n" + "".join(f"{k} = {v}\n" for k,v in managed.items())
path.write_text(text)
PY

cat > "$POLICY" <<EOF
schema_version = 3

[ui]
language = "$UI_LANGUAGE"

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
notifications = $TELEMETRY_NOTIFICATIONS
retention_days = $TELEMETRY_RETENTION_DAYS
source = "hooks+app-server"
EOF

cp "$ROOT_DIR/templates/agents/worker-explorer.toml" "$CODEX_HOME/agents/worker-explorer.toml"
cp "$ROOT_DIR/templates/agents/worker-implementer.toml" "$CODEX_HOME/agents/worker-implementer.toml"
cp "$ROOT_DIR/templates/skills/flow-pilot/SKILL.md" "$CODEX_HOME/skills/flow-pilot/SKILL.md"
rm -f "$CODEX_HOME/agents/luna-explorer.toml" "$CODEX_HOME/agents/luna-implementer.toml"

printf '%s\n' "$ROOT_DIR" > "$STATE_DIR/source"
printf '%s\n' "$VERSION" > "$STATE_DIR/version"
cp "$ROOT_DIR/bin/codex-flow" "$BIN_DIR/codex-flow"; chmod +x "$BIN_DIR/codex-flow"
for file in telemetry.py manage-hooks.py menu.py localization.py ui.py doctor.py; do cp "$ROOT_DIR/scripts/$file" "$STATE_DIR/$file"; done
rm -rf "$STATE_DIR/telemetry_core"
cp -r "$ROOT_DIR/scripts/telemetry_core" "$STATE_DIR/telemetry_core"
chmod +x "$STATE_DIR/telemetry.py" "$STATE_DIR/manage-hooks.py" "$STATE_DIR/menu.py" "$STATE_DIR/localization.py" "$STATE_DIR/ui.py" "$STATE_DIR/doctor.py"

if [[ "$TELEMETRY_ENABLED" == "true" ]]; then python3 "$STATE_DIR/manage-hooks.py" install --hooks "$HOOKS" --script "$STATE_DIR/telemetry.py"; else python3 "$STATE_DIR/manage-hooks.py" uninstall --hooks "$HOOKS"; fi

if [[ "$SHELL_NAME" == "bash" || "$SHELL_NAME" == "zsh" ]]; then
  mkdir -p "$STATE_DIR/shell"
  cp "$ROOT_DIR/scripts/manage-shell.py" "$STATE_DIR/shell/manage-shell.py"
  cp "$ROOT_DIR/completions/codex-flow.$SHELL_NAME" "$STATE_DIR/shell/codex-flow.$SHELL_NAME"
  python3 "$STATE_DIR/shell/manage-shell.py" install --state-dir "$STATE_DIR" --shell "$SHELL_NAME" --config-dir "$SHELL_CONFIG_DIR" --bin-dir "$BIN_DIR"
fi

if [[ "$(uname -s)" == "Darwin" && -d "$ROOT_DIR/apps/macos-overlay" ]]; then
  mkdir -p "$STATE_DIR/bin"
  [[ -f "$ROOT_DIR/apps/macos-overlay/bin/FlowPilot" ]] && { cp "$ROOT_DIR/apps/macos-overlay/bin/FlowPilot" "$STATE_DIR/bin/FlowPilot"; chmod +x "$STATE_DIR/bin/FlowPilot"; }
  [[ -f "$ROOT_DIR/apps/macos-overlay/bin/codex-flow-overlay" ]] && { cp "$ROOT_DIR/apps/macos-overlay/bin/codex-flow-overlay" "$STATE_DIR/bin/codex-flow-overlay"; chmod +x "$STATE_DIR/bin/codex-flow-overlay"; }
fi

UI_LANG="$(python3 "$LOCALIZATION" --policy "$POLICY" --resolved 2>/dev/null || echo en)"
cf_t() { if [[ "$UI_LANG" == "zh" ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
display_path() { local p="$1"; if [[ -n "${HOME:-}" && "$p" == "$HOME"* ]]; then printf '~%s' "${p#$HOME}"; else printf '%s' "$p"; fi; }
disp_policy="$(display_path "$POLICY")"; disp_cli="$(display_path "$BIN_DIR/codex-flow")"; disp_shell_rc="$(display_path "$SHELL_CONFIG_DIR/.${SHELL_NAME}rc")"

printf '\n🚀 %s\n\n' "$(cf_t "codex-flow v$VERSION installed successfully" "codex-flow v$VERSION 安装成功")"
printf '  ╭─ %s ──────────────────────────────────────────────────────────╮\n' "$(cf_t 'Summary' '安装摘要')"
printf '  │  • %s: %s\n' "$(cf_t 'Policy' '策略')" "$disp_policy"
printf '  │  • CLI: %s\n' "$disp_cli"
printf '  │  • Skill: FlowPilot (flow-pilot)\n'
printf '  │  • %s: parent (%s) -> worker (%s)\n' "$(cf_t 'Routing' '路由')" "$PARENT_MODEL_POLICY" "$WORKER_MODEL"
printf '  │  • %s: %s (%s: %s)\n' "$(cf_t 'Language' '语言')" "$UI_LANGUAGE" "$(cf_t 'configured' '配置')" "$UI_LANG"
if [[ "$TELEMETRY_ENABLED" == "true" ]]; then printf '  │  • Telemetry: ● enabled (%sd retention)\n' "$TELEMETRY_RETENTION_DAYS"; else printf '  │  • Telemetry: ○ disabled\n'; fi
printf '  ╰────────────────────────────────────────────────────────────────────╯\n\n'

if [[ "$UI_LANG" == "zh" ]]; then
  printf '  ┌─ ⚠️  必须完成的后续步骤 ───────────────────────────────────────────┐\n'
  if [[ "$SHELL_NAME" == "bash" || "$SHELL_NAME" == "zsh" ]]; then
    printf '  │  [1/3] Shell 补全：执行 source %s（或打开新终端）\n' "$disp_shell_rc"
  else
    printf '  │  [1/3] PATH：确保 %s 所在目录已加入 PATH\n' "$disp_cli"
  fi
  printf '  │  [2/3] 完整重启 Codex：完全退出后重新启动，仅新建任务不够。\n'
  if [[ "$TELEMETRY_ENABLED" == "true" ]]; then
    printf '  │  [3/3] 授权 Hooks：在 Codex 中运行 /hooks，并批准 FlowPilot telemetry。\n'
  else
    printf '  │  [3/3] Hooks：遥测已关闭，无需进行 hook 授权。\n'
  fi
  printf '  └────────────────────────────────────────────────────────────────────┘\n\n'
else
  printf '  ┌─ ⚠️  REQUIRED NEXT STEPS ───────────────────────────────────────────┐\n'
  if [[ "$SHELL_NAME" == "bash" || "$SHELL_NAME" == "zsh" ]]; then
    printf '  │  [1/3] Shell Completion\n'
    printf '  │        Run: source %s (or open a new terminal)\n' "$disp_shell_rc"
  else
    printf '  │  [1/3] PATH Configuration\n'
    printf '  │        Add %s to PATH to run codex-flow status\n' "${disp_cli%/*}"
  fi
  printf '  │  [2/3] Complete Codex Restart\n'
  printf '  │        Fully quit Codex and relaunch it. Starting a new task\n'
  printf '  │        alone is NOT enough to load new hooks and snapshots.\n'
  if [[ "$TELEMETRY_ENABLED" == "true" ]]; then
    printf '  │  [3/3] Authorize Hooks\n'
    printf '  │        Run /hooks in Codex and approve FlowPilot telemetry if it is pending approval.\n'
  else
    printf '  │  [3/3] Hooks Status\n'
    printf '  │        Telemetry is disabled: no hook authorization is required.\n'
  fi
  printf '  └────────────────────────────────────────────────────────────────────┘\n\n'
fi
