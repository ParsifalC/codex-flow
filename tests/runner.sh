#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) workdir="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$workdir" ]]
if [[ "$model" == "gpt-test-fail" ]]; then
  printf '%s\n' 'simulated infrastructure failure' >&2
  exit 2
fi
count_file="$workdir/.fake-codex-count"
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

python3 "$ROOT/scripts/run-benchmark.py" --manifest "$TMP/manifest.json" --dry-run > "$TMP/plan.json"
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
assert r['repair_cycles'] == 1, r
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

printf 'runner smoke test passed\n'
