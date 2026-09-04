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

python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" show --json > "$TMP/show.json"
python3 - "$TMP/show.json" <<'PY'
import json, sys
obj=json.load(open(sys.argv[1]))
assert obj == {"enabled":True,"strategy":"efficient","routing":"adaptive","valid":True}, obj
PY
[[ "$(python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY")" == "enabled=true strategy=efficient routing=adaptive" ]]
[[ "$(python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" enabled)" == "true" ]]

# Missing master-switch state in older policies remains backward-compatible.
cp "$POLICY" "$TMP/legacy-policy.toml"
python3 - "$TMP/legacy-policy.toml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace("enabled = true\n", "", 1))
PY
[[ "$(python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/legacy-policy.toml" enabled)" == "true" ]]

# A present-but-invalid master switch fails closed instead of silently enabling dispatch.
for invalid_value in flase '""'; do
  cp "$POLICY" "$TMP/invalid-enabled.toml"
  python3 - "$TMP/invalid-enabled.toml" "$invalid_value" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); value=sys.argv[2]
p.write_text(p.read_text().replace("enabled = true\n", f"enabled = {value}\n", 1))
PY
  set +e
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/invalid-enabled.toml" show --json > "$TMP/invalid-enabled.json" 2> "$TMP/invalid-enabled.err"
  invalid_show_rc=$?
  set -e
  [[ "$invalid_show_rc" -eq 2 ]]
  python3 - "$TMP/invalid-enabled.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["enabled"] is False and p["valid"] is False, p
assert "invalid [strategy].enabled" in p["error"], p
PY
  if python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/invalid-enabled.toml" enabled >/dev/null 2>"$TMP/invalid-enabled-command.err"; then
    echo "invalid strategy switch unexpectedly reported a usable state" >&2
    exit 1
  fi
  grep -Fq "invalid [strategy].enabled" "$TMP/invalid-enabled-command.err"
  if python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/invalid-enabled.toml" plan --repo-policy none --quota-pressure unknown >/dev/null 2>"$TMP/invalid-enabled-plan.err"; then
    echo "invalid strategy switch unexpectedly compiled a plan" >&2
    exit 1
  fi
  grep -Fq "invalid [strategy].enabled" "$TMP/invalid-enabled-plan.err"
done

# The global master switch bypasses FlowPilot planning and cannot be re-enabled by repository policy.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" disable >/dev/null
[[ "$(python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" enabled)" == "false" ]]
[[ "$(python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY")" == "enabled=false strategy=efficient routing=adaptive" ]]
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" show --json > "$TMP/disabled-show.json"
python3 - "$TMP/disabled-show.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["enabled"] is False and p["strategy"] == "efficient" and p["routing"] == "adaptive", p
PY
mkdir -p "$TMP/repo"
cat > "$TMP/repo/.codex-flow.toml" <<'EOF'
[strategy]
enabled = true
profile = "quality"
[routing]
mode = "delegate"
EOF
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" show --effective --repo-policy "$TMP/repo/.codex-flow.toml" --json > "$TMP/disabled-effective.json"
python3 - "$TMP/disabled-effective.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["enabled"] is False and p["strategy"] == "quality" and p["routing"] == "delegate", p
PY
if python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy "$TMP/repo/.codex-flow.toml" --quota-pressure unknown >"$TMP/disabled-plan.json" 2>"$TMP/disabled-plan.err"; then
  echo "disabled strategy unexpectedly compiled a plan" >&2
  exit 1
fi
grep -q "strategy dispatch is disabled" "$TMP/disabled-plan.err"
if python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --profile quality --routing delegate --quota-pressure unknown >/dev/null 2>&1; then
  echo "current-task overrides unexpectedly bypassed the disabled master switch" >&2
  exit 1
fi
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" enable >/dev/null
[[ "$(python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" enabled)" == "true" ]]

# Temporary bypass is one-shot, does not mutate the global switch, and is atomically consumed.
BYPASS_HOME="$TMP/bypass-home"
[[ "$(CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" bypass-pending)" == "false" ]]
CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" bypass-once >/dev/null
[[ "$(CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" bypass-pending)" == "true" ]]
[[ "$(python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" enabled)" == "true" ]]
[[ "$(CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" consume-bypass)" == "true" ]]
[[ "$(CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" consume-bypass)" == "false" ]]

CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" bypass-once >/dev/null
CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" consume-bypass > "$TMP/consume-a" &
pid_a=$!
CODEX_HOME="$BYPASS_HOME" python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" consume-bypass > "$TMP/consume-b" &
pid_b=$!
wait "$pid_a" "$pid_b"
[[ "$(cat "$TMP/consume-a") $(cat "$TMP/consume-b")" == "true false" || "$(cat "$TMP/consume-a") $(cat "$TMP/consume-b")" == "false true" ]]
grep -Fq "consume-bypass" "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq "task only" "$ROOT/templates/skills/flow-pilot/SKILL.md"

# Registry owns topology/resource/lifecycle preferences. Generic Runtime only normalizes them.
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
    budget=spec.worker_budget(task); budget.validate()
    for role in ('explorer','implementer','reviewer'):
        assert spec.capability(task, role) in {'worker','parent'}, (name, role)
    for stage in ('exploration','implementation','review'):
        lifecycle=spec.lifecycle(task, stage)
        lifecycle.validate()
    assert spec.exploration_bonus(task) >= 0, name
    assert spec.reviewer_bonus(task) >= 0, name
    assert isinstance(spec.notes(task), tuple), name
PY

# Guard against built-in strategy decisions leaking back into generic Runtime.
! grep -Eq 'strategy[[:space:]]*(==|!=)[[:space:]]*"(efficient|balanced|quality|speed)"' "$ROOT/scripts/strategy_runtime.py"

# Direct work has no delegated resources or lifecycle stages.
plan --complexity small --risk low > "$TMP/small.json"
python3 - "$TMP/small.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['schema_version']==10, p
assert p['strategy']=='efficient' and p['routing']=='direct', p
assert p['quality_intent']=='normal', p
for prefix in ('explorer','implementer','reviewer'):
    assert p[f'{prefix}_capability_policy'] is None, p
    assert p[f'{prefix}_model'] is None, p
    assert p[f'{prefix}_reasoning'] is None, p
for stage in ('exploration_stage','implementation_stage','review_stage'):
    assert p[stage] is None, (stage,p)
assert p['implementation_workers']==0 and p['reviewer_workers']==0 and p['planned_worker_count']==0, p
assert p['max_concurrent_threads']==1, p
PY

# Efficient complex work gets quorum exploration + required implementation.
plan --complexity complex --uncertainty high --exploration-need high > "$TMP/efficient.json"
python3 - "$TMP/efficient.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['routing']=='delegate', p
assert p['parent_reasoning']=='high', p
assert p['explorer_reasoning']=='xhigh' and p['implementer_reasoning']=='xhigh', p
assert p['explorer_capability_policy']=='latest-efficient' and p['implementer_capability_policy']=='latest-efficient', p
assert p['exploration_workers']==2 and p['implementation_workers']==1 and p['reviewer_workers']==0, p
exp=p['exploration_stage']; imp=p['implementation_stage']
assert exp['join_policy']=='quorum' and exp['min_successful_workers']==1, exp
assert exp['cancel_if_superseded'] is True and exp['cancel_stragglers_after_quorum'] is True, exp
assert exp['idle_timeout_seconds']==120 and exp['hard_timeout_seconds']==900, exp
assert imp['join_policy']=='required' and imp['min_successful_workers']==1, imp
assert imp['cancel_if_superseded'] is False and imp['fallback_policy']=='replan', imp
assert p['review_stage'] is None, p
PY

# Efficient delegated workers expose the three rollout modes without changing
# direct or non-efficient strategy behavior. The proposed effort is the
# rollout class target/minimum/Parent maximum; shadow and legacy still select
# the historical worker effort.
for complexity in routine complex critical; do
  for mode in legacy shadow adaptive; do
    plan --routing delegate --complexity "$complexity" --efficient-reasoning "$mode" \
      > "$TMP/rollout-${complexity}-${mode}.json"
  done
done
python3 - "$TMP" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = {
    "routine": ("xhigh", "high"),
    "complex": ("xhigh", "xhigh"),
    "critical": ("max", "max"),
}
for complexity, (legacy, proposed) in expected.items():
    for mode in ("legacy", "shadow", "adaptive"):
        p = json.load(open(root / f"rollout-{complexity}-{mode}.json"))
        d = p["reasoning_rollout"]
        assert p["schema_version"] == 10, p
        assert d["mode"] == mode and d["legacy_worker_reasoning"] == legacy, d
        assert d["proposed_worker_reasoning"] == proposed, d
        assert d["selected_worker_reasoning"] == (proposed if mode == "adaptive" else legacy), d
        assert d["applied"] is (mode == "adaptive"), d
        assert p["explorer_reasoning"] == d["selected_worker_reasoning"], p
        assert p["implementer_reasoning"] == d["selected_worker_reasoning"], p
        assert p["reviewer_reasoning"] is None, p
PY

# A current-task CLI override changes only this plan; the installed policy
# remains the release-compatible shadow default when its optional section is
# absent (legacy policy compatibility).
plan --routing delegate --complexity routine > "$TMP/rollout-default.json"
plan --routing delegate --complexity routine --efficient-reasoning adaptive > "$TMP/rollout-override.json"
python3 - "$TMP/rollout-default.json" "$TMP/rollout-override.json" <<'PY'
import json
import sys

default, override = (json.load(open(path)) for path in sys.argv[1:])
assert default["reasoning_rollout"]["mode"] == "shadow", default
assert default["reasoning_rollout"]["applied"] is False, default
assert override["reasoning_rollout"]["mode"] == "adaptive", override
assert override["reasoning_rollout"]["applied"] is True, override
assert override["implementer_reasoning"] == override["reasoning_rollout"]["selected_worker_reasoning"], override
PY

# User rollout floors and Parent floors raise the proposal; they never reduce
# the legacy baseline. Repository floors may raise efforts but cannot switch a
# user's legacy/shadow mode to adaptive.
cp "$POLICY" "$TMP/user-rollout-floor.toml"
cat >> "$TMP/user-rollout-floor.toml" <<'EOF'

[reasoning.rollout]
minimum = "max"
routine = "max"
complex = "max"
critical = "max"
EOF
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/user-rollout-floor.toml" plan \
  --repo-policy none --quota-pressure unknown --routing delegate --complexity routine \
  --efficient-reasoning adaptive > "$TMP/user-rollout-floor.json"
cp "$POLICY" "$TMP/parent-rollout-floor.toml"
python3 - "$TMP/parent-rollout-floor.toml" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text().replace(
    'min_reasoning_effort = "high"\nroutine_effort = "high"',
    'min_reasoning_effort = "xhigh"\nroutine_effort = "xhigh"',
    1,
)
p.write_text(s)
PY
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/parent-rollout-floor.toml" plan \
  --repo-policy none --quota-pressure unknown --routing delegate --complexity routine \
  --efficient-reasoning adaptive > "$TMP/parent-rollout-floor.json"
cat > "$TMP/repo-rollout-floor.toml" <<'EOF'
[reasoning.rollout]
mode = "adaptive"
minimum = "max"
EOF
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan \
  --repo-policy "$TMP/repo-rollout-floor.toml" --quota-pressure unknown --routing delegate \
  --complexity routine > "$TMP/repo-rollout-floor.json"
python3 - "$TMP/user-rollout-floor.json" "$TMP/parent-rollout-floor.json" "$TMP/repo-rollout-floor.json" <<'PY'
import json
import sys

user, parent, repo = (json.load(open(path)) for path in sys.argv[1:])
assert user["reasoning_rollout"]["proposed_worker_reasoning"] == "max", user
assert user["reasoning_rollout"]["selected_worker_reasoning"] == "max", user
assert parent["parent_reasoning"] == "xhigh", parent
assert parent["reasoning_rollout"]["proposed_worker_reasoning"] == "xhigh", parent
assert parent["implementer_reasoning"] == "xhigh", parent
assert repo["reasoning_rollout"]["mode"] == "shadow", repo
assert repo["reasoning_rollout"]["proposed_worker_reasoning"] == "max", repo
assert repo["reasoning_rollout"]["selected_worker_reasoning"] == "xhigh", repo
assert repo["reasoning_rollout"]["applied"] is False, repo
PY

# Parent=max is allowed to equal the proposed/selected max effort.
cp "$POLICY" "$TMP/max-parent-rollout.toml"
python3 - "$TMP/max-parent-rollout.toml" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text().replace(
    'min_reasoning_effort = "high"\nroutine_effort = "high"',
    'min_reasoning_effort = "max"\nroutine_effort = "max"',
    1,
)
p.write_text(s)
PY
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$TMP/max-parent-rollout.toml" plan \
  --repo-policy none --quota-pressure unknown --routing delegate --complexity routine \
  --efficient-reasoning adaptive > "$TMP/max-parent-rollout.json"
python3 - "$TMP/max-parent-rollout.json" <<'PY'
import json
import sys

p = json.load(open(sys.argv[1]))
d = p["reasoning_rollout"]
assert p["parent_reasoning"] == "max", p
assert d["proposed_worker_reasoning"] == d["selected_worker_reasoning"] == "max", d
assert any("cannot exceed max" in note for note in p["notes"]), p
PY

# Direct efficient work and delegated non-efficient work do not emit or apply
# rollout decisions, even when the current task asks for adaptive mode.
plan --routing direct --complexity routine --efficient-reasoning adaptive > "$TMP/rollout-direct.json"
plan --profile balanced --routing delegate --complexity routine --efficient-reasoning adaptive > "$TMP/rollout-balanced.json"
python3 - "$TMP/rollout-direct.json" "$TMP/rollout-balanced.json" <<'PY'
import json
import sys

direct, balanced = (json.load(open(path)) for path in sys.argv[1:])
assert direct["routing"] == "direct" and direct["reasoning_rollout"] is None, direct
assert balanced["strategy"] == "balanced" and balanced["routing"] == "delegate", balanced
assert balanced["reasoning_rollout"] is None, balanced
assert balanced["implementer_reasoning"] == "xhigh", balanced
PY

# Rollout contracts are strict: booleans and unknown values are rejected.
python3 - "$ROOT" <<'PY'
import sys

sys.path.insert(0, sys.argv[1] + "/scripts")
from strategies.base import ReasoningRolloutDecision, ReasoningRolloutPolicy

for value in (
    {"mode": True},
    {"mode": "adaptive", "minimum": "low"},
    {"mode": "adaptive", "unknown": "high"},
):
    try:
        ReasoningRolloutPolicy.from_dict(value)
    except ValueError:
        pass
    else:
        raise AssertionError(f"invalid rollout policy accepted: {value}")
try:
    ReasoningRolloutDecision("adaptive", "high", "high", "high", 1).validate()
except ValueError:
    pass
else:
    raise AssertionError("boolean rollout decision accepted")
PY

# Delegated Worker reasoning remains at least one tier above Parent when possible.
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
assert p['parent_reasoning']=='xhigh' and p['implementer_reasoning']=='max', p
if p['exploration_workers']:
    assert p['explorer_reasoning']=='max', p
PY

# Parent=max is the only non-strict effort case because max is the top tier.
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

# Normal quality keeps efficient capability while adding deeper verification/lifecycle.
plan --profile quality --complexity complex --uncertainty high --risk high --parallelism high \
  --scope repo-wide --exploration-need high > "$TMP/quality.json"
python3 - "$TMP/quality.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['strategy']=='quality' and p['quality_intent']=='normal' and p['routing']=='delegate', p
assert p['parent_reasoning']=='xhigh', p
assert p['explorer_capability_policy']=='latest-efficient' and p['implementer_capability_policy']=='latest-efficient', p
assert p['exploration_workers']==4 and p['reviewer_workers']==1, p
assert p['review_mode']=='independent+parent', p
assert p['exploration_stage']['join_policy']=='quorum', p
assert p['exploration_stage']['min_successful_workers']==2, p
assert p['review_stage']['join_policy']=='required', p
# Strategy asks for 2 reviewers, Runtime normalizes to the one reviewer actually planned.
assert p['review_stage']['min_successful_workers']==1, p
assert p['review_stage']['cancel_if_superseded'] is False, p
assert p['review_stage']['fallback_policy']=='replan', p
PY

# Strong quality upgrades implementer/reviewer capability, not ordinary exploration.
plan --profile quality --quality-intent strong --complexity routine --risk medium --parallelism limited > "$TMP/quality-strong.json"
python3 - "$TMP/quality-strong.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['quality_intent']=='strong' and p['routing']=='delegate', p
assert p['parent_reasoning']=='xhigh', p
assert p['explorer_capability_policy']=='latest-efficient', p
assert p['implementer_capability_policy']=='latest-capable', p
assert p['reviewer_capability_policy']=='latest-capable', p
assert p['exploration_workers']>=2, p
assert p['exploration_stage']['min_successful_workers']==2, p
assert p['review_stage']['join_policy']=='required' and p['review_stage']['min_successful_workers']==1, p
assert p['review_stage']['cancel_if_superseded'] is False, p
assert any('strong quality intent' in n for n in p['notes']), p
PY

# Absolute quality retains two useful explorer results and two independent reviewers.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure critical --profile quality \
  --quality-intent absolute --complexity routine --risk medium --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/quality-absolute.json"
python3 - "$TMP/quality-absolute.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['quality_intent']=='absolute' and p['routing']=='delegate', p
assert p['parent_reasoning']=='max', p
assert p['explorer_capability_policy']=='latest-efficient', p
assert p['implementer_capability_policy']=='latest-capable' and p['reviewer_capability_policy']=='latest-capable', p
assert p['implementation_workers']==4 and p['reviewer_workers']==2, p
assert p['planned_worker_count']==8, p
exp=p['exploration_stage']; rev=p['review_stage']; imp=p['implementation_stage']
assert exp['join_policy']=='quorum' and exp['min_successful_workers']==2, exp
assert exp['cancel_stragglers_after_quorum'] is False, exp
assert rev['join_policy']=='required' and rev['min_successful_workers']==2, rev
assert rev['cancel_if_superseded'] is False and rev['fallback_policy']=='replan', rev
assert imp['join_policy']=='required' and imp['hard_timeout_seconds']==3600, imp
for stage in (exp, imp, rev):
    assert stage['idle_timeout_seconds'] <= 600, stage
    assert stage['hard_timeout_seconds'] <= 3600, stage
PY

# Critical normal quality may upgrade all role capabilities.
plan --profile quality --complexity critical --risk critical --verification-cost high --parallelism high > "$TMP/quality-critical.json"
python3 - "$TMP/quality-critical.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['quality_intent']=='normal', p
assert p['explorer_capability_policy']=='latest-capable', p
assert p['implementer_capability_policy']=='latest-capable', p
assert p['reviewer_capability_policy']=='latest-capable', p
assert p['reviewer_workers']==2, p
assert p['review_stage']['min_successful_workers']==2, p
PY

# quality_intent must not affect non-quality topology, resources, or lifecycle.
plan --profile balanced --routing delegate --quality-intent normal --complexity routine --risk medium > "$TMP/non-quality-normal.json"
plan --profile balanced --routing delegate --quality-intent strong --complexity routine --risk medium > "$TMP/non-quality-strong.json"
python3 - "$TMP/non-quality-normal.json" "$TMP/non-quality-strong.json" <<'PY'
import json, sys
normal=json.load(open(sys.argv[1])); strong=json.load(open(sys.argv[2]))
keys=(
    'routing','worker_budget','exploration_workers','implementation_workers','reviewer_workers',
    'planned_worker_count','max_concurrent_threads','parent_reasoning',
    'explorer_capability_policy','explorer_model','explorer_reasoning',
    'implementer_capability_policy','implementer_model','implementer_reasoning',
    'reviewer_capability_policy','reviewer_model','reviewer_reasoning','review_mode',
    'exploration_stage','implementation_stage','review_stage'
)
for key in keys:
    assert normal[key] == strong[key], (key, normal[key], strong[key])
PY

# parallelism=none remains a hard topology constraint.
plan --profile quality --complexity complex --uncertainty high --parallelism none > "$TMP/no-parallel.json"
python3 - "$TMP/no-parallel.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['exploration_workers']==0 and p['exploration_stage'] is None, p
assert p['implementation_workers']==1 and p['implementation_stage']['join_policy']=='required', p
assert p['reviewer_workers']==1 and p['max_concurrent_threads']==1, p
PY

# Speed keeps speculative exploration opportunistic and short-lived.
plan --profile speed --complexity routine --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/speed.json"
python3 - "$TMP/speed.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['implementation_workers']==4 and p['max_concurrent_threads']==4, p
exp=p['exploration_stage']; imp=p['implementation_stage']
assert exp['join_policy']=='opportunistic' and exp['min_successful_workers']==0, exp
assert exp['idle_timeout_seconds']==60 and exp['hard_timeout_seconds']==600, exp
assert exp['fallback_policy']=='continue_partial', exp
assert imp['join_policy']=='required' and imp['hard_timeout_seconds']==1200, imp
PY

# Balanced consumes multiple proven writable workstreams within its smaller budget.
plan --profile balanced --routing delegate --complexity complex --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/balanced.json"
python3 - "$TMP/balanced.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['implementation_workers']==3, p
assert p['worker_budget']['max_implementers']==3, p
assert p['implementation_stage']['join_policy']=='required', p
PY

# Strict review is a generic modifier: every planned reviewer must return terminal evidence.
plan --profile efficient --review strict --fanout aggressive --complexity complex --uncertainty high \
  --parallelism high --write-conflict low --writable-workstreams 2 > "$TMP/strict.json"
python3 - "$TMP/strict.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['review_modifier']=='strict' and p['review_mode']=='independent+parent', p
assert p['reviewer_workers']==1, p
rev=p['review_stage']
assert rev['join_policy']=='required', rev
assert rev['min_successful_workers']==p['reviewer_workers'], rev
assert rev['cancel_if_superseded'] is False, rev
assert rev['cancel_stragglers_after_quorum'] is False, rev
assert rev['fallback_policy']=='replan', rev
PY

# Direct routing cannot create lifecycle stages even with quality + strict.
plan --profile quality --routing direct --review strict --complexity critical --risk critical > "$TMP/direct.json"
python3 - "$TMP/direct.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['routing']=='direct' and p['review_mode']=='parent', p
assert p['planned_worker_count']==0, p
assert p['exploration_stage'] is None and p['implementation_stage'] is None and p['review_stage'] is None, p
PY

# Runtime hard lifecycle ceilings clamp an otherwise valid strategy preference.
python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/scripts')
from strategies.base import StagePolicy
from strategy_runtime import Modifiers, TaskProfile, _bounded_stage_policy
class Spec:
    @staticmethod
    def lifecycle(_task, _stage):
        return StagePolicy('required', 99, 5000, 10000, False, False, 'replan')
task=TaskProfile()
p=_bounded_stage_policy(Spec(), task, 'implementation', 3, Modifiers())
assert p.min_successful_workers == 3, p
assert p.idle_timeout_seconds == 600, p
assert p.hard_timeout_seconds == 3600, p
PY

# Lifecycle contract rejects internally inconsistent policies.
python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/scripts')
from strategies.base import StagePolicy, WorkerBudget
from strategy_runtime import Modifiers, TaskProfile
invalid=(
    StagePolicy('opportunistic',1,60,600),
    StagePolicy('quorum',0,60,600),
    StagePolicy('required',1,600,300),
    StagePolicy('required',1,60,600,fallback_policy='nonsense'),
    StagePolicy('required',True,60,600),
    StagePolicy('required',1,60,600,soft_timeout_seconds=True),
    StagePolicy('required',1,60,600,max_worker_repair_attempts=True),
    StagePolicy('required',1,60,600,join_between_work_units=1),
    StagePolicy('required',1,60,600,maximum_work_units=True),
    StagePolicy('required',1,60,600,require_write_paths=1),
    StagePolicy('required',1,60,600,work_unit_mode='single',maximum_work_units=2),
    StagePolicy('required',1,60,600,work_unit_mode='bounded',minimum_work_units=2,join_between_work_units=True,maximum_work_units=1),
)
for item in invalid:
    try: item.validate()
    except ValueError: pass
    else: raise AssertionError(f'invalid StagePolicy accepted: {item}')
for item in (TaskProfile(scope='nonsense'), TaskProfile(writable_workstreams=0), TaskProfile(quality_intent='nonsense')):
    try: item.validate()
    except ValueError: pass
    else: raise AssertionError('invalid TaskProfile accepted')
try: Modifiers(review='nonsense').validate()
except ValueError: pass
else: raise AssertionError('invalid modifier accepted')
try: WorkerBudget(1,0,0,1).validate()
except ValueError: pass
else: raise AssertionError('invalid WorkerBudget accepted')
PY

# Quota adapter remains deterministic and independent of strategy/lifecycle semantics.
python3 - "$ROOT" <<'PY'
import sys
import json
sys.path.insert(0, sys.argv[1] + '/scripts')
from telemetry_core.app_server import _nvm_version_sort_key, quota_windows
from strategy_runtime import quota_pressure_from_snapshot
from pathlib import Path
versions = sorted((Path(name) for name in ('v9.0.0', 'v22.1.0', 'v22.0.9')), key=_nvm_version_sort_key, reverse=True)
assert [path.name for path in versions] == ['v22.1.0', 'v22.0.9', 'v9.0.0'], versions
assert quota_pressure_from_snapshot(None) == 'unknown'
assert quota_pressure_from_snapshot({'rateLimits': {'primary': {'usedPercent': 20}}}) == 'low'
assert quota_pressure_from_snapshot({'rateLimits': {'primary': {'usedPercent': 55}}}) == 'medium'
assert quota_pressure_from_snapshot({'rateLimits': {'primary': {'usedPercent': 80}}}) == 'high'
assert quota_pressure_from_snapshot({'rateLimits': {'primary': {'usedPercent': 95}}}) == 'critical'
fixture = json.load(open(sys.argv[1] + '/tests/fixtures/account-rate-limits.json'))
windows = quota_windows(fixture)
assert [(row['window_duration_mins'], row['used_percent']) for row in windows] == [(300, 42), (10080, 61)], windows
assert quota_pressure_from_snapshot(fixture) == 'medium', windows
PY

# Repository policy precedence/ceilings continue to work with lifecycle v8.
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
assert p['reviewer_workers']==1 and p['review_stage']['join_policy']=='required', p
assert p['max_concurrent_threads']<=2 and p['max_repair_cycles']==1, p
PY

# Explicit current-task overrides still outrank repo policy without mutating it.
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

# Critical quota pressure compresses worker counts; lifecycle is normalized after compression.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --profile balanced --routing delegate \
  --complexity complex --uncertainty high --parallelism high --quota-pressure critical > "$TMP/quota.json"
python3 - "$TMP/quota.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['exploration_workers']==1 and p['implementation_workers']==1, p
assert p['max_concurrent_threads']==1 and p['max_repair_cycles']==1, p
assert p['exploration_stage']['min_successful_workers']==1, p
assert p['implementation_stage']['min_successful_workers']==1, p
PY

# Schema-v3 persistent-policy users retain the historical default strategy/routing.
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

# Skill must treat lifecycle as an authoritative plan boundary, not a prose heuristic.
grep -Fq 'FlowPilot profiles. `strategy_runtime.py` + the strategy registry decide. FlowPilot executes the returned plan.' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'Current contract (schema v10)' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'A `wait()` timeout is never a Worker timeout.' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'cancel_if_superseded' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'Fallback always operates on the missing delta' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'scope_id' "$ROOT/templates/skills/flow-pilot/SKILL.md"
grep -Fq 'do not kill a Luna `xhigh/max` Explorer' "$ROOT/templates/skills/flow-pilot/SKILL.md"

printf 'strategy runtime test passed\n'
