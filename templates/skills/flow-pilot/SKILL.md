---
name: flow-pilot
description: Profile non-trivial technical work, compile a deterministic ExecutionPlan through codex-flow, and execute its worker, lifecycle, task-budget, review, and validation contracts exactly.
---

# FlowPilot Strategy Runtime

FlowPilot is the semantic profiler and execution runtime for codex-flow. It is **not** a second strategy engine.

> **FlowPilot profiles. `strategy_runtime.py` + the strategy registry decide. FlowPilot executes the returned plan.**

Do not independently re-implement strategy topology, capability selection, reasoning selection, quota policy, Worker counts, review mode, fan-out, lifecycle policy, local repair budget, task budget, phase admission, or implementation work-unit policy. The installed planner and deterministic runtime helpers are authoritative.

Default policy remains `strategy=efficient` with `routing=adaptive`.

## 0. Strategy gate and precedence

Before automatic FlowPilot delegation, read the installed strategy state:

```bash
python3 ~/.codex/codex-flow/strategy_runtime.py \
  --policy ~/.codex/codex-flow.toml \
  show --json
```

If enabled, atomically consume any one-shot bypass:

```bash
python3 ~/.codex/codex-flow/strategy_runtime.py \
  --policy ~/.codex/codex-flow.toml \
  consume-bypass
```

If that prints `true`, bypass FlowPilot for this task only. If `enabled=false`, do not build a FlowPilot TaskProfile or compile an ExecutionPlan; continue with ordinary Codex execution. Repository policy and task overrides cannot re-enable a disabled global switch.

Policy precedence is:

```text
hard runtime / safety ceilings
  > explicit current-task overrides
  > repository .codex-flow.toml
  > ~/.codex/codex-flow.toml
  > release defaults
```

Persistent dimensions are independent:

- strategy: `efficient | balanced | quality | speed`
- routing: `adaptive | direct | delegate`
- review: `auto | standard | strict`
- fanout: `auto | conservative | aggressive`

`direct` — do not spawn or delegate to subagents for this task.

`delegate` — use subagent delegation for execution when the runtime supports it and safe scoping is possible.

`adaptive` — let the deterministic planner choose from the TaskProfile.

Strategy and routing are orthogonal.

## 1. Build only the semantic TaskProfile

Profile the task before broad execution:

```text
complexity: small | routine | complex | critical
uncertainty: low | medium | high
risk: low | medium | high | critical
scope: local | module | cross-module | repo-wide
parallelism: none | limited | high
write_conflict: low | high
exploration_need: low | medium | high
verification_cost: low | medium | high
iteration_intensity: one-shot | iterative | heavy-loop
writable_workstreams: positive integer
quality_intent: normal | strong | absolute
```

`writable_workstreams` counts already-proven isolated writable scopes/worktrees. Default to `1`; never invent extra writable streams merely to gain concurrency.

`quality_intent` is user intent, not risk. `strong` and `absolute` require explicit preference for correctness/quality over ordinary quota or latency.

Re-profile only when material evidence changes scope, risk, uncertainty, isolation, iteration intensity, or explicit quality intent.

## 2. Compile the authoritative plan

Invoke:

```bash
python3 ~/.codex/codex-flow/strategy_runtime.py \
  --policy ~/.codex/codex-flow.toml \
  plan \
  --complexity <...> \
  --uncertainty <...> \
  --risk <...> \
  --scope <...> \
  --parallelism <...> \
  --write-conflict <...> \
  --exploration-need <...> \
  --verification-cost <...> \
  --iteration-intensity <...> \
  --writable-workstreams <N> \
  --quality-intent normal|strong|absolute
```

Task-only overrides may append:

```text
--profile efficient|balanced|quality|speed
--routing adaptive|direct|delegate
--review auto|standard|strict
--fanout auto|conservative|aggressive
--efficient-reasoning legacy|shadow|adaptive
```

If the planner/registry is unavailable, treat that as an installation/runtime failure. Do not reconstruct its policy from this skill.

## 3. ExecutionPlan is the hard boundary

Current contract (schema v11):

