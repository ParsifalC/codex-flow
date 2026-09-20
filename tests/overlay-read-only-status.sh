#!/usr/bin/env bash
# Client status must not create an application or telemetry directory.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_STATUS_ROOT="$(mktemp -d)"
trap 'rm -rf "$FLOW_STATUS_ROOT"' EXIT
export CODEX_HOME="$FLOW_STATUS_ROOT/home"
mkdir -p "$CODEX_HOME"
printf '[telemetry]\nenabled=false\n' > "$CODEX_HOME/codex-flow.toml"
if "$ROOT/apps/macos-overlay/bin/FlowPilot" status --json > "$FLOW_STATUS_ROOT/status.json"; then
    echo 'Unexpected daemon in isolated status test' >&2
    exit 1
else
    FLOW_STATUS_EXIT=$?
    test "$FLOW_STATUS_EXIT" -eq 1
fi
python3 - "$FLOW_STATUS_ROOT/status.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    assert json.load(stream)["running"] is False
PY
test ! -e "$CODEX_HOME/codex-flow"
echo 'Read-only overlay status check passed'
