#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/login"
printf '%s\n' '{"fixture":"local-login"}' > "$TMP/login/auth.json"
printf '%s\n' 'Global instructions must not leak into baselines' > "$TMP/login/AGENTS.md"
export CODEX_HOME="$TMP/login"

REPO="$TMP/source"
BIN="$TMP/bin"
mkdir -p "$REPO" "$BIN"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
cat > "$REPO/verify.py" <<'PY'
from pathlib import Path
raise SystemExit(0 if Path('answer.txt').read_text().strip() == 'correct' else 1)
PY
echo seed > "$REPO/seed.txt"
git -C "$REPO" add .
git -C "$REPO" commit -qm seed
BASE="$(git -C "$REPO" rev-parse HEAD)"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
workdir=""
model=""
last_message=""
prompt="${!#}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) workdir="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --output-last-message|-o) last_message="$2"; shift 2 ;;
    --output-schema) shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$workdir" ]]
if [[ "$CODEX_HOME" == *".codex-baseline" ]]; then
  [[ -f "$CODEX_HOME/auth.json" && ! -e "$CODEX_HOME/AGENTS.md" ]]
fi
if [[ "$model" == "gpt-test-fail" ]]; then
  printf '%s\n' 'simulated infrastructure failure' >&2
  exit 2
fi
if [[ "$model" == "gpt-test-parent" ]]; then
  if [[ -n "$last_message" ]]; then
    if [[ "$prompt" == *"performing the codex-flow final review"* ]]; then
      if [[ -f "$workdir/answer.txt" ]] && [[ "$(cat "$workdir/answer.txt")" == "correct" ]]; then
        printf '%s\n' '{"verdict":"pass","feedback":""}' > "$last_message"
      else
        printf '%s\n' '{"verdict":"repair","feedback":"write the required correct answer"}' > "$last_message"
      fi
    else
      printf '%s\n' 'Implement answer.txt exactly as required and verify it.' > "$last_message"
    fi
  elif [[ "$prompt" == *"FlowPilot"* ]]; then
    python3 - "$CODEX_HOME/auth.json" <<'AUTH'
import json, stat, sys
from pathlib import Path
p=Path(sys.argv[1])
assert json.loads(p.read_text()) == {"fixture": "local-login"}
assert stat.S_IMODE(p.stat().st_mode) == 0o600
AUTH
    printf 'correct\n' > "$workdir/answer.txt"
    if [[ -n "${CODEX_HOME:-}" ]]; then
      mkdir -p "$CODEX_HOME/codex-flow/telemetry/runs"
      cat > "$CODEX_HOME/codex-flow/telemetry/runs/simulated-run.json" <<'TELEM'
{"parent":{"model":"gpt-test-parent","usage":{"input_tokens":80,"cached_input_tokens":15,"output_tokens":8}},"workers":{"worker-1":{"name":"worker-implementer","model":"gpt-test-worker","reasoning_effort":"xhigh","usage":{"input_tokens":120,"cached_input_tokens":25,"output_tokens":12}}}}
TELEM
    fi
  fi
  printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}'
  exit 0
fi
count_file="$workdir/.fake-codex-count-$model"
count=0
[[ -f "$count_file" ]] && count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [[ "$count" -eq 1 ]]; then
  printf 'wrong\n' > "$workdir/answer.txt"
else
  printf 'correct\n' > "$workdir/answer.txt"
fi
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}'
SH
chmod +x "$BIN/codex"
export PATH="$BIN:$PATH"

cat > "$TMP/manifest.json" <<EOF
{
  "schema_version": 1,
  "repetitions": 1,
  "timeout_seconds": 30,
  "max_repair_cycles": 2,
  "matrix": [
    {"model":"gpt-test-worker","reasoning_effort":"high"},
    {"model":"gpt-test-fail","reasoning_effort":"high"}
  ],
  "tasks": [{
    "id":"runner-smoke",
    "class":"routine",
    "source":"$REPO",
    "base_ref":"$BASE",
    "prompt":"Create answer.txt containing correct.",
    "verify":["python3","verify.py"]
  }]
}
EOF

