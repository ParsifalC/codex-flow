#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT_DIR/tests/telemetry-core.sh"
bash "$ROOT_DIR/tests/telemetry-repair.sh"
