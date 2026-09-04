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
  python3 "$ROOT/scripts/strategies/work_unit_runtime.py" \
    --policy-json "$1" --manifest-json "$2" \
    --implementation-workers "$3" --max-concurrent-threads "$4"
}

WORK_UNITS="$ROOT/scripts/strategies/work_unit_runtime.py"
python3 -m py_compile "$WORK_UNITS"

plan --routing delegate --complexity routine --scope module > "$TMP/routine.json"
plan --routing delegate --complexity complex --scope cross-module > "$TMP/complex.json"
plan --routing delegate --complexity complex --scope repo-wide --iteration-intensity heavy-loop > "$TMP/repo.json"
python3 - "$TMP/routine.json" "$TMP/complex.json" "$TMP/repo.json" <<'PY'
import json,sys
r,c,p=[json.load(open(x))['implementation_stage'] for x in sys.argv[1:]]
assert (r['work_unit_mode'],r['minimum_work_units'],r['maximum_work_units'],r['require_write_paths'])==('single',1,1,False),r
assert (c['work_unit_mode'],c['minimum_work_units'],c['maximum_work_units'],c['require_write_paths'])==('bounded',1,2,True),c
assert (p['work_unit_mode'],p['minimum_work_units'],p['maximum_work_units'],p['require_write_paths'])==('bounded',1,3,True),p
PY
python3 - "$TMP/complex.json" > "$TMP/complex-policy.json" <<'PY'
import json,sys
print(json.dumps(json.load(open(sys.argv[1]))['implementation_stage'],separators=(',',':')))
PY
COMPLEX_POLICY="$(cat "$TMP/complex-policy.json")"

ONE='{"units":[{"unit_id":"u1","scope_id":"all","generation":0,"acceptance_delta":"complete change","write_scope_id":"live","write_paths":["src/all.py"],"validation":["test all"],"depends_on":[]}]}'
validate_units "$COMPLEX_POLICY" "$ONE" 1 4 > "$TMP/one.json"

SERIAL='{"units":[{"unit_id":"u1","scope_id":"auth","generation":0,"acceptance_delta":"parser","write_scope_id":"auth-live","write_paths":["src/auth/parser.py"],"validation":["test parser"],"depends_on":[]},{"unit_id":"u2","scope_id":"auth","generation":0,"acceptance_delta":"integration","write_scope_id":"auth-live","write_paths":["src/auth/parser.py"],"validation":["test auth"],"depends_on":["u1"]}]}'
validate_units "$COMPLEX_POLICY" "$SERIAL" 1 4 > "$TMP/serial.json"

PARALLEL='{"units":[{"unit_id":"api","scope_id":"api","generation":0,"acceptance_delta":"api","write_scope_id":"wt-api","write_paths":["src/api.py"],"validation":["test api"],"depends_on":[],"parallel_group":"wave"},{"unit_id":"ui","scope_id":"ui","generation":0,"acceptance_delta":"ui","write_scope_id":"wt-ui","write_paths":["src/ui.py"],"validation":["test ui"],"depends_on":[],"parallel_group":"wave"}]}'
validate_units "$COMPLEX_POLICY" "$PARALLEL" 2 4 > "$TMP/parallel.json"
python3 - "$TMP/one.json" "$TMP/serial.json" "$TMP/parallel.json" <<'PY'
import json,sys
one,serial,parallel=[json.load(open(x)) for x in sys.argv[1:]]
assert one['valid'] and one['unit_count']==1,one
assert serial['valid'] and serial['unit_count']==2,serial
assert parallel['parallel_groups']==['wave'] and parallel['max_parallel_units']==2,parallel
PY