```text
ExecutionPlan
  schema_version = 11
  strategy
  routing
  review_modifier
  fanout_modifier
  quality_intent
  parent_capability_policy
  parent_model_floor
  parent_reasoning
  reasoning_rollout | none
    mode
    legacy_worker_reasoning
    proposed_worker_reasoning
    selected_worker_reasoning
    applied
  explorer_capability_policy/model/reasoning | none
  implementer_capability_policy/model/reasoning | none
  reviewer_capability_policy/model/reasoning | none
  worker_budget
  task_budget | none
    soft_timeout_seconds
    hard_timeout_seconds
    max_work_units
    max_implementation_attempts
    max_replans
    max_replacements
    max_review_attempts
    parent_finalization_seconds
  exploration_workers
  implementation_workers
  reviewer_workers
  planned_worker_count
  exploration_stage | none
  implementation_stage | none
  review_stage | none
    join_policy
    min_successful_workers
    idle_timeout_seconds
    hard_timeout_seconds
    soft_timeout_seconds | none
    checkpoint_rearm_seconds | none
    max_worker_repair_attempts | none
    work_unit_mode
    minimum_work_units
    join_between_work_units
    maximum_work_units | none
    require_write_paths
    cancel_if_superseded
    cancel_stragglers_after_quorum
    fallback_policy
  review_mode
  max_repair_cycles
  max_concurrent_threads
  escalate_on_failure
  quota_pressure
  repo_policy | none
  context_mode
  notes
```

Direct plans emit `task_budget=null` and no delegated stages. Delegated built-in strategies emit one canonical `task_budget`; there is no second effective budget.

For delegated implementation:

```text
implementation_workers <= task_budget.max_work_units
implementation_workers <= task_budget.max_implementation_attempts
implementation_stage.maximum_work_units == task_budget.max_work_units
```

The compiler enforces these invariants. Do not locally raise topology or counters.

## 4. Canonical task budget and phase admission

Immediately after the **initial** delegated ExecutionPlan is compiled, persist that exact plan JSON as the task's initial budget plan and initialize through the phase helper:

```bash
python3 ~/.codex/codex-flow/strategies/task_phase_runtime.py init \
  --state-file <task-ledger-path> \
  --task-id <task-id> \
  --plan-json '<initial ExecutionPlan JSON>' \
  --now <unix-seconds>
```

The initial budget-plan identity is immutable for the task. A later semantic re-profile may compile another ExecutionPlan for current topology/lifecycle decisions, but it must not reset, replace, or extend the original task ledger. All phase status/reservation calls continue to pass the initial budget plan.

The canonical task timeline is:

```text
started_at
  |
  | general exploration / writable implementation
  v
soft_deadline == general_work_deadline
  |
  | required read-only review, when planned
  v
review_deadline == hard_deadline - parent_finalization_seconds
  |
  | Parent finalization only
  v
hard_deadline == absolute task execution stop
```

The compiler has already made `hard_timeout_seconds` large enough to contain any planned review-stage hard window plus `parent_finalization_seconds`; the phase helper validates this rather than deriving another budget.

Before exploration or implementation continuation:

```bash
python3 ~/.codex/codex-flow/strategies/task_phase_runtime.py status \
  --state-file <task-ledger-path> \
  --task-id <task-id> \
  --plan-json '<initial ExecutionPlan JSON>' \
  --phase exploration|implementation \
  --now <unix-seconds>
```

Before each logical unit, implementation attempt, replan, or implementation replacement:

```bash
python3 ~/.codex/codex-flow/strategies/task_phase_runtime.py reserve \
  --state-file <task-ledger-path> \
  --task-id <task-id> \
  --plan-json '<initial ExecutionPlan JSON>' \
  --phase implementation \
  --kind work_unit|implementation_attempt|replan|replacement \
  --reservation-id <stable-id> \
  --fingerprint <stable-fingerprint> \
  --now <unix-seconds>
```

At `soft_deadline`, genuinely new general-work reservations stop. Exact durable-ledger replay of an already-recorded general reservation remains idempotent and is not new work. Existing writable work must checkpoint/converge rather than silently opening another attempt.

If the plan has reviewers, required completion starts after general-work convergence. Query:

```bash
python3 ~/.codex/codex-flow/strategies/task_phase_runtime.py status \
  --state-file <task-ledger-path> \
  --task-id <task-id> \
  --plan-json '<initial ExecutionPlan JSON>' \
  --phase required_completion \
  --now <unix-seconds>
```

