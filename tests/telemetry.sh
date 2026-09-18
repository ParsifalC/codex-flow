#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  cd "$ROOT_DIR"
  python3 -m unittest tests/test_turn_context.py tests/test_turn_context_cli.py \
    tests/test_turn_result.py tests/test_publication.py tests/test_lock_recovery.py \
    tests/test_telemetry_write_guards.py
)

python3 "$ROOT_DIR/tests/test_hook_trust.py"
bash "$ROOT_DIR/tests/account-snapshot.sh"
bash "$ROOT_DIR/tests/telemetry-core.sh"
bash "$ROOT_DIR/tests/telemetry-repair.sh"
bash "$ROOT_DIR/tests/latency-telemetry.sh"
