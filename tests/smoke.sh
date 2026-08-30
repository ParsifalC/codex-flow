#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CODEX_HOME="$TMP/.codex"
export CODEX_FLOW_BIN_DIR="$TMP/bin-installed"
mkdir -p "$TMP/bin" "$CODEX_HOME" "$CODEX_FLOW_BIN_DIR"

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

bash "$ROOT_DIR/install.sh"

[[ -f "$CODEX_HOME/codex-flow.toml" ]]
[[ -f "$CODEX_HOME/codex-flow/source" ]]
[[ -f "$CODEX_HOME/codex-flow/version" ]]
[[ -x "$CODEX_FLOW_BIN_DIR/codex-flow" ]]
[[ -f "$CODEX_HOME/agents/worker-explorer.toml" ]]
[[ -f "$CODEX_HOME/agents/worker-implementer.toml" ]]
[[ -f "$CODEX_HOME/skills/cost-aware-development/SKILL.md" ]]
grep -Fq 'model = "user-parent-model"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_model = "gpt-5.6-luna"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_reasoning_effort = "high"' "$CODEX_HOME/config.toml"
grep -Fq 'model = "auto"' "$CODEX_HOME/codex-flow.toml"
grep -Fq 'resolved_model = "gpt-5.6-luna"' "$CODEX_HOME/codex-flow.toml"
grep -Fxq "$ROOT_DIR" "$CODEX_HOME/codex-flow/source"
grep -Fxq "$(cat "$ROOT_DIR/VERSION")" "$CODEX_HOME/codex-flow/version"

codex-flow status
codex-flow doctor

# Explicit overrides must become both policy and concrete Codex fallback.
CODEX_FLOW_WORKER_MODEL=gpt-test-worker \
CODEX_FLOW_WORKER_MIN_EFFORT=xhigh \
CODEX_FLOW_PARENT_MIN_EFFORT=xhigh \
bash "$ROOT_DIR/install.sh"

grep -Fq 'default_subagent_model = "gpt-test-worker"' "$CODEX_HOME/config.toml"
grep -Fq 'default_subagent_reasoning_effort = "xhigh"' "$CODEX_HOME/config.toml"
grep -Fq 'resolved_model = "gpt-test-worker"' "$CODEX_HOME/codex-flow.toml"
codex-flow doctor

codex-flow uninstall
[[ ! -e "$CODEX_HOME/codex-flow.toml" ]]
[[ ! -e "$CODEX_HOME/codex-flow" ]]
[[ ! -e "$CODEX_FLOW_BIN_DIR/codex-flow" ]]
[[ ! -e "$CODEX_HOME/agents/worker-explorer.toml" ]]
[[ ! -e "$CODEX_HOME/agents/worker-implementer.toml" ]]
[[ ! -e "$CODEX_HOME/skills/cost-aware-development" ]]
grep -Fq 'model = "user-parent-model"' "$CODEX_HOME/config.toml"
grep -Fq 'keep_me = true' "$CODEX_HOME/config.toml"
! grep -q '^default_subagent_model' "$CODEX_HOME/config.toml"
! grep -q '^default_subagent_reasoning_effort' "$CODEX_HOME/config.toml"

printf 'smoke test passed\n'
