#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
POLICY="$TMP/codex-flow.toml"

cat > "$POLICY" <<'EOF'
schema_version = 4

[strategy]
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

python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" show --json > "$TMP/show.json"
python3 - "$TMP/show.json" <<'PY'
import json, sys
obj=json.load(open(sys.argv[1]))
assert obj == {"strategy":"efficient","routing":"adaptive","valid":True}, obj
PY

[[ "$(python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY")" == "strategy=efficient routing=adaptive" ]]

# Built-in strategies are registered modules with explicit WorkerBudget/resource hooks.
python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/scripts')
from strategies import all_specs, get, names
assert names() == ('efficient', 'balanced', 'quality', 'speed'), names()
assert tuple(spec.name for spec in all_specs()) == names()
task=type('T', (), {
    'complexity':'routine','risk':'medium','scope':'module','iteration_intensity':'iterative',
    'uncertainty':'medium','exploration_need':'medium','verification_cost':'medium',
    'quality_intent':'normal'
})()
for name in names():
    spec=get(name)
    assert spec.name == name
    budget=spec.worker_budget(task)
    budget.validate()
    for role in ('explorer','implementer','reviewer'):
        assert spec.capability(task, role) in {'worker','parent'}, (name, role)
    assert spec.exploration_bonus(task) >= 0, name
    assert spec.reviewer_bonus(task) >= 0, name
    assert isinstance(spec.notes(task), tuple), name
PY
# Guard must match real source text: built-in strategy decisions may not leak back into Runtime.
! grep -Eq 'strategy[[:space:]]*(==|!=)[[:space:]]*"(efficient|balanced|quality|speed)"' "$ROOT/scripts/strategy_runtime.py"

# Small low-risk work remains direct but still exposes the selected budget envelope.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --complexity small --risk low > "$TMP/small.json"
python3 - "$TMP/small.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['schema_version']==7, p
assert p['quality_intent']=='normal', p
assert p['strategy']=='efficient' and p['routing']=='direct', p
for prefix in ('explorer','implementer','reviewer'):
    assert p[f'{prefix}_capability_policy'] is None, p
    assert p[f'{prefix}_model'] is None, p
    assert p[f'{prefix}_reasoning'] is None, p
assert p['implementation_workers']==0 and p['reviewer_workers']==0 and p['planned_worker_count']==0, p
assert p['worker_budget']['max_total_workers']>=1, p
assert p['max_concurrent_threads']==1, p
PY

# Complex efficient work offloads exploration and gives cheap worker roles deeper reasoning.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown \
  --complexity complex --uncertainty high --exploration-need high > "$TMP/efficient.json"
python3 - "$TMP/efficient.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['routing']=='delegate', p
assert p['parent_reasoning']=='high', p
assert p['explorer_reasoning']=='xhigh' and p['implementer_reasoning']=='xhigh', p
assert p['explorer_capability_policy']=='latest-efficient' and p['implementer_capability_policy']=='latest-efficient', p
assert p['explorer_model']=='gpt-test-efficient' and p['implementer_model']=='gpt-test-efficient', p
assert p['exploration_workers']==2 and p['implementation_workers']==1, p
assert p['reviewer_workers']==0 and p['planned_worker_count']==3, p
assert p['max_concurrent_threads']==2, p
PY

# Runtime invariant: every delegated worker role is at least one effort tier above Parent when possible.
cp "$POLICY" "$TMP/floor.toml"
python3 - "$TMP/floor.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace('min_reasoning_effort = "high"\nroutine_effort = "high"', 'min_reasoning_effort = "xhigh"\nroutine_effort = "high"', 1)
p.write_text(s)
PY
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/floor.toml" plan --repo-policy none --quota-pressure unknown \
  --routing delegate --complexity routine --risk low > "$TMP/floor.json"
python3 - "$TMP/floor.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['parent_reasoning']=='xhigh', p
assert p['implementer_reasoning']=='max', p
if p['exploration_workers']:
    assert p['explorer_reasoning']=='max', p
PY

# Parent=max is the only non-strict case because max is the top effort tier.
cp "$POLICY" "$TMP/max-parent.toml"
python3 - "$TMP/max-parent.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace('min_reasoning_effort = "high"\nroutine_effort = "high"', 'min_reasoning_effort = "max"\nroutine_effort = "max"', 1)
p.write_text(s)
PY
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/max-parent.toml" plan --repo-policy none --quota-pressure unknown \
  --routing delegate --complexity routine > "$TMP/max-parent.json"
python3 - "$TMP/max-parent.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['parent_reasoning']=='max' and p['implementer_reasoning']=='max', p
assert any('cannot exceed max' in n for n in p['notes']), p
PY

# Release defaults are consumed by the planner, not duplicated in Python constants.
mkdir -p "$TMP/runtime"
cp "$ROOT/scripts/strategy_runtime.py" "$TMP/runtime/strategy_runtime.py"
cp -R "$ROOT/scripts/strategies" "$TMP/runtime/strategies"
cp "$ROOT/policy/defaults.toml" "$TMP/runtime/defaults.toml"
python3 - "$TMP/runtime/defaults.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace('[reasoning.parent]\nminimum = "high"\nroutine = "high"', '[reasoning.parent]\nminimum = "high"\nroutine = "xhigh"')
p.write_text(s)
PY
cat > "$TMP/release-only.toml" <<'EOF'
schema_version = 3
EOF
python3 "$TMP/runtime/strategy_runtime.py" --policy "$TMP/release-only.toml" plan --repo-policy none --quota-pressure unknown --routing delegate --complexity routine --risk low > "$TMP/release-default.json"
python3 - "$TMP/release-default.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['parent_reasoning']=='xhigh' and p['implementer_reasoning']=='max', p
PY

# Normal quality remains efficient-worker-first across roles while using deeper reasoning and wider review.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --profile quality \
  --complexity complex --uncertainty high --risk high --parallelism high --scope repo-wide --exploration-need high > "$TMP/quality.json"
python3 - "$TMP/quality.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['strategy']=='quality' and p['quality_intent']=='normal' and p['routing']=='delegate', p
assert p['parent_reasoning']=='xhigh', p
assert p['explorer_reasoning']=='max' and p['implementer_reasoning']=='max', p
assert p['explorer_capability_policy']=='latest-efficient' and p['implementer_capability_policy']=='latest-efficient', p
assert p['explorer_model']=='gpt-test-efficient' and p['implementer_model']=='gpt-test-efficient', p
assert p['exploration_workers']==4, p
assert p['review_mode']=='independent+parent' and p['reviewer_workers']==1, p
assert p['reviewer_capability_policy']=='latest-efficient', p
assert p['reviewer_model']=='gpt-test-efficient' and p['reviewer_reasoning']=='max', p
assert p['planned_worker_count']==6 and p['max_concurrent_threads']==4, p
PY

# Strong quality upgrades high-value implementation/review, not read-only exploration.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --profile quality \
  --quality-intent strong --complexity routine --risk medium --parallelism limited > "$TMP/quality-strong.json"
python3 - "$TMP/quality-strong.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['quality_intent']=='strong' and p['routing']=='delegate', p
assert p['parent_reasoning']=='xhigh', p
assert p['explorer_reasoning']=='max' and p['implementer_reasoning']=='max', p
assert p['explorer_capability_policy']=='latest-efficient' and p['explorer_model']=='gpt-test-efficient', p
assert p['implementer_capability_policy']=='latest-capable' and p['implementer_model'] is None, p
assert p['review_mode']=='independent+parent' and p['reviewer_workers']==1, p
assert p['reviewer_capability_policy']=='latest-capable' and p['reviewer_model'] is None, p
assert p['exploration_workers']>=2, p
assert any('strong quality intent' in n for n in p['notes']), p
assert any('implementer role requests parent-class capability' in n for n in p['notes']), p
assert not any('explorer role requests parent-class capability' in n for n in p['notes']), p
PY

# Absolute quality maximizes high-value capability/reasoning/verification without premium exploration by default.
# It still obeys writable isolation, total worker budgets, and the runtime concurrency ceiling.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure critical --profile quality \
  --quality-intent absolute --complexity routine --risk medium --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/quality-absolute.json"
python3 - "$TMP/quality-absolute.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['quality_intent']=='absolute' and p['routing']=='delegate', p
assert p['parent_reasoning']=='max', p
assert p['explorer_reasoning']=='max' and p['implementer_reasoning']=='max' and p['reviewer_reasoning']=='max', p
assert p['explorer_capability_policy']=='latest-efficient', p
assert p['implementer_capability_policy']=='latest-capable' and p['reviewer_capability_policy']=='latest-capable', p
assert p['implementation_workers']==4 and p['reviewer_workers']==2, p
assert p['planned_worker_count']==8 and p['worker_budget']['max_total_workers']==8, p
assert p['max_concurrent_threads']==4 and p['max_repair_cycles']==2, p
assert p['quota_pressure']=='critical', p
assert any('absolute quality intent' in n for n in p['notes']), p
assert any('4 proven isolated workstreams' in n for n in p['notes']), p
PY

# Critical normal quality may upgrade all roles because exploration itself carries critical decision risk.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --profile quality \
  --complexity critical --risk critical --verification-cost high --parallelism high > "$TMP/quality-critical.json"
python3 - "$TMP/quality-critical.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['quality_intent']=='normal', p
assert p['explorer_capability_policy']=='latest-capable', p
assert p['implementer_capability_policy']=='latest-capable', p
assert p['explorer_reasoning']=='max' and p['implementer_reasoning']=='max', p
assert p['reviewer_workers']==2 and p['reviewer_reasoning']=='max', p
assert p['reviewer_capability_policy']=='latest-capable', p
PY

# quality_intent must not affect topology or resources for non-quality strategies.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --profile balanced --routing delegate \
  --quality-intent normal --complexity routine --risk medium > "$TMP/non-quality-normal.json"
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --profile balanced --routing delegate \
  --quality-intent strong --complexity routine --risk medium > "$TMP/non-quality-strong.json"
python3 - "$TMP/non-quality-normal.json" "$TMP/non-quality-strong.json" <<'PY'
import json, sys
normal=json.load(open(sys.argv[1])); strong=json.load(open(sys.argv[2]))
assert normal['quality_intent']=='normal' and strong['quality_intent']=='strong', (normal,strong)
keys=(
    'routing','worker_budget','exploration_workers','implementation_workers','reviewer_workers',
    'planned_worker_count','max_concurrent_threads','parent_reasoning',
    'explorer_capability_policy','explorer_model','explorer_reasoning',
    'implementer_capability_policy','implementer_model','implementer_reasoning',
    'reviewer_capability_policy','reviewer_model','reviewer_reasoning','review_mode'
)
for key in keys:
    assert normal[key] == strong[key], (key, normal[key], strong[key])
PY

# parallelism=none is a hard TaskProfile constraint, including reviewers.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --profile quality \
  --complexity complex --uncertainty high --parallelism none > "$TMP/no-parallel.json"
python3 - "$TMP/no-parallel.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['exploration_workers']==0 and p['implementation_workers']==1, p
assert p['explorer_capability_policy'] is None and p['explorer_reasoning'] is None, p
assert p['reviewer_workers']==1 and p['max_concurrent_threads']==1, p
PY

# Speed scales writable workers to proven isolated workstreams instead of a fixed cap of two.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --profile speed \
  --complexity routine --parallelism high --write-conflict low > "$TMP/speed-one.json"
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --profile speed \
  --complexity routine --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/speed-four.json"
python3 - "$TMP/speed-one.json" "$TMP/speed-four.json" <<'PY'
import json, sys
one=json.load(open(sys.argv[1])); four=json.load(open(sys.argv[2]))
assert one['implementation_workers']==1, one
assert four['implementation_workers']==4, four
assert four['max_concurrent_threads']==4, four
assert four['worker_budget']['max_implementers']==8, four
assert any('4 proven isolated workstreams' in n for n in four['notes']), four
PY

# Balanced also consumes multiple proven writable workstreams, but only within its smaller budget.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --profile balanced --routing delegate \
  --complexity complex --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/balanced-four.json"
python3 - "$TMP/balanced-four.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['implementation_workers']==3, p
assert p['worker_budget']['max_implementers']==3, p
PY

# Modifiers remain orthogonal and cannot bypass the strategy budget or safety proof.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown \
  --profile efficient --review strict --fanout aggressive --complexity complex --uncertainty high \
  --parallelism high --write-conflict low --writable-workstreams 2 > "$TMP/modifiers.json"
python3 - "$TMP/modifiers.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['strategy']=='efficient', p
assert p['review_modifier']=='strict' and p['review_mode']=='independent+parent', p
assert p['fanout_modifier']=='aggressive', p
assert p['exploration_workers']==2 and p['implementation_workers']==2, p
assert p['reviewer_workers']==1 and p['reviewer_reasoning']=='xhigh', p
assert p['planned_worker_count']==5, p
PY

# Direct routing remains orthogonal and cannot create workers/reviewer.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown \
  --profile quality --routing direct --review strict --complexity critical --risk critical > "$TMP/direct.json"
python3 - "$TMP/direct.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['routing']=='direct' and p['parent_reasoning']=='xhigh', p
for prefix in ('explorer','implementer','reviewer'):
    assert p[f'{prefix}_reasoning'] is None, p
assert p['exploration_workers']==0 and p['implementation_workers']==0 and p['reviewer_workers']==0, p
assert p['planned_worker_count']==0 and p['review_mode']=='parent', p
PY

# Quota adapter is deterministic and independent of strategy semantics.
python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/scripts')
from strategy_runtime import quota_pressure_from_snapshot
assert quota_pressure_from_snapshot(None) == 'unknown'
assert quota_pressure_from_snapshot({'rateLimits': {'primary': {'usedPercent': 20}}}) == 'low'
assert quota_pressure_from_snapshot({'rateLimits': {'primary': {'usedPercent': 55}}}) == 'medium'
assert quota_pressure_from_snapshot({'rateLimits': {'primary': {'usedPercent': 80}}}) == 'high'
assert quota_pressure_from_snapshot({'rateLimits': {'primary': {'usedPercent': 95}}}) == 'critical'
PY

# Repository policy overrides user strategy/routing/modifiers, tightens ceilings, and raises floors.
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
assert p['reviewer_workers']==1 and p['reviewer_reasoning']=='max', p
assert p['max_concurrent_threads']<=2 and p['max_repair_cycles']==1, p
PY

# Explicit current-task strategy/routing/modifiers outrank repo policy without mutating it.
(
  cd "$TMP/repo/subdir"
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --quota-pressure unknown \
    --profile speed --routing direct --review standard --fanout aggressive --complexity routine > "$TMP/override.json"
)
python3 - "$TMP/override.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['strategy']=='speed' and p['routing']=='direct', p
assert p['review_modifier']=='standard' and p['fanout_modifier']=='aggressive', p
PY
grep -Fq 'profile = "quality"' "$TMP/repo/.codex-flow.toml"

# Explicit repo-policy none disables auto-discovery.
(
  cd "$TMP/repo/subdir"
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" show --effective --repo-policy none --json > "$TMP/no-repo-show.json"
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --complexity routine > "$TMP/no-repo-plan.json"
)
python3 - "$TMP/no-repo-show.json" "$TMP/no-repo-plan.json" <<'PY'
import json, sys
show=json.load(open(sys.argv[1])); p=json.load(open(sys.argv[2]))
assert show['strategy']=='efficient' and show['routing']=='adaptive', show
assert show['repo_policy'] is None and p['repo_policy'] is None, (show,p)
PY

# Runtime ceilings are hard: task flags may tighten but never raise them.
(
  cd "$TMP/repo/subdir"
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --quota-pressure unknown --routing delegate \
    --complexity complex --parallelism high --max-threads 99 --max-repairs 99 > "$TMP/hard-ceiling.json"
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --quota-pressure unknown --routing delegate \
    --complexity complex --parallelism high --max-threads 1 --max-repairs 0 > "$TMP/tightened.json"
)
python3 - "$TMP/hard-ceiling.json" "$TMP/tightened.json" <<'PY'
import json, sys
hard=json.load(open(sys.argv[1])); tight=json.load(open(sys.argv[2]))
assert hard['max_concurrent_threads'] <= 2 and hard['max_repair_cycles'] == 1, hard
assert tight['max_concurrent_threads'] == 1 and tight['max_repair_cycles'] == 0, tight
PY

# Critical quota pressure collapses cost-aware fan-out without lowering worker-role reasoning.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" set balanced >/dev/null
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" routing delegate >/dev/null
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none \
  --complexity complex --uncertainty high --parallelism high --quota-pressure critical > "$TMP/quota.json"
python3 - "$TMP/quota.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['strategy']=='balanced' and p['routing']=='delegate', p
assert p['quota_pressure']=='critical', p
assert p['exploration_workers']==1 and p['implementation_workers']==1, p
assert p['max_concurrent_threads']==1 and p['max_repair_cycles']==1, p
assert p['parent_reasoning']=='high' and p['implementer_reasoning']=='xhigh', p
assert p['explorer_reasoning']=='xhigh', p
assert any('quota pressure' in n for n in p['notes']), p
PY

# Validation covers profile/modifier/budget dimensions.
python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/scripts')
from strategies.base import WorkerBudget
from strategy_runtime import Modifiers, TaskProfile
for item in (TaskProfile(scope='nonsense'), TaskProfile(writable_workstreams=0), TaskProfile(quality_intent='nonsense')):
    try: item.validate()
    except ValueError: pass
    else: raise AssertionError('invalid TaskProfile accepted')
try: Modifiers(review='nonsense').validate()
except ValueError: pass
else: raise AssertionError('invalid modifier accepted')
try: WorkerBudget(1, 0, 0, 1).validate()
except ValueError: pass
else: raise AssertionError('invalid WorkerBudget accepted')
PY

# Schema v3 compatibility retains historical strategy/routing defaults.
cat > "$TMP/v3.toml" <<'EOF'
schema_version = 3
[parent]
min_reasoning_effort = "high"
[worker]
min_reasoning_effort = "high"
[runtime]
max_concurrent_threads = 4
max_repair_cycles = 2
EOF
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/v3.toml" show --json > "$TMP/v3.json"
python3 - "$TMP/v3.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['strategy']=='efficient' and p['routing']=='adaptive' and p['valid'], p
PY

# Guard against strategy logic drifting back into the Skill/runtime compiler.
grep -Fq 'FlowPilot profiles. `strategy_runtime.py` + the strategy registry decide. FlowPilot executes the returned plan.' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'Do not independently re-implement strategy topology' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'quality_intent' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'worker_budget' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'reviewer_workers' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'explorer_capability_policy' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'implementer_capability_policy' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'worker-reviewer' "$ROOT/templates/skills/flow-pilot/SKILL.md"

printf 'strategy runtime test passed\n'
