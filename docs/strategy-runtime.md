# FlowPilot Multi-Strategy Runtime

FlowPilot is the semantic profiler and execution runtime for codex-flow. Persistent policy remains **schema v4**. The execution contract introduced by this runtime is **ExecutionPlan schema v11** with a canonical cumulative task budget, shared Worker lifecycle semantics, bounded implementation units, read-only review retries, and phase-aware admission.

```text
User task
  ↓
FlowPilot semantic TaskProfile
  ↓
strategy_runtime.py + strategy registry
  ↓
ExecutionPlan v11
  ↓
──────────────── authoritative boundary ────────────────
  ↓
FlowPilot execution
  ├─ exploration
  ├─ bounded implementation
  ├─ required read-only review
  └─ Parent finalization
  ↓
Telemetry
```

The invariant is:

> **FlowPilot profiles. `strategy_runtime.py` plus the strategy registry decide. FlowPilot executes the returned plan.**

The Skill must not keep a second copy of strategy topology, Worker counts, role capability/reasoning policy, lifecycle thresholds, task-budget limits, phase-admission rules, or quota logic.

## Design invariants

1. Strategy is an optimization objective; routing is an orthogonal execution constraint.
2. WorkerBudget is an envelope, not a mandatory Worker count.
3. Strategy-specific tuning lives in `scripts/strategies/*.py`; the generic compiler normalizes it against runtime/safety constraints.
4. `quality_intent` is user optimization intent and is not equivalent to technical risk.
5. Model capability and reasoning effort are independent axes.
6. Multiple writable implementers require already-proven isolated writable workstreams.
7. `max_concurrent_threads` is a per-stage concurrency ceiling, not a whole-task Worker total.
8. Bounded work units are logical acceptance transactions, not permission to create extra writers.
9. `minimum_work_units=1` for all built-in strategies; no strategy mechanically forces a fake split.
10. A task-level budget is durable across implementation attempts/replans/replacements and cannot be reset by recompiling a later plan.
11. ExecutionPlan is the only canonical task-budget source. Phase runtime validates and executes it; it does not derive a second budget.
12. Required review and Parent finalization have explicit time windows.
13. Review failure retries are read-only `retry_review`, not writable implementation replans.
14. A returned checkpoint is harvested before any fallback that could discard useful work.
15. `wait()` timeouts are not Worker timeouts.
16. Telemetry is observational and never calls a model only to estimate usage or latency.
17. The new task-ledger contract has no grandfather/adoption path because no earlier persisted-task format containing this feature was released. Incompatible task-ledger schema/policy fails closed.

## Strategy registry

Built-in strategies:

```text
scripts/strategies/
├── efficient.py
├── balanced.py
├── quality.py
├── speed.py
├── base.py
├── lifecycle_runtime.py
├── work_unit_runtime.py
├── task_budget_runtime.py
└── task_phase_runtime.py
```

Each StrategySpec supplies the optimization preferences used by the generic compiler:

```text
adaptive_route(task)
effort(task, role)
worker_budget(task)
independent_review(task)
capability(task, role)
exploration_bonus(task)
reviewer_bonus(task)
notes(task)
lifecycle(task, stage)
task_budget(task)
reasoning_rollout(...) | none
```

The compiler owns generic policy precedence, runtime ceilings, writable-isolation proof, quota normalization, concrete topology, and final ExecutionPlan construction.

## ExecutionPlan schema v11

The important runtime fields are:

```text
ExecutionPlan
  schema_version = 11
  strategy
  routing
  review_modifier
  fanout_modifier
  quality_intent

  parent_* capability/reasoning
  explorer_* capability/model/reasoning | none
  implementer_* capability/model/reasoning | none
  reviewer_* capability/model/reasoning | none
  reasoning_rollout | none

  worker_budget
  exploration_workers
  implementation_workers
  reviewer_workers
  planned_worker_count
  max_concurrent_threads

  exploration_stage | none
  implementation_stage | none
  review_stage | none

  task_budget | none
    soft_timeout_seconds
    hard_timeout_seconds
    max_work_units
    max_implementation_attempts
    max_replans
    max_replacements
    max_review_attempts
    parent_finalization_seconds

  review_mode
  max_repair_cycles
  quota_pressure
  notes
```

Direct plans have no delegated stages and `task_budget=null`.

For delegated work, compiler validation includes:

