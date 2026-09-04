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
assert imp["maximum_work_units"]==1, imp
assert imp["require_write_paths"] is False, imp
assert imp["join_between_work_units"] is False, imp
assert imp["soft_timeout_seconds"]==600 and imp["hard_timeout_seconds"]==1800, imp
assert imp["max_worker_repair_attempts"]==1, imp
print(json.dumps(imp, separators=(",", ":")))
PY

# Complex/cross-module work has bounded capacity for independently evidenced units and joins Parent between them.
plan --routing delegate --complexity complex --scope cross-module > "$TMP/complex.json"
python3 - "$TMP/complex.json" > "$TMP/complex-policy.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); imp=p["implementation_stage"]
assert imp["work_unit_mode"]=="bounded", imp
assert imp["minimum_work_units"]==1, imp
assert imp["maximum_work_units"]==2, imp
assert imp["require_write_paths"] is True, imp
assert imp["join_between_work_units"] is True, imp
assert imp["soft_timeout_seconds"]==900 and imp["hard_timeout_seconds"]==1800, imp
assert imp["max_worker_repair_attempts"]==2, imp
print(json.dumps(imp, separators=(",", ":")))
PY
COMPLEX_POLICY="$(cat "$TMP/complex-policy.json")"
LEGACY_COMPLEX_POLICY="$(python3 - "$COMPLEX_POLICY" <<'PY'
import json, sys
p=json.loads(sys.argv[1])
p.pop("maximum_work_units", None)
p.pop("require_write_paths", None)
print(json.dumps(p, separators=(",", ":")))
PY
)"

# Repo-wide/heavy-loop work gets bounded capacity up to three units without lowering the old hard ceiling.
plan --routing delegate --complexity complex --scope repo-wide --iteration-intensity heavy-loop > "$TMP/repo-wide.json"
python3 - "$TMP/repo-wide.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); imp=p["implementation_stage"]
assert imp["work_unit_mode"]=="bounded", imp
assert imp["minimum_work_units"]==1, imp
assert imp["maximum_work_units"]==3, imp
assert imp["require_write_paths"] is True, imp
assert imp["join_between_work_units"] is True, imp
assert imp["hard_timeout_seconds"]==1800, imp
PY
python3 - "$TMP/repo-wide.json" > "$TMP/repo-wide-policy.json" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1]))["implementation_stage"], separators=(",", ":")))
PY
REPO_WIDE_POLICY="$(cat "$TMP/repo-wide-policy.json")"
REPO_WIDE_ONE='{"units":[{"unit_id":"repo-all","scope_id":"repo-wide","acceptance_delta":"complete repository change","write_scope_id":"repo-live","validation":["run repository checks"],"generation":0,"write_paths":["src/repo.py"]}]}'
validate_units "$REPO_WIDE_POLICY" "$REPO_WIDE_ONE" 1 4 > "$TMP/repo-wide-one.json"
python3 - "$TMP/repo-wide-one.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["valid"] and d["unit_count"] == 1 and d["maximum_work_units"] == 3, d
PY

# Same writable scope is valid only as an explicit serial dependency chain.
SERIAL_MANIFEST='{"units":[{"unit_id":"impl-1","scope_id":"module-auth","acceptance_delta":"implement parser change","write_scope_id":"auth-live","validation":["test parser"],"depends_on":[],"generation":0,"write_paths":["src/auth/parser.py"]},{"unit_id":"impl-2","scope_id":"module-auth","acceptance_delta":"add regression coverage and finish integration","write_scope_id":"auth-live","validation":["test auth regression"],"depends_on":["impl-1"],"generation":0,"write_paths":["src/auth/parser.py"]}]}'
validate_units "$COMPLEX_POLICY" "$SERIAL_MANIFEST" 1 4 > "$TMP/serial.json"
python3 - "$TMP/serial.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["valid"] is True and p["unit_count"]==2, p
assert p["work_unit_mode"]=="bounded" and p["join_between_work_units"] is True, p
assert p["max_parallel_units"]==1, p
PY
LEGACY_MIN2='{"work_unit_mode":"bounded","minimum_work_units":2,"join_between_work_units":true}'
validate_units "$LEGACY_MIN2" "$SERIAL_MANIFEST" 1 4 > "$TMP/legacy-min2.json"
python3 - "$TMP/legacy-min2.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); assert d["valid"] and d["minimum_work_units"] == 2, d
PY

