#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
POLICY="$TMP/codex-flow.toml"
LIFECYCLE="$ROOT/scripts/strategies/lifecycle_runtime.py"

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

plan() {
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown "$@"
}

python3 -m py_compile "$LIFECYCLE"
plan --routing delegate --complexity complex --uncertainty high > "$TMP/impl-plan.json"
python3 - "$TMP/impl-plan.json" > "$TMP/impl-policy.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); s=p['implementation_stage']
assert s['soft_timeout_seconds']==900 and s['checkpoint_rearm_seconds']==240 and s['hard_timeout_seconds']==1800,s
assert s['fallback_policy']=='replan',s
print(json.dumps(s,separators=(',',':')))
PY
IMPL_POLICY="$(cat "$TMP/impl-policy.json")"

python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id active --stage implementation \
  --started-at 100 --last-progress-at 220 --now 250 --writable > "$TMP/active.json"
python3 - "$TMP/active.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='continue' and d['state']=='progressing',d
assert not d['cancel_required'] and not d['fence_required'],d
PY

python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id soft --stage implementation \
  --started-at 100 --last-progress-at 995 --last-meaningful-progress-at 995 --now 1000 --writable --in-flight > "$TMP/soft.json"
python3 - "$TMP/soft.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='request_checkpoint' and d['next_checkpoint_sequence']==1,d
assert d['checkpoint_status']=='not_requested' and not d['cancel_required'],d
PY

SEQ_REQUESTED='[{"sequence":1,"generation":0,"requested_at":1000}]'
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id soft --stage implementation \
  --started-at 100 --last-progress-at 1005 --now 1010 --writable --in-flight --checkpoint-sequence-json "$SEQ_REQUESTED" > "$TMP/requested.json"
python3 - "$TMP/requested.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='await_checkpoint' and d['checkpoint_status']=='requested',d
PY

SEQ_RECEIVED='[{"sequence":1,"generation":0,"requested_at":1000,"received_at":1005}]'
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id soft --stage implementation \
  --started-at 100 --last-progress-at 1005 --last-meaningful-progress-at 1005 --now 1010 --writable --terminal-failure \
  --checkpoint-sequence-json "$SEQ_RECEIVED" > "$TMP/received.json"
python3 - "$TMP/received.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='harvest_checkpoint' and d['checkpoint_status']=='received',d
assert d['fallback_policy'] is None and not d['cancel_required'],d
PY

SEQ_HARVESTED='[{"sequence":1,"generation":0,"requested_at":900,"received_at":910,"harvested_at":920}]'
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id no-rearm --stage implementation \
  --started-at 100 --last-progress-at 1195 --now 1200 --writable --in-flight --checkpoint-sequence-json "$SEQ_HARVESTED" > "$TMP/no-rearm.json"
python3 - "$TMP/no-rearm.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='continue' and d['next_checkpoint_sequence'] is None,d
assert 'last_progress_at cannot re-arm' in d['reason'],d
PY

python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id rearm --stage implementation \
  --started-at 100 --last-progress-at 1155 --last-meaningful-progress-at 1155 --now 1160 --writable --in-flight \
  --checkpoint-sequence-json "$SEQ_HARVESTED" > "$TMP/rearm.json"
python3 - "$TMP/rearm.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='request_checkpoint' and d['next_checkpoint_sequence']==2,d
assert d['checkpoint_rearm_at']==1160 and d['checkpoint_rearm_remaining_seconds']==0,d
PY

python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id cooldown --stage implementation \
  --started-at 100 --last-progress-at 995 --last-meaningful-progress-at 995 --now 1000 --writable --in-flight \
  --checkpoint-sequence-json "$SEQ_HARVESTED" > "$TMP/cooldown.json"
python3 - "$TMP/cooldown.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='continue' and d['checkpoint_rearm_remaining_seconds']==160,d
PY

SEQ_HARD_RECEIVED='[{"sequence":1,"generation":0,"requested_at":1850,"received_at":1890}]'
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id hard --stage implementation \
  --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 --now 1900 --writable \
  --checkpoint-sequence-json "$SEQ_HARD_RECEIVED" > "$TMP/hard-received.json"
python3 - "$TMP/hard-received.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['wall_seconds']==1800 and d['action']=='harvest_checkpoint',d
PY

SEQ_HARD_HARVESTED='[{"sequence":1,"generation":0,"requested_at":1850,"received_at":1890,"harvested_at":1900}]'
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id hard --stage implementation \
  --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 --now 1901 --writable \
  --checkpoint-sequence-json "$SEQ_HARD_HARVESTED" > "$TMP/hard-harvested.json"
python3 - "$TMP/hard-harvested.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='request_cancel' and d['cancel_required'] and d['fence_required'],d
assert d['replan_scope']=='checkpoint_remaining_delta' and d['checkpoint_reuse_mode']=='retained_workspace',d
PY

