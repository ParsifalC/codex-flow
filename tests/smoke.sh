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
[[ "$install_output" == *"efficient / adaptive"* ]]
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
[[ -f "$CODEX_HOME/codex-flow/defaults.toml" ]]
[[ -f "$CODEX_HOME/codex-flow/telemetry.py" ]]
[[ -f "$CODEX_HOME/codex-flow/strategy_runtime.py" ]]
[[ -d "$CODEX_HOME/codex-flow/strategies" ]]
[[ -d "$CODEX_HOME/codex-flow/telemetry_core" ]]
[[ -f "$CODEX_HOME/codex-flow/telemetry_core/latency.py" ]]
[[ -f "$CODEX_HOME/codex-flow/menu.py" ]]
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
[[ -f "$CODEX_HOME/agents/worker-reviewer.toml" ]]
[[ -f "$CODEX_HOME/skills/flow-pilot/SKILL.md" ]]
grep -Fq 'name: flow-pilot' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'model = "user-parent-model"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_model = "gpt-5.6-luna"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_reasoning_effort = "xhigh"' "$CODEX_HOME/config.toml"
grep -Fq 'schema_version = 4' "$CODEX_HOME/codex-flow.toml"
grep -Fq '[strategy]' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'profile = "efficient"' "$CODEX_HOME/codex-flow.toml"
grep -Fq '[routing]' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'mode = "adaptive"' "$CODEX_HOME/codex-flow.toml"
grep -Fq '[reasoning.rollout]' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'mode = "shadow"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'model = "auto"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'resolved_model = "gpt-5.6-luna"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'enabled = true' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'notifications = true' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'retention_days = 30' "$CODEX_HOME/codex-flow.toml"
grep -Fq '`direct` — do not spawn or delegate to subagents for this task.' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq '`delegate` — use subagent delegation for execution when the runtime supports it' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'Strategy and routing are orthogonal.' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'quality_intent' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'worker_budget' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'reviewer_workers' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'explorer_capability_policy' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'implementer_capability_policy' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'A `wait()` timeout is never a Worker timeout.' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'cancel_if_superseded' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'UserPromptSubmit' "$CODEX_HOME/hooks.json"
grep -Fq 'SubagentStart' "$CODEX_HOME/hooks.json"
grep -Fq 'SubagentStop' "$CODEX_HOME/hooks.json"
grep -Fq 'Stop' "$CODEX_HOME/hooks.json"
grep -Fq 'codex-flow/telemetry.py' "$CODEX_HOME/hooks.json"
grep -Fxq "$ROOT_DIR" "$CODEX_HOME/codex-flow/source"
grep -Fxq "$(cat "$ROOT_DIR/VERSION")" "$CODEX_HOME/codex-flow/version"

codex-flow status
strategy_show="$(codex-flow strategy show)"
[[ "$strategy_show" == "enabled=true strategy=efficient routing=adaptive" ]]
[[ "$(codex-flow strategy)" == "enabled=true strategy=efficient routing=adaptive" ]]
[[ "$(codex-flow strategy enabled)" == "true" ]]
codex-flow strategy plan --complexity complex --uncertainty high > "$TMP/installed-plan.json"
python3 - "$TMP/installed-plan.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['schema_version']==10, p
assert p['quality_intent']=='normal', p
assert p['strategy']=='efficient' and p['routing']=='delegate', p
assert p['parent_reasoning']=='high', p
assert p['explorer_reasoning']=='xhigh' and p['implementer_reasoning']=='xhigh', p
assert p['explorer_capability_policy']=='latest-efficient' and p['implementer_capability_policy']=='latest-efficient', p
assert p['exploration_workers']==2 and p['implementation_workers']==1, p
assert p['planned_worker_count']==3, p
assert p['exploration_stage']['join_policy']=='quorum', p
assert p['implementation_stage']['join_policy']=='required', p
assert p['review_stage'] is None, p
assert p['task_budget']['soft_timeout_seconds']==1500, p
assert p['task_budget']['hard_timeout_seconds']==1800, p
PY
codex-flow usage list >/dev/null || true
codex-flow usage stats >/dev/null || true
codex-flow telemetry latency report --json > "$TMP/installed-latency-report.json"
python3 - "$TMP/installed-latency-report.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["n"] == 0 and p["eligible_for_tuning"] is False and p["policy_mutation"] is False, p
PY
doctor_output="$(codex-flow doctor 2>&1)"
printf '%s\n' "$doctor_output"
[[ "$doctor_output" == *"policy schema v4"* ]]
[[ "$doctor_output" == *"strategy profile: efficient"* ]]
[[ "$doctor_output" == *"routing mode: adaptive"* ]]
[[ "$doctor_output" == *"review modifier: auto"* ]]
[[ "$doctor_output" == *"fanout modifier: auto"* ]]
[[ "$doctor_output" == *"release policy defaults installed"* ]]
[[ "$doctor_output" == *"FlowPilot lifecycle hooks installed"* ]]
[[ "$doctor_output" == *"task budget runtime helper installed"* ]]
[[ "$doctor_output" == *"latency telemetry helper installed"* ]]
[[ "$doctor_output" == *"thread-attributed telemetry may be unavailable"* ]]
[[ "$doctor_output" == *"FlowPilot hook authorization: approval required"* ]]
[[ "$doctor_output" == *"Installed with action required"* ]]