# Shared writable scope without an explicit dependency is rejected: never imply concurrent same-scope writers.
BAD_SHARED='{"units":[{"unit_id":"impl-1","scope_id":"module-auth","acceptance_delta":"first half","write_scope_id":"auth-live","validation":["test one"],"generation":0,"write_paths":["src/auth/parser.py"]},{"unit_id":"impl-2","scope_id":"module-auth","acceptance_delta":"second half","write_scope_id":"auth-live","validation":["test two"],"generation":0,"write_paths":["src/auth/parser.py"]}]}'
if validate_units "$COMPLEX_POLICY" "$BAD_SHARED" 1 4 > /dev/null 2> "$TMP/shared.err"; then
  echo "overlapping writable units unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "must directly depend on previous unit" "$TMP/shared.err"

# Proven isolated scopes may share a parallel wave when the resolved plan has two implementation slots.
PARALLEL_MANIFEST='{"units":[{"unit_id":"impl-api","scope_id":"api","acceptance_delta":"update API contract","write_scope_id":"worktree-api","validation":["test api"],"parallel_group":"wave-1","generation":0,"write_paths":["src/api/contract.py"]},{"unit_id":"impl-ui","scope_id":"ui","acceptance_delta":"update UI consumer","write_scope_id":"worktree-ui","validation":["test ui"],"parallel_group":"wave-1","generation":0,"write_paths":["src/ui/consumer.py"]}]}'
validate_units "$COMPLEX_POLICY" "$PARALLEL_MANIFEST" 2 4 > "$TMP/parallel.json"
python3 - "$TMP/parallel.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["parallel_groups"]==["wave-1"] and p["max_parallel_units"]==2, p
PY

# Parallel groups cannot hide overlapping writers.
BAD_PARALLEL='{"units":[{"unit_id":"impl-a","scope_id":"a","acceptance_delta":"a","write_scope_id":"shared","validation":["test a"],"parallel_group":"wave-1","generation":0,"write_paths":["src/shared/a.py"]},{"unit_id":"impl-b","scope_id":"b","acceptance_delta":"b","write_scope_id":"shared","validation":["test b"],"parallel_group":"wave-1","depends_on":["impl-a"],"generation":0,"write_paths":["src/shared/a.py"]}]}'
if validate_units "$COMPLEX_POLICY" "$BAD_PARALLEL" 2 4 > /dev/null 2> "$TMP/parallel.err"; then
  echo "unsafe parallel work units unexpectedly accepted" >&2
  exit 1
fi
grep -Eq "overlapping write scope|dependency-linked units" "$TMP/parallel.err"

# Indirect dependencies are also ordering edges and therefore cannot share one parallel wave.
TRANSITIVE_PARALLEL='{"units":[{"unit_id":"impl-base","scope_id":"base","acceptance_delta":"base","write_scope_id":"worktree-base","validation":["test base"],"parallel_group":"wave-1","generation":0,"write_paths":["src/base.py"]},{"unit_id":"impl-middle","scope_id":"middle","acceptance_delta":"middle","write_scope_id":"worktree-middle","validation":["test middle"],"depends_on":["impl-base"],"generation":0,"write_paths":["src/middle.py"]},{"unit_id":"impl-top","scope_id":"top","acceptance_delta":"top","write_scope_id":"worktree-top","validation":["test top"],"depends_on":["impl-middle"],"parallel_group":"wave-1","generation":0,"write_paths":["src/top.py"]}]}'
if validate_units "$LEGACY_COMPLEX_POLICY" "$TRANSITIVE_PARALLEL" 2 4 > /dev/null 2> "$TMP/transitive.err"; then
  echo "transitively dependent parallel units unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "transitively dependency-linked units" "$TMP/transitive.err"

# A manifest cannot exceed either resolved implementation slots or the Runtime thread ceiling.
TOO_WIDE='{"units":[{"unit_id":"impl-a","scope_id":"a","acceptance_delta":"a","write_scope_id":"wa","validation":["test a"],"parallel_group":"wave-1","generation":0,"write_paths":["src/a.py"]},{"unit_id":"impl-b","scope_id":"b","acceptance_delta":"b","write_scope_id":"wb","validation":["test b"],"parallel_group":"wave-1","generation":0,"write_paths":["src/b.py"]},{"unit_id":"impl-c","scope_id":"c","acceptance_delta":"c","write_scope_id":"wc","validation":["test c"],"parallel_group":"wave-1","generation":0,"write_paths":["src/c.py"]}]}'
if validate_units "$LEGACY_COMPLEX_POLICY" "$TOO_WIDE" 2 4 > /dev/null 2> "$TMP/width.err"; then
  echo "parallel group wider than implementation_workers unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "allows at most 2 concurrent implementation units" "$TMP/width.err"
