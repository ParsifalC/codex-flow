#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CODEX_HOME="$TMP/.codex"
export CODEX_FLOW_BIN_DIR="$TMP/bin-installed"
export CODEX_FLOW_SHELL_CONFIG_DIR="$TMP/shell-config"
export CODEX_FLOW_SHELL=bash
mkdir -p "$TMP/bin" "$CODEX_HOME" "$CODEX_FLOW_BIN_DIR" "$CODEX_FLOW_SHELL_CONFIG_DIR"

printf '%s\n' '# bashrc sentinel' > "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"
printf '%s\n' '# profile sentinel' > "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile"

cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "codex-test ${CODEX_TEST_VERSION:-0.147.0}" || exit 0
EOF
chmod +x "$TMP/bin/codex"
export CODEX_TEST_VERSION=0.147.0
export PATH="$TMP/bin:$CODEX_FLOW_BIN_DIR:$PATH"

cat > "$CODEX_HOME/config.toml" <<'EOF'
model = "user-parent-model"
model_reasoning_effort = "high"

[unrelated]
keep_me = true
EOF

install_output="$(bash "$ROOT_DIR/install.sh")"
printf '%s\n' "$install_output"
[[ "$install_output" == *"FlowPilot (flow-pilot)"* ]]
[[ "$install_output" == *"● enabled"* ]]
[[ "$install_output" == *"source "*"$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"* ]]
[[ "$install_output" == *"or open a new terminal"* ]]
[[ "$install_output" == *"REQUIRED NEXT STEPS"* ]]
[[ "$install_output" == *"Complete Codex Restart"* ]]
[[ "$install_output" == *"Fully quit Codex and relaunch it."* ]]
[[ "$install_output" == *"Authorize Hooks"* ]]
[[ "$install_output" == *"/hooks"* ]]

disabled_output="$(
  CODEX_HOME="$TMP/.codex-disabled" \
  CODEX_FLOW_BIN_DIR="$TMP/bin-disabled" \
  CODEX_FLOW_SHELL=none \
  CODEX_FLOW_TELEMETRY_ENABLED=false \
  bash "$ROOT_DIR/install.sh"
)"
printf '%s\n' "$disabled_output"
[[ "$disabled_output" == *"Telemetry is disabled: no hook authorization is required."* ]]
[[ "$disabled_output" == *"Complete Codex Restart"* ]]
! [[ "$disabled_output" == *"approve FlowPilot telemetry"* ]]