```text
implementation_stage.maximum_work_units == task_budget.max_work_units
implementation_workers <= task_budget.max_work_units
implementation_workers <= task_budget.max_implementation_attempts
reviewer_workers <= task_budget.max_review_attempts  # when review is planned
```

When no reviewer Worker is planned, canonical `max_review_attempts=0`.

## Shared Worker lifecycle

All four strategies use the same lifecycle mechanics. Strategies tune only thresholds and maximum logical units.

| Strategy | Implementation soft checkpoint | Rearm | Worker-local repairs | Max logical units | Worker hard ceiling |
| --- | --- | --- | --- | --- | --- |
| `efficient` | 600 / 900 / 1200s | 180 / 240 / 300s | 1–2 | 1–3 | 1800s |
| `balanced` | 1200 / 1500 / 1800s | 240 / 300 / 360s | 1–2 | 1–3 | 2400s |
| `quality` | 1800 / 2400 / 2700s | 360 / 480 / 600s | 2–3 | 1–4 | 3600s |
| `speed` | 420 / 600 / 720s | 180s | 1 | 1–4 | 1200s |

Lifecycle semantics:

- `last_progress_at` is liveness activity.
- `last_meaningful_progress_at` is acceptance-relevant progress.
- soft timeout requests/converges toward checkpoints but does not itself cancel a Worker.
- repeated checkpoint requests require explicit meaningful progress after the latest harvest plus `checkpoint_rearm_seconds`.
- an unharvested received checkpoint is harvested before terminal failure, hard timeout, idle fallback, cancellation handling, or writer replacement.
- implementation `replan` operates on uncovered/remaining delta, not the original complete task.

### Review lifecycle

Review fallback is `retry_review`.

It is intentionally distinct from implementation `replan`:

```text
review failure
  → retry_review
  → read-only replacement_allowed
  → consume review_attempt
  → no replan_scope
  → no writable scope
  → no writer fence
```

A reviewer retry can occur only while phase admission says `permits_review_start=true`.

## Evidence-based bounded implementation

`StagePolicy` carries:

```text
work_unit_mode: single | bounded
minimum_work_units
join_between_work_units
maximum_work_units | none
require_write_paths
```

All built-in strategies keep `minimum_work_units=1`. Complexity/risk/scope/quality may raise only the maximum.

A split is valid only when Parent has evidence for an independent acceptance delta, validation boundary, ownership/dependency boundary, or already-proven isolated writable stream. Do not split solely to satisfy a number.

For strategies that permit parallel writers, `implementation_maximum_work_units()` also accounts for real writer topology:

```text
topology_floor = min(writable_workstreams, strategy.max_implementers)
maximum_work_units = max(semantic_maximum, topology_floor)
```

This prevents impossible plans such as four proven implementers with only one logical unit/attempt budget.

The deterministic manifest validator checks:

- required unit fields and types;
- normalized repository-relative POSIX `write_paths`;
- no absolute/traversal/glob/backslash/NUL/Windows-drive paths;
- dependency ordering for overlapping paths/write scopes;
- no dependency-linked units inside one parallel group;
- parallel width <= compiled implementation/thread concurrency;
- manifest count <= `maximum_work_units`.

`write_paths` are lexical preflight only. They are not OS locks, symlink resolution, or durable scheduler fencing.

## Canonical cumulative task budget

Each delegated built-in strategy emits a raw task envelope. The compiler then canonicalizes it against the actual planned topology/review stage.

Typical raw general-work envelopes:

| Strategy | Soft | Base hard | Work units | Implementation attempts | Replans | Replacements | Review attempts | Parent finalization |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `efficient` | 1500s | 1800s | 1–3 | units + 1 | 1 | 1 | 2 | 150s |
| `speed` | 1200s | 1800s | 1–4 | units + 1 | 1 | 1 | 2 | 120s |
| `balanced` | 2400–3000s | 3000–3600s | 1–3 | units + 2 | 2 | 2 | 2 | 180s |
| `quality` | 4800–6000s | 6000–7200s | 1–4 | units + 3 | 3 | 3 | 2–4 | 300s |

When reviewer Workers are planned:

```text
completion_tail = review_stage.hard_timeout_seconds
                + task_budget.parent_finalization_seconds

canonical_hard = max(
  raw_hard,
  task_budget.soft_timeout_seconds + completion_tail
)
```

The resulting canonical budget is written directly into ExecutionPlan. No runtime helper later rewrites the soft/hard values.

Example: `efficient + strict review` keeps its complete 1500-second general-work window and receives the required completion tail instead of shrinking implementation to make review fit.

