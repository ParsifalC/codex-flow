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
PY

# Reaching the soft budget requests convergence/checkpoint only. It never cancels or fences a healthy Worker.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl-soft \
  --stage implementation --started-at 100 --last-progress-at 995 --now 1000 --writable --in-flight > "$TMP/soft.json"
python3 - "$TMP/soft.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="progressing" and d["action"]=="request_checkpoint", d
assert d["cancel_required"] is False, d
assert d["replacement_allowed"] is False and d["fence_required"] is False, d
assert d["fallback_policy"] is None, d
assert "without cancelling Worker" in d["reason"], d
PY

# Old ExecutionPlans without the optional soft field retain the historical lifecycle behavior after upgrade.
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
assert d["cancel_required"] is False, d
PY

# Writable stall + replan is fenced: do not spawn same-scope replacement while old Worker may resume.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable > "$TMP/stall.json"
python3 - "$TMP/stall.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="stalled" and d["action"]=="request_cancel", d
assert d["cancel_required"] is True, d
assert d["fence_required"] is True and d["replacement_allowed"] is False, d
PY

# Once cancellation/termination is confirmed, replan may create a replacement.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 100 --now 400 --writable --cancel-confirmed > "$TMP/cancelled.json"
python3 - "$TMP/cancelled.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="cancelled" and d["action"]=="replan", d
assert d["cancel_required"] is False, d
assert d["fence_required"] is True and d["replacement_allowed"] is True, d
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

# Terminal failure is already fenced and may immediately replan.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 100 --now 120 --writable --terminal-failure > "$TMP/failed.json"
python3 - "$TMP/failed.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="failed" and d["action"]=="replan", d
assert d["cancel_required"] is False and d["replacement_allowed"] is True, d
PY

# Hard wall ceiling wins even if an operation is visibly in-flight.
python3 "$LIFECYCLE" --policy-json "$IMPL_POLICY" --scope-id impl \
  --stage implementation --started-at 100 --last-progress-at 1800 --now 2000 --writable --in-flight > "$TMP/hard.json"
python3 - "$TMP/hard.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d["state"]=="stalled" and d["action"]=="request_cancel", d
assert d["cancel_required"] is True, d
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
