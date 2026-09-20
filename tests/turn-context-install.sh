#!/usr/bin/env bash
# Validate the recursively installed runtime without touching the user's home.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_INSTALL_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$FLOW_INSTALL_TEST_ROOT"' EXIT
export CODEX_HOME="$FLOW_INSTALL_TEST_ROOT/home"
export CODEX_FLOW_BIN_DIR="$FLOW_INSTALL_TEST_ROOT/bin"
export CODEX_FLOW_SHELL=none
export PYTHONDONTWRITEBYTECODE=1
export PYTHONIOENCODING=utf-8
bash "$ROOT_DIR/install.sh" > "$FLOW_INSTALL_TEST_ROOT/install.log"
for module in turn_context turn_result publication; do
  test -f "$CODEX_HOME/codex-flow/telemetry_core/$module.py"
done
grep -Fq 'context write-goal' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
grep -Fq 'context write-plan' "$CODEX_HOME/skills/flow-pilot/SKILL.md"
CODEX_FLOW_TEST_TELEMETRY_SCRIPT="$CODEX_HOME/codex-flow/telemetry.py" \
  python3 "$ROOT_DIR/tests/test_turn_context_cli.py"
python3 - "$ROOT_DIR/scripts/telemetry.py" "$CODEX_HOME/codex-flow/telemetry.py" <<'PY'
import json, os, subprocess, sys
responses = []
for script in sys.argv[1:]:
    result = subprocess.run([sys.executable, script, "context", "write-goal"],
                            capture_output=True, text=True, env=os.environ.copy())
    assert result.returncode == 2, result
    responses.append(json.loads(result.stderr))
assert responses[0] == responses[1], responses
PY
printf '%s\n' 'Turn context isolated installation checks passed.'
