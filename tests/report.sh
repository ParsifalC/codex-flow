#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 "$ROOT/scripts/analyze-benchmark.py" \
  --results "$ROOT/tests/fixtures/benchmark-results.jsonl" \
  --prices "$ROOT/tests/fixtures/benchmark-prices.json" \
  --json > "$TMP/analysis.json"

python3 "$ROOT/scripts/render-benchmark-report.py" \
  --results "$ROOT/tests/fixtures/benchmark-results.jsonl" \
  --prices "$ROOT/tests/fixtures/benchmark-prices.json" \
  --analysis "$TMP/analysis.json" \
  --output "$TMP/report.md" \
  --title 'Fixture benchmark'

grep -Fq '# Fixture benchmark' "$TMP/report.md"
grep -Fq '## Overall' "$TMP/report.md"
grep -Fq '## Configuration results' "$TMP/report.md"
grep -Fq '## Advisory routing' "$TMP/report.md"
grep -Fq 'gpt-5.6-luna' "$TMP/report.md"
grep -Fq 'gpt-5.6-terra' "$TMP/report.md"
grep -Fq 'Routing output is advisory only' "$TMP/report.md"

printf 'report smoke test passed\n'