[[ -f "$CODEX_HOME/codex-flow.toml" ]]
[[ -f "$CODEX_HOME/codex-flow/source" ]]
[[ -f "$CODEX_HOME/codex-flow/version" ]]
[[ -f "$CODEX_HOME/codex-flow/telemetry.py" ]]
[[ -f "$CODEX_HOME/codex-flow/manage-hooks.py" ]]
[[ -f "$CODEX_HOME/hooks.json" ]]
[[ -x "$CODEX_FLOW_BIN_DIR/codex-flow" ]]
[[ -f "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc" ]]
[[ -f "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile" ]]
[[ ! -e "$CODEX_FLOW_SHELL_CONFIG_DIR/.bash_profile" ]]
[[ "$(grep -cF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc")" == 1 ]]
[[ "$(grep -cF '# <<< codex-flow <<<' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc")" == 1 ]]
[[ "$(grep -cF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile")" == 1 ]]
grep -Fq '# bashrc sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"
grep -Fq '# profile sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile"
grep -Fq "$CODEX_HOME/codex-flow/shell/init.sh" "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"
grep -Fq "codex-flow.bash" "$CODEX_HOME/codex-flow/shell/init.sh"
[[ -f "$CODEX_HOME/agents/worker-explorer.toml" ]]
[[ -f "$CODEX_HOME/agents/worker-implementer.toml" ]]
[[ -f "$CODEX_HOME/skills/flow-pilot/SKILL.md" ]]
[[ ! -e "$CODEX_HOME/skills/cost-aware-development" ]]
grep -Fq 'name: flow-pilot' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'model = "user-parent-model"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_model = "gpt-5.6-luna"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_reasoning_effort = "high"' "$CODEX_HOME/config.toml"
grep -Fq 'schema_version = 3' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'model = "auto"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'resolved_model = "gpt-5.6-luna"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'enabled = true' "$CODEX_HOME/codex-flow.toml"
grep -Fq '`direct` — do not spawn or delegate to subagents for this task.' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq '`delegate` — use subagent delegation for execution when the runtime supports it' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'Routing override scope is the current task only.' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'UserPromptSubmit' "$CODEX_HOME/hooks.json"
grep -Fq 'SubagentStart' "$CODEX_HOME/hooks.json"
grep -Fq 'SubagentStop' "$CODEX_HOME/hooks.json"
grep -Fq 'Stop' "$CODEX_HOME/hooks.json"
grep -Fq 'codex-flow/telemetry.py' "$CODEX_HOME/hooks.json"
grep -Fxq "$ROOT_DIR" "$CODEX_HOME/codex-flow/source"
grep -Fxq "$(cat "$ROOT_DIR/VERSION")" "$CODEX_HOME/codex-flow/version"

codex-flow status
doctor_output="$(codex-flow doctor 2>&1)"
printf '%s\n' "$doctor_output"
[[ "$doctor_output" == *"policy schema v3"* ]]
[[ "$doctor_output" == *"FlowPilot lifecycle hooks installed"* ]]
[[ "$doctor_output" == *"thread-attributed telemetry may be unavailable"* ]]
[[ "$doctor_output" == *"Ready. FlowPilot routing and deterministic telemetry are installed."* ]]

for CODEX_TEST_VERSION in 0.151.0 0.151.0-alpha.1; do
  export CODEX_TEST_VERSION
  capable_doctor_output="$(codex-flow doctor 2>&1)"
  ! [[ "$capable_doctor_output" == *"thread-attributed telemetry may be unavailable"* ]]
done

no_cli_output="$(env PATH="$CODEX_FLOW_BIN_DIR:/usr/bin:/bin" "$CODEX_FLOW_BIN_DIR/codex-flow" doctor 2>&1)"
printf '%s\n' "$no_cli_output"
[[ "$no_cli_output" == *"Codex CLI not found in PATH"* ]]
[[ "$no_cli_output" == *"Core FlowPilot routing is installed and healthy"* ]]

# A mixed hook group must preserve user handlers across reinstall and uninstall.
python3 - "$CODEX_HOME/hooks.json" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = json.load(stream)
entry = data["hooks"]["Stop"][0]
entry["hooks"].append({"type": "command", "command": "user-stop-handler"})
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY

# A second install must replace managed hooks and shell blocks, not duplicate them.
bash "$ROOT_DIR/install.sh"
[[ "$(grep -cF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc")" == 1 ]]
[[ "$(grep -cF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile")" == 1 ]]
python3 - "$CODEX_HOME/hooks.json" <<'PY'
import json, sys
hooks=json.load(open(sys.argv[1]))["hooks"]
for event in ("UserPromptSubmit","SubagentStart","SubagentStop","Stop"):
    managed=[entry for entry in hooks[event] if any("codex-flow/telemetry.py" in hook.get("command", "").replace("\\", "/") for hook in entry.get("hooks", []))]
    assert len(managed) == 1, (event, managed)
stop_hooks = hooks["Stop"][0]["hooks"]
assert any(hook.get("command") == "user-stop-handler" for hook in stop_hooks), stop_hooks
PY

grep -Fq '# bashrc sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"
grep -Fq '# profile sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile"

bash --noprofile --norc -c 'source "$1"; [[ "$PATH" == "$2"* ]]; type -t codex-flow >/dev/null' _ "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc" "$CODEX_FLOW_BIN_DIR"
bash --noprofile --norc -c '
  source "$1"
  COMP_WORDS=(codex-flow st); COMP_CWORD=1; _codex_flow_completion; [[ "${COMPREPLY[*]}" == status ]]
  COMP_WORDS=(codex-flow benchmark-corpus f); COMP_CWORD=2; _codex_flow_completion; [[ "${COMPREPLY[*]}" == full ]]
  COMP_WORDS=(codex-flow benchmark-local q); COMP_CWORD=2; _codex_flow_completion; [[ "${COMPREPLY[*]}" == quick ]]
' _ "$CODEX_HOME/codex-flow/shell/codex-flow.bash"

CODEX_FLOW_SHELL=zsh bash "$ROOT_DIR/install.sh"
[[ "$(grep -cF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.zshrc")" == 1 ]]
grep -Fq "codex-flow.zsh" "$CODEX_HOME/codex-flow/shell/init.sh"
if command -v zsh >/dev/null 2>&1; then
  zsh -fc 'autoload -Uz compinit; compinit -d "$3"; source "$1"; [[ "${_comps[codex-flow]}" == _codex_flow ]]' _ "$CODEX_HOME/codex-flow/shell/init.sh" unused "$TMP/zcompdump"
else
  grep -Fq 'compdef _codex_flow codex-flow' "$CODEX_HOME/codex-flow/shell/codex-flow.zsh"
fi

CODEX_FLOW_WORKER_MODEL=gpt-test-worker CODEX_FLOW_WORKER_MIN_EFFORT=xhigh CODEX_FLOW_PARENT_MIN_EFFORT=xhigh bash "$ROOT_DIR/install.sh"
grep -Fq 'default_subagent_model = "gpt-test-worker"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_reasoning_effort = "xhigh"' "$CODEX_HOME/config.toml"
grep -Fq 'resolved_model = "gpt-test-worker"' "$CODEX_HOME/codex-flow.toml"
codex-flow doctor

env -u CODEX_FLOW_BIN_DIR codex-flow uninstall
[[ ! -e "$CODEX_HOME/codex-flow.toml" ]]
[[ ! -e "$CODEX_HOME/codex-flow" ]]
[[ ! -e "$CODEX_FLOW_BIN_DIR/codex-flow" ]]
[[ ! -e "$CODEX_HOME/agents/worker-explorer.toml" ]]
[[ ! -e "$CODEX_HOME/agents/worker-implementer.toml" ]]
[[ ! -e "$CODEX_HOME/skills/flow-pilot" ]]
[[ ! -e "$CODEX_HOME/skills/cost-aware-development" ]]
! grep -qF 'codex-flow/telemetry.py' "$CODEX_HOME/hooks.json"
python3 - "$CODEX_HOME/hooks.json" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    hooks = json.load(stream)["hooks"]
stop_hooks = hooks["Stop"][0]["hooks"]
assert stop_hooks == [{"type": "command", "command": "user-stop-handler"}], stop_hooks
PY
! grep -qF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"
! grep -qF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile"
! grep -qF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.zshrc"
grep -Fq '# bashrc sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"
grep -Fq '# profile sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile"
grep -Fq 'model = "user-parent-model"' "$CODEX_HOME/config.toml"
grep -Fq 'keep_me = true' "$CODEX_HOME/config.toml"
! grep -q '^default_subagent_model' "$CODEX_HOME/config.toml"
! grep -q '^default_subagent_reasoning_effort' "$CODEX_HOME/config.toml"

printf 'smoke test passed\n'