for CODEX_TEST_VERSION in 0.151.0 0.151.0-alpha.1; do
  export CODEX_TEST_VERSION
  capable_doctor_output="$(codex-flow doctor 2>&1)"
  ! [[ "$capable_doctor_output" == *"thread-attributed telemetry may be unavailable"* ]]
done

no_cli_output="$(env PATH="$CODEX_FLOW_BIN_DIR:/usr/bin:/bin" "$CODEX_FLOW_BIN_DIR/codex-flow" doctor 2>&1)"
printf '%s\n' "$no_cli_output"
[[ "$no_cli_output" == *"Codex CLI not found in PATH"* ]]
[[ "$no_cli_output" == *"Hook review is required, but Codex CLI is not in PATH"* ]]
[[ "$no_cli_output" == *"Installed with action required"* ]]

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

# Customize every supported policy dimension so reinstall/update round-trip remains lossless.
python3 - "$CODEX_HOME/codex-flow.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
replacements = {
    'enabled = true': 'enabled = false',
    'profile = "efficient"': 'profile = "balanced"',
    'mode = "adaptive"': 'mode = "delegate"',
    'review = "auto"': 'review = "strict"',
    'fanout = "auto"': 'fanout = "conservative"',
    '[reasoning.rollout]\nmode = "shadow"\nminimum = "high"\nroutine = "high"\ncomplex = "xhigh"\ncritical = "max"': '[reasoning.rollout]\nmode = "legacy"\nminimum = "xhigh"\nroutine = "xhigh"\ncomplex = "max"\ncritical = "max"',
    'min_reasoning_effort = "high"\nreasoning_policy = "adaptive"\nroutine_effort = "high"\ncomplex_effort = "high"\ncritical_effort = "xhigh"': 'min_reasoning_effort = "xhigh"\nreasoning_policy = "adaptive"\nroutine_effort = "xhigh"\ncomplex_effort = "max"\ncritical_effort = "max"',
    'min_reasoning_effort = "xhigh"\nreasoning_policy = "adaptive"\nroutine_effort = "xhigh"\ncomplex_effort = "xhigh"\ncritical_effort = "max"': 'min_reasoning_effort = "xhigh"\nreasoning_policy = "adaptive"\nroutine_effort = "max"\ncomplex_effort = "max"\ncritical_effort = "max"',
    'max_concurrent_threads = 4': 'max_concurrent_threads = 3',
    'max_repair_cycles = 2': 'max_repair_cycles = 1',
    'notifications = true': 'notifications = false',
    'retention_days = 30': 'retention_days = 17',
}
for old,new in replacements.items():
    if old not in s:
        raise AssertionError(f'missing replacement source: {old!r}')
    s=s.replace(old,new,1)
p.write_text(s)
PY