if validate_units "$LEGACY_COMPLEX_POLICY" "$PARALLEL_MANIFEST" 4 1 > /dev/null 2> "$TMP/thread-width.err"; then
  echo "parallel group wider than max_concurrent_threads unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "allows at most 1 concurrent implementation units" "$TMP/thread-width.err"

# Bounded mode permits one unit when no natural independent split is evidenced.
ONE_BIG='{"units":[{"unit_id":"impl-all","scope_id":"all","acceptance_delta":"do everything","write_scope_id":"all-live","validation":["test all"],"generation":0,"write_paths":["src/all.py"]}]}'
validate_units "$COMPLEX_POLICY" "$ONE_BIG" 1 4 > "$TMP/one.json"
python3 - "$TMP/one.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); assert d["valid"] and d["unit_count"] == 1, d
PY

# The hardened bounded contract rejects type confusion, duplicate deltas, unsafe
# paths, missing parallel isolation evidence, and manifests above the policy max.
python3 - "$ROOT" "$COMPLEX_POLICY" <<'PY'
import copy
import json
import sys

sys.path.insert(0, sys.argv[1] + "/scripts")
from strategies.work_unit_runtime import validate_manifest

policy = json.loads(sys.argv[2])
base_unit = {
    "unit_id": "u1",
    "scope_id": "scope-1",
    "acceptance_delta": "delta-1",
    "write_scope_id": "write-1",
    "validation": ["test one"],
    "depends_on": [],
    "generation": 0,
    "write_paths": ["src/one.py"],
}
peer_unit = {
    "unit_id": "u2",
    "scope_id": "scope-2",
    "acceptance_delta": "delta-2",
    "write_scope_id": "write-2",
    "validation": ["test two"],
    "depends_on": [],
    "generation": 0,
    "write_paths": ["src/two.py"],
}

def manifest(*units):
    return {"units": list(units)}

def invalid(candidate, candidate_policy=policy, *, workers=1, threads=4):
    try:
        validate_manifest(candidate_policy, candidate, implementation_workers=workers, max_concurrent_threads=threads)
    except ValueError:
        return
    raise AssertionError(f"invalid manifest unexpectedly accepted: {candidate}")

def valid(candidate, candidate_policy=policy, *, workers=1, threads=4):
    validate_manifest(candidate_policy, candidate, implementation_workers=workers, max_concurrent_threads=threads)

def invalid_unit(candidate):
    # Keep the surrounding manifest valid so a malformed unit cannot be hidden
    # by the bounded policy's minimum-unit rejection.
    invalid(manifest(candidate, copy.deepcopy(peer_unit)))

# Every contract string is type-checked instead of stringified.
for key, values in {
    "unit_id": [None, True, 7, {}],
    "scope_id": [None, False, 7, []],
    "acceptance_delta": [None, True, 7, {}],
    "write_scope_id": [None, False, 7, []],
}.items():
    for value in values:
        bad = copy.deepcopy(base_unit)
        bad[key] = value
        invalid_unit(bad)
for value in [None, "test one", {}, [None], [True], [7], [{}]]:
    bad = copy.deepcopy(base_unit); bad["validation"] = value
    invalid_unit(bad)
for value in [None, "u0", {}, [None], [True], [7], [{}]]:
    bad = copy.deepcopy(base_unit); bad["depends_on"] = value
    invalid_unit(bad)
for value in [True, 7, {}]:
    bad = copy.deepcopy(base_unit); bad["parallel_group"] = value
    invalid_unit(bad)
null_group = copy.deepcopy(base_unit); null_group["parallel_group"] = None
valid(manifest(null_group, copy.deepcopy(peer_unit)))

# Integers reject bool, float, string, null, and negative generation.
for key, values in {
    "generation": [None, True, 1.0, "1", -1],
}.items():
    for value in values:
        bad = copy.deepcopy(base_unit); bad[key] = value
        invalid_unit(bad)
for value in [None, "src/one.py", {}, [], [None], [True], [7], [{}]]:
    bad = copy.deepcopy(base_unit); bad["write_paths"] = value
    invalid_unit(bad)

# Policy and resolved concurrency fields use the same no-coercion contract.
valid_pair = manifest(copy.deepcopy(base_unit), copy.deepcopy(peer_unit))
for key, values in {
    "work_unit_mode": [None, True, 7, {}],
    "minimum_work_units": [None, True, 2.0, "2"],
    "join_between_work_units": [None, 1, "true"],
    "maximum_work_units": [True, 2.0, "2", 0, 1],
    "require_write_paths": [None, 1, "true"],
}.items():
    for value in values:
        bad_policy = copy.deepcopy(policy); bad_policy[key] = value
        invalid(valid_pair, bad_policy)
