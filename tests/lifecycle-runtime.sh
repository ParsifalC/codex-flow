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

plan() {
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown "$@"
}

LIFECYCLE="$ROOT/scripts/strategies/lifecycle_runtime.py"
python3 -m py_compile "$LIFECYCLE"

# The lifecycle state machine consumes observable facts, never Parent wait counts.
plan --routing delegate --complexity complex --uncertainty high > "$TMP/plan.json"
python3 - "$TMP/plan.json" > "$TMP/impl-policy.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["implementation_stage"]["soft_timeout_seconds"] == 900, p
assert p["implementation_stage"]["hard_timeout_seconds"] == 1800, p
print(json.dumps(p["implementation_stage"], separators=(",", ":")))
PY
IMPL_POLICY="$(cat "$TMP/impl-policy.json")"

# Efficient soft budgets are complexity-aware while preserving the existing 30-minute hard ceiling.
plan --routing delegate --complexity routine > "$TMP/routine-plan.json"
plan --routing delegate --complexity critical --risk critical > "$TMP/critical-plan.json"
python3 - "$TMP/routine-plan.json" "$TMP/critical-plan.json" <<'PY'
import json, sys
routine=json.load(open(sys.argv[1])); critical=json.load(open(sys.argv[2]))
assert routine["implementation_stage"]["soft_timeout_seconds"] == 600, routine
assert critical["implementation_stage"]["soft_timeout_seconds"] == 1200, critical
assert routine["implementation_stage"]["hard_timeout_seconds"] == 1800, routine
assert critical["implementation_stage"]["hard_timeout_seconds"] == 1800, critical
PY

python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 220 --now 250 --writable > "$TMP/progress.json"
python3 - "$TMP/progress.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="progressing" and d["action"]=="continue", d
assert d["cancel_required"] is False, d
assert d["replacement_allowed"] is False and d["fence_required"] is False, d
assert d["progress_quality"]=="meaningful" and d["meaningful_idle_seconds"]==30, d
assert d["checkpoint_status"]=="not_requested", d
assert d["replan_scope"] is None and d["checkpoint_reuse_mode"] is None, d
PY

# Reaching the soft budget requests convergence/checkpoint only. It never cancels or fences a healthy Worker.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-soft \
  --stage implementation --started-at 100 --last-progress-at 995 --now 1000 --writable --in-flight > "$TMP/soft.json"
python3 - "$TMP/soft.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="progressing" and d["action"]=="request_checkpoint", d
assert d["checkpoint_status"]=="not_requested", d
assert d["cancel_required"] is False, d
assert d["replacement_allowed"] is False and d["fence_required"] is False, d
assert d["fallback_policy"] is None, d
assert d["progress_quality"]=="meaningful", d
assert d["replan_scope"] is None, d
assert "without cancelling Worker" in d["reason"], d
PY

# Checkpoint request is stateful: after requesting it, do not repeatedly request or cancel the Worker.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-soft \
  --stage implementation --started-at 100 --last-progress-at 995 --now 1010 --writable --in-flight \
  --checkpoint-requested-at 1000 > "$TMP/checkpoint-requested.json"
python3 - "$TMP/checkpoint-requested.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["action"]=="await_checkpoint" and d["checkpoint_status"]=="requested", d
assert d["cancel_required"] is False and d["fallback_policy"] is None, d
assert d["fence_required"] is False and d["replacement_allowed"] is False, d
PY

# Once the Worker returns a checkpoint, Parent must harvest it before any later fallback.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-soft \
  --stage implementation --started-at 100 --last-progress-at 1005 --last-meaningful-progress-at 1005 \
  --now 1010 --writable --in-flight --checkpoint-requested-at 1000 --checkpoint-received-at 1005 \
  > "$TMP/checkpoint-received.json"
python3 - "$TMP/checkpoint-received.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["action"]=="harvest_checkpoint" and d["checkpoint_status"]=="received", d
assert d["cancel_required"] is False and d["fallback_policy"] is None, d
assert d["fence_required"] is False and d["replacement_allowed"] is False, d
assert d["replan_scope"] is None, d
assert "remaining delta" in d["reason"], d
PY