Before every reviewer Worker start or retry, reserve:

```bash
python3 ~/.codex/codex-flow/strategies/task_phase_runtime.py reserve \
  --state-file <task-ledger-path> \
  --task-id <task-id> \
  --plan-json '<initial ExecutionPlan JSON>' \
  --phase required_completion \
  --kind review_attempt \
  --reservation-id <stable-review-attempt-id> \
  --fingerprint <stable-review-fingerprint> \
  --now <unix-seconds>
```

`max_review_attempts` counts reviewer starts/retries independently of implementation replans/replacements.

The phase result is binding:

- `permits_general_work`: new exploration/writable implementation may start.
- `permits_review_start`: a new read-only reviewer may start.
- `permits_parent_finalization`: Parent may continue final reconciliation/verification before hard.
- `review_deadline`: no new reviewer starts at or after this boundary.
- `action=finalize_parent`: reviewer admission is closed; use the remaining tail only for Parent finalization. This is an admission transition, **not** evidence that required review succeeded.
- `action=stop`: task hard deadline/closed state reached; do not start new execution.

A soft deadline must never silently skip an independent/strict review already required by the initial plan. A reviewer must never consume the Parent finalization reserve. If `review_stage.join_policy` is required/quorum, successful delivery still requires at least `review_stage.min_successful_workers` accepted reviewer results. Reaching `review_deadline` without satisfying that join is fail-closed: do not silently downgrade to Parent-only review or report task success.

Before entering Parent-only finalization, every writable Worker must already be terminal/cancel-confirmed or safely fenced with its latest returned checkpoint harvested. The Parent finalization tail must not be consumed by unresolved writable execution.

The raw task-budget helper is the durable atomic ledger. The phase helper is the scheduling admission boundary. Neither schedules Workers by itself.

## 5. Worker lifecycle

Lifecycle comes from the relevant StagePolicy, not Parent heuristics. Track stable lineage:

```text
(scope_id, generation)
(scope_id, unit_id, generation) for bounded implementation
```

Replacement/replan increments generation. Checkpoint/continue does not.

Track when evidence exists:

- `last_progress_at`: liveness/tool/in-flight activity.
- `last_meaningful_progress_at`: acceptance-relevant delta, validation change, concrete blocker reduction, or bounded-scope completion.

Do not mark repeated unchanged reads/tests/heartbeats as meaningful progress.

`idle_timeout_seconds` is a renewable liveness lease. `soft_timeout_seconds` is an advisory checkpoint/convergence boundary. `hard_timeout_seconds` is the Worker wall-clock ceiling.

**A `wait()` timeout is never a Worker timeout.**

Use the deterministic evaluator:

```bash
python3 ~/.codex/codex-flow/strategies/lifecycle_runtime.py \
  --policy-json '<StagePolicy JSON>' \
  --scope-id <scope-id> \
  --stage exploration|implementation|review \
  --started-at <unix-seconds> \
  --last-progress-at <unix-seconds> \
  [--last-meaningful-progress-at <unix-seconds>] \
  [--checkpoint-sequence-json <json-array>] \
  [--generation <non-negative-int>] \
  --now <unix-seconds> \
  [--writable] [--in-flight] \
  [--terminal-success] [--terminal-failure] \
  [--scope-superseded] [--cancel-confirmed] \
  [--replacement-isolated]
```

Use returned `state`, `action`, `cancel_required`, `replacement_allowed`, `fence_required`, `progress_quality`, checkpoint fields, `replan_scope`, `checkpoint_reuse_mode`, and `fallback_policy` exactly.

### Checkpoints

Checkpoint sequence state is:

```text
not_requested -> requested -> received -> harvested
```

Soft-budget actions:

- `request_checkpoint`: ask the same Worker for a non-terminal checkpoint.
- `await_checkpoint`: do not spam another request.
- `harvest_checkpoint`: persist returned partial work before any destructive boundary.
- after a harvest, re-arm only when explicit acceptance-relevant progress occurred after the harvest and `checkpoint_rearm_seconds` elapsed.

Implementation checkpoint payload must carry enough evidence to continue safely:

```text
scope_id / unit_id when bounded
status
completed
changed_files/current_patch_state
validation
blockers
remaining_delta
workspace_state
```

