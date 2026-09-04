#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
POLICY="$TMP/codex-flow.toml"

cat > "$POLICY" <<'EOF'
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

plan() {
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown "$@"
}

validate_units() {
  local policy_json="$1" manifest_json="$2" implementation_workers="$3" max_threads="$4"
  python3 "$ROOT/scripts/strategies/work_unit_runtime.py" \
    --policy-json "$policy_json" \
    --manifest-json "$manifest_json" \
    --implementation-workers "$implementation_workers" \
    --max-concurrent-threads "$max_threads"
}

WORK_UNITS="$ROOT/scripts/strategies/work_unit_runtime.py"
python3 -m py_compile "$WORK_UNITS"

# Routine implementation remains a single bounded transaction.
plan --routing delegate --complexity routine --scope module > "$TMP/routine.json"
python3 - "$TMP/routine.json" > "$TMP/routine-policy.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); imp=p["implementation_stage"]
assert imp["work_unit_mode"]=="single", imp
assert imp["minimum_work_units"]==1, imp
assert imp["join_between_work_units"] is False, imp
assert imp["soft_timeout_seconds"]==600 and imp["hard_timeout_seconds"]==1800, imp
assert imp["max_worker_repair_attempts"]==1, imp
print(json.dumps(imp, separators=(",", ":")))
PY

# Complex/cross-module work must be split into at least two units and join Parent between them.
plan --routing delegate --complexity complex --scope cross-module > "$TMP/complex.json"
python3 - "$TMP/complex.json" > "$TMP/complex-policy.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); imp=p["implementation_stage"]
assert imp["work_unit_mode"]=="bounded", imp
assert imp["minimum_work_units"]==2, imp
assert imp["join_between_work_units"] is True, imp
assert imp["soft_timeout_seconds"]==900 and imp["hard_timeout_seconds"]==1800, imp
assert imp["max_worker_repair_attempts"]==2, imp
print(json.dumps(imp, separators=(",", ":")))
PY
COMPLEX_POLICY="$(cat "$TMP/complex-policy.json")"

# Repo-wide/heavy-loop work gets a stronger three-unit minimum without lowering the old hard ceiling.
plan --routing delegate --complexity complex --scope repo-wide --iteration-intensity heavy-loop > "$TMP/repo-wide.json"
python3 - "$TMP/repo-wide.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); imp=p["implementation_stage"]
assert imp["work_unit_mode"]=="bounded", imp
assert imp["minimum_work_units"]==3, imp
assert imp["join_between_work_units"] is True, imp
assert imp["hard_timeout_seconds"]==1800, imp
PY

# Same writable scope is valid only as an explicit serial dependency chain.
SERIAL_MANIFEST='{"units":[{"unit_id":"impl-1","scope_id":"module-auth","acceptance_delta":"implement parser change","write_scope_id":"auth-live","validation":["test parser"],"depends_on":[]},{"unit_id":"impl-2","scope_id":"module-auth","acceptance_delta":"add regression coverage and finish integration","write_scope_id":"auth-live","validation":["test auth regression"],"depends_on":["impl-1"]}]}'
validate_units "$COMPLEX_POLICY" "$SERIAL_MANIFEST" 1 4 > "$TMP/serial.json"
python3 - "$TMP/serial.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["valid"] is True and p["unit_count"]==2, p
assert p["work_unit_mode"]=="bounded" and p["join_between_work_units"] is True, p
assert p["max_parallel_units"]==1, p
PY

# Shared writable scope without an explicit dependency is rejected: never imply concurrent same-scope writers.
BAD_SHARED='{"units":[{"unit_id":"impl-1","scope_id":"module-auth","acceptance_delta":"first half","write_scope_id":"auth-live","validation":["test one"]},{"unit_id":"impl-2","scope_id":"module-auth","acceptance_delta":"second half","write_scope_id":"auth-live","validation":["test two"]}]}'
if validate_units "$COMPLEX_POLICY" "$BAD_SHARED" 1 4 > /dev/null 2> "$TMP/shared.err"; then
  echo "overlapping writable units unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "must directly depend on previous unit" "$TMP/shared.err"