# A terminal-success flag does not let Parent consume a returned checkpoint
# without harvesting it first.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-terminal-checkpoint \
  --stage implementation --started-at 100 --last-progress-at 1005 --last-meaningful-progress-at 1005 \
  --now 1010 --writable --terminal-success --checkpoint-requested-at 1000 --checkpoint-received-at 1005 \
  > "$TMP/terminal-checkpoint.json"
python3 - "$TMP/terminal-checkpoint.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["action"]=="harvest_checkpoint" and d["checkpoint_status"]=="received", d
assert d["cancel_required"] is False and d["fallback_policy"] is None, d
PY

# A harvested checkpoint is non-terminal; the existing Worker continues instead of being recalled.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-soft \
  --stage implementation --started-at 100 --last-progress-at 1010 --last-meaningful-progress-at 1005 \
  --now 1020 --writable --in-flight --checkpoint-requested-at 1000 --checkpoint-received-at 1005 \
  --checkpoint-harvested-at 1010 > "$TMP/checkpoint-harvested.json"
python3 - "$TMP/checkpoint-harvested.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["action"]=="continue" and d["checkpoint_status"]=="harvested", d
assert d["cancel_required"] is False and d["fallback_policy"] is None, d
assert d["replan_scope"] is None and d["checkpoint_reuse_mode"] is None, d
assert "already been harvested" in d["reason"], d
PY

# Critical invariant: even at the hard ceiling, an already-returned checkpoint is harvested before cancellation/fallback.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-hard-checkpoint \
  --stage implementation --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 \
  --now 1900 --writable --checkpoint-requested-at 1850 --checkpoint-received-at 1890 \
  > "$TMP/hard-checkpoint-unharvested.json"
python3 - "$TMP/hard-checkpoint-unharvested.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["wall_seconds"]==1800 and d["action"]=="harvest_checkpoint", d
assert d["checkpoint_status"]=="received", d
assert d["cancel_required"] is False and d["fallback_policy"] is None, d
assert d["fence_required"] is False and d["replan_scope"] is None, d
PY

# A requested checkpoint without a returned payload does not defeat a hard
# timeout: the Worker still needs fallback and cancellation/fencing.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-requested-hard \
  --stage implementation --started-at 100 --last-progress-at 1895 --now 1900 --writable --in-flight \
  --checkpoint-requested-at 1850 > "$TMP/requested-hard.json"
python3 - "$TMP/requested-hard.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["wall_seconds"]==1800 and d["checkpoint_status"]=="requested", d
assert d["action"]=="request_cancel" and d["cancel_required"] is True, d
assert d["fence_required"] is True and d["fallback_policy"]=="replan", d
assert d["replan_scope"]=="uncovered_scope", d
PY

# The same requested-without-payload state remains a fallback/cancel decision
# after the hard boundary, not an indefinitely pending checkpoint.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-requested-timeout \
  --stage implementation --started-at 100 --last-progress-at 1895 --now 2000 --writable \
  --checkpoint-requested-at 1850 > "$TMP/requested-timeout.json"
python3 - "$TMP/requested-timeout.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["wall_seconds"]==1900 and d["checkpoint_status"]=="requested", d
assert d["action"]=="request_cancel" and d["cancel_required"] is True, d
assert d["fence_required"] is True and d["fallback_policy"]=="replan", d
assert d["replan_scope"]=="uncovered_scope", d
PY

# After harvest, hard-timeout cancellation is fenced and the future replan is explicitly restricted to remaining_delta.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-hard-checkpoint \
  --stage implementation --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 \
  --now 1901 --writable --checkpoint-requested-at 1850 --checkpoint-received-at 1890 \
  --checkpoint-harvested-at 1900 > "$TMP/hard-checkpoint-harvested.json"
