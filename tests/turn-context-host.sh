#!/usr/bin/env bash
# Read the selected installation's real Desktop probe; never launch a synthetic task.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT_DIR/tests/turn-context-desktop-probe.py" status