invalid(valid_pair, policy, workers=True)
invalid(valid_pair, policy, threads=True)
invalid([], policy)
try:
    validate_manifest(policy, [], implementation_workers=1, max_concurrent_threads=4)
except ValueError:
    pass
else:
    raise AssertionError("non-object manifest unexpectedly accepted")

# Duplicate acceptance deltas are not independently harvestable units.
duplicate = copy.deepcopy(base_unit)
duplicate["unit_id"] = "u2"
duplicate["write_scope_id"] = "write-2"
duplicate["write_paths"] = ["src/two.py"]
invalid(manifest(base_unit, duplicate))

# Path preflight is lexical and fail-closed.
for path in [
    "", ".", "..", "../escape.py", "src/../escape.py", "/absolute.py",
    "C:/drive.py", "C:relative.py", "//server/share.py", "src/*.py",
    "src/[a].py", "src\\windows.py", "src\x00nul.py", "src//double.py", "src/./dot.py",
]:
    bad = copy.deepcopy(base_unit); bad["write_paths"] = [path]
    invalid(manifest(bad))

# Same/ancestor paths require a direct or transitive serial dependency.
ancestor = copy.deepcopy(base_unit)
ancestor["unit_id"] = "u2"
ancestor["acceptance_delta"] = "delta-2"
ancestor["write_scope_id"] = "write-2"
ancestor["write_paths"] = ["src"]
invalid(manifest(base_unit, ancestor))
ancestor["depends_on"] = ["u1"]
valid(manifest(base_unit, ancestor))

# Same logical write-scope units retain the stronger direct predecessor fence;
# an indirect dependency is not enough even when paths are distinct.
middle = copy.deepcopy(peer_unit)
middle["depends_on"] = ["u1"]
same_scope_late = copy.deepcopy(base_unit)
same_scope_late["unit_id"] = "u3"
same_scope_late["acceptance_delta"] = "delta-3"
same_scope_late["validation"] = ["test three"]
same_scope_late["write_paths"] = ["src/three.py"]
same_scope_late["depends_on"] = ["u2"]
invalid(manifest(base_unit, middle, same_scope_late), {**policy, "maximum_work_units": 3})

# A parallel group needs concrete non-overlapping path evidence, even for a
# legacy policy that otherwise permits path-less serial manifests.
legacy = {"work_unit_mode": "bounded", "minimum_work_units": 2, "join_between_work_units": True}
parallel_missing = [copy.deepcopy(base_unit), copy.deepcopy(ancestor)]
for unit in parallel_missing:
    unit.pop("write_paths", None)
    unit["parallel_group"] = "wave"
    unit["depends_on"] = []
invalid(manifest(*parallel_missing), legacy, workers=2)

# The exact new maximum is enforced independently of worker concurrency.
too_many = []
for index in range(3):
    unit = copy.deepcopy(base_unit)
    unit["unit_id"] = f"u{index + 1}"
    unit["acceptance_delta"] = f"delta-{index + 1}"
    unit["write_scope_id"] = f"write-{index + 1}"
    unit["write_paths"] = [f"src/{index + 1}.py"]
    too_many.append(unit)
invalid(manifest(*too_many), policy, workers=1)

# Legacy single policy remains valid without generation/write_paths.
legacy_single = {"work_unit_mode": "single", "minimum_work_units": 1, "join_between_work_units": False}
legacy_unit = {
    "unit_id": "legacy",
    "scope_id": "legacy",
    "acceptance_delta": "legacy delta",
    "write_scope_id": "legacy-write",
    "validation": ["legacy test"],
}
valid(manifest(legacy_unit), legacy_single)

# Fingerprints are deterministic and include one entry per unit.
fingerprint_unit = copy.deepcopy(base_unit)
fingerprint_unit["unit_id"] = "u2"
fingerprint_unit["acceptance_delta"] = "delta-2"
fingerprint_unit["write_scope_id"] = "write-2"
fingerprint_unit["write_paths"] = ["src/two.py"]
fingerprint_unit["depends_on"] = ["u1"]
first = validate_manifest(policy, manifest(base_unit, fingerprint_unit), implementation_workers=1, max_concurrent_threads=4)
second = validate_manifest(policy, manifest(base_unit, fingerprint_unit), implementation_workers=1, max_concurrent_threads=4)
assert first["unit_fingerprints"] == second["unit_fingerprints"], (first, second)
assert len(first["unit_fingerprints"]["u1"]) == 64 and len(first["unit_fingerprints"]["u2"]) == 64, first
print("adversarial work-unit contract tests passed")
PY

printf 'bounded work-unit runtime tests passed\n'
