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
policy_or_default() {
  local section="$1" key="$2" fallback="$3" value=""
  if [[ -f "$POLICY" ]]; then
    value="$(read_toml_value "$section" "$key" "$POLICY" 2>/dev/null || true)"
  fi
  printf '%s\n' "${value:-$fallback}"
}

DEFAULT_WORKER_MODEL="$(read_default models worker_model)"
DEFAULT_WORKER_POLICY="$(read_default models worker_policy)"
DEFAULT_PARENT_POLICY="$(read_default models parent_policy)"
DEFAULT_PARENT_MIN_MODEL="$(read_default models parent_min_model)"
DEFAULT_STRATEGY_ENABLED="$(read_default strategy enabled)"
DEFAULT_STRATEGY="$(read_default strategy profile)"
DEFAULT_ROUTING_MODE="$(read_default routing mode)"
DEFAULT_REVIEW_MODIFIER="$(read_default modifiers review)"
DEFAULT_FANOUT_MODIFIER="$(read_default modifiers fanout)"
DEFAULT_PARENT_MIN_EFFORT="$(read_default reasoning.parent minimum)"
DEFAULT_PARENT_ROUTINE_EFFORT="$(read_default reasoning.parent routine)"
DEFAULT_PARENT_COMPLEX_EFFORT="$(read_default reasoning.parent complex)"
DEFAULT_PARENT_CRITICAL_EFFORT="$(read_default reasoning.parent critical)"
DEFAULT_WORKER_MIN_EFFORT="$(read_default reasoning.worker minimum)"
DEFAULT_WORKER_ROUTINE_EFFORT="$(read_default reasoning.worker routine)"
DEFAULT_WORKER_COMPLEX_EFFORT="$(read_default reasoning.worker complex)"
DEFAULT_WORKER_CRITICAL_EFFORT="$(read_default reasoning.worker critical)"
DEFAULT_ROLLOUT_MODE="$(read_default reasoning.rollout mode)"
DEFAULT_ROLLOUT_MINIMUM="$(read_default reasoning.rollout minimum)"
DEFAULT_ROLLOUT_ROUTINE="$(read_default reasoning.rollout routine)"
DEFAULT_ROLLOUT_COMPLEX="$(read_default reasoning.rollout complex)"
DEFAULT_ROLLOUT_CRITICAL="$(read_default reasoning.rollout critical)"
DEFAULT_MAX_THREADS="$(read_default runtime max_concurrent_threads)"
DEFAULT_MAX_REPAIRS="$(read_default runtime max_repair_cycles)"
DEFAULT_TELEMETRY_ENABLED="$(read_default telemetry enabled)"
DEFAULT_TELEMETRY_NOTIFICATIONS="$(read_default telemetry notifications)"
DEFAULT_TELEMETRY_RETENTION_DAYS="$(read_default telemetry retention_days)"

