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

# Global strategy state and task-only bypass remain deterministic.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" show --json > "$TMP/show.json"
python3 - "$TMP/show.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p == {"enabled":True,"strategy":"efficient","routing":"adaptive","valid":True}, p
PY
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" disable >/dev/null
[[ "$(python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" enabled)" == "false" ]]
if python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown >/dev/null 2>&1; then
  echo "disabled strategy unexpectedly compiled a plan" >&2
  exit 1
fi
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" enable >/dev/null
BYPASS_HOME="$TMP/bypass-home"
CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" bypass-once >/dev/null
[[ "$(CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" consume-bypass)" == "true" ]]
[[ "$(CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" consume-bypass)" == "false" ]]

# Registry owns strategy-specific lifecycle/budget decisions. The synthetic task
# includes every field consumed by current v11 strategy hooks.
python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/scripts')
from strategies import all_specs, get, names
assert names() == ('efficient', 'balanced', 'quality', 'speed'), names()
task=type('T', (), {
    'complexity':'routine','risk':'medium','scope':'module','iteration_intensity':'iterative',
    'uncertainty':'medium','exploration_need':'medium','verification_cost':'medium',
    'quality_intent':'normal','parallelism':'limited','write_conflict':'low','writable_workstreams':1,
})()
for name in names():
    spec=get(name)
    budget=spec.worker_budget(task); budget.validate()
    task_budget=spec.task_budget(task); task_budget.validate()
    for role in ('explorer','implementer','reviewer'):
        assert spec.capability(task, role) in {'worker','parent'}, (name, role)
    for stage in ('exploration','implementation','review'):
        policy=spec.lifecycle(task, stage); policy.validate()
    assert spec.lifecycle(task, 'review').fallback_policy == 'retry_review', name
PY

# Direct routing has no delegated topology or task ledger.
plan --routing direct --complexity small --risk low > "$TMP/direct.json"
python3 - "$TMP/direct.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['schema_version']==11 and p['routing']=='direct', p
assert p['task_budget'] is None and p['planned_worker_count']==0, p
for prefix in ('explorer','implementer','reviewer'):
    assert p[f'{prefix}_capability_policy'] is None, p
    assert p[f'{prefix}_model'] is None, p
    assert p[f'{prefix}_reasoning'] is None, p
for stage in ('exploration_stage','implementation_stage','review_stage'):
    assert p[stage] is None, p
PY

# Efficient complex work keeps required implementation, shared checkpointing,
# and Parent-only review under auto.
plan --routing delegate --complexity complex --uncertainty high --exploration-need high > "$TMP/efficient.json"
python3 - "$TMP/efficient.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['schema_version']==11 and p['strategy']=='efficient', p
assert p['parent_reasoning']=='high', p
assert p['explorer_reasoning']=='xhigh' and p['implementer_reasoning']=='xhigh', p
assert p['exploration_workers']==2 and p['implementation_workers']==1 and p['reviewer_workers']==0, p
imp=p['implementation_stage']
assert imp['join_policy']=='required' and imp['fallback_policy']=='replan', imp
assert imp['soft_timeout_seconds']==900 and imp['checkpoint_rearm_seconds']==240, imp
assert imp['minimum_work_units']==1 and imp['maximum_work_units']==2, imp
assert p['task_budget']['soft_timeout_seconds']==1500, p
assert p['task_budget']['hard_timeout_seconds']==1800, p
assert p['task_budget']['max_review_attempts']==0, p
PY

# Efficient reasoning rollout remains scoped to efficient delegated Workers.
for complexity in routine complex critical; do
  for mode in legacy shadow adaptive; do
    plan --routing delegate --complexity "$complexity" --efficient-reasoning "$mode" > "$TMP/rollout-${complexity}-${mode}.json"
  done
done
python3 - "$TMP" <<'PY'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
expected={"routine":("xhigh","high"),"complex":("xhigh","xhigh"),"critical":("max","max")}
for complexity,(legacy,proposed) in expected.items():
    for mode in ('legacy','shadow','adaptive'):
        p=json.load(open(root / f'rollout-{complexity}-{mode}.json'))
        d=p['reasoning_rollout']
        assert p['schema_version']==11, p
        assert d['mode']==mode and d['legacy_worker_reasoning']==legacy, d
        assert d['proposed_worker_reasoning']==proposed, d
        assert d['selected_worker_reasoning']==(proposed if mode=='adaptive' else legacy), d
        assert d['applied'] is (mode=='adaptive'), d
        assert p['implementer_reasoning']==d['selected_worker_reasoning'], p
PY
plan --profile balanced --routing delegate --complexity routine --efficient-reasoning adaptive > "$TMP/non-efficient-rollout.json"
python3 - "$TMP/non-efficient-rollout.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['reasoning_rollout'] is None and p['implementer_reasoning']=='xhigh', p
PY

# Quality auto review uses read-only retry_review. Strong/absolute intent may
# raise capability and topology but remains inside runtime ceilings.
plan --profile quality --complexity complex --uncertainty high --risk high --parallelism high --scope repo-wide --exploration-need high > "$TMP/quality.json"
python3 - "$TMP/quality.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['strategy']=='quality' and p['review_mode']=='independent+parent', p
assert p['reviewer_workers']==1 and p['review_stage']['fallback_policy']=='retry_review', p
assert p['review_stage']['join_policy']=='required', p
assert p['task_budget']['max_review_attempts']>=p['reviewer_workers'], p
assert p['task_budget']['hard_timeout_seconds'] >= p['task_budget']['soft_timeout_seconds'] + p['review_stage']['hard_timeout_seconds'] + p['task_budget']['parent_finalization_seconds'], p
PY
plan --profile quality --quality-intent strong --complexity routine --risk medium > "$TMP/quality-strong.json"
python3 - "$TMP/quality-strong.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['routing']=='delegate' and p['quality_intent']=='strong', p
assert p['implementer_capability_policy']=='latest-capable', p
assert p['reviewer_capability_policy']=='latest-capable', p
assert p['review_stage']['fallback_policy']=='retry_review', p
PY
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure critical \
  --profile quality --quality-intent absolute --complexity routine --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/quality-absolute.json"
python3 - "$TMP/quality-absolute.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['parent_reasoning']=='max', p
assert p['implementation_workers']==4 and p['reviewer_workers']==2, p
assert p['planned_worker_count']==8, p
assert p['review_stage']['fallback_policy']=='retry_review', p
assert p['task_budget']['max_work_units']>=p['implementation_workers'], p
for stage in ('exploration_stage','implementation_stage','review_stage'):
    if p[stage] is not None:
        assert p[stage]['idle_timeout_seconds']<=600, p[stage]
        assert p[stage]['hard_timeout_seconds']<=3600, p[stage]
PY

# Speed saturates proven writable topology; balanced caps it at its strategy envelope.
plan --profile speed --routing delegate --complexity routine --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/speed.json"
python3 - "$TMP/speed.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['implementation_workers']==4 and p['max_concurrent_threads']==4, p
assert p['implementation_stage']['maximum_work_units']==4, p
assert p['task_budget']['max_work_units']==4, p
assert p['exploration_stage']['join_policy']=='opportunistic', p
PY
plan --profile balanced --routing delegate --complexity complex --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/balanced.json"
python3 - "$TMP/balanced.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['implementation_workers']==3, p
assert p['implementation_stage']['maximum_work_units']>=3, p
assert p['task_budget']['max_work_units']>=3, p
PY

# Strict review creates a real required-completion tail and review-specific retry,
# never an implementation replan.
plan --profile efficient --routing delegate --review strict --fanout aggressive --complexity complex \
  --uncertainty high --parallelism high --write-conflict low --writable-workstreams 2 > "$TMP/strict.json"
python3 - "$TMP/strict.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
rev=p['review_stage']; budget=p['task_budget']
assert p['review_mode']=='independent+parent' and p['reviewer_workers']==1, p
assert rev['join_policy']=='required' and rev['fallback_policy']=='retry_review', rev
assert rev['cancel_if_superseded'] is False and rev['cancel_stragglers_after_quorum'] is False, rev
assert budget['soft_timeout_seconds']==1500 and budget['hard_timeout_seconds']==2850, budget
assert budget['max_review_attempts']==2 and budget['parent_finalization_seconds']==150, budget
PY

# parallelism=none remains a hard topology constraint.
plan --profile quality --routing delegate --complexity complex --uncertainty high --parallelism none > "$TMP/no-parallel.json"
python3 - "$TMP/no-parallel.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['exploration_workers']==0 and p['exploration_stage'] is None, p
assert p['implementation_workers']==1 and p['reviewer_workers']==1, p
assert p['max_concurrent_threads']==1, p
PY

# Runtime hard lifecycle ceilings normalize strategy preference.
python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/scripts')
from strategies.base import StagePolicy
from strategy_runtime import Modifiers, TaskProfile, _bounded_stage_policy
class Spec:
    @staticmethod
    def lifecycle(_task,_stage):
        return StagePolicy('required',99,5000,10000,False,False,'replan')
p=_bounded_stage_policy(Spec(), TaskProfile(), 'implementation', 3, Modifiers())
assert p.min_successful_workers==3 and p.idle_timeout_seconds==600 and p.hard_timeout_seconds==3600, p
PY

# Repository policy precedence and ceilings remain authoritative.
mkdir -p "$TMP/repo/subdir"
touch "$TMP/repo/.git"
cat > "$TMP/repo/.codex-flow.toml" <<'EOF'
[strategy]
profile = "quality"
[routing]
mode = "delegate"
[modifiers]
review = "strict"
fanout = "conservative"
[parent]
min_reasoning_effort = "xhigh"
[runtime]
max_concurrent_threads = 2
max_repair_cycles = 1
EOF
(
  cd "$TMP/repo/subdir"
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" show --effective --json > "$TMP/effective.json"
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --quota-pressure unknown --complexity routine > "$TMP/repo-plan.json"
)
python3 - "$TMP/effective.json" "$TMP/repo-plan.json" <<'PY'
import json, sys
show=json.load(open(sys.argv[1])); p=json.load(open(sys.argv[2]))
assert show['strategy']=='quality' and show['routing']=='delegate', show
assert show['review']=='strict' and show['fanout']=='conservative', show
assert p['parent_reasoning']=='xhigh' and p['implementer_reasoning']=='max', p
assert p['reviewer_workers']==1 and p['review_stage']['fallback_policy']=='retry_review', p
assert p['max_concurrent_threads']<=2 and p['max_repair_cycles']==1, p
PY

# Critical quota pressure compresses quota-sensitive strategies before lifecycle normalization.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --profile balanced --routing delegate \
  --complexity complex --uncertainty high --parallelism high --quota-pressure critical > "$TMP/quota.json"
python3 - "$TMP/quota.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['exploration_workers']==1 and p['implementation_workers']==1, p
assert p['max_concurrent_threads']==1 and p['max_repair_cycles']==1, p
assert p['implementation_stage']['min_successful_workers']==1, p
PY

# Invalid public contracts fail closed.
python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/scripts')
from strategies.base import StagePolicy, TaskBudgetPolicy, WorkerBudget
from strategy_runtime import Modifiers, TaskProfile
invalid=(
    StagePolicy('opportunistic',1,60,600),
    StagePolicy('quorum',0,60,600),
    StagePolicy('required',1,600,300),
    StagePolicy('required',1,60,600,fallback_policy='nonsense'),
    StagePolicy('required',1,60,600,soft_timeout_seconds=True),
    StagePolicy('required',1,60,600,work_unit_mode='single',maximum_work_units=2),
)
for item in invalid:
    try: item.validate()
    except ValueError: pass
    else: raise AssertionError(f'invalid StagePolicy accepted: {item}')
try: TaskProfile(writable_workstreams=0).validate()
except ValueError: pass
else: raise AssertionError('invalid TaskProfile accepted')
try: Modifiers(review='nonsense').validate()
except ValueError: pass
else: raise AssertionError('invalid modifier accepted')
try: WorkerBudget(1,0,0,1).validate()
except ValueError: pass
else: raise AssertionError('invalid WorkerBudget accepted')
try:
    TaskBudgetPolicy(10,20,1,1,0,0,max_review_attempts=True,parent_finalization_seconds=120).validate()
except ValueError: pass
else: raise AssertionError('boolean review budget accepted')
PY

# FlowPilot must consume the current v11 runtime contract rather than old prose heuristics.
grep -Fq 'FlowPilot profiles. `strategy_runtime.py` + the strategy registry decide. FlowPilot executes the returned plan.' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'Current contract (schema v11)' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'A `wait()` timeout is never a Worker timeout.' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'retry_review' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'review_deadline' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'Fallback always operates on the missing delta' "$ROOT/templates/skills/flow-pilot/SKILL.md"

printf 'strategy runtime test passed\n'