Checkpoint is not completion. Never discard/reset/stash work merely to checkpoint.

**Harvest-before-fallback invariant:** a received but unharvested checkpoint outranks terminal failure, idle fallback, hard timeout, cancellation handling, and writer replacement. Harvest it first, then re-evaluate.

### Remaining-delta replan

Fallback always operates on the missing delta, never by restarting the whole stage.

For implementation `fallback_policy=replan`:

- `uncovered_scope`: replan only demonstrably uncovered scope.
- `checkpoint_remaining_delta`: use harvested `remaining_delta` plus completed/patch/validation/blocker evidence.
- `retained_workspace`: only after the old writer is terminal/cancelled.
- `harvested_snapshot_only`: isolated replacement consumes the immutable harvested snapshot and fences later old-worker output.

Completed accepted work is reopened only with concrete invalidating evidence.

Writable fallback still obeys cancellation/fencing. Never let a Parent writer or replacement Worker overlap a live old writer on the same scope.

### Read-only review retry

Review fallback is `retry_review`, not implementation `replan`.

`retry_review`:

- is valid only for review stage;
- is read-only;
- never produces implementation `replan_scope`;
- never opens writable scope or requires writer fencing;
- must consume a `review_attempt` reservation before the new reviewer starts;
- is forbidden once `review_deadline` is reached.

## 6. Exploration

Spawn at most `exploration_workers`, using planned role capability/model/reasoning when supported. Give each Explorer a distinct evidence question.

Do not kill a Luna `xhigh/max` Explorer merely because a short Parent wait returned no final output. Re-evaluate lifecycle from real progress evidence.

Respect join policy and `min_successful_workers`. Cancel stragglers only when the plan/evaluator permits it.

## 7. Evidence-based bounded implementation

When `implementation_stage.work_unit_mode=bounded`, Parent creates an explicit manifest before implementation spawn. Every unit contains:

```text
unit_id
scope_id
generation
acceptance_delta
write_scope_id
validation: non-empty list
write_paths: normalized repo-relative POSIX paths when required
depends_on
parallel_group: optional
```

Do not manufacture meaningless splits solely to satisfy a number. `minimum_work_units` remains the hard minimum; current built-in strategies keep it at `1`. `maximum_work_units` is a hard manifest bound, not a Worker count. Strategy semantic limits may be raised only by already-proven writable topology within the strategy's WorkerBudget; this permits serial waves without inventing extra workstreams.

Validate before spawn:

```bash
python3 ~/.codex/codex-flow/strategies/work_unit_runtime.py \
  --policy-json '<implementation_stage JSON>' \
  --manifest-json '<{"units":[...]}>' \
  --implementation-workers <ExecutionPlan implementation_workers> \
  --max-concurrent-threads <ExecutionPlan max_concurrent_threads>
```

Safety rules:

- same write scope is serial and dependency ordered;
- overlapping/ancestor-descendant `write_paths` require dependency ordering;
- a parallel group requires distinct non-overlapping write scopes/paths and no dependency path inside the group;
- a parallel group cannot exceed already-planned implementation/thread concurrency;
- work-unit partitioning never creates new writable workstreams;
- `write_paths` are lexical preflight evidence, not OS locks or symlink-safe ownership enforcement.

`implementation_workers` is concurrent topology, not total logical units. Reuse planned slots across serial waves. `join_between_work_units=true` returns control to Parent after each completed unit.

Do not send all bounded units to one Worker as a giant “complete everything” transaction.

## 8. Implementation handoff and local repair

Every implementation handoff should be bounded to its assigned scope/unit and contain:

- scope/unit/generation;
- acceptance delta;
- allowed write scope/paths;
- dependencies and prior harvested evidence;
- root-cause/design decision;
- constraints/non-goals;
- validation;
- `max_worker_repair_attempts` when present.

A Worker changes only its assigned unit and proves it with validation. For bounded mode it must return to Parent rather than beginning the next unit.

Local repair semantics:

- initial implementation + first validation = zero repairs;
- one repair = attributable validation failure -> corrective edit -> targeted revalidation;
- investigation without an edit does not consume an attempt;
- unrelated pre-existing failures do not count;
- on exhaustion, preserve patch/evidence and return the smallest remaining delta.

