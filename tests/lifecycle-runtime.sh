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
import json, sys
p=json.load(open(sys.argv[1]))
stage=p['implementation_stage']
assert stage['soft_timeout_seconds']==900 and stage['hard_timeout_seconds']==1800, stage
assert stage['checkpoint_rearm_seconds']==240 and stage['fallback_policy']=='replan', stage
print(json.dumps(stage,separators=(',',':')))
PY
IMPL_POLICY="$(cat "$TMP/impl-policy.json")"

# Active liveness is not a timeout and Parent wait intervals are not lifecycle evidence.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 220 --now 250 --writable > "$TMP/active.json"
python3 - "$TMP/active.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='continue' and d['state']=='progressing',d
assert not d['cancel_required'] and not d['fence_required'],d
assert d['progress_quality']=='meaningful',d
PY

# Soft budget requests a non-terminal checkpoint and does not cancel/fence.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id soft \
  --stage implementation --started-at 100 --last-progress-at 995 --last-meaningful-progress-at 995 \
  --now 1000 --writable --in-flight > "$TMP/soft.json"
python3 - "$TMP/soft.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='request_checkpoint' and d['next_checkpoint_sequence']==1,d
assert d['checkpoint_status']=='not_requested',d
assert not d['cancel_required'] and not d['fence_required'],d
PY

# Outstanding checkpoint request is awaited, not spammed.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id soft \
  --stage implementation --started-at 100 --last-progress-at 1005 --now 1010 --writable --in-flight \
  --checkpoint-requested-at 1000 > "$TMP/requested.json"
python3 - "$TMP/requested.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='await_checkpoint' and d['checkpoint_status']=='requested',d
assert not d['cancel_required'],d
PY

# Returned checkpoint is always harvested before terminal/fallback processing.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id soft \
  --stage implementation --started-at 100 --last-progress-at 1005 --last-meaningful-progress-at 1005 \
  --now 1010 --writable --terminal-failure --checkpoint-requested-at 1000 --checkpoint-received-at 1005 \
  > "$TMP/received.json"
python3 - "$TMP/received.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='harvest_checkpoint' and d['checkpoint_status']=='received',d
assert d['fallback_policy'] is None and not d['cancel_required'],d
PY

# A harvested checkpoint is non-terminal. With no new explicit meaningful delta,
# liveness alone does not re-arm another checkpoint.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id soft \
  --stage implementation --started-at 100 --last-progress-at 1195 --now 1200 --writable --in-flight \
  --checkpoint-sequence-json '[{"sequence":1,"generation":0,"requested_at":900,"received_at":910,"harvested_at":920}]' \
  > "$TMP/no-rearm.json"
python3 - "$TMP/no-rearm.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='continue' and d['checkpoint_status']=='harvested',d
assert d['next_checkpoint_sequence'] is None,d
assert 'last_progress_at cannot re-arm' in d['reason'],d
PY

# Explicit acceptance-relevant progress plus cooldown re-arms sequence 2.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id rearm \
  --stage implementation --started-at 100 --last-progress-at 1155 --last-meaningful-progress-at 1155 \
  --now 1160 --writable --in-flight \
  --checkpoint-sequence-json '[{"sequence":1,"generation":0,"requested_at":900,"received_at":910,"harvested_at":920}]' \
  > "$TMP/rearm.json"
python3 - "$TMP/rearm.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='request_checkpoint' and d['checkpoint_sequence']==1,d
assert d['next_checkpoint_sequence']==2 and d['checkpoint_rearm_at']==1160,d
PY

# Before cooldown expiry, even meaningful progress does not churn checkpoints.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id cooldown \
  --stage implementation --started-at 100 --last-progress-at 995 --last-meaningful-progress-at 995 \
  --now 1000 --writable --in-flight \
  --checkpoint-sequence-json '[{"sequence":1,"generation":0,"requested_at":900,"received_at":910,"harvested_at":920}]' \
  > "$TMP/cooldown.json"
python3 - "$TMP/cooldown.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='continue' and d['checkpoint_rearm_remaining_seconds']==160,d
PY

