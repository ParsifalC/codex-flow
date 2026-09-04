#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "$ROOT_DIR/tests/test_hook_trust.py"
bash "$ROOT_DIR/tests/account-snapshot.sh"
bash "$ROOT_DIR/tests/telemetry-core.sh"
bash "$ROOT_DIR/tests/telemetry-repair.sh"
bash "$ROOT_DIR/tests/latency-telemetry.sh"
