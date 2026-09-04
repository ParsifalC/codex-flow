#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RUNTIME="$ROOT/scripts/strategies/task_budget_runtime.py"
STATE="$TMP/task-budget.json"
POLICY='{"soft_timeout_seconds":10,"hard_timeout_seconds":20,"max_work_units":2,"max_implementation_attempts":2,"max_replans":1,"max_replacements":1}'

python3 -m py_compile "$ROOT/scripts/strategies/base.py" "$ROOT/scripts/strategies/efficient.py" "$RUNTIME"

run() {
  python3 "$RUNTIME" "$@"
}

expect_fail() {
  if "$@" >"$TMP/expected.out" 2>"$TMP/expected.err"; then
    echo "command unexpectedly succeeded: $*" >&2
    exit 1
  fi
  test ! -s "$TMP/expected.out"
  test -s "$TMP/expected.err"
}

run init --state-file "$STATE" --task-id task-alpha --now 100 --policy-json "$POLICY" >"$TMP/init.json"
python3 - "$TMP/init.json" "$STATE" <<'PY'
import hashlib
import json
import pathlib
import sys

result = json.load(open(sys.argv[1]))
state = json.load(open(sys.argv[2]))
assert result["initialized"] is True and result["action"] == "continue", result
assert state["schema_version"] == 1, state
assert state["task_id"] == hashlib.sha256(b"task-alpha").hexdigest(), state
assert "task-alpha" not in json.dumps(state), state
assert "src/secret.py" not in json.dumps(state), state
assert state["limits"] == {
    "work_unit": 2,
    "implementation_attempt": 2,
    "replan": 1,
    "replacement": 1,
}, state
PY

# Re-init is idempotent and never refreshes the original start/deadlines.
run init --state-file "$STATE" --task-id task-alpha --now 101 --policy-json "$POLICY" >"$TMP/reinit.json"
python3 - "$TMP/reinit.json" "$STATE" <<'PY'
import json, sys
result = json.load(open(sys.argv[1])); state = json.load(open(sys.argv[2]))
assert result["initialized"] is False and result["idempotent"] is True, result
assert state["started_at"] == 100 and state["soft_deadline"] == 110 and state["hard_deadline"] == 120, state
PY

# Existing ledger identity is immutable: neither a different task nor policy may reset it.
expect_fail run init --state-file "$STATE" --task-id task-other --now 101 --policy-json "$POLICY"
OTHER_POLICY='{"soft_timeout_seconds":11,"hard_timeout_seconds":20,"max_work_units":2,"max_implementation_attempts":2,"max_replans":1,"max_replacements":1}'
expect_fail run init --state-file "$STATE" --task-id task-alpha --now 101 --policy-json "$OTHER_POLICY"

# Each reservation is hashed, fingerprint-idempotent, and bounded by its kind.
run reserve --state-file "$STATE" --task-id task-alpha --now 102 --kind work_unit --reservation-id unit-1 --fingerprint 'src/secret.py' >"$TMP/unit.json"
run reserve --state-file "$STATE" --task-id task-alpha --now 103 --kind work_unit --reservation-id unit-1 --fingerprint 'src/secret.py' >"$TMP/unit-repeat.json"
python3 - "$TMP/unit-repeat.json" "$STATE" <<'PY'
import hashlib, json, sys
result = json.load(open(sys.argv[1])); state = json.load(open(sys.argv[2]))
assert result["idempotent"] is True and result["counters"]["work_unit"] == 1, result
entry = state["reservations"]["work_unit"][0]
assert entry["reservation_id"] == hashlib.sha256(b"unit-1").hexdigest(), entry
assert entry["fingerprint"] == hashlib.sha256(b"src/secret.py").hexdigest(), entry
assert "src/secret.py" not in json.dumps(state), state
PY
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 103 --kind work_unit --reservation-id unit-1 --fingerprint changed
run reserve --state-file "$STATE" --task-id task-alpha --now 104 --kind work_unit --reservation-id unit-2 --fingerprint delta-2 >/dev/null
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 105 --kind work_unit --reservation-id unit-3 --fingerprint delta-3

run reserve --state-file "$STATE" --task-id task-alpha --now 106 --kind implementation_attempt --reservation-id attempt-1 --fingerprint attempt >/dev/null
run reserve --state-file "$STATE" --task-id task-alpha --now 107 --kind implementation_attempt --reservation-id attempt-2 --fingerprint attempt >/dev/null
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 108 --kind implementation_attempt --reservation-id attempt-3 --fingerprint attempt
run reserve --state-file "$STATE" --task-id task-alpha --now 109 --kind replan --reservation-id replan-1 --fingerprint remaining-delta >/dev/null
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 109 --kind replan --reservation-id replan-2 --fingerprint another-delta
run reserve --state-file "$STATE" --task-id task-alpha --now 109 --kind replacement --reservation-id replacement-1 --fingerprint isolated >/dev/null
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 109 --kind replacement --reservation-id replacement-2 --fingerprint isolated

# Time decisions are deterministic and soft/hard boundaries reject new work.
run status --state-file "$STATE" --task-id task-alpha --now 109 >"$TMP/continue.json"
python3 - "$TMP/continue.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["action"] == "continue" and p["permits_new_work"] is True, p
PY
run status --state-file "$STATE" --task-id task-alpha --now 110 >"$TMP/converge.json"
python3 - "$TMP/converge.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["action"] == "converge" and p["permits_new_work"] is False and not p["cancel_required"], p
PY
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 110 --kind replan --reservation-id replan-soft --fingerprint blocked
run status --state-file "$STATE" --task-id task-alpha --now 120 >"$TMP/stop.json"
python3 - "$TMP/stop.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["action"] == "stop" and p["cancel_required"] is True, p
PY
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 120 --kind replan --reservation-id replan-hard --fingerprint blocked
run finish --state-file "$STATE" --task-id task-alpha --now 121 --outcome success >"$TMP/finish.json"
python3 - "$TMP/finish.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["closed"] is True and p["action"] == "stop" and not p["cancel_required"], p
PY
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 121 --kind replan --reservation-id replan-closed --fingerprint blocked