# At Worker hard ceiling, a returned checkpoint still wins and is harvested first.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id hard \
  --stage implementation --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 \
  --now 1900 --writable --checkpoint-requested-at 1850 --checkpoint-received-at 1890 > "$TMP/hard-received.json"
python3 - "$TMP/hard-received.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['wall_seconds']==1800 and d['action']=='harvest_checkpoint',d
assert d['checkpoint_status']=='received' and not d['cancel_required'],d
PY

# After harvest, a live writer at hard timeout is cancelled/fenced. Replan is
# restricted to the harvested remaining delta.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id hard \
  --stage implementation --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 \
  --now 1901 --writable --checkpoint-requested-at 1850 --checkpoint-received-at 1890 --checkpoint-harvested-at 1900 \
  > "$TMP/hard-harvested.json"
python3 - "$TMP/hard-harvested.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='request_cancel' and d['cancel_required'],d
assert d['fence_required'] and not d['replacement_allowed'],d
assert d['replan_scope']=='checkpoint_remaining_delta',d
assert d['checkpoint_reuse_mode']=='retained_workspace',d
PY

# Once cancellation is confirmed, replacement may replan only the remaining delta.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id hard \
  --stage implementation --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 \
  --now 1902 --writable --cancel-confirmed \
  --checkpoint-requested-at 1850 --checkpoint-received-at 1890 --checkpoint-harvested-at 1900 \
  > "$TMP/after-cancel.json"
python3 - "$TMP/after-cancel.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='replan' and d['replacement_allowed'],d
assert d['replan_scope']=='checkpoint_remaining_delta',d
assert d['checkpoint_reuse_mode']=='retained_workspace',d
PY

# Isolated replacement can proceed from immutable harvested snapshot while old
# writer cancellation remains required; later old output remains fenced.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id isolated \
  --stage implementation --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 \
  --now 1901 --writable --replacement-isolated \
  --checkpoint-requested-at 1850 --checkpoint-received-at 1890 --checkpoint-harvested-at 1900 \
  > "$TMP/isolated.json"
python3 - "$TMP/isolated.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='replan' and d['replacement_allowed'] and d['cancel_required'],d
assert d['fence_required'] and d['checkpoint_reuse_mode']=='harvested_snapshot_only',d
PY

# Without a checkpoint, writable idle fallback claims only uncovered scope and
# requires cancellation/fencing before replacement on the same live scope.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id idle \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable > "$TMP/idle.json"
python3 - "$TMP/idle.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['state']=='stalled' and d['action']=='request_cancel',d
assert d['cancel_required'] and d['fence_required'],d
assert d['replan_scope']=='uncovered_scope',d
PY

# Parent delta is also a writer and obeys the same fence.
python3 - "$TMP/impl-policy.json" > "$TMP/parent-policy.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); p['fallback_policy']='parent_delta'
print(json.dumps(p,separators=(',',':')))
PY
PARENT_POLICY="$(cat "$TMP/parent-policy.json")"
python3 "$LIFECYCLE" --policy-json "$PARENT_POLICY" --scope-id parent \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable > "$TMP/parent.json"
python3 - "$TMP/parent.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='request_cancel' and d['cancel_required'] and d['fence_required'],d
assert d['fallback_policy']=='parent_delta' and d['replan_scope'] is None,d
PY

# Review fallback is now explicitly read-only retry_review, never implementation replan.
plan --profile quality --routing delegate --complexity complex --risk high --verification-cost high > "$TMP/review-plan.json"
python3 - "$TMP/review-plan.json" > "$TMP/review-policy.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); stage=p['review_stage']
assert stage is not None and stage['fallback_policy']=='retry_review',stage
print(json.dumps(stage,separators=(',',':')))
PY
REVIEW_POLICY="$(cat "$TMP/review-policy.json")"
python3 "$LIFECYCLE" --policy-json "$REVIEW_POLICY" --scope-id review \
  --stage review --started-at 100 --last-progress-at 100 --now 500 > "$TMP/review-stall.json"