# v11 bounded policy fields are mandatory; no legacy policy defaulting.
python3 - "$ROOT" "$COMPLEX_POLICY" <<'PY'
import copy,json,sys
sys.path.insert(0,sys.argv[1]+'/scripts')
from strategies.work_unit_runtime import validate_manifest
policy=json.loads(sys.argv[2])
unit={
 'unit_id':'u1','scope_id':'s1','generation':0,'acceptance_delta':'d1','write_scope_id':'w1',
 'write_paths':['src/one.py'],'validation':['test one'],'depends_on':[]
}
peer={
 'unit_id':'u2','scope_id':'s2','generation':0,'acceptance_delta':'d2','write_scope_id':'w2',
 'write_paths':['src/two.py'],'validation':['test two'],'depends_on':[]
}
def invalid(manifest,pol=policy,workers=1,threads=4):
    try: validate_manifest(pol,manifest,implementation_workers=workers,max_concurrent_threads=threads)
    except ValueError: return
    raise AssertionError((manifest,pol))
def valid(manifest,pol=policy,workers=1,threads=4):
    return validate_manifest(pol,manifest,implementation_workers=workers,max_concurrent_threads=threads)

for field in ('work_unit_mode','minimum_work_units','join_between_work_units','maximum_work_units','require_write_paths'):
    p=copy.deepcopy(policy); p.pop(field,None); invalid({'units':[unit]},p)

# bounded units require explicit generation and write_paths.
for field in ('generation','write_paths'):
    u=copy.deepcopy(unit); u.pop(field); invalid({'units':[u]})

# Type confusion and unsafe paths fail closed.
for key,values in {
 'unit_id':[None,True,7,{}], 'scope_id':[None,False,7,[]],
 'acceptance_delta':[None,True,7,{}], 'write_scope_id':[None,False,7,[]],
 'generation':[None,True,1.0,'1',-1],
}.items():
    for value in values:
        u=copy.deepcopy(unit); u[key]=value; invalid({'units':[u]})
for path in ['', '.', '..', '../escape.py', 'src/../escape.py', '/absolute.py', 'C:/drive.py', 'src/*.py', 'src\\win.py', 'src//double.py']:
    u=copy.deepcopy(unit); u['write_paths']=[path]; invalid({'units':[u]})

# Duplicate deltas and un-ordered path overlap are invalid.
u=copy.deepcopy(peer); u['acceptance_delta']='d1'; invalid({'units':[unit,u]})
u=copy.deepcopy(peer); u['write_paths']=['src']; invalid({'units':[unit,u]})
u['depends_on']=['u1']; valid({'units':[unit,u]})

# Same writable scope requires direct predecessor ordering.
u=copy.deepcopy(peer); u['write_scope_id']='w1'; invalid({'units':[unit,u]})
u['depends_on']=['u1']; valid({'units':[unit,u]})

# Parallel isolation and width are enforced.
a=copy.deepcopy(unit); b=copy.deepcopy(peer); a['parallel_group']=b['parallel_group']='wave'
valid({'units':[a,b]},workers=2)
invalid({'units':[a,b]},workers=1)
b['write_paths']=['src/one.py']; invalid({'units':[a,b]},workers=2)

# Maximum units remain authoritative.
third=copy.deepcopy(peer); third.update(unit_id='u3',scope_id='s3',acceptance_delta='d3',write_scope_id='w3',write_paths=['src/three.py'])
invalid({'units':[unit,peer,third]})

# Fingerprints are deterministic; generation changes attempt fingerprint only.
first=valid({'units':[unit,peer]})
second=valid({'units':[unit,peer]})
assert first['unit_fingerprints']==second['unit_fingerprints']
next_peer=copy.deepcopy(peer); next_peer['generation']=1
third_result=valid({'units':[unit,next_peer]})
assert first['unit_fingerprints']['u2']!=third_result['unit_fingerprints']['u2']
assert first['logical_unit_fingerprints']['u2']==third_result['logical_unit_fingerprints']['u2']
print('strict v11 work-unit contract tests passed')
PY

# A legacy bounded policy must now fail instead of being normalized.
LEGACY='{"work_unit_mode":"bounded","minimum_work_units":1,"join_between_work_units":true}'
if validate_units "$LEGACY" "$ONE" 1 4 >/dev/null 2>&1; then
  echo "legacy bounded policy unexpectedly accepted" >&2
  exit 1
fi

printf 'bounded work-unit v11 contract tests passed\n'