python3 - "$TMP/hard-checkpoint-harvested.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["action"]=="request_cancel" and d["checkpoint_status"]=="harvested", d
assert d["cancel_required"] is True and d["fence_required"] is True, d
assert d["fallback_policy"]=="replan", d
assert d["replan_scope"]=="checkpoint_remaining_delta", d
assert d["checkpoint_reuse_mode"]=="retained_workspace", d
assert "remaining_delta" in d["reason"] and "completed work must be preserved" in d["reason"], d
PY

# Even an already-harvested checkpoint cannot keep a Worker past hard timeout;
# the fallback is limited to the harvested remaining delta and is fenced.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-harvested-hard \
  --stage implementation --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 \
  --now 1900 --writable --checkpoint-requested-at 1850 --checkpoint-received-at 1890 \
  --checkpoint-harvested-at 1895 > "$TMP/harvested-hard.json"
python3 - "$TMP/harvested-hard.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["wall_seconds"]==1800 and d["checkpoint_status"]=="harvested", d
assert d["action"]=="request_cancel" and d["cancel_required"] is True, d
assert d["fence_required"] is True and d["fallback_policy"]=="replan", d
assert d["replan_scope"]=="checkpoint_remaining_delta", d
PY

# Once the old writer is confirmed cancelled, replacement replan still receives only remaining_delta and retains the workspace.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-hard-checkpoint \
  --stage implementation --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 \
  --now 1902 --writable --cancel-confirmed --checkpoint-requested-at 1850 --checkpoint-received-at 1890 \
  --checkpoint-harvested-at 1900 > "$TMP/replan-after-cancel.json"
python3 - "$TMP/replan-after-cancel.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["action"]=="replan" and d["replacement_allowed"] is True, d
assert d["replan_scope"]=="checkpoint_remaining_delta", d
assert d["checkpoint_reuse_mode"]=="retained_workspace", d
assert d["cancel_required"] is False, d
PY

# An isolated replacement may start from the immutable harvested snapshot only; later old-Worker output stays fenced.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-hard-checkpoint \
  --stage implementation --started-at 100 --last-progress-at 1895 --last-meaningful-progress-at 1890 \
  --now 1901 --writable --replacement-isolated --checkpoint-requested-at 1850 --checkpoint-received-at 1890 \
  --checkpoint-harvested-at 1900 > "$TMP/replan-isolated.json"
python3 - "$TMP/replan-isolated.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["action"]=="replan" and d["replacement_allowed"] is True, d
assert d["cancel_required"] is True and d["fence_required"] is True, d
assert d["replan_scope"]=="checkpoint_remaining_delta", d
assert d["checkpoint_reuse_mode"]=="harvested_snapshot_only", d
PY

# Terminal failure also harvests a returned checkpoint before replanning, so partial work is never silently discarded.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-failed-checkpoint \
  --stage implementation --started-at 100 --last-progress-at 300 --now 320 --writable --terminal-failure \
  --checkpoint-requested-at 250 --checkpoint-received-at 300 > "$TMP/failed-checkpoint.json"
python3 - "$TMP/failed-checkpoint.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["action"]=="harvest_checkpoint" and d["checkpoint_status"]=="received", d
assert d["cancel_required"] is False and d["fallback_policy"] is None, d
PY

# After that checkpoint is harvested, terminal failure replan is remaining-delta-only.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-failed-checkpoint \
  --stage implementation --started-at 100 --last-progress-at 300 --now 321 --writable --terminal-failure \
  --checkpoint-requested-at 250 --checkpoint-received-at 300 --checkpoint-harvested-at 320 \
  > "$TMP/failed-checkpoint-harvested.json"
python3 - "$TMP/failed-checkpoint-harvested.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["action"]=="replan" and d["replacement_allowed"] is True, d
assert d["replan_scope"]=="checkpoint_remaining_delta", d
assert d["checkpoint_reuse_mode"]=="retained_workspace", d
PY