# Input/type/time/symlink hardening fails closed without a traceback.
expect_fail run status --state-file "$STATE" --task-id task-alpha --now 99
expect_fail run status --state-file "$STATE" --task-id task-alpha --now 1700000000000
expect_fail run status --state-file "$STATE" --task-id task-alpha --now nan
if python3 "$RUNTIME" init --state-file "$TMP/bool.json" --task-id bool --now 0 --policy-json \
  '{"soft_timeout_seconds":true,"hard_timeout_seconds":20,"max_work_units":1,"max_implementation_attempts":1,"max_replans":0,"max_replacements":0}' \
  >"$TMP/bool.out" 2>"$TMP/bool.err"; then
  echo "boolean policy value unexpectedly accepted" >&2
  exit 1
fi
grep -Fq 'must be an integer' "$TMP/bool.err"
ln -s "$STATE" "$TMP/state-link.json"
expect_fail run status --state-file "$TMP/state-link.json" --task-id task-alpha --now 121
ln -s "$TMP/lock-target" "$TMP/lock-link.json.lock"
touch "$TMP/lock-target"
expect_fail run init --state-file "$TMP/lock-link.json" --task-id task-lock --now 0 --policy-json "$POLICY"

# At least one concurrent atomic reserve per process succeeds without lost updates.
CONCURRENT="$TMP/concurrent.json"
CONCURRENT_POLICY='{"soft_timeout_seconds":100,"hard_timeout_seconds":200,"max_work_units":8,"max_implementation_attempts":1,"max_replans":1,"max_replacements":1}'
run init --state-file "$CONCURRENT" --task-id concurrent --now 1000 --policy-json "$CONCURRENT_POLICY" >/dev/null
for i in 1 2 3 4 5 6 7 8; do
  run reserve --state-file "$CONCURRENT" --task-id concurrent --now 1001 --kind work_unit \
    --reservation-id "unit-$i" --fingerprint "delta-$i" >"$TMP/concurrent-$i.json" &
done
wait
run status --state-file "$CONCURRENT" --task-id concurrent --now 1002 >"$TMP/concurrent-status.json"
python3 - "$TMP/concurrent-status.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["counters"]["work_unit"] == 8, p
PY

# Reservations from different kinds may interleave in wall-clock order; only
# each individual kind's append order must be monotonic.
INTERLEAVED="$TMP/interleaved.json"
run init --state-file "$INTERLEAVED" --task-id interleaved --now 2000 --policy-json "$POLICY" >/dev/null
run reserve --state-file "$INTERLEAVED" --task-id interleaved --now 2001 --kind implementation_attempt \
  --reservation-id attempt-1 --fingerprint attempt-1 >/dev/null
run reserve --state-file "$INTERLEAVED" --task-id interleaved --now 2002 --kind work_unit \
  --reservation-id unit-1 --fingerprint logical-unit-1 >/dev/null
run status --state-file "$INTERLEAVED" --task-id interleaved --now 2003 >"$TMP/interleaved-status.json"
python3 - "$TMP/interleaved-status.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["counters"]["implementation_attempt"] == 1, p
assert p["counters"]["work_unit"] == 1, p
PY

# Compiler carries the efficient budget only for delegated plans; direct and legacy strategies stay None.
cat >"$TMP/policy.toml" <<'EOF'
schema_version = 4
[strategy]
enabled = true
profile = "efficient"
[routing]
mode = "adaptive"
[modifiers]
review = "auto"
fanout = "auto"
[parent]
model_policy = "latest-capable"
min_model = "auto"
min_reasoning_effort = "high"
routine_effort = "high"
complex_effort = "high"
critical_effort = "xhigh"
[worker]
model_policy = "latest-efficient"
model = "auto"
resolved_model = "gpt-test-efficient"
min_reasoning_effort = "xhigh"
routine_effort = "xhigh"
complex_effort = "xhigh"
critical_effort = "max"
[runtime]
max_concurrent_threads = 4
max_repair_cycles = 2
EOF
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/policy.toml" plan --repo-policy none --quota-pressure unknown \
  --routing delegate --complexity complex --scope cross-module >"$TMP/plan.json"
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/policy.toml" plan --repo-policy none --quota-pressure unknown \
  --routing direct --complexity complex --scope cross-module >"$TMP/direct-plan.json"
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/policy.toml" plan --repo-policy none --quota-pressure unknown \
  --profile balanced --routing delegate --complexity complex --scope cross-module >"$TMP/legacy-plan.json"
python3 - "$TMP/plan.json" "$TMP/direct-plan.json" "$TMP/legacy-plan.json" <<'PY'
import json, sys
delegated, direct, legacy = (json.load(open(path)) for path in sys.argv[1:])
assert delegated["schema_version"] == 10, delegated
assert delegated["task_budget"] == {
    "soft_timeout_seconds": 1500,
    "hard_timeout_seconds": 1800,
    "max_work_units": 2,
    "max_implementation_attempts": 3,
    "max_replans": 1,
    "max_replacements": 1,
}, delegated
assert delegated["implementation_stage"]["maximum_work_units"] == delegated["task_budget"]["max_work_units"], delegated
assert direct["schema_version"] == 10 and direct["task_budget"] is None, direct
assert legacy["schema_version"] == 10 and legacy["task_budget"] is None, legacy
PY

printf 'task budget runtime test passed\n'