EXISTING_STRATEGY_ENABLED="$(policy_or_default strategy enabled "$DEFAULT_STRATEGY_ENABLED")"
EXISTING_STRATEGY="$(policy_or_default strategy profile "$DEFAULT_STRATEGY")"
EXISTING_ROUTING="$(policy_or_default routing mode "$DEFAULT_ROUTING_MODE")"
EXISTING_REVIEW="$(policy_or_default modifiers review "$DEFAULT_REVIEW_MODIFIER")"
EXISTING_FANOUT="$(policy_or_default modifiers fanout "$DEFAULT_FANOUT_MODIFIER")"
EXISTING_PARENT_POLICY="$(policy_or_default parent model_policy "$DEFAULT_PARENT_POLICY")"
EXISTING_PARENT_MIN_MODEL="$(policy_or_default parent min_model "$DEFAULT_PARENT_MIN_MODEL")"
EXISTING_PARENT_MIN_EFFORT="$(policy_or_default parent min_reasoning_effort "$DEFAULT_PARENT_MIN_EFFORT")"
EXISTING_PARENT_ROUTINE_EFFORT="$(policy_or_default parent routine_effort "$DEFAULT_PARENT_ROUTINE_EFFORT")"
EXISTING_PARENT_COMPLEX_EFFORT="$(policy_or_default parent complex_effort "$DEFAULT_PARENT_COMPLEX_EFFORT")"
EXISTING_PARENT_CRITICAL_EFFORT="$(policy_or_default parent critical_effort "$DEFAULT_PARENT_CRITICAL_EFFORT")"
EXISTING_WORKER_POLICY="$(policy_or_default worker model_policy "$DEFAULT_WORKER_POLICY")"
EXISTING_WORKER_MODEL="$(policy_or_default worker model auto)"
EXISTING_WORKER_MIN_EFFORT="$(policy_or_default worker min_reasoning_effort "$DEFAULT_WORKER_MIN_EFFORT")"
EXISTING_WORKER_ROUTINE_EFFORT="$(policy_or_default worker routine_effort "$DEFAULT_WORKER_ROUTINE_EFFORT")"
EXISTING_WORKER_COMPLEX_EFFORT="$(policy_or_default worker complex_effort "$DEFAULT_WORKER_COMPLEX_EFFORT")"
EXISTING_WORKER_CRITICAL_EFFORT="$(policy_or_default worker critical_effort "$DEFAULT_WORKER_CRITICAL_EFFORT")"
EXISTING_ROLLOUT_MODE="$(policy_or_default reasoning.rollout mode "$DEFAULT_ROLLOUT_MODE")"
EXISTING_ROLLOUT_MINIMUM="$(policy_or_default reasoning.rollout minimum "$DEFAULT_ROLLOUT_MINIMUM")"
EXISTING_ROLLOUT_ROUTINE="$(policy_or_default reasoning.rollout routine "$DEFAULT_ROLLOUT_ROUTINE")"
EXISTING_ROLLOUT_COMPLEX="$(policy_or_default reasoning.rollout complex "$DEFAULT_ROLLOUT_COMPLEX")"
EXISTING_ROLLOUT_CRITICAL="$(policy_or_default reasoning.rollout critical "$DEFAULT_ROLLOUT_CRITICAL")"
EXISTING_MAX_THREADS="$(policy_or_default runtime max_concurrent_threads "$DEFAULT_MAX_THREADS")"
EXISTING_MAX_REPAIRS="$(policy_or_default runtime max_repair_cycles "$DEFAULT_MAX_REPAIRS")"
EXISTING_TELEMETRY_ENABLED="$(policy_or_default telemetry enabled "$DEFAULT_TELEMETRY_ENABLED")"
EXISTING_TELEMETRY_NOTIFICATIONS="$(policy_or_default telemetry notifications "$DEFAULT_TELEMETRY_NOTIFICATIONS")"
EXISTING_TELEMETRY_RETENTION_DAYS="$(policy_or_default telemetry retention_days "$DEFAULT_TELEMETRY_RETENTION_DAYS")"
EXISTING_UPDATE_CHANNEL="$(policy_or_default update channel stable)"
EXISTING_UPDATE_CHECK="$(policy_or_default update check true)"
EXISTING_UPDATE_INTERVAL="$(policy_or_default update check_interval_hours 24)"
EXISTING_UPDATE_NOTIFY_CLI="$(policy_or_default update notify_cli true)"
EXISTING_UPDATE_NOTIFY_APP="$(policy_or_default update notify_app true)"
EXISTING_UPDATE_AUTO_INSTALL="$(policy_or_default update auto_install false)"