# Invalid checkpoint timelines fail fast instead of pretending a payload was harvested.
if python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-invalid-checkpoint \
  --stage implementation --started-at 100 --last-progress-at 500 --now 600 --writable \
  --checkpoint-received-at 550 > /dev/null 2> "$TMP/checkpoint.err"; then
  echo "checkpoint without request unexpectedly accepted" >&2
  exit 1
fi
grep -Fq 'checkpoint_received_at requires checkpoint_requested_at' "$TMP/checkpoint.err"

# Liveness activity and meaningful progress are independent: repeated tool activity does not fake an acceptance delta.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-activity-only \
  --stage implementation --started-at 100 --last-progress-at 995 --last-meaningful-progress-at 200 \
  --now 1000 --writable --in-flight > "$TMP/activity-only-soft.json"
python3 - "$TMP/activity-only-soft.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="progressing" and d["action"]=="request_checkpoint", d
assert d["progress_quality"]=="activity_only", d
assert d["idle_seconds"]==5 and d["meaningful_idle_seconds"]==800, d
assert d["cancel_required"] is False and d["fence_required"] is False, d
assert "no recent acceptance-relevant delta" in d["reason"], d
PY

# Recent acceptance-relevant output is classified separately from mere liveness.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-meaningful \
  --stage implementation --started-at 100 --last-progress-at 995 --last-meaningful-progress-at 950 \
  --now 1000 --writable --in-flight > "$TMP/meaningful-soft.json"
python3 - "$TMP/meaningful-soft.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["progress_quality"]=="meaningful" and d["meaningful_idle_seconds"]==50, d
assert d["action"]=="request_checkpoint" and d["cancel_required"] is False, d
assert "recent acceptance-relevant progress" in d["reason"], d
PY

# Before the soft budget, activity-only work remains alive and is not cancelled or stalled.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-activity-only-early \
  --stage implementation --started-at 100 --last-progress-at 500 --last-meaningful-progress-at 100 \
  --now 600 --writable > "$TMP/activity-only-early.json"
python3 - "$TMP/activity-only-early.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="progressing" and d["action"]=="continue", d
assert d["progress_quality"]=="activity_only", d
assert d["cancel_required"] is False and d["fallback_policy"] is None, d
PY

# Meaningful progress is itself observable progress and cannot be newer than the liveness timestamp.
if python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-invalid-meaningful \
  --stage implementation --started-at 100 --last-progress-at 500 --last-meaningful-progress-at 510 \
  --now 600 --writable > /dev/null 2> "$TMP/meaningful.err"; then
  echo "future meaningful progress timestamp unexpectedly accepted" >&2
  exit 1
fi
grep -Fq 'last_meaningful_progress_at cannot be newer than last_progress_at' "$TMP/meaningful.err"

# Old ExecutionPlans/callers without the optional soft/meaningful/checkpoint fields retain historical lifecycle behavior after upgrade.
python3 - "$TMP/impl-policy.json" > "$TMP/legacy-impl-policy.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
p.pop("soft_timeout_seconds", None)
print(json.dumps(p, separators=(",", ":")))
PY
LEGACY_IMPL_POLICY="$(cat "$TMP/legacy-impl-policy.json")"
python3 "$LIFECYCLE" --policy-json "$LEGACY_IMPL_POLICY" --scope-id impl-legacy \
  --stage implementation --started-at 100 --last-progress-at 995 --now 1000 --writable --in-flight > "$TMP/legacy.json"
python3 - "$TMP/legacy.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="progressing" and d["action"]=="continue", d
assert d["progress_quality"]=="meaningful", d
assert d["checkpoint_status"]=="not_requested", d
assert d["cancel_required"] is False and d["fallback_policy"] is None, d
PY

# Millisecond timestamps are rejected rather than silently misclassified as huge elapsed seconds.
if python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 1725324000000 --last-progress-at 1725324001000 \
  --now 1725324002000 --writable > /dev/null 2> "$TMP/millisecond.err"; then
  echo "millisecond timestamp unexpectedly accepted" >&2
  exit 1
