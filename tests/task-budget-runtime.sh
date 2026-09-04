#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RUNTIME="$ROOT/scripts/strategies/task_budget_runtime.py"
STATE="$TMP/task-budget.json"
POLICY='{"soft_timeout_seconds":10,"hard_timeout_seconds":20,"max_work_units":2,"max_implementation_attempts":2,"max_replans":1,"max_replacements":1,"max_review_attempts":2,"parent_finalization_seconds":2}'

python3 -m py_compile \
  "$ROOT/scripts/strategy_runtime.py" \
  "$ROOT/scripts/strategies/base.py" \
  "$ROOT/scripts/strategies/efficient.py" \
  "$ROOT/scripts/strategies/balanced.py" \
  "$ROOT/scripts/strategies/quality.py" \
  "$ROOT/scripts/strategies/speed.py" \
  "$RUNTIME"

run() { python3 "$RUNTIME" "$@"; }
expect_fail() {
  if "$@" >"$TMP/expected.out" 2>"$TMP/expected.err"; then
    echo "command unexpectedly succeeded: $*" >&2; exit 1
  fi
  test ! -s "$TMP/expected.out"; test -s "$TMP/expected.err"
}

run init --state-file "$STATE" --task-id task-alpha --now 100 --policy-json "$POLICY" >"$TMP/init.json"
python3 - "$TMP/init.json" "$STATE" <<'PY'
import hashlib, json, sys
result=json.load(open(sys.argv[1])); state=json.load(open(sys.argv[2]))
assert result["initialized"] is True and result["action"] == "continue", result
assert state["schema_version"] == 2, state
assert state["task_id"] == hashlib.sha256(b"task-alpha").hexdigest(), state
assert state["limits"] == {
    "work_unit":2,"implementation_attempt":2,"replan":1,"replacement":1,"review_attempt":2
}, state
assert "task-alpha" not in json.dumps(state), state
PY

run init --state-file "$STATE" --task-id task-alpha --now 101 --policy-json "$POLICY" >"$TMP/reinit.json"
python3 - "$TMP/reinit.json" "$STATE" <<'PY'
import json, sys
r=json.load(open(sys.argv[1])); s=json.load(open(sys.argv[2]))
assert r["initialized"] is False and r["idempotent"] is True, r
assert s["started_at"] == 100 and s["soft_deadline"] == 110 and s["hard_deadline"] == 120, s
PY

expect_fail run init --state-file "$STATE" --task-id task-other --now 101 --policy-json "$POLICY"
OTHER_POLICY='{"soft_timeout_seconds":11,"hard_timeout_seconds":20,"max_work_units":2,"max_implementation_attempts":2,"max_replans":1,"max_replacements":1,"max_review_attempts":2,"parent_finalization_seconds":2}'
expect_fail run init --state-file "$STATE" --task-id task-alpha --now 101 --policy-json "$OTHER_POLICY"

run reserve --state-file "$STATE" --task-id task-alpha --now 102 --kind work_unit --reservation-id unit-1 --fingerprint 'src/secret.py' >"$TMP/unit.json"
run reserve --state-file "$STATE" --task-id task-alpha --now 103 --kind work_unit --reservation-id unit-1 --fingerprint 'src/secret.py' >"$TMP/unit-repeat.json"
python3 - "$TMP/unit-repeat.json" "$STATE" <<'PY'
import hashlib, json, sys
r=json.load(open(sys.argv[1])); s=json.load(open(sys.argv[2]))
assert r["idempotent"] is True and r["counters"]["work_unit"] == 1, r
e=s["reservations"]["work_unit"][0]
assert e["reservation_id"] == hashlib.sha256(b"unit-1").hexdigest(), e
assert e["fingerprint"] == hashlib.sha256(b"src/secret.py").hexdigest(), e
assert "src/secret.py" not in json.dumps(s), s
PY
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 103 --kind work_unit --reservation-id unit-1 --fingerprint changed
run reserve --state-file "$STATE" --task-id task-alpha --now 104 --kind work_unit --reservation-id unit-2 --fingerprint delta-2 >/dev/null
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 105 --kind work_unit --reservation-id unit-3 --fingerprint delta-3
run reserve --state-file "$STATE" --task-id task-alpha --now 106 --kind implementation_attempt --reservation-id attempt-1 --fingerprint attempt >/dev/null
run reserve --state-file "$STATE" --task-id task-alpha --now 107 --kind implementation_attempt --reservation-id attempt-2 --fingerprint attempt >/dev/null
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 108 --kind implementation_attempt --reservation-id attempt-3 --fingerprint attempt
run reserve --state-file "$STATE" --task-id task-alpha --now 109 --kind replan --reservation-id replan-1 --fingerprint remaining-delta >/dev/null
run reserve --state-file "$STATE" --task-id task-alpha --now 109 --kind replacement --reservation-id replacement-1 --fingerprint isolated >/dev/null