python3 "$ROOT/scripts/run-benchmark.py" \
  --manifest "$TMP/manifest.json" \
  --output "$TMP/dry-run-results.jsonl" \
  --dry-run > "$TMP/plan.json"
python3 - "$TMP/plan.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['planned_runs'] == 2, p
PY

python3 "$ROOT/scripts/run-benchmark.py" --manifest "$TMP/manifest.json" --output "$TMP/results.jsonl"
python3 - "$TMP/results.jsonl" <<'PY'
import json, sys
rows=[json.loads(x) for x in open(sys.argv[1]) if x.strip()]
assert len(rows) == 2, rows
by_model={r['model']: r for r in rows}

r=by_model['gpt-test-worker']
assert r['passed'] is True, r
assert r['strategy_id'] == 'gpt-test-worker-high', r
assert r['strategy'] == 'direct', r
assert r['reasoning_policy'] == 'fixed', r
assert r['first_passed'] is False, r
assert r['repair_cycles'] == 1, r
assert r['review_cycles'] == 0, r
assert r['input_tokens'] == 200, r
assert r['cached_input_tokens'] == 40, r
assert r['output_tokens'] == 20, r
assert r['reasoning_effort'] == 'high', r
assert r['source_commit'], r

f=by_model['gpt-test-fail']
assert f['passed'] is False, f
assert f['repair_cycles'] == 0, f
assert f['codex_exit_code'] == 2, f
assert f['input_tokens'] == 0 and f['output_tokens'] == 0, f
assert 'simulated infrastructure failure' in f['diagnostic_excerpt'], f
PY

cat > "$TMP/flow-manifest.json" <<EOF
{
  "schema_version": 2,
  "repetitions": 1,
  "timeout_seconds": 30,
  "max_repair_cycles": 2,
  "matrix": [{
    "id":"codex-flow-high",
    "strategy":"flow",
    "reasoning_policy":"fixed",
    "parent":{"model":"gpt-test-parent","reasoning_effort":"high"},
    "worker":{"model":"gpt-test-worker","reasoning_effort":"high"}
  }],
  "tasks": [{
    "id":"flow-smoke",
    "class":"complex",
    "source":"$REPO",
    "base_ref":"$BASE",
    "prompt":"Create answer.txt containing correct.",
    "verify":["python3","verify.py"]
  }]
}
EOF

python3 "$ROOT/scripts/run-benchmark.py" --manifest "$TMP/flow-manifest.json" --output "$TMP/flow-results.jsonl"
python3 - "$TMP/flow-results.jsonl" <<'PY'
import json, sys
row=json.loads(open(sys.argv[1]).read())
assert row['strategy_id']=='codex-flow-high',row
assert row['strategy']=='flow' and row['reasoning_policy']=='fixed',row
assert row['model']=='gpt-test-parent' and row['worker_model']=='gpt-test-worker',row
assert row['passed'] is True and row['first_passed'] is False,row
assert row['repair_cycles']==1 and row['review_cycles']==2,row
assert row['input_tokens']==500 and row['cached_input_tokens']==100 and row['output_tokens']==50,row
usage={item['role']:item for item in row['model_usage']}
assert usage['parent']['calls']==3 and usage['parent']['input_tokens']==300,usage
assert usage['worker']['calls']==2 and usage['worker']['input_tokens']==200,usage
PY

cat > "$TMP/runtime-manifest.json" <<EOF
{
  "schema_version": 2,
  "repetitions": 1,
  "timeout_seconds": 30,
  "max_repair_cycles": 2,
  "matrix": [{
    "id":"codex-flow-runtime",
    "strategy":"runtime",
    "reasoning_policy":"fixed",
    "parent":{"model":"gpt-test-parent","reasoning_effort":"high"},
    "worker":{"model":"gpt-test-worker","reasoning_effort":"high"}
  }],
  "tasks": [{
    "id":"runtime-smoke",
    "class":"complex",
    "source":"$REPO",
    "base_ref":"$BASE",
    "prompt":"Create answer.txt containing correct.",
    "verify":["python3","verify.py"]
  }]
}
EOF