## Phase-aware admission

Initialize the task ledger with the exact initial ExecutionPlan:

```bash
python3 ~/.codex/codex-flow/strategies/task_phase_runtime.py init \
  --state-file <state> \
  --task-id <task-id> \
  --plan-json '<ExecutionPlan v11 JSON>' \
  --now <unix-seconds>
```

The initial budget-plan identity owns this ledger for the task lifetime. A later recompiled plan may control current execution semantics but cannot replace/reset/extend the original ledger.

The phase timeline is:

```text
started_at
  |
  | general exploration + writable implementation
  v
soft_deadline = general_work_deadline
  |
  | required read-only review
  v
review_deadline = hard_deadline - parent_finalization_seconds
  |
  | Parent finalization only
  v
hard_deadline = absolute stop
```

### General work

General reservation kinds:

```text
work_unit
implementation_attempt
replan
replacement
```

They must use `phase=implementation`. New general reservations are rejected at soft deadline. Exact replay of an already-recorded reservation stays idempotent because the durable ledger checks identity before its deadline gate.

### Required review

Reviewer starts/retries reserve:

```text
phase=required_completion
kind=review_attempt
```

A new reviewer is admitted only before `review_deadline`. At/after that boundary, phase action becomes `finalize_parent`; no reviewer start/retry may consume the Parent finalization reserve.

### Parent finalization

From `review_deadline` until hard deadline:

- no new reviewer;
- no reopened writable implementation;
- Parent reconciles already-collected review evidence and runs final non-writing verification/delivery work;
- at hard deadline action is `stop`.

Important phase output:

```text
permits_general_work
permits_required_completion
permits_review_start
permits_parent_finalization
general_work_deadline
review_deadline
hard_deadline
checkpoint_convergence_required
required_completion_handoff
action
```

## Durable ledger

`task_budget_runtime.py` schema v2 stores hashes/limits/reservations, not prompts or output payloads.

Reservation kinds:

```text
work_unit
implementation_attempt
replan
replacement
review_attempt
```

The ledger uses file locking, atomic replace, monotonic timestamps, policy/task fingerprints, bounded counters, and idempotent reservation IDs.

The phase helper is the scheduling/admission layer. Raw ledger flags are not a substitute for phase-specific decisions.

## Initial-plan identity and replan

Replanning never receives a fresh task budget.

```text
initial ExecutionPlan
  → initialize ledger once
  → reserve/execute
  → evidence changes
  → compile newer ExecutionPlan for current topology/lifecycle
  → keep initial plan + same ledger for cumulative admission
```

If newer execution cannot fit the remaining original budget, converge/fail closed rather than resetting counters/deadlines.

Completed bounded units and harvested checkpoints remain evidence unless concrete new information invalidates them.

## Efficient reasoning rollout

Reasoning rollout remains intentionally `efficient`-specific:

```text
legacy   select historical Worker effort
shadow   report proposal, select historical effort
adaptive select proposal
```

Proposal:

```text
max(rollout class target, rollout minimum, parent_reasoning)
```

The plan records intent. Runtime-observed effort must come from runtime evidence and must not be fabricated from the requested value.

## Quota and telemetry

Quota state comes from reliable runtime/app-server data or is `unknown`; it is never guessed.

Telemetry is deterministic and observational. A telemetry failure is fail-open and must not block checkpoint harvest, fencing, cancellation, or delivery.

Use homogeneous samples and success/censoring context before tuning latency thresholds or moving an effort rollout from shadow to adaptive.

## Current limitations

The contract deliberately distinguishes deterministic policy from capabilities supplied by the surrounding scheduler/runtime:

- `write_paths` do not provide OS-level locking or symlink-safe ownership.
- lifecycle helpers evaluate state but do not independently schedule/cancel Workers.
- checkpoints require the surrounding runtime to persist/use the returned payload.
- generation lineage must be enforced when integrating real Worker output.
- reasoning rollout is currently efficient-specific.
- task-budget values are policy envelopes, not empirical latency predictions.

These limitations should be addressed through scheduler/runtime integration and telemetry-guided tuning, not by weakening the deterministic contracts above.

## Version invariant

Persistent policy schema remains v4. ExecutionPlan schema v11 and task-ledger schema v2 are the only supported interpretation of this unreleased task-execution contract. There is intentionally no `legacy_unclamped`, effective-budget migration, or grandfathered pre-phase task-ledger path.