fi
grep -Fq 'timestamps must use seconds, not milliseconds' "$TMP/millisecond.err"

# A visible in-flight operation keeps the idle lease alive even beyond idle timeout.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable --in-flight > "$TMP/inflight.json"
python3 - "$TMP/inflight.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"] in {"running","progressing"} and d["action"]=="continue", d
assert d["progress_quality"]=="activity_only", d
assert d["cancel_required"] is False, d
PY

# Writable stall + replan without a harvested checkpoint still reports uncovered scope and is fenced.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable > "$TMP/stall.json"
python3 - "$TMP/stall.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="stalled" and d["action"]=="request_cancel", d
assert d["cancel_required"] is True, d
assert d["fence_required"] is True and d["replacement_allowed"] is False, d
assert d["replan_scope"]=="uncovered_scope" and d["checkpoint_reuse_mode"] is None, d
PY

# Once cancellation/termination is confirmed, replan may create a replacement for uncovered scope.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable --cancel-confirmed > "$TMP/cancelled.json"
python3 - "$TMP/cancelled.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="cancelled" and d["action"]=="replan", d
assert d["cancel_required"] is False, d
assert d["fence_required"] is True and d["replacement_allowed"] is True, d
assert d["replan_scope"]=="uncovered_scope", d
PY

# A fresh isolated replacement may proceed while cancellation is still required for the old Worker.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable --replacement-isolated > "$TMP/isolated.json"
python3 - "$TMP/isolated.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="stalled" and d["action"]=="replan", d
assert d["cancel_required"] is True, d
assert d["replacement_allowed"] is True and d["fence_required"] is True, d
assert d["replan_scope"]=="uncovered_scope", d
assert "isolated" in d["reason"], d
PY

# Writable Parent delta is also a new writer and must obey the same hard fence.
python3 - "$TMP/impl-policy.json" > "$TMP/parent-delta-policy.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
p["fallback_policy"]="parent_delta"
print(json.dumps(p, separators=(",", ":")))
PY
PARENT_DELTA_POLICY="$(cat "$TMP/parent-delta-policy.json")"
python3 "$LIFECYCLE" --policy-json "$PARENT_DELTA_POLICY" --scope-id impl-parent \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable > "$TMP/parent-delta-stall.json"
python3 - "$TMP/parent-delta-stall.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="stalled" and d["action"]=="request_cancel", d
assert d["cancel_required"] is True and d["fence_required"] is True, d
assert d["replacement_allowed"] is False and d["fallback_policy"]=="parent_delta", d
assert d["replan_scope"] is None, d
PY

# Parent may take the writable delta only after old Worker termination is confirmed.
python3 "$LIFECYCLE" --policy-json "$PARENT_DELTA_POLICY" --scope-id impl-parent \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable --cancel-confirmed > "$TMP/parent-delta-cancelled.json"
python3 - "$TMP/parent-delta-cancelled.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="cancelled" and d["action"]=="parent_delta", d
assert d["cancel_required"] is False and d["fence_required"] is True, d
assert d["replacement_allowed"] is False, d
PY

# Or Parent may write in a fresh isolated worktree while the old Worker is still being cancelled.
python3 "$LIFECYCLE" --policy-json "$PARENT_DELTA_POLICY" --scope-id impl-parent \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable --replacement-isolated > "$TMP/parent-delta-isolated.json"
python3 - "$TMP/parent-delta-isolated.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="stalled" and d["action"]=="parent_delta", d
assert d["cancel_required"] is True and d["fence_required"] is True, d
assert d["replacement_allowed"] is False, d
assert "downstream writer is explicitly isolated" in d["reason"], d
PY

# Terminal failure without a checkpoint may immediately replan, but only uncovered scope is claimed.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 100 --now 120 --writable --terminal-failure > "$TMP/failed.json"
python3 - "$TMP/failed.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="failed" and d["action"]=="replan", d
assert d["cancel_required"] is False and d["replacement_allowed"] is True, d
assert d["replan_scope"]=="uncovered_scope", d
PY