mkdir -p "$TMP/login"
printf '%s\n' '{"fixture":"local-login"}' > "$TMP/login/auth.json"
CODEX_HOME="$TMP/login" python3 "$ROOT/scripts/run-benchmark.py" --manifest "$TMP/runtime-manifest.json" --output "$TMP/runtime-results.jsonl"
python3 - "$TMP/runtime-results.jsonl" <<'PY'
import json, sys
row=json.loads(open(sys.argv[1]).read())
assert row['strategy_id']=='codex-flow-runtime',row
assert row['strategy']=='runtime' and row['reasoning_policy']=='fixed',row
assert row['model']=='gpt-test-parent' and row['worker_model']=='gpt-test-worker',row
assert row['passed'] is True and row['first_passed'] is True,row
assert row['repair_cycles']==0,row
assert row['input_tokens']==200 and row['cached_input_tokens']==40 and row['output_tokens']==20,row
usage={item['role']:item for item in row['model_usage']}
assert usage['parent']['calls']==1 and usage['parent']['input_tokens']==80,usage
assert usage['worker']['calls']==1 and usage['worker']['input_tokens']==120,usage
assert usage['worker']['reasoning_effort']=='xhigh',usage
assert row['worker_reasoning_effort']=='high',row
PY

cat > "$TMP/prices.json" <<'EOF'
{
  "gpt-test-parent": {"input": 1.0, "cached_input": 0.5, "output": 2.0},
  "gpt-test-worker": {"input": 0.5, "cached_input": 0.2, "output": 1.0}
}
EOF

python3 "$ROOT/scripts/analyze-benchmark.py" \
  --results "$TMP/runtime-results.jsonl" \
  --prices "$TMP/prices.json" \
  --policy "$ROOT/policy/benchmark.toml" \
  --min-samples 1 \
  --json > "$TMP/runtime-analysis.json"
python3 - "$TMP/runtime-analysis.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
configs = data['configurations']
assert any(c['strategy_id'] == 'codex-flow-runtime' and c['strategy'] == 'runtime' for c in configs), configs
PY


cat > "$TMP/failfast.json" <<EOF
{
  "schema_version": 1,
  "repetitions": 1,
  "timeout_seconds": 30,
  "max_repair_cycles": 2,
  "matrix": [
    {"model":"gpt-test-fail","reasoning_effort":"high"},
    {"model":"gpt-test-worker","reasoning_effort":"high"}
  ],
  "tasks": [{
    "id":"runner-failfast",
    "class":"routine",
    "source":"$REPO",
    "base_ref":"$BASE",
    "prompt":"Create answer.txt containing correct.",
    "verify":["python3","verify.py"]
  }]
}
EOF

if python3 "$ROOT/scripts/run-benchmark.py" \
  --manifest "$TMP/failfast.json" \
  --output "$TMP/failfast-results.jsonl" \
  --fail-fast-infrastructure; then
  echo 'fail-fast benchmark unexpectedly succeeded' >&2
  exit 1
fi
python3 - "$TMP/failfast-results.jsonl" <<'PY'
import json, sys
rows=[json.loads(x) for x in open(sys.argv[1]) if x.strip()]
assert len(rows) == 1, rows
assert rows[0]['model'] == 'gpt-test-fail', rows
assert rows[0]['codex_exit_code'] == 2, rows
PY

python3 - "$ROOT/scripts/run-benchmark.py" "$TMP/timeout-repo" <<'PY'
import importlib.util, subprocess, sys
from pathlib import Path
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('runner', sys.argv[1])
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
timeout = subprocess.TimeoutExpired(
    ['codex'], 1,
    output=b'{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}\n',
    stderr=b'startup diagnostic',
)
workdir=Path(sys.argv[2]); workdir.mkdir()
with patch.object(runner.subprocess, 'run', side_effect=timeout) as run:
    result = runner.run_codex(workdir, 'fixture', 'high', 'fixture', 1)
assert result[0] == 124 and result[1]['input_tokens'] == 10, result
assert 'startup diagnostic' in result[2] and 'turn.completed' in result[2], result
assert run.call_args.kwargs['stdin'] == subprocess.DEVNULL
PY

printf 'runner smoke test passed\n'