python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id hard --stage implementation \
  --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 --now 1902 --writable --cancel-confirmed \
  --checkpoint-sequence-json "$SEQ_HARD_HARVESTED" > "$TMP/after-cancel.json"
python3 - "$TMP/after-cancel.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='replan' and d['replacement_allowed'],d
assert d['replan_scope']=='checkpoint_remaining_delta',d
PY

python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id isolated --stage implementation \
  --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 --now 1901 --writable --replacement-isolated \
  --checkpoint-sequence-json "$SEQ_HARD_HARVESTED" > "$TMP/isolated.json"
python3 - "$TMP/isolated.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='replan' and d['replacement_allowed'] and d['cancel_required'],d
assert d['checkpoint_reuse_mode']=='harvested_snapshot_only' and d['fence_required'],d
PY

python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id idle --stage implementation \
  --started-at 100 --last-progress-at 100 --now 400 --writable > "$TMP/idle.json"
python3 - "$TMP/idle.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='request_cancel' and d['replan_scope']=='uncovered_scope',d
assert d['cancel_required'] and d['fence_required'],d
PY

python3 - "$TMP/impl-policy.json" > "$TMP/parent-policy.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); p['fallback_policy']='parent_delta'; print(json.dumps(p,separators=(',',':')))
PY
PARENT_POLICY="$(cat "$TMP/parent-policy.json")"
python3 "$LIFECYCLE" --policy-json "$PARENT_POLICY" --scope-id parent --stage implementation \
  --started-at 100 --last-progress-at 100 --now 400 --writable > "$TMP/parent.json"
python3 - "$TMP/parent.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='request_cancel' and d['fence_required'],d
assert d['fallback_policy']=='parent_delta' and d['replan_scope'] is None,d
PY

plan --profile quality --routing delegate --complexity complex --risk high --verification-cost high > "$TMP/review-plan.json"
python3 - "$TMP/review-plan.json" > "$TMP/review-policy.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); s=p['review_stage']; assert s and s['fallback_policy']=='retry_review',s
print(json.dumps(s,separators=(',',':')))
PY
REVIEW_POLICY="$(cat "$TMP/review-policy.json")"
python3 "$LIFECYCLE" --policy-json "$REVIEW_POLICY" --scope-id review --stage review \
  --started-at 100 --last-progress-at 100 --now 500 > "$TMP/review.json"
python3 - "$TMP/review.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='retry_review' and d['replacement_allowed'],d
assert d['replan_scope'] is None and not d['fence_required'],d
PY

plan --routing delegate --complexity complex --uncertainty high > "$TMP/explore-plan.json"
python3 - "$TMP/explore-plan.json" > "$TMP/explore-policy.json" <<'PY'
import json,sys
print(json.dumps(json.load(open(sys.argv[1]))['exploration_stage'],separators=(',',':')))
PY
EXP_POLICY="$(cat "$TMP/explore-policy.json")"
python3 "$LIFECYCLE" --policy-json "$EXP_POLICY" --scope-id explore --stage exploration \
  --started-at 100 --last-progress-at 120 --now 130 --scope-superseded > "$TMP/superseded.json"
python3 - "$TMP/superseded.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['action']=='request_cancel' and not d['fence_required'],d
PY

# v11 implementation lifecycle is strict: no missing soft/rearm compatibility path.
python3 - "$ROOT" "$IMPL_POLICY" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[1]+'/scripts')
from strategies.lifecycle_runtime import LifecyclePolicy,WorkerObservation,evaluate_worker,CheckpointRecord
base=json.loads(sys.argv[2])
obs=WorkerObservation('strict','implementation',100,100,101)
for field in ('soft_timeout_seconds','checkpoint_rearm_seconds'):
    bad=dict(base); bad.pop(field,None)
    try: evaluate_worker(LifecyclePolicy.from_dict(bad),obs)
    except ValueError: pass
    else: raise AssertionError(field)
for candidate in (
    WorkerObservation('gap','implementation',100,100,200,checkpoint_sequence=(CheckpointRecord(2,0,150),)),
    WorkerObservation('gen','implementation',100,100,200,generation=1,checkpoint_sequence=(CheckpointRecord(1,0,150),)),
    WorkerObservation('meaningful','implementation',100,150,200,last_meaningful_progress_at=160),
):
    try: candidate.validate()
    except ValueError: pass
    else: raise AssertionError(candidate)
print('strict v11 lifecycle contract tests passed')
PY

# Removed legacy checkpoint CLI flags must fail argument parsing.
if python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id legacy --stage implementation \
  --started-at 100 --last-progress-at 100 --now 101 --checkpoint-requested-at 100 >/dev/null 2>&1; then
  echo "removed legacy checkpoint flag unexpectedly accepted" >&2
  exit 1
fi

printf 'lifecycle runtime v11 contract tests passed\n'