STRATEGY_ENABLED="${CODEX_FLOW_STRATEGY_ENABLED:-$EXISTING_STRATEGY_ENABLED}"
STRATEGY_PROFILE="${CODEX_FLOW_STRATEGY:-$EXISTING_STRATEGY}"
ROUTING_MODE="${CODEX_FLOW_ROUTING_MODE:-$EXISTING_ROUTING}"
REVIEW_MODIFIER="${CODEX_FLOW_REVIEW_MODIFIER:-$EXISTING_REVIEW}"
FANOUT_MODIFIER="${CODEX_FLOW_FANOUT_MODIFIER:-$EXISTING_FANOUT}"
PARENT_MODEL_POLICY="${CODEX_FLOW_PARENT_MODEL_POLICY:-$EXISTING_PARENT_POLICY}"
PARENT_MIN_MODEL="${CODEX_FLOW_PARENT_MIN_MODEL:-$EXISTING_PARENT_MIN_MODEL}"
PARENT_MIN_EFFORT="${CODEX_FLOW_PARENT_MIN_EFFORT:-$EXISTING_PARENT_MIN_EFFORT}"
PARENT_ROUTINE_EFFORT="${CODEX_FLOW_PARENT_ROUTINE_EFFORT:-$EXISTING_PARENT_ROUTINE_EFFORT}"
PARENT_COMPLEX_EFFORT="${CODEX_FLOW_PARENT_COMPLEX_EFFORT:-$EXISTING_PARENT_COMPLEX_EFFORT}"
PARENT_CRITICAL_EFFORT="${CODEX_FLOW_PARENT_CRITICAL_EFFORT:-$EXISTING_PARENT_CRITICAL_EFFORT}"
WORKER_MODEL_POLICY="${CODEX_FLOW_WORKER_MODEL_POLICY:-$EXISTING_WORKER_POLICY}"
WORKER_MODEL_REQUESTED="${CODEX_FLOW_WORKER_MODEL:-$EXISTING_WORKER_MODEL}"
WORKER_MODEL="$WORKER_MODEL_REQUESTED"; [[ "$WORKER_MODEL" == "auto" ]] && WORKER_MODEL="$DEFAULT_WORKER_MODEL"
WORKER_MIN_EFFORT="${CODEX_FLOW_WORKER_MIN_EFFORT:-$EXISTING_WORKER_MIN_EFFORT}"
WORKER_ROUTINE_EFFORT="${CODEX_FLOW_WORKER_ROUTINE_EFFORT:-$EXISTING_WORKER_ROUTINE_EFFORT}"
WORKER_COMPLEX_EFFORT="${CODEX_FLOW_WORKER_COMPLEX_EFFORT:-$EXISTING_WORKER_COMPLEX_EFFORT}"
WORKER_CRITICAL_EFFORT="${CODEX_FLOW_WORKER_CRITICAL_EFFORT:-$EXISTING_WORKER_CRITICAL_EFFORT}"
ROLLOUT_MODE="${CODEX_FLOW_REASONING_ROLLOUT_MODE:-$EXISTING_ROLLOUT_MODE}"
ROLLOUT_MINIMUM="${CODEX_FLOW_REASONING_ROLLOUT_MINIMUM:-$EXISTING_ROLLOUT_MINIMUM}"
ROLLOUT_ROUTINE="${CODEX_FLOW_REASONING_ROLLOUT_ROUTINE:-$EXISTING_ROLLOUT_ROUTINE}"
ROLLOUT_COMPLEX="${CODEX_FLOW_REASONING_ROLLOUT_COMPLEX:-$EXISTING_ROLLOUT_COMPLEX}"
ROLLOUT_CRITICAL="${CODEX_FLOW_REASONING_ROLLOUT_CRITICAL:-$EXISTING_ROLLOUT_CRITICAL}"
MAX_THREADS="${CODEX_FLOW_MAX_THREADS:-$EXISTING_MAX_THREADS}"
MAX_REPAIRS="${CODEX_FLOW_MAX_REPAIR_CYCLES:-$EXISTING_MAX_REPAIRS}"
TELEMETRY_ENABLED="${CODEX_FLOW_TELEMETRY_ENABLED:-$EXISTING_TELEMETRY_ENABLED}"
TELEMETRY_NOTIFICATIONS="${CODEX_FLOW_TELEMETRY_NOTIFICATIONS:-$EXISTING_TELEMETRY_NOTIFICATIONS}"
TELEMETRY_RETENTION_DAYS="${CODEX_FLOW_TELEMETRY_RETENTION_DAYS:-$EXISTING_TELEMETRY_RETENTION_DAYS}"
UPDATE_CHANNEL="${CODEX_FLOW_UPDATE_CHANNEL:-$EXISTING_UPDATE_CHANNEL}"
UPDATE_CHECK="${CODEX_FLOW_UPDATE_CHECK:-$EXISTING_UPDATE_CHECK}"
UPDATE_INTERVAL="${CODEX_FLOW_UPDATE_CHECK_INTERVAL_HOURS:-$EXISTING_UPDATE_INTERVAL}"
UPDATE_NOTIFY_CLI="${CODEX_FLOW_UPDATE_NOTIFY_CLI:-$EXISTING_UPDATE_NOTIFY_CLI}"
UPDATE_NOTIFY_APP="${CODEX_FLOW_UPDATE_NOTIFY_APP:-$EXISTING_UPDATE_NOTIFY_APP}"
UPDATE_AUTO_INSTALL="${CODEX_FLOW_UPDATE_AUTO_INSTALL:-$EXISTING_UPDATE_AUTO_INSTALL}"
UI_LANGUAGE="auto"
if [[ -f "$POLICY" ]]; then UI_LANGUAGE="$(python3 "$LOCALIZATION" --policy "$POLICY" --configured 2>/dev/null || echo auto)"; fi
UI_LANGUAGE="$(python3 "$LOCALIZATION" --normalize "$UI_LANGUAGE")"