# Proven isolated scopes may share a parallel wave when the resolved plan has two implementation slots.
PARALLEL_MANIFEST='{"units":[{"unit_id":"impl-api","scope_id":"api","acceptance_delta":"update API contract","write_scope_id":"worktree-api","validation":["test api"],"parallel_group":"wave-1"},{"unit_id":"impl-ui","scope_id":"ui","acceptance_delta":"update UI consumer","write_scope_id":"worktree-ui","validation":["test ui"],"parallel_group":"wave-1"}]}'
validate_units "$COMPLEX_POLICY" "$PARALLEL_MANIFEST" 2 4 > "$TMP/parallel.json"
python3 - "$TMP/parallel.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["parallel_groups"]==["wave-1"] and p["max_parallel_units"]==2, p
PY

# Parallel groups cannot hide overlapping writers.
BAD_PARALLEL='{"units":[{"unit_id":"impl-a","scope_id":"a","acceptance_delta":"a","write_scope_id":"shared","validation":["test a"],"parallel_group":"wave-1"},{"unit_id":"impl-b","scope_id":"b","acceptance_delta":"b","write_scope_id":"shared","validation":["test b"],"parallel_group":"wave-1","depends_on":["impl-a"]}]}'
if validate_units "$COMPLEX_POLICY" "$BAD_PARALLEL" 2 4 > /dev/null 2> "$TMP/parallel.err"; then
  echo "unsafe parallel work units unexpectedly accepted" >&2
  exit 1
fi
grep -Eq "overlapping write scope|dependency-linked units" "$TMP/parallel.err"

# Indirect dependencies are also ordering edges and therefore cannot share one parallel wave.
TRANSITIVE_PARALLEL='{"units":[{"unit_id":"impl-base","scope_id":"base","acceptance_delta":"base","write_scope_id":"worktree-base","validation":["test base"],"parallel_group":"wave-1"},{"unit_id":"impl-middle","scope_id":"middle","acceptance_delta":"middle","write_scope_id":"worktree-middle","validation":["test middle"],"depends_on":["impl-base"]},{"unit_id":"impl-top","scope_id":"top","acceptance_delta":"top","write_scope_id":"worktree-top","validation":["test top"],"depends_on":["impl-middle"],"parallel_group":"wave-1"}]}'
if validate_units "$COMPLEX_POLICY" "$TRANSITIVE_PARALLEL" 2 4 > /dev/null 2> "$TMP/transitive.err"; then
  echo "transitively dependent parallel units unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "transitively dependency-linked units" "$TMP/transitive.err"

# A manifest cannot exceed either resolved implementation slots or the Runtime thread ceiling.
TOO_WIDE='{"units":[{"unit_id":"impl-a","scope_id":"a","acceptance_delta":"a","write_scope_id":"wa","validation":["test a"],"parallel_group":"wave-1"},{"unit_id":"impl-b","scope_id":"b","acceptance_delta":"b","write_scope_id":"wb","validation":["test b"],"parallel_group":"wave-1"},{"unit_id":"impl-c","scope_id":"c","acceptance_delta":"c","write_scope_id":"wc","validation":["test c"],"parallel_group":"wave-1"}]}'
if validate_units "$COMPLEX_POLICY" "$TOO_WIDE" 2 4 > /dev/null 2> "$TMP/width.err"; then
  echo "parallel group wider than implementation_workers unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "allows at most 2 concurrent implementation units" "$TMP/width.err"
if validate_units "$COMPLEX_POLICY" "$PARALLEL_MANIFEST" 4 1 > /dev/null 2> "$TMP/thread-width.err"; then
  echo "parallel group wider than max_concurrent_threads unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "allows at most 1 concurrent implementation units" "$TMP/thread-width.err"

# Bounded mode cannot silently collapse back to one large Worker transaction.
ONE_BIG='{"units":[{"unit_id":"impl-all","scope_id":"all","acceptance_delta":"do everything","write_scope_id":"all-live","validation":["test all"]}]}'
if validate_units "$COMPLEX_POLICY" "$ONE_BIG" 1 4 > /dev/null 2> "$TMP/one.err"; then
  echo "bounded implementation unexpectedly accepted one giant unit" >&2
  exit 1
fi
grep -Fq "requires at least 2 work units" "$TMP/one.err"

printf 'bounded work-unit runtime tests passed\n'
