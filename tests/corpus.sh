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
assert summary['tasks']==9, summary
assert summary['configurations']==5, summary
assert summary['repetitions']==1, summary
assert summary['planned_runs']==45, summary
assert summary['controlled_reasoning_effort']=='high', summary
assert summary['strategies']==['luna-direct','terra-direct','sol-direct','codex-flow-high','codex-flow-adaptive'],summary
assert len(a['tasks'])==9 and len(a['matrix'])==5 and a['repetitions']==1 and a['schema_version']==2
assert {name:sum(t['class']==name for t in a['tasks']) for name in ('routine','complex','critical')} == {'routine':3,'complex':3,'critical':3}
assert [t['base_ref'] for t in a['tasks']] == [t['base_ref'] for t in b['tasks']]
for task in a['tasks']:
    assert len(task['base_ref']) == 40, task
    proc=subprocess.run(task['verify'], cwd=task['source'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
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
assert s['tasks']==9, s
assert s['configurations']==6, s
assert s['repetitions']==3, s
assert s['planned_runs']==162, s
PY

# Agentic is the real FlowPilot comparison surface. Keep both efficient and
# balanced runtime profiles paired with the same three direct baselines.
python3 "$ROOT/scripts/materialize-corpus.py" \
  --corpus "$ROOT/benchmark/corpus.json" \
  --profiles "$ROOT/benchmark/profiles.json" \
  --profile agentic \
  --output-dir "$TMP/agentic" \
  --manifest "$TMP/agentic.json" > "$TMP/agentic-summary.json"
python3 - "$TMP/agentic-summary.json" "$TMP/agentic.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); m=json.load(open(sys.argv[2]))
expected=['luna-direct','terra-direct','sol-direct','codex-flow-runtime-efficient','codex-flow-runtime-balanced','codex-flow-runtime-astra-high']
assert s['tasks']==9 and s['configurations']==6 and s['repetitions']==1, s
assert s['planned_runs']==54 and s['strategies']==expected, s
assert [entry['id'] for entry in m['matrix']] == expected, m['matrix']
profiles={entry['id']:entry.get('profile') for entry in m['matrix'] if entry['strategy']=='runtime'}
astra=next(entry for entry in m['matrix'] if entry['id']=='codex-flow-runtime-astra-high')
assert astra['parent']=={'model':'gpt-6-astra','reasoning_effort':'high'}, astra
assert astra['routing_mode']=='delegate' and astra['worker']=={'model':'gpt-5.6-luna','reasoning_effort':'high'}, astra
assert profiles == {'codex-flow-runtime-efficient':'efficient','codex-flow-runtime-balanced':'balanced','codex-flow-runtime-astra-high':'efficient'}, profiles
PY

python3 "$ROOT/scripts/run-benchmark.py" --manifest "$TMP/quick-a.json" --output "$TMP/unused.jsonl" --dry-run > "$TMP/runner-plan.json"
python3 - "$TMP/runner-plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['planned_runs']==45,p
assert p['strategies']==['luna-direct','terra-direct','sol-direct','codex-flow-high','codex-flow-adaptive'],p
PY

printf 'corpus test passed\n'