# Hard wall ceiling still wins when there is no returned checkpoint to preserve, even if work is visibly in-flight.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 1800 --now 2000 --writable --in-flight > "$TMP/hard.json"
python3 - "$TMP/hard.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="stalled" and d["action"]=="request_cancel", d
assert d["cancel_required"] is True, d
assert d["replan_scope"]=="uncovered_scope", d
assert "hard worker wall-clock ceiling" in d["reason"], d
PY

# Read-only supersession remains cancellable without writable replacement fencing.
plan --routing delegate --complexity complex --uncertainty high > "$TMP/explorer-plan.json"
python3 - "$TMP/explorer-plan.json" > "$TMP/explorer-policy.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
print(json.dumps(p["exploration_stage"], separators=(",", ":")))
PY
EXP_POLICY="$(cat "$TMP/explorer-policy.json")"
python3 "$LIFECYCLE" --policy-json "$EXP_POLICY" --scope-id metadata \
  --stage exploration --started-at 100 --last-progress-at 120 --now 130 --scope-superseded > "$TMP/superseded.json"
python3 - "$TMP/superseded.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="superseded" and d["action"]=="request_cancel", d
assert d["cancel_required"] is True, d
assert d["fence_required"] is False and d["replacement_allowed"] is False, d
PY

# Once a superseded Worker is cancelled, the scope is already satisfied: no fallback duplication.
python3 "$LIFECYCLE" --policy-json "$EXP_POLICY" --scope-id metadata \
  --stage exploration --started-at 100 --last-progress-at 120 --now 140 --scope-superseded --cancel-confirmed > "$TMP/superseded-cancelled.json"
python3 - "$TMP/superseded-cancelled.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="superseded" and d["action"]=="continue", d
assert d["cancel_required"] is False, d
assert d["fallback_policy"] is None, d
PY

# A read-only stalled Worker can fall back immediately, but cancellation is still mandatory.
python3 "$LIFECYCLE" --policy-json "$EXP_POLICY" --scope-id metadata \
  --stage exploration --started-at 100 --last-progress-at 100 --now 250 > "$TMP/read-stall.json"
python3 - "$TMP/read-stall.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="stalled" and d["action"]=="parent_delta", d
assert d["cancel_required"] is True, d
assert d["fence_required"] is False and d["replacement_allowed"] is False, d
PY

# Read-only replan may launch a replacement while the old stalled Worker is being cancelled.
plan --profile quality --routing delegate --complexity complex --risk high --verification-cost high > "$TMP/review-plan.json"
python3 - "$TMP/review-plan.json" > "$TMP/review-policy.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["review_stage"] is not None, p
print(json.dumps(p["review_stage"], separators=(",", ":")))
PY
REV_POLICY="$(cat "$TMP/review-policy.json")"
python3 "$LIFECYCLE" --policy-json "$REV_POLICY" --scope-id review-runtime \
  --stage review --started-at 100 --last-progress-at 100 --now 500 > "$TMP/review-stall.json"
python3 - "$TMP/review-stall.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="stalled" and d["action"]=="replan", d
assert d["cancel_required"] is True, d
assert d["replacement_allowed"] is True and d["fence_required"] is False, d
assert d["replan_scope"]=="uncovered_scope", d
PY

# ---- Restored PR5 regression coverage ----

# Release defaults remain the source of truth for reasoning policy.
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
python3 "$TMP/runtime/strategy_runtime.py" --policy "$TMP/release-only.toml" plan --repo-policy none --quota-pressure unknown \
  --routing delegate --complexity routine --risk low > "$TMP/release-default.json"
python3 - "$TMP/release-default.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["parent_reasoning"]=="xhigh" and p["implementer_reasoning"]=="max", p
PY

# Role-specific model/reasoning behavior from PR5 remains intact.
plan --profile quality --complexity complex --uncertainty high --risk high --parallelism high \
  --scope repo-wide --exploration-need high > "$TMP/quality.json"