case "$STRATEGY_ENABLED" in true|false) ;; *) echo "CODEX_FLOW_STRATEGY_ENABLED must be true or false" >&2; exit 2 ;; esac
case "$STRATEGY_PROFILE" in efficient|balanced|quality|speed) ;; *) echo "CODEX_FLOW_STRATEGY must be efficient, balanced, quality, or speed" >&2; exit 2 ;; esac
case "$ROUTING_MODE" in adaptive|direct|delegate) ;; *) echo "CODEX_FLOW_ROUTING_MODE must be adaptive, direct, or delegate" >&2; exit 2 ;; esac
case "$REVIEW_MODIFIER" in auto|standard|strict) ;; *) echo "CODEX_FLOW_REVIEW_MODIFIER must be auto, standard, or strict" >&2; exit 2 ;; esac
case "$FANOUT_MODIFIER" in auto|conservative|aggressive) ;; *) echo "CODEX_FLOW_FANOUT_MODIFIER must be auto, conservative, or aggressive" >&2; exit 2 ;; esac
for effort in "$PARENT_MIN_EFFORT" "$PARENT_ROUTINE_EFFORT" "$PARENT_COMPLEX_EFFORT" "$PARENT_CRITICAL_EFFORT" "$WORKER_MIN_EFFORT" "$WORKER_ROUTINE_EFFORT" "$WORKER_COMPLEX_EFFORT" "$WORKER_CRITICAL_EFFORT"; do
  case "$effort" in high|xhigh|max) ;; *) echo "reasoning efforts must be high, xhigh, or max" >&2; exit 2 ;; esac
done
case "$ROLLOUT_MODE" in legacy|shadow|adaptive) ;; *) echo "CODEX_FLOW_REASONING_ROLLOUT_MODE must be legacy, shadow, or adaptive" >&2; exit 2 ;; esac
for effort in "$ROLLOUT_MINIMUM" "$ROLLOUT_ROUTINE" "$ROLLOUT_COMPLEX" "$ROLLOUT_CRITICAL"; do
  case "$effort" in high|xhigh|max) ;; *) echo "reasoning rollout efforts must be high, xhigh, or max" >&2; exit 2 ;; esac