python3 - "$TMP/review-stall.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['state']=='stalled' and d['action']=='retry_review',d
assert d['cancel_required'] and d['replacement_allowed'],d
assert not d['fence_required'],d
assert d['replan_scope'] is None and d['checkpoint_reuse_mode'] is None,d
assert d['fallback_policy']=='retry_review',d
PY

# Terminal review failure can immediately request a read-only replacement.
python3 "$LIFECYCLE" --policy-json "$REVIEW_POLICY" --scope-id review \
  --stage review --started-at 100 --last-progress-at 120 --now 130 --terminal-failure > "$TMP/review-failed.json"
python3 - "$TMP/review-failed.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='retry_review' and not d['cancel_required'],d
assert d['replacement_allowed'] and not d['fence_required'],d
assert d['replan_scope'] is None,d
PY

# Superseded read-only exploration is cancellable without writer fencing.
plan --routing delegate --complexity complex --uncertainty high > "$TMP/explore-plan.json"
python3 - "$TMP/explore-plan.json" > "$TMP/explore-policy.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); print(json.dumps(p['exploration_stage'],separators=(',',':')))
PY
EXP_POLICY="$(cat "$TMP/explore-policy.json")"
python3 "$LIFECYCLE" --policy-json "$EXP_POLICY" --scope-id metadata \
  --stage exploration --started-at 100 --last-progress-at 120 --now 130 --scope-superseded > "$TMP/superseded.json"
python3 - "$TMP/superseded.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['action']=='request_cancel' and d['cancel_required'],d
assert not d['fence_required'] and not d['replacement_allowed'],d
PY

# Invalid checkpoint/timestamp/type contracts fail closed.
if python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id invalid \
  --stage implementation --started-at 100 --last-progress-at 500 --now 600 --writable \
  --checkpoint-received-at 550 >/dev/null 2>"$TMP/checkpoint.err"; then
  echo "checkpoint without request unexpectedly accepted" >&2
  exit 1
fi
grep -Fq 'checkpoint_received_at requires checkpoint_requested_at' "$TMP/checkpoint.err"

if python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id future \
  --stage implementation --started-at 100 --last-progress-at 601 --now 600 >/dev/null 2>"$TMP/future.err"; then
  echo "future progress unexpectedly accepted" >&2
  exit 1
fi
grep -Fq 'last_progress_at cannot be in the future' "$TMP/future.err"

if python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id ms \
  --stage implementation --started-at 1725324000000 --last-progress-at 1725324001000 --now 1725324002000 \
  >/dev/null 2>"$TMP/ms.err"; then
  echo "millisecond timestamp unexpectedly accepted" >&2
  exit 1
fi
grep -Fq 'timestamps must use seconds, not milliseconds' "$TMP/ms.err"

python3 - "$ROOT" <<'PY'
import math,sys
sys.path.insert(0,sys.argv[1]+'/scripts')
from strategies.lifecycle_runtime import LifecyclePolicy, WorkerObservation, CheckpointRecord
base={
 'join_policy':'required','min_successful_workers':1,'idle_timeout_seconds':10,'hard_timeout_seconds':20,
 'cancel_if_superseded':False,'cancel_stragglers_after_quorum':False,'fallback_policy':'replan'
}
for key,value in (
 ('join_policy',1),('fallback_policy',1),('min_successful_workers',True),
 ('idle_timeout_seconds','10'),('hard_timeout_seconds',float('inf')),('checkpoint_rearm_seconds',True),
):
    candidate=dict(base); candidate[key]=value
    try: LifecyclePolicy.from_dict(candidate)
    except ValueError: pass
    else: raise AssertionError((key,value))
for observation in (
    WorkerObservation('future','implementation',100,101,100),
    WorkerObservation('generation','implementation',100,100,100,generation=1,checkpoint_sequence=(CheckpointRecord(1,0,100),)),
    WorkerObservation('mixed','implementation',100,100,100,checkpoint_requested_at=100,checkpoint_sequence=()),
):
    try: observation.validate()
    except ValueError: pass
    else: raise AssertionError(observation)
print('adversarial lifecycle contract tests passed')
PY

printf 'lifecycle runtime and restored regression tests passed\n'