python3 - "$TMP/quality.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["parent_reasoning"]=="xhigh", p
assert p["explorer_reasoning"]=="max" and p["implementer_reasoning"]=="max", p
assert p["explorer_model"]=="gpt-test-efficient" and p["implementer_model"]=="gpt-test-efficient", p
assert p["reviewer_model"]=="gpt-test-efficient" and p["reviewer_reasoning"]=="max", p
PY

plan --profile quality --quality-intent strong --complexity routine --risk medium --parallelism limited > "$TMP/quality-strong.json"
python3 - "$TMP/quality-strong.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["explorer_capability_policy"]=="latest-efficient" and p["explorer_model"]=="gpt-test-efficient", p
assert p["implementer_capability_policy"]=="latest-capable" and p["implementer_model"] is None, p
assert p["reviewer_capability_policy"]=="latest-capable" and p["reviewer_model"] is None, p
assert p["explorer_reasoning"]=="max" and p["implementer_reasoning"]=="max", p
PY

# Speed scaling still follows proven writable-workstream count.
plan --profile speed --complexity routine --parallelism high --write-conflict low > "$TMP/speed-one.json"
plan --profile speed --complexity routine --parallelism high --write-conflict low --writable-workstreams 4 > "$TMP/speed-four.json"
python3 - "$TMP/speed-one.json" "$TMP/speed-four.json" <<'PY'
import json, sys
one=json.load(open(sys.argv[1])); four=json.load(open(sys.argv[2]))
assert one["implementation_workers"]==1, one
assert four["implementation_workers"]==4 and four["max_concurrent_threads"]==4, four
assert four["worker_budget"]["max_implementers"]==8, four
assert any("4 proven isolated workstreams" in n for n in four["notes"]), four
PY

# Modifiers cannot bypass strategy budgets or writable isolation.
plan --profile efficient --review strict --fanout aggressive --complexity complex --uncertainty high \
  --parallelism high --write-conflict low --writable-workstreams 2 > "$TMP/modifiers.json"
python3 - "$TMP/modifiers.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["exploration_workers"]==2 and p["implementation_workers"]==2, p
assert p["reviewer_workers"]==1 and p["planned_worker_count"]==5, p
assert p["worker_budget"]["max_total_workers"]==5, p
PY

# Explicit repo-policy none still disables repository policy discovery.
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
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" show --effective --repo-policy none --json > "$TMP/no-repo-show.json"
  python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --quota-pressure unknown --complexity routine > "$TMP/no-repo-plan.json"
)
python3 - "$TMP/no-repo-show.json" "$TMP/no-repo-plan.json" <<'PY'
import json, sys
show=json.load(open(sys.argv[1])); p=json.load(open(sys.argv[2]))
assert show["strategy"]=="efficient" and show["routing"]=="adaptive", show
assert show["repo_policy"] is None and p["repo_policy"] is None, (show,p)
PY

# Task flags may tighten but never raise repository runtime ceilings.
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
assert hard["max_concurrent_threads"] <= 2 and hard["max_repair_cycles"] == 1, hard
assert tight["max_concurrent_threads"] == 1 and tight["max_repair_cycles"] == 0, tight
PY

# Critical quota pressure compresses fan-out without lowering reasoning floors.
python3 "$ROOT/scripts/strategy_runtime.py" --policy "$POLICY" plan --repo-policy none --profile balanced --routing delegate \
  --complexity complex --uncertainty high --parallelism high --quota-pressure critical > "$TMP/quota.json"
python3 - "$TMP/quota.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p["exploration_workers"]==1 and p["implementation_workers"]==1, p
assert p["max_concurrent_threads"]==1 and p["max_repair_cycles"]==1, p
assert p["parent_reasoning"]=="high", p
assert p["explorer_reasoning"]=="xhigh" and p["implementer_reasoning"]=="xhigh", p
PY

printf 'lifecycle runtime and restored regression tests passed\n'