Local repair is separate from Parent `max_repair_cycles` and from lifecycle fallback.

## 9. Review and Parent finalization

Parent always reviews relevant diff, affected call sites, validation evidence, acceptance criteria, architecture consistency, and regression risk.

- `review_mode=parent`: no reviewer Worker.
- `review_mode=independent+parent`: spawn exactly the planned reviewer topology, subject to `review_attempt` reservations and the review window.

Review only a terminal workspace or immutable harvested snapshot, never concurrently mutating writable scope.

Multiple reviewers should receive complementary scopes. They are read-only and must not silently implement.

Track accepted reviewer completions against `review_stage.min_successful_workers`. `action=finalize_parent` only closes reviewer admission; it does not satisfy the review join. If the required/quorum reviewer join is still unsatisfied at `review_deadline`, preserve the available review evidence and fail/escalate rather than silently converting the plan to Parent-only success.

Once `action=finalize_parent`, do not start/retry reviewers. Use the remaining tail for Parent reconciliation and final verification. Enter that tail only after writable Workers are terminal/cancel-confirmed or safely fenced and all returned checkpoints have been harvested. At hard deadline, no new Worker or Parent writer starts; only already-collected evidence may be reported.

Direct mode still requires Parent self-review.

## 10. Parent repair and replan

Parent repair receives the smallest defect delta, not the original full task. Never exceed `max_repair_cycles`.

A repair requiring writes is general work and therefore cannot open after the task soft/general-work deadline.

Re-profile and compile a newer ExecutionPlan when material evidence changes task semantics, but continue using the original task ledger and initial budget plan for cumulative admission. A newer plan cannot reset counters or extend deadlines.

Worker stall/failure/checkpoint/replan does not itself consume Parent repair cycles.

## 11. Efficient reasoning rollout

Reasoning rollout is currently efficient-specific. Modes:

- `legacy`: select historical Worker effort.
- `shadow`: report proposal but select historical effort.
- `adaptive`: select proposal.

Proposal:

```text
max(rollout class target, rollout minimum, parent_reasoning)
```

The planner output is intent, not proof that the active runtime applied a per-spawn override. If runtime override is unsupported, use the installed baseline and report that limitation. Do not fabricate observed effort.

## 12. Quota and telemetry discipline

Quota is never guessed. Unavailable quota state is `unknown`.

Telemetry is observational. Never call a model solely to estimate tokens, quota, or duration.

For each Worker, record available deterministic lifecycle/latency evidence with stable IDs and no prompt/transcript/path payload. `observed_effort` must be runtime-confirmed; otherwise record null.

Telemetry failures are fail-open and must never block checkpoint harvest, cancellation/fencing, joining, or delivery.

Do not auto-tune policy from a handful of runs. Compare latency, completion, failures/censoring, and quota after a sufficiently homogeneous sample.

## 13. Concurrency discipline

`max_concurrent_threads` is a stage concurrency ceiling. WorkerBudget maxima are envelopes, not mandatory counts.

Parallel writable work requires already-proven isolated scopes/worktrees represented in `writable_workstreams`. Replan does not magically create another safe writer.

Prefer targeted search, compact context, diff-scoped review, narrow validation, and harvested evidence. Avoid duplicated agents, rereading unchanged files, and Parent reimplementation of Worker work.

## 14. Re-plan triggers

Re-profile when:

- complexity/risk materially changes;
- root cause is disproven;
- cross-module dependency appears;
- writable isolation changes;
- explicit quality intent changes;
- a required implementation stage returns `fallback_policy=replan`;
- Parent repair fails;
- reliable quota/runtime state materially changes.

Replan from evaluator-provided missing scope, never the original task by default. Completed accepted units remain evidence unless specifically invalidated.

## Runtime/version invariant

Persistent user policy remains schema v4. This FlowPilot runtime consumes ExecutionPlan schema v11 and task-ledger schema v2 for this feature set. These task-ledger semantics were not released with an older persisted-task format, so there is intentionally no grandfather/adoption path for incompatible task-ledger state: mismatched plan/policy/schema fails closed.

This does **not** relax ordinary persistent policy precedence or installer configuration preservation; it only means the new v11 task-execution contract has one canonical interpretation.