#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 "$ROOT/scripts/materialize-corpus.py" \
  --corpus "$ROOT/benchmark/corpus.json" \
  --profiles "$ROOT/benchmark/profiles.json" \
  --profile quick \
  --output-dir "$TMP/a" \
  --manifest "$TMP/quick-a.json" > "$TMP/summary-a.json"

python3 "$ROOT/scripts/materialize-corpus.py" \
  --corpus "$ROOT/benchmark/corpus.json" \
  --profiles "$ROOT/benchmark/profiles.json" \
  --profile quick \
  --output-dir "$TMP/b" \
  --manifest "$TMP/quick-b.json" > "$TMP/summary-b.json"

python3 - "$TMP/summary-a.json" "$TMP/quick-a.json" "$TMP/quick-b.json" <<'PY'
import json, subprocess, sys
summary=json.load(open(sys.argv[1]))
a=json.load(open(sys.argv[2])); b=json.load(open(sys.argv[3]))
assert summary['tasks']==6, summary
assert summary['configurations']==3, summary
assert summary['repetitions']==1, summary
assert summary['planned_runs']==18, summary
assert len(a['tasks'])==6 and len(a['matrix'])==3 and a['repetitions']==1
assert [t['base_ref'] for t in a['tasks']] == [t['base_ref'] for t in b['tasks']]
for task in a['tasks']:
    assert len(task['base_ref']) == 40, task
    proc=subprocess.run(task['verify'], cwd=task['source'])
    assert proc.returncode != 0, f"seed unexpectedly passes verifier: {task['id']}"
PY

python3 "$ROOT/scripts/materialize-corpus.py" \
  --corpus "$ROOT/benchmark/corpus.json" \
  --profiles "$ROOT/benchmark/profiles.json" \
  --profile full \
  --output-dir "$TMP/full" \
  --manifest "$TMP/full.json" > "$TMP/full-summary.json"
python3 - "$TMP/full-summary.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s['tasks']==6, s
assert s['configurations']==5, s
assert s['repetitions']==3, s
assert s['planned_runs']==90, s
PY

python3 "$ROOT/scripts/run-benchmark.py" --manifest "$TMP/quick-a.json" --output "$TMP/unused.jsonl" --dry-run > "$TMP/runner-plan.json"
python3 - "$TMP/runner-plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['planned_runs']==18,p
PY

printf 'corpus test passed\n'