bash "$ROOT_DIR/install.sh"
[[ "$(codex-flow strategy enabled)" == "false" ]]
grep -Fq 'profile = "balanced"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'mode = "delegate"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'review = "strict"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'fanout = "conservative"' "$CODEX_HOME/codex-flow.toml"
grep -Fq '[reasoning.rollout]' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'mode = "legacy"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'minimum = "xhigh"' "$CODEX_HOME/codex-flow.toml"
[[ "$(grep -cF 'routine_effort = "xhigh"' "$CODEX_HOME/codex-flow.toml")" == 1 ]]
[[ "$(grep -cF 'routine_effort = "max"' "$CODEX_HOME/codex-flow.toml")" == 1 ]]
[[ "$(grep -cF 'complex_effort = "max"' "$CODEX_HOME/codex-flow.toml")" == 2 ]]
grep -Fq 'max_concurrent_threads = 3' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'max_repair_cycles = 1' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'notifications = false' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'retention_days = 17' "$CODEX_HOME/codex-flow.toml"
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

roundtrip_doctor="$(codex-flow doctor 2>&1)"
[[ "$roundtrip_doctor" == *"strategy dispatch: disabled by policy"* ]]
[[ "$roundtrip_doctor" == *"strategy profile: balanced"* ]]
[[ "$roundtrip_doctor" == *"routing mode: delegate"* ]]
[[ "$roundtrip_doctor" == *"review modifier: strict"* ]]
[[ "$roundtrip_doctor" == *"fanout modifier: conservative"* ]]
[[ "$roundtrip_doctor" == *"efficient reasoning rollout: legacy"* ]]
[[ "$roundtrip_doctor" == *"rollout minimum: xhigh"* ]]
[[ "$roundtrip_doctor" == *"runtime thread ceiling: 3"* ]]
[[ "$roundtrip_doctor" == *"runtime repair ceiling: 1"* ]]

grep -Fq '# bashrc sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"
grep -Fq '# profile sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile"

bash --noprofile --norc -c 'source "$1"; [[ "$PATH" == "$2"* ]]; type -t codex-flow >/dev/null' _ "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc" "$CODEX_FLOW_BIN_DIR"
bash --noprofile --norc -c '
  source "$1"
  COMP_WORDS=(codex-flow st); COMP_CWORD=1; _codex_flow_completion; [[ "${COMPREPLY[*]}" == status ]]
  COMP_WORDS=(codex-flow strategy q); COMP_CWORD=2; _codex_flow_completion; [[ "${COMPREPLY[*]}" == quality* || "${COMPREPLY[*]}" == "" ]]
  COMP_WORDS=(codex-flow strategy set q); COMP_CWORD=3; _codex_flow_completion; [[ "${COMPREPLY[*]}" == quality ]]
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

CODEX_FLOW_STRATEGY_ENABLED=true CODEX_FLOW_STRATEGY=quality CODEX_FLOW_ROUTING_MODE=direct CODEX_FLOW_WORKER_MODEL=gpt-test-worker CODEX_FLOW_WORKER_MIN_EFFORT=xhigh CODEX_FLOW_PARENT_MIN_EFFORT=xhigh bash "$ROOT_DIR/install.sh"
[[ "$(codex-flow strategy enabled)" == "true" ]]
grep -Fq 'profile = "quality"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'mode = "direct"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'review = "strict"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'fanout = "conservative"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'default_subagent_model = "gpt-test-worker"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_reasoning_effort = "xhigh"' "$CODEX_HOME/config.toml"
grep -Fq 'resolved_model = "gpt-test-worker"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'max_concurrent_threads = 3' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'retention_days = 17' "$CODEX_HOME/codex-flow.toml"
codex-flow doctor

env -u CODEX_FLOW_BIN_DIR codex-flow uninstall
[[ ! -e "$CODEX_HOME/codex-flow.toml" ]]
[[ ! -e "$CODEX_HOME/codex-flow" ]]
[[ ! -e "$CODEX_FLOW_BIN_DIR/codex-flow" ]]
[[ ! -e "$CODEX_HOME/agents/worker-explorer.toml" ]]
[[ ! -e "$CODEX_HOME/agents/worker-implementer.toml" ]]
[[ ! -e "$CODEX_HOME/agents/worker-reviewer.toml" ]]
[[ ! -e "$CODEX_HOME/skills/flow-pilot" ]]
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