run status --state-file "$STATE" --task-id task-alpha --now 110 >"$TMP/converge.json"
python3 - "$TMP/converge.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["action"]=="converge" and not p["permits_new_work"] and p["permits_new_review"], p
PY
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 110 --kind replan --reservation-id replan-soft --fingerprint blocked
# Read-only required-completion attempts remain admissible after soft.
run reserve --state-file "$STATE" --task-id task-alpha --now 111 --kind review_attempt --reservation-id review-1 --fingerprint reviewer-a >"$TMP/review1.json"
run reserve --state-file "$STATE" --task-id task-alpha --now 112 --kind review_attempt --reservation-id review-2 --fingerprint reviewer-b >"$TMP/review2.json"
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 113 --kind review_attempt --reservation-id review-3 --fingerprint reviewer-c
# Replay remains idempotent even after the hard boundary.
run reserve --state-file "$STATE" --task-id task-alpha --now 120 --kind review_attempt --reservation-id review-1 --fingerprint reviewer-a >"$TMP/review-replay.json"
python3 - "$TMP/review-replay.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["idempotent"] is True and p["counters"]["review_attempt"] == 2, p
PY
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 120 --kind review_attempt --reservation-id review-new --fingerprint reviewer-new
run status --state-file "$STATE" --task-id task-alpha --now 120 >"$TMP/stop.json"
python3 - "$TMP/stop.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["action"]=="stop" and p["cancel_required"], p
PY
run finish --state-file "$STATE" --task-id task-alpha --now 121 --outcome success >/dev/null
expect_fail run reserve --state-file "$STATE" --task-id task-alpha --now 121 --kind review_attempt --reservation-id closed --fingerprint closed

expect_fail run status --state-file "$STATE" --task-id task-alpha --now 99
expect_fail run status --state-file "$STATE" --task-id task-alpha --now 1700000000000
expect_fail run status --state-file "$STATE" --task-id task-alpha --now nan
if python3 "$RUNTIME" init --state-file "$TMP/bool.json" --task-id bool --now 0 --policy-json \
  '{"soft_timeout_seconds":true,"hard_timeout_seconds":20,"max_work_units":1,"max_implementation_attempts":1,"max_replans":0,"max_replacements":0,"max_review_attempts":0,"parent_finalization_seconds":1}' \
  >"$TMP/bool.out" 2>"$TMP/bool.err"; then
  echo "boolean policy value unexpectedly accepted" >&2; exit 1
fi
grep -Fq 'must be an integer' "$TMP/bool.err"
ln -s "$STATE" "$TMP/state-link.json"
expect_fail run status --state-file "$TMP/state-link.json" --task-id task-alpha --now 121

CONCURRENT="$TMP/concurrent.json"
CONCURRENT_POLICY='{"soft_timeout_seconds":100,"hard_timeout_seconds":200,"max_work_units":8,"max_implementation_attempts":1,"max_replans":1,"max_replacements":1,"max_review_attempts":1,"parent_finalization_seconds":1}'
run init --state-file "$CONCURRENT" --task-id concurrent --now 1000 --policy-json "$CONCURRENT_POLICY" >/dev/null
for i in 1 2 3 4 5 6 7 8; do
  run reserve --state-file "$CONCURRENT" --task-id concurrent --now 1001 --kind work_unit --reservation-id "unit-$i" --fingerprint "delta-$i" >"$TMP/concurrent-$i.json" &
done
wait
run status --state-file "$CONCURRENT" --task-id concurrent --now 1002 >"$TMP/concurrent-status.json"
python3 - "$TMP/concurrent-status.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); assert p["counters"]["work_unit"] == 8, p
PY

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
for profile in efficient balanced quality speed; do
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/policy.toml" plan --repo-policy none --quota-pressure unknown \
    --profile "$profile" --routing delegate --complexity complex --scope cross-module >"$TMP/${profile}-plan.json"
done
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/policy.toml" plan --repo-policy none --quota-pressure unknown \
  --routing direct --complexity complex --scope cross-module >"$TMP/direct-plan.json"
python3 - "$TMP" <<'PY'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
expected={
 "efficient":{"soft_timeout_seconds":1500,"hard_timeout_seconds":1800,"max_work_units":2,"max_implementation_attempts":3,"max_replans":1,"max_replacements":1,"max_review_attempts":0,"parent_finalization_seconds":150},
 "balanced":{"soft_timeout_seconds":2700,"hard_timeout_seconds":3300,"max_work_units":2,"max_implementation_attempts":4,"max_replans":2,"max_replacements":2,"max_review_attempts":0,"parent_finalization_seconds":180},
 "quality":{"soft_timeout_seconds":5400,"hard_timeout_seconds":8700,"max_work_units":3,"max_implementation_attempts":6,"max_replans":3,"max_replacements":3,"max_review_attempts":4,"parent_finalization_seconds":300},
 "speed":{"soft_timeout_seconds":1200,"hard_timeout_seconds":1800,"max_work_units":3,"max_implementation_attempts":4,"max_replans":1,"max_replacements":1,"max_review_attempts":0,"parent_finalization_seconds":120},
}
for name,budget in expected.items():
    p=json.load(open(root/f"{name}-plan.json"))
    assert p["schema_version"]==11 and p["strategy"]==name, p
    assert p["task_budget"]==budget, (name,p["task_budget"])
    assert p["implementation_stage"]["maximum_work_units"]==budget["max_work_units"], p
    if p["reviewer_workers"]:
        assert p["review_stage"]["fallback_policy"]=="retry_review", p

direct=json.load(open(root/"direct-plan.json"))
assert direct["schema_version"]==11 and direct["task_budget"] is None, direct
PY

printf 'task budget runtime test passed\n'
