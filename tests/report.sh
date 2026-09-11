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
grep -Fq '## Strategy results' "$TMP/report.md"
grep -Fq '## Token efficiency' "$TMP/report.md"
grep -Fq 'net-new' "$TMP/report.md"
grep -Fq '## Sol capability evidence' "$TMP/report.md"
grep -Fq '## Fixed-high flow evidence' "$TMP/report.md"
grep -Fq '## Adaptive reasoning evidence' "$TMP/report.md"
grep -Fq '## Advisory routing' "$TMP/report.md"
grep -Fq 'gpt-5.6-luna' "$TMP/report.md"
grep -Fq 'gpt-5.6-terra' "$TMP/report.md"
grep -Fq 'Conclusions are advisory' "$TMP/report.md"

# Mixed-model runtime reporting must expose raw total volume separately from
# Parent/Worker attribution and cached-vs-net-new input. This is the key view
# for deciding whether FlowPilot saves expensive Parent work even when total
# token volume grows.
python3 - "$TMP/token-results.jsonl" <<'PY'
import json,sys
path=sys.argv[1]
rows=[
    {
        'schema_version':2,'task_id':'t1','task_class':'routine','strategy_id':'sol-direct','strategy':'direct',
        'reasoning_policy':'fixed','model':'gpt-5.6-sol','reasoning_effort':'high','worker_model':None,
        'worker_reasoning_effort':None,'passed':True,'first_passed':True,'input_tokens':100,'cached_input_tokens':40,
        'output_tokens':20,'model_usage':[{'role':'direct','model':'gpt-5.6-sol','reasoning_effort':'high','calls':1,
        'input_tokens':100,'cached_input_tokens':40,'output_tokens':20}],'repair_cycles':0,'review_cycles':0,
        'wall_time_seconds':1.0,'codex_exit_code':0
    },
    {
        'schema_version':2,'task_id':'t1','task_class':'routine','strategy_id':'codex-flow-runtime-efficient','strategy':'runtime',
        'reasoning_policy':'fixed','model':'gpt-5.6-sol','reasoning_effort':'high','worker_model':'gpt-5.6-luna',
        'worker_reasoning_effort':'high','passed':True,'first_passed':True,'input_tokens':110,'cached_input_tokens':65,
        'output_tokens':20,'model_usage':[
            {'role':'parent','model':'gpt-5.6-sol','reasoning_effort':'high','calls':1,'input_tokens':20,'cached_input_tokens':5,'output_tokens':5},
            {'role':'worker','model':'gpt-5.6-luna','reasoning_effort':'high','calls':1,'input_tokens':90,'cached_input_tokens':60,'output_tokens':15}
        ],'repair_cycles':0,'review_cycles':0,'wall_time_seconds':1.0,'codex_exit_code':0
    },
]
with open(path,'w') as sink:
    for row in rows: sink.write(json.dumps(row)+'\n')
PY
printf '{}\n' > "$TMP/empty-analysis.json"
python3 "$ROOT/scripts/render-benchmark-report.py" \
  --results "$TMP/token-results.jsonl" \
  --prices "$ROOT/benchmark/prices/gpt-5.6-2026-08-30.json" \
  --analysis "$TMP/empty-analysis.json" \
  --output "$TMP/token-report.md" \
  --title 'Token attribution fixture'
grep -Fq '| codex-flow-runtime-efficient | 130 | 25 | 105 | 65 | 45 | 59.1% | +8.3% | -25.0% | +79.2% |' "$TMP/token-report.md"
grep -Fq '| sol-direct | 120 | 0 | 0 | 40 | 60 | 40.0% | +0.0% | +0.0% | n/a |' "$TMP/token-report.md"

printf 'report smoke test passed\n'