done
case "$TELEMETRY_ENABLED" in true|false) ;; *) echo "CODEX_FLOW_TELEMETRY_ENABLED must be true or false" >&2; exit 2 ;; esac
case "$TELEMETRY_NOTIFICATIONS" in true|false) ;; *) echo "CODEX_FLOW_TELEMETRY_NOTIFICATIONS must be true or false" >&2; exit 2 ;; esac
[[ "$MAX_THREADS" =~ ^[1-9][0-9]*$ ]] || { echo "CODEX_FLOW_MAX_THREADS must be a positive integer" >&2; exit 2; }
[[ "$MAX_REPAIRS" =~ ^[0-9]+$ ]] || { echo "CODEX_FLOW_MAX_REPAIR_CYCLES must be a non-negative integer" >&2; exit 2; }
[[ "$TELEMETRY_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "CODEX_FLOW_TELEMETRY_RETENTION_DAYS must be a positive integer" >&2; exit 2; }
case "$UPDATE_CHANNEL" in stable|beta|nightly) ;; *) echo "CODEX_FLOW_UPDATE_CHANNEL must be stable, beta, or nightly" >&2; exit 2 ;; esac
case "$UPDATE_CHECK" in true|false) ;; *) echo "CODEX_FLOW_UPDATE_CHECK must be true or false" >&2; exit 2 ;; esac
case "$UPDATE_NOTIFY_CLI" in true|false) ;; *) echo "CODEX_FLOW_UPDATE_NOTIFY_CLI must be true or false" >&2; exit 2 ;; esac
case "$UPDATE_NOTIFY_APP" in true|false) ;; *) echo "CODEX_FLOW_UPDATE_NOTIFY_APP must be true or false" >&2; exit 2 ;; esac
case "$UPDATE_AUTO_INSTALL" in true|false) ;; *) echo "CODEX_FLOW_UPDATE_AUTO_INSTALL must be true or false" >&2; exit 2 ;; esac
[[ "$UPDATE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "CODEX_FLOW_UPDATE_CHECK_INTERVAL_HOURS must be a positive integer" >&2; exit 2; }

mkdir -p "$CODEX_HOME/agents" "$CODEX_HOME/skills/flow-pilot" "$STATE_DIR" "$STATE_DIR/state" "$STATE_DIR/versions" "$BIN_DIR"
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
schema_version = 4

[ui]
language = "$UI_LANGUAGE"

[strategy]
enabled = $STRATEGY_ENABLED
profile = "$STRATEGY_PROFILE"

[routing]
mode = "$ROUTING_MODE"

[modifiers]
review = "$REVIEW_MODIFIER"
fanout = "$FANOUT_MODIFIER"

[parent]
model_policy = "$PARENT_MODEL_POLICY"
min_model = "$PARENT_MIN_MODEL"
min_reasoning_effort = "$PARENT_MIN_EFFORT"
reasoning_policy = "adaptive"
routine_effort = "$PARENT_ROUTINE_EFFORT"
complex_effort = "$PARENT_COMPLEX_EFFORT"
critical_effort = "$PARENT_CRITICAL_EFFORT"

[worker]
model_policy = "$WORKER_MODEL_POLICY"
model = "$WORKER_MODEL_REQUESTED"
resolved_model = "$WORKER_MODEL"
min_reasoning_effort = "$WORKER_MIN_EFFORT"
reasoning_policy = "adaptive"
routine_effort = "$WORKER_ROUTINE_EFFORT"
complex_effort = "$WORKER_COMPLEX_EFFORT"
critical_effort = "$WORKER_CRITICAL_EFFORT"

[reasoning.rollout]
mode = "$ROLLOUT_MODE"
minimum = "$ROLLOUT_MINIMUM"
routine = "$ROLLOUT_ROUTINE"
complex = "$ROLLOUT_COMPLEX"
critical = "$ROLLOUT_CRITICAL"

[runtime]
max_concurrent_threads = $MAX_THREADS
max_repair_cycles = $MAX_REPAIRS

[telemetry]
enabled = $TELEMETRY_ENABLED
summary = true
notifications = $TELEMETRY_NOTIFICATIONS
retention_days = $TELEMETRY_RETENTION_DAYS
source = "hooks+app-server"

[update]
channel = "$UPDATE_CHANNEL"
check = $UPDATE_CHECK
check_interval_hours = $UPDATE_INTERVAL
notify_cli = $UPDATE_NOTIFY_CLI
notify_app = $UPDATE_NOTIFY_APP
auto_install = $UPDATE_AUTO_INSTALL
EOF

cp "$ROOT_DIR/templates/agents/worker-explorer.toml" "$CODEX_HOME/agents/worker-explorer.toml"
cp "$ROOT_DIR/templates/agents/worker-implementer.toml" "$CODEX_HOME/agents/worker-implementer.toml"
cp "$ROOT_DIR/templates/agents/worker-reviewer.toml" "$CODEX_HOME/agents/worker-reviewer.toml"
cp "$ROOT_DIR/templates/skills/flow-pilot/SKILL.md" "$CODEX_HOME/skills/flow-pilot/SKILL.md"
rm -f "$CODEX_HOME/agents/luna-explorer.toml" "$CODEX_HOME/agents/luna-implementer.toml"

printf '%s\n' "$ROOT_DIR" > "$STATE_DIR/source"
printf '%s\n' "$VERSION" > "$STATE_DIR/version"
printf '%s\n' "$BIN_DIR" > "$STATE_DIR/bin_dir"
cp "$DEFAULTS" "$STATE_DIR/defaults.toml"
cp "$ROOT_DIR/bin/codex-flow" "$BIN_DIR/codex-flow"; chmod +x "$BIN_DIR/codex-flow"
for file in updater.py update_runtime_config.py telemetry.py manage-hooks.py menu.py localization.py ui.py doctor.py strategy_runtime.py; do cp "$ROOT_DIR/scripts/$file" "$STATE_DIR/$file"; done
rm -rf "$STATE_DIR/strategies" "$STATE_DIR/telemetry_core"
cp -r "$ROOT_DIR/scripts/strategies" "$STATE_DIR/strategies"
cp -r "$ROOT_DIR/scripts/telemetry_core" "$STATE_DIR/telemetry_core"
chmod +x "$STATE_DIR/updater.py" "$STATE_DIR/telemetry.py" "$STATE_DIR/manage-hooks.py" "$STATE_DIR/menu.py" "$STATE_DIR/localization.py" "$STATE_DIR/ui.py" "$STATE_DIR/doctor.py" "$STATE_DIR/strategy_runtime.py"

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
printf '  │  • %s: %s\n' "$(cf_t 'Policy' '策略文件')" "$disp_policy"
printf '  │  • CLI: %s\n' "$disp_cli"
printf '  │  • Skill: FlowPilot (flow-pilot)\n'
printf '  │  • %s: %s / %s\n' "$(cf_t 'Strategy' '执行策略')" "$STRATEGY_PROFILE" "$ROUTING_MODE"
printf '  │  • %s: %s (%s / %s / %s / %s)\n' "$(cf_t 'Reasoning rollout' '推理 rollout')" "$ROLLOUT_MODE" "$ROLLOUT_MINIMUM" "$ROLLOUT_ROUTINE" "$ROLLOUT_COMPLEX" "$ROLLOUT_CRITICAL"
printf '  │  • %s: review=%s / fanout=%s\n' "$(cf_t 'Modifiers' '修饰策略')" "$REVIEW_MODIFIER" "$FANOUT_MODIFIER"
printf '  │  • %s: parent (%s) -> worker (%s)\n' "$(cf_t 'Models' '模型')" "$PARENT_MODEL_POLICY" "$WORKER_MODEL"
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
