#!/usr/bin/env bash
# Exercise real SwiftUI layout; state-only tests cannot catch layout reentrancy.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_ACCOUNT_TEST="$(mktemp -d)"
FLOW_ACCOUNT_PID=""
cleanup() {
    if [[ -n "$FLOW_ACCOUNT_PID" ]]; then
        kill "$FLOW_ACCOUNT_PID" 2>/dev/null || true
        wait "$FLOW_ACCOUNT_PID" 2>/dev/null || true
    fi
    rm -rf "$FLOW_ACCOUNT_TEST"
}
trap cleanup EXIT
export CODEX_HOME="$FLOW_ACCOUNT_TEST/home"
export CODEX_FLOW_BIN_DIR="$ROOT/bin"
mkdir -p "$CODEX_HOME"
printf '[telemetry]\nenabled=false\n' > "$CODEX_HOME/codex-flow.toml"
BIN="$ROOT/apps/macos-overlay/bin/FlowPilot"
"$BIN" start > "$FLOW_ACCOUNT_TEST/app.log" 2>&1 &
FLOW_ACCOUNT_PID=$!
for _ in {1..50}; do
    if "$BIN" status --json > /dev/null 2>&1; then break; fi
    sleep 0.1
done
for _ in {1..5}; do
    "$BIN" tab account > /dev/null
    sleep 0.5
    if ! "$BIN" status --json > "$FLOW_ACCOUNT_TEST/status.json"; then
        cat "$FLOW_ACCOUNT_TEST/app.log" >&2
        exit 1
    fi
    python3 - "$FLOW_ACCOUNT_TEST/status.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    state = json.load(stream)
assert state['running'] and state['activeTab'] == 'Account', state
PY
    "$BIN" tab inspector > /dev/null
    sleep 0.2
done
echo 'Account tab renders repeatedly without crashing'
