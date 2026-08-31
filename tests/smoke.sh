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

# doctor only needs a version-capable codex binary for this installer smoke test.
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "codex-test 0.0.0" || exit 0
EOF
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$CODEX_FLOW_BIN_DIR:$PATH"

cat > "$CODEX_HOME/config.toml" <<'EOF'
model = "user-parent-model"
model_reasoning_effort = "high"

[unrelated]
keep_me = true
EOF

install_output="$(bash "$ROOT_DIR/install.sh")"
printf '%s\n' "$install_output"
[[ "$install_output" == *"source $CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"* ]]
[[ "$install_output" == *"Or open a new terminal."* ]]

[[ -f "$CODEX_HOME/codex-flow.toml" ]]
[[ -f "$CODEX_HOME/codex-flow/source" ]]
[[ -f "$CODEX_HOME/codex-flow/version" ]]
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
[[ -f "$CODEX_HOME/skills/cost-aware-development/SKILL.md" ]]
grep -Fq 'model = "user-parent-model"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_model = "gpt-5.6-luna"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_reasoning_effort = "high"' "$CODEX_HOME/config.toml"
grep -Fq 'model = "auto"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'resolved_model = "gpt-5.6-luna"' "$CODEX_HOME/codex-flow.toml"
grep -Fq '`direct` — do not spawn or delegate to subagents for this task.' "$CODEX_HOME/skills/cost-aware-development/SKILL.md"
grep -Fq '`delegate` — use subagent delegation for execution when the runtime supports it' "$CODEX_HOME/skills/cost-aware-development/SKILL.md"
grep -Fq 'Routing override scope is the current task only.' "$CODEX_HOME/skills/cost-aware-development/SKILL.md"
grep -Fxq "$ROOT_DIR" "$CODEX_HOME/codex-flow/source"
grep -Fxq "$(cat "$ROOT_DIR/VERSION")" "$CODEX_HOME/codex-flow/version"

codex-flow status
doctor_output="$(codex-flow doctor)"
printf '%s\n' "$doctor_output"
[[ "$doctor_output" == *"✓ policy schema v2"* ]]
[[ "$doctor_output" != *"policy schema is  2"* ]]
[[ "$doctor_output" == *"Ready. Routing is capability-based"* ]]

# Codex CLI is an optional doctor capability: core routing remains healthy when
# this shell cannot resolve `codex`, while real benchmark execution is called out.
no_cli_output="$(env PATH="$CODEX_FLOW_BIN_DIR:/usr/bin:/bin" "$CODEX_FLOW_BIN_DIR/codex-flow" doctor)"
printf '%s\n' "$no_cli_output"
[[ "$no_cli_output" == *"! Codex CLI not found in PATH; core routing remains usable"* ]]
[[ "$no_cli_output" == *"Ready. Core routing is installed and healthy"* ]]
[[ "$no_cli_output" == *"benchmark-local or a real benchmark"* ]]

# A second install must replace the same managed block, not append another.
bash "$ROOT_DIR/install.sh"
[[ "$(grep -cF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc")" == 1 ]]
[[ "$(grep -cF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile")" == 1 ]]
[[ ! -e "$CODEX_FLOW_SHELL_CONFIG_DIR/.bash_profile" ]]
grep -Fq '# bashrc sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc"
grep -Fq '# profile sentinel' "$CODEX_FLOW_SHELL_CONFIG_DIR/.profile"

# A fresh bash receives PATH and completion from the managed rc source.
bash --noprofile --norc -c \
  'source "$1"; [[ "$PATH" == "$2"* ]]; type -t codex-flow >/dev/null' \
  _ "$CODEX_FLOW_SHELL_CONFIG_DIR/.bashrc" "$CODEX_FLOW_BIN_DIR"
bash --noprofile --norc -c '
  source "$1"
  COMP_WORDS=(codex-flow st); COMP_CWORD=1
  _codex_flow_completion
  [[ "${COMPREPLY[*]}" == status ]]
  COMP_WORDS=(codex-flow benchmark-corpus f); COMP_CWORD=2
  _codex_flow_completion
  [[ "${COMPREPLY[*]}" == full ]]
  COMP_WORDS=(codex-flow benchmark-local q); COMP_CWORD=2
  _codex_flow_completion
  [[ "${COMPREPLY[*]}" == quick ]]
' _ "$CODEX_HOME/codex-flow/shell/codex-flow.bash"

# Switching shells removes the old managed paths and registers zsh completion.
CODEX_FLOW_SHELL=zsh bash "$ROOT_DIR/install.sh"
[[ "$(grep -cF '# >>> codex-flow >>>' "$CODEX_FLOW_SHELL_CONFIG_DIR/.zshrc")" == 1 ]]
grep -Fq "codex-flow.zsh" "$CODEX_HOME/codex-flow/shell/init.sh"
if command -v zsh >/dev/null 2>&1; then
  zsh -fc \
    'autoload -Uz compinit; compinit -d "$3"; source "$1"; [[ "${_comps[codex-flow]}" == _codex_flow ]]' \
    _ "$CODEX_HOME/codex-flow/shell/init.sh" unused "$TMP/zcompdump"
else
  grep -Fq 'compdef _codex_flow codex-flow' "$CODEX_HOME/codex-flow/shell/codex-flow.zsh"
fi

# Explicit overrides must become both policy and concrete Codex fallback.
CODEX_FLOW_WORKER_MODEL=gpt-test-worker \
CODEX_FLOW_WORKER_MIN_EFFORT=xhigh \
CODEX_FLOW_PARENT_MIN_EFFORT=xhigh \
bash "$ROOT_DIR/install.sh"

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
[[ ! -e "$CODEX_HOME/skills/cost-aware-development" ]]
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
