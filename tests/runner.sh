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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) workdir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$workdir" ]]
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
  "matrix": [{"model":"gpt-test-worker","reasoning_effort":"high"}],
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
assert p['planned_runs'] == 1, p
PY

python3 "$ROOT/scripts/run-benchmark.py" --manifest "$TMP/manifest.json" --output "$TMP/results.jsonl"
python3 - "$TMP/results.jsonl" <<'PY'
import json, sys
rows=[json.loads(x) for x in open(sys.argv[1]) if x.strip()]
assert len(rows) == 1, rows
r=rows[0]
assert r['passed'] is True, r
assert r['repair_cycles'] == 1, r
assert r['input_tokens'] == 200, r
assert r['cached_input_tokens'] == 40, r
assert r['output_tokens'] == 20, r
assert r['model'] == 'gpt-test-worker', r
assert r['reasoning_effort'] == 'high', r
assert r['source_commit'], r
PY

printf 'runner smoke test passed\n'
