#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(python3 "$ROOT_DIR/scripts/analyze-benchmark.py" \
  --results "$ROOT_DIR/tests/fixtures/benchmark-results.jsonl" \
  --prices "$ROOT_DIR/tests/fixtures/benchmark-prices.json" \
  --policy "$ROOT_DIR/policy/benchmark.toml" \
  --json)"
python3 - "$out" <<'PY'
import json, sys
r = json.loads(sys.argv[1])["recommendations"]
assert r["routine"]["model"] == "gpt-5.6-luna", r
assert r["routine"]["reasoning_effort"] == "high", r
assert r["complex"]["model"] == "gpt-5.6-terra", r
assert r["complex"]["reasoning_effort"] == "xhigh", r
assert r["critical"]["model"] == "gpt-5.6-terra", r
assert r["critical"]["reasoning_effort"] == "max", r
PY
printf 'benchmark test passed\n'
