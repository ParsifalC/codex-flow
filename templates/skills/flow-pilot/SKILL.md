---
name: flow-pilot
description: Profile non-trivial technical work, compile a deterministic ExecutionPlan through the codex-flow strategy runtime, then execute parent/worker/review/repair and asynchronous worker lifecycle exactly from that plan while honoring current-task and repository policy.
---

# FlowPilot Strategy Runtime

FlowPilot is the semantic profiler and execution runtime for codex-flow. It is **not** a second strategy engine.

The invariant is:

> **FlowPilot profiles. `strategy_runtime.py` + the strategy registry decide. FlowPilot executes the returned plan.**

Do not independently re-implement strategy topology, capability selection, reasoning selection, quota policy, worker counts, review mode, fan-out, lifecycle/join policy, cancellation policy, fallback policy, local repair budget, task budget, or implementation work-unit policy in this skill. The installed planner and built-in strategy registry are the single source of truth for those decisions. Hard Worker lifecycle safety invariants are evaluated by the installed deterministic lifecycle helper; bounded implementation manifests are validated by the installed deterministic work-unit helper.

Default compatibility remains `strategy = efficient` plus `routing = adaptive`.

## 0. Policy precedence and current-task intent

### Global strategy master switch

Before TaskProfile construction or any automatic Worker delegation, read the installed global strategy state:

```bash
python3 ~/.codex/codex-flow/strategy_runtime.py \
  --policy ~/.codex/codex-flow.toml \
  show --json
```

If the returned `enabled` field is `true`, consume any armed one-shot bypass before TaskProfile construction:

```bash
python3 ~/.codex/codex-flow/strategy_runtime.py \
  --policy ~/.codex/codex-flow.toml \
  consume-bypass
```

If that command prints `true`, **stop FlowPilot strategy processing for this task only** and continue with ordinary Codex execution. The token is consumed atomically; concurrent tasks cannot both claim the same temporary bypass. The persistent global master switch remains enabled and the following task returns to normal strategy processing.

If `enabled=false`, stop FlowPilot strategy processing for this task:

- do not build a FlowPilot TaskProfile;
- do not compile an ExecutionPlan;
- do not apply codex-flow strategy, routing, modifier, WorkerBudget, lifecycle, repair, or role-capability decisions;
- do not automatically spawn/delegate Workers on behalf of FlowPilot;
- continue with ordinary Codex execution using the active Codex runtime/configuration.

The switch disables codex-flow automatic distribution, not Codex's native Agent capability. Explicit user requests to use native subagents outside FlowPilot may still be honored when appropriate.

`[strategy].enabled` is a global master gate. Repository policy and current-task overrides cannot re-enable it. Missing `enabled` in an older policy resolves to `true` for compatibility.

When enabled, planner precedence is:

```text
hard runtime / safety ceilings
  > explicit current-task overrides
  > repository .codex-flow.toml
  > ~/.codex/codex-flow.toml
  > codex-flow release defaults
```

Repository policy may choose strategy/routing/modifiers, tighten runtime ceilings, and raise reasoning floors. It must not silently lower user reasoning floors.

Persistent dimensions are independent:

- `[strategy].profile`: `efficient`, `balanced`, `quality`, `speed`;
- `[routing].mode`: `adaptive`, `direct`, `delegate`;
- `[modifiers].review`: `auto`, `standard`, `strict`;
- `[modifiers].fanout`: `auto`, `conservative`, `aggressive`.

Explicit current-task intent overrides those dimensions for that task only and must not mutate persistent policy.

Routing:

- `direct` — do not spawn or delegate to subagents for this task.
- `delegate` — use subagent delegation for execution when the runtime supports it and safe scoping is possible.
- `adaptive` — let the deterministic planner choose direct or delegated execution from the TaskProfile.

Strategies:

- `efficient`: minimize expensive Parent use and total waste while moving deep execution loops to efficient Workers;
- `balanced`: balance quality, quota, and wall-clock latency;
- `quality`: prioritize correctness, deeper verification, and higher-value capability where explicit quality intent warrants it;
- `speed`: minimize wall-clock latency by saturating proven-safe concurrency.

Strategy and routing are orthogonal. Modifiers do not create new strategy names.

## 1. Build only the semantic TaskProfile

Before broad execution classify:

```text
TaskProfile
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

`writable_workstreams` is the count of **already proven isolated, non-overlapping writable scopes/worktrees**. Default to `1`; never claim `2+` merely because parallel writes would be faster.

`quality_intent` is current-task intent, independent of technical risk:

- `normal`: ordinary expectations;
- `strong`: explicit quality/correctness preference over ordinary cost efficiency;
- `absolute`: explicit highest-practical-quality intent with materially higher cost/latency accepted.

Do not infer strong/absolute from generic wording such as “careful” or “good”. Do not convert quality intent into critical risk.

Guidance:

- `small`: obvious localized low-risk work;
- `routine`: clear implementation path and ordinary validation;
- `complex`: architecture/debugging/refactor/migration/cross-system uncertainty;
- `critical`: security, destructive/data-integrity, production-critical, or repeated-failure work;
- `parallelism=none`: no planner-created parallel Workers;
- `write_conflict=high`: writable work is not safe to fan out.

Re-profile only when material evidence changes risk, scope, uncertainty, parallelism, workstream isolation, iteration intensity, or explicit quality intent.

## 2. Compile the authoritative ExecutionPlan

Invoke the installed deterministic planner before broad execution:

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

For explicit current-task overrides append only requested dimensions:

```text
--profile efficient|balanced|quality|speed
--routing adaptive|direct|delegate
--review auto|standard|strict
--fanout auto|conservative|aggressive
--efficient-reasoning legacy|shadow|adaptive
```

The planner merges release/user/repository policy, loads the selected strategy, resolves WorkerBudget, computes topology, resolves StagePolicy and task budget, chooses per-role capability/reasoning, applies runtime ceilings and writable-isolation checks, reads reliable quota state when available, and emits one ExecutionPlan without extra LLM calls.

If planner/registry is unavailable, treat it as installation/runtime failure. Do not reconstruct strategy logic from this file.

## 3. ExecutionPlan is the hard strategy/runtime boundary

Current contract (schema v10):

```text
ExecutionPlan
  schema_version
  strategy
  routing
  review_modifier
  fanout_modifier
  quality_intent
  parent_capability_policy
  parent_model_floor
  parent_reasoning
  reasoning_rollout | none
    mode: legacy | shadow | adaptive
    legacy_worker_reasoning
    proposed_worker_reasoning
    selected_worker_reasoning
    applied
  explorer_capability_policy | none
  explorer_model | none
  explorer_reasoning | none
  implementer_capability_policy | none
  implementer_model | none
  implementer_reasoning | none
  reviewer_capability_policy | none
  reviewer_model | none
  reviewer_reasoning | none
  worker_budget
  task_budget | none
    soft_timeout_seconds
    hard_timeout_seconds
    max_work_units
    max_implementation_attempts
    max_replans
    max_replacements
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
    work_unit_mode: single | bounded
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

`implementation_stage.max_worker_repair_attempts` bounds local Implementer validation/fix loops and is independent from top-level Parent `max_repair_cycles`.

`implementation_stage.work_unit_mode=bounded` is binding. `minimum_work_units` is the minimum number of logical acceptance-bounded implementation transactions and may be 1. Default to one unit; split only when every split has an independent acceptance delta, validation boundary, and ownership/dependency evidence. `maximum_work_units`, when present, is a hard manifest count bound and must be at least the minimum. `join_between_work_units=true` means control must return to Parent after each completed unit before a dependent next unit begins. These fields do **not** authorize extra writable concurrency. `require_write_paths=true` opts a new bounded policy into generation and normalized repository-relative `write_paths` validation.

### Task-level cumulative budget

`task_budget` is a strategy-owned cumulative contract for delegated built-in strategy work. It is separate from `StagePolicy`: stage fields describe one Worker stage, while task reservations live in a durable ledger and are never reset by a replan or a new process. Direct plans emit `task_budget=null`.

Current built-in policy envelopes are strategy-specific:

```text
strategy    task soft/hard        work units      implementation attempts   replans/replacements
efficient   1500 / 1800           1..3            units + 1                 1 / 1
speed       1200 / 1800           1..4            units + 1                 1 / 1
balanced    2400..3000 / 3000..3600 1..3          units + 2                 2 / 2
quality     4800..6000 / 6000..7200 1..4          units + 3                 3 / 3
```

The exact values come only from the current immutable ExecutionPlan. Never infer them from the strategy name and never substitute efficient's numbers for another strategy. When both are present, `task_budget.max_work_units` must equal `implementation_stage.maximum_work_units`.

Immediately after the first plan is compiled, initialize `task_budget_runtime.py` with the plan's exact `task_budget`, task id, and runtime-owned state path. Before any Worker spawn, query `status`; exploration/review Workers consume wall time but do not consume implementation counters. Before each logical work-unit start, implementation Worker attempt, replan, or replacement, reserve the corresponding kind (`work_unit`, `implementation_attempt`, `replan`, or `replacement`). After every join or wait, query `status`; at task completion, call `finish`. A replan reuses the original ledger/state path and remaining counters, never a fresh budget.

For a bounded manifest, reserve `work_unit` with the validator's stable `logical_unit_fingerprints[unit_id]`, which excludes generation. Reserve `implementation_attempt` with the generation-aware `unit_fingerprints[unit_id]` and an identity derived from `(scope_id, unit_id, generation)`. A replacement therefore consumes a new implementation attempt/replacement reservation without double-counting the same logical work unit; changing acceptance/scope/path/validation under the same logical unit still fails closed.

At the plan's `task_budget.soft_timeout_seconds` deadline, do not open new work or create reservations; ask existing Workers to checkpoint/converge and harvest their evidence. At the plan's `task_budget.hard_timeout_seconds` deadline, first harvest any received checkpoint, then apply lifecycle fencing and cancel active writers. Do not start a replacement Worker or Parent writer after hard stop. An implementation handoff must carry the task-budget state path and current remaining seconds/counters.

The task-budget helper is a ledger/decision boundary, not an automatic scheduler: it does not spawn, checkpoint, cancel, fence, or replace Workers. FlowPilot/runtime performs those actions from its result. The lifecycle helper likewise reports requirements; actual cancellation and scheduling remain runtime responsibilities.

### Efficient reasoning rollout

The optional `[reasoning.rollout]` policy applies only when the compiled plan is
`strategy=efficient` and `routing=delegate` with delegated Worker roles. Its
release defaults are:

```text
mode=shadow
minimum=high, routine=high, complex=xhigh, critical=max
```

`legacy` is the kill switch: the current Worker reasoning selection remains
unchanged. `shadow` also selects the legacy effort, while exposing a proposed
effort in `ExecutionPlan.reasoning_rollout`. `adaptive` selects that proposal.
The proposal is computed after the existing legacy selection as:

```text
max(rollout class target, rollout minimum, parent_reasoning)
```

The selected effort is written consistently to every planned
`explorer_reasoning`, `implementer_reasoning`, and `reviewer_reasoning` field;
direct plans and non-efficient strategies emit `reasoning_rollout=null` and
retain their existing behavior. Adaptive explicitly permits the selected
Worker effort to equal Parent at the `max` ceiling.

User rollout floors are persistent optional policy. Repository policy may raise
the rollout minimum/class floors, but cannot change a user's `legacy` or
`shadow` mode to `adaptive`. `--efficient-reasoning legacy|shadow|adaptive` is
a current-task override and does not mutate policy.

The decision is intent, not an observation: `proposed_worker_reasoning` and
`selected_worker_reasoning` do not prove what the runtime actually applied. If
the active Codex build cannot apply a per-spawn effort override, use the
installed Worker baseline and report that limitation; later telemetry may
record the observed effective effort. This helper does not schedule Workers or
collect telemetry.

Once compiled, execute the plan. Prohibited duplication includes:

- adding Workers/reviewers beyond planner topology because a strategy name suggests it;
- changing role model/reasoning locally;
- treating WorkerBudget maxima as mandatory counts;
- inventing lifecycle timeout/retry/cancellation rules;
- terminating a non-terminal Worker because `wait()` returned without a final result;
- expanding local Worker repair attempts or Parent repair cycles beyond the plan;
- collapsing a plan with multiple evidenced bounded units back into one giant implementation transaction;
- converting bounded logical units into parallel writers unless the existing plan already proves distinct writable workstreams;
- replacing `direct` with delegation because delegation seems useful.

If requested per-spawn model/capability override is unsupported, use installed baseline, preserve topology/lifecycle/work-unit/repair semantics, and report the limitation.

## 4. Parent owns semantic decisions

Parent owns root cause/architecture, scope/non-goals, compatibility constraints, implementation sequence, risks, acceptance criteria, TaskProfile construction, and bounded-unit partitioning when required by the plan.

Parent should spend reasoning on high-value semantic decisions rather than duplicating Worker loops. Delegated Workers intentionally run with deeper reasoning than Parent by default because the efficient Worker model is cheaper. Parent=max is the top-tier exception where Worker cannot exceed max.

Capability and reasoning are independent. `Luna max` is not automatically Parent-class capability.

## 5. Async Worker lifecycle and progress tracking

Lifecycle comes from ExecutionPlan, not Parent heuristics. Every Worker gets a stable bounded lineage before spawn: `(scope_id, unit_id, generation)` for bounded implementation units, or `(scope_id, generation)` for legacy/single work. A replacement Worker or replan increments `generation`; checkpoint/continue of the same unit does not. Parent accepts result evidence only for the current generation.

Semantic states:

```text
queued
running
progressing
completed
stalled
failed
superseded
cancelled
```

Track independently when reliable evidence exists:

- `last_progress_at`: liveness activity; tool/command/search/file-read/in-flight activity may renew it;
- `last_meaningful_progress_at`: acceptance-relevant delta; advance only for new evidence, code/output change, validation-state change, bounded-scope completion, or a concrete blocker narrowing remaining work.

Do not advance meaningful progress for repeated unchanged search/read/test loops or heartbeat chatter.

Meaningful-progress quality is observational and non-destructive. `activity_only` does not authorize cancellation. Existing liveness lease and hard ceiling remain safety boundaries.

`idle_timeout_seconds` is a renewable liveness lease. `soft_timeout_seconds` is an advisory checkpoint/convergence budget. `hard_timeout_seconds` is the absolute Worker wall-clock ceiling.

The lifecycle helper is a deterministic evaluator, not a durable scheduler or checkpoint store. The separate task-budget helper is the durable cross-process ledger for task-level reservations. Both helpers report decisions/requirements; the runtime must enforce cancellation, checkpoint harvest, writer fencing, and Worker scheduling.

**A `wait()` timeout is never a Worker timeout.** Repeated Parent waits without terminal output do not by themselves justify stalled/failed/cancelled.

If intermediate activity is unreliable, do not guess. Omit `--last-meaningful-progress-at`; legacy behavior may treat `last_progress_at` as meaningful for progress classification and the first soft checkpoint, but it never uses that fallback to re-arm a harvested multi-round checkpoint.

### Deterministic lifecycle evaluator

Use Unix seconds and invoke:

```bash
python3 ~/.codex/codex-flow/strategies/lifecycle_runtime.py \
  --policy-json '<relevant StagePolicy JSON>' \
  --scope-id <scope-id> \
  --stage exploration|implementation|review \
  --started-at <unix-seconds> \
  --last-progress-at <unix-seconds> \
  [--last-meaningful-progress-at <unix-seconds>] \
  [--checkpoint-requested-at <unix-seconds>] \
  [--checkpoint-received-at <unix-seconds>] \
  [--checkpoint-harvested-at <unix-seconds>] \
  [--generation <non-negative-int>] \
  [--checkpoint-sequence-json <json-array>] \
  --now <unix-seconds> \
  [--writable] [--in-flight] \
  [--terminal-success] [--terminal-failure] \
  [--scope-superseded] [--cancel-confirmed] \
  [--replacement-isolated]
```

Use returned `state`, `action`, `cancel_required`, `replacement_allowed`, `fence_required`, `progress_quality`, `meaningful_idle_seconds`, `checkpoint_status`, `replan_scope`, `checkpoint_reuse_mode`, and `fallback_policy` exactly.

The legacy checkpoint flags remain supported and normalize to sequence 1. Do not mix them with `--checkpoint-sequence-json`; sequence records must be contiguous within the current generation, and only the latest may be unharvested. Replacement/replan starts generation+1 with sequence reset. Decisions also expose `checkpoint_generation`, latest `checkpoint_sequence` (0 when absent), `harvested_checkpoint_sequence` (0 when absent), and `next_checkpoint_sequence` only for `request_checkpoint`, plus `checkpoint_rearm_at` and `checkpoint_rearm_remaining_seconds` when a policy cooldown is configured.

Checkpoint state is monotonic within each sequence; globally `checkpoint_status` reports the latest sequence, so a new sequence transitions from the prior harvested state back to requested:

```text
not_requested -> requested -> received -> harvested
```

Record timestamps only after real events.

Soft-budget actions:

- `request_checkpoint`: ask the existing Worker for a non-terminal checkpoint; do not cancel or add a writer;
- `await_checkpoint`: request is already outstanding; do not spam;
- `harvest_checkpoint`: preserve returned payload before anything that could discard partial work;
- `continue` with harvested checkpoint: existing Worker continues its assigned scope/unit until completion or a real lifecycle boundary;
- after a harvest, request the next sequence only when the Worker explicitly reports `last_meaningful_progress_at` later than the latest harvest, `checkpoint_rearm_seconds` has elapsed, and the soft budget is reached; `last_progress_at` activity alone never re-arms it. Without the explicit timestamp or cooldown policy, continue as a one-shot/legacy plan without repeating the request.

Implementation checkpoint payload must include:

```text
scope_id / unit_id when bounded
status: progressing | blocked | ready
completed
changed_files/current_patch_state
validation
blockers
remaining_delta
workspace_state
```

Checkpoint is not completion. Never reset/revert/clean/stash/discard work merely to checkpoint. If required fields are missing, request correction from the same Worker; do not fabricate empty remaining delta.

**Harvest-before-fallback invariant:** a returned but unharvested checkpoint outranks terminal failure, idle fallback, hard timeout, cancellation handling, and writer replacement. Preserve it first, then re-evaluate lifecycle with the real harvested timestamp.

This precedence also applies when the Worker reports terminal success in the same observation: `checkpoint_status=received` must return `harvest_checkpoint` before `consume_result`. A requested checkpoint without a returned payload does not postpone hard/idle fallback.

### Remaining-delta replan

Fallback always operates on the missing delta, never by restarting the whole stage:

When `fallback_policy=replan`, obey evaluator `replan_scope`:

- `uncovered_scope`: replan only demonstrably uncovered scope, never automatically the full original task;
- `checkpoint_remaining_delta`: build the replacement handoff from harvested `remaining_delta` only; carry completed work, patch state, prior validation, and blockers as evidence.

For checkpoint-based replan, `checkpoint_reuse_mode` is binding:

- `retained_workspace`: after old writer terminal/cancelled, preserve current workspace/patch;
- `harvested_snapshot_only`: isolated replacement uses only immutable harvested snapshot; fence all later old-Worker output.

Move completed checkpoint work back into remaining delta only with concrete new invalidating evidence and record the reason.

If `cancel_required=true`, old non-terminal Worker still requires cancellation even if an isolated fallback may proceed safely.

### Hard writable writer fence

A downstream writer may enter an old writable scope only after either:

1. old writer is confirmed terminal/cancelled/failed; or
2. downstream writer uses a fresh isolated worktree and old output is fenced from integration.

This applies to both Parent `parent_delta` and replacement `replan`. Never let recovered old Worker and downstream writer modify the same live scope concurrently.

Parent execution is fork/join, not fork/block: spawn planned Workers, continue non-overlapping Parent work, consume results opportunistically, join only at real dependencies, and never redo a whole Worker scope because it is merely slow.

## 6. Execute exploration exactly from the plan

If `exploration_workers=0`, Parent performs targeted discovery and `exploration_stage` is none.

Otherwise delegate exactly the planned count to distinct bounded read-only questions, each with a unique `scope_id`. Respect `max_concurrent_threads` and role capability/model/reasoning. Do not collapse multiple planned explorers merely out of habit.

Execute exploration join/cancellation/fallback only from `exploration_stage`. In particular, do not kill a Luna `xhigh/max` Explorer merely because it has taken multiple Parent wait intervals while continuing to read files, run commands, or produce other observable progress.

## 7. Partition bounded implementation before spawning

If `implementation_stage.work_unit_mode=single`, keep historical behavior: one assigned implementation scope/transaction per planned implementer slot.

If `work_unit_mode=bounded`, Parent must create an explicit implementation unit manifest **before spawning implementation work**. It must contain at least `minimum_work_units` logical units. Each unit owns exactly one acceptance delta and must include:

```text
unit_id
scope_id
generation
acceptance_delta
write_scope_id
validation: non-empty list
write_paths: normalized repo-relative POSIX paths when required by the plan
depends_on: unit ids, when ordered
parallel_group: optional
```

Partition by acceptance boundary, module/file ownership, dependency order, or validation boundary. Do not manufacture meaningless splits solely to satisfy a number; each unit must represent independently describable progress that can be harvested and resumed. A typical same-scope split may be “core implementation” -> “dependent integration/regression completion”.

Validate the manifest deterministically before spawn. Copy `implementation_workers` and `max_concurrent_threads` verbatim from the same immutable ExecutionPlan; never raise either value locally:

```bash
python3 ~/.codex/codex-flow/strategies/work_unit_runtime.py \
  --policy-json '<implementation_stage JSON>' \
  --manifest-json '<{"units":[...]}>' \
  --implementation-workers <ExecutionPlan implementation_workers> \
  --max-concurrent-threads <ExecutionPlan max_concurrent_threads>
```

Use the helper result as the gate. If validation fails, fix the manifest; do not bypass the work-unit contract. The helper caps a parallel wave at `min(implementation_workers, max_concurrent_threads)` and rejects direct or transitive dependency-linked units in the same wave.

Safety rules enforced by the manifest/runtime contract:

- same `write_scope_id` units are sequential and each later unit must depend on the previous same-scope unit;
- same or ancestor/descendant `write_paths` across units require a direct or transitive dependency;
- `parallel_group` may contain only isolated distinct `write_scope_id`s with no direct or transitive dependency path inside that group;
- every unit in a `parallel_group` must provide non-empty, normalized `write_paths`, and paths in that group must be completely non-overlapping;
- path checks reject absolute, traversal, glob, backslash, NUL, and Windows drive/UNC forms;
- `maximum_work_units`, when present, bounds total manifest units;
- a parallel group cannot exceed the already-resolved implementation/thread concurrency from ExecutionPlan;
- bounded mode cannot collapse to fewer than `minimum_work_units`;
- work-unit partitioning never creates new `writable_workstreams`; existing ExecutionPlan isolation is still authoritative.

`write_paths` are static lexical preflight evidence only. They are not an OS lock, do not resolve symlinks, and do not provide durable scheduler enforcement. Parent still owns real writable-scope fencing and must persist/compare the current `(scope_id, unit_id, generation)` lineage when accepting results.

`implementation_workers` is the maximum concurrent implementer topology for a wave, **not permission to run every logical unit concurrently**. When only one writable workstream is proven, execute bounded units serially even if there are multiple units. When the plan already authorizes isolated parallel implementation workers, independent units may share a validated `parallel_group` up to the existing concurrency ceiling.

Logical work-unit boundaries do not enlarge WorkerBudget. Reuse the same planned implementer slot/thread for subsequent serial units when the runtime supports continued agent input. If a fresh Worker identity is required for a later unit, it replaces a terminal prior slot sequentially; never exceed `implementation_workers`, `max_concurrent_threads`, or the strategy's speculative WorkerBudget envelope merely because there are more logical units than concurrent implementer slots.

`join_between_work_units=true` means every completed unit returns control to Parent. Parent harvests the unit result/workspace state, verifies its unit acceptance delta, then decides whether the next dependent unit may start. This is a normal execution boundary, not cancellation and not a reason to discard the workspace.

Do not send all bounded units to one Worker in a single “complete everything” handoff. That recreates the long transaction this policy is designed to avoid.

## 8. Compact implementation handoff

Every implementation handoff includes only:

- `scope_id` / isolated writable scope;
- one `unit_id` and `acceptance_delta` when bounded;
- current `generation` for that unit;
- allowed `write_scope_id`;
- normalized `write_paths` when required by the plan;
- dependencies and harvested prior-unit evidence;
- root cause/design decision;
- relevant files/components;
- unit-local steps;
- constraints/non-goals;
- unit-local acceptance criteria;
- required validation;
- `implementation_stage.max_worker_repair_attempts` when present.

For `checkpoint_remaining_delta`, replace full-scope handoff with the same `scope_id`/`unit_id` lineage and unchanged generation, `replan_scope`, `checkpoint_reuse_mode`, harvested completed/validation/patch baseline, and **only** harvested remaining delta. A replacement Worker or replan superseding a prior attempt uses generation+1; checkpoint/continue does not increment. Parent accepts only current-generation evidence. Never paste the original complete task as a second goal.

Prefer fresh/no-history child context when supported.

If planned multiple implementation workers no longer have proven isolated writable workstreams, re-profile and recompile instead of silently changing topology.

Prefer `worker-implementer`; apply planned capability/model/reasoning when supported. If not supported, use installed baseline and report the limitation.

Implementation normally uses required lifecycle. Do not cancel a progressing writer merely so Parent can recreate its patch. On failure/stall follow deterministic lifecycle and writer fencing.

When lifecycle says `request_checkpoint`, send it to the same Worker. When payload returns, preserve it and record real timestamps; do not mark completion just because it checkpointed.

## 9. Worker implements and proves one unit

Worker changes only assigned scope/unit, runs narrow validation first, fixes failures caused by the patch within local budget, and returns:

- scope id / unit id;
- acceptance delta satisfied;
- changed files;
- concise implementation summary;
- validation commands/results;
- local repair attempts used/budget;
- deviations;
- unresolved risks/failures;
- retained workspace state.

For bounded mode Worker must not begin the next unit. Unit completion is a Parent join point.

`max_worker_repair_attempts` semantics:

- initial implementation + first validation is not a repair attempt;
- one attempt = attributable validation failure -> corrective edit pass -> targeted revalidation;
- investigation without corrective edit does not count;
- unrelated pre-existing failures do not count;
- when exhausted, preserve patch, report failing validation/blocker/smallest remaining delta, and return control to Parent.

Budget exhaustion is controlled handoff, not lifecycle timeout. Do not cancel/discard patch or count it as lifecycle failure.

If local repair field is absent in an older plan, do not retroactively impose a cap.

Evidence beats verbose logs.

## 10. Review exactly according to the plan

Parent always reviews relevant diff, affected call sites, validation evidence, acceptance criteria, architecture consistency, and regression risk.

- `review_mode=parent`: no reviewer Workers;
- `review_mode=independent+parent`: spawn exactly `reviewer_workers` bounded independent reviewers, execute `review_stage`, then Parent final verification.

Multiple reviewers get complementary scopes, not duplicated prompts. Reviewers are read-only and must not silently implement.

Do not terminate progressing reviewers merely because Parent completed unrelated work or waits returned. Execute review lifecycle exactly from plan.

Direct mode still requires Parent self-review.

## 11. Parent repair from bounded deltas

On implementation defect returned to Parent, send the smallest repair delta: exact defect, impact, correction, relevant symbol/file, and validation.

Never exceed top-level `max_repair_cycles`. These cycles begin only after Implementer returned control and are separate from local Worker repair attempts.

If repair fails or evidence materially changes the task, update TaskProfile and compile a new ExecutionPlan. Do not mutate old plan ad hoc.

Worker stall/failure/supersession, checkpoint handling, timeout fallback, unit joins, and remaining-delta replan do not themselves consume Parent repair cycles.

## 12. Quota and telemetry discipline

Quota is never guessed. Planner reads app-server rate-limit state when available; unavailable state is `unknown`.

Telemetry is observational and deterministic. Never call a model solely to estimate tokens/quota/duration or produce a usage summary.

For every Worker spawn, retain its Unix-second start time and the plan's strategy, task class, stage/role/model, rollout mode, and legacy/proposed/selected effort. On each received checkpoint and once at terminal state, invoke the installed telemetry CLI's `latency record` path with a stable event ID, task/Worker/work-unit IDs, the boundary time, repair/checkpoint counters, and terminal outcome where applicable. The helper hashes identifiers with a local salt and rejects free-form payload fields; never send prompt, transcript, conclusion, tool arguments/output, cwd, or paths. A checkpoint has `boundary=checkpoint` and no outcome. A terminal observation has `boundary=terminal` and `outcome=completed|failed|cancelled|timeout`.

`observed_effort` means effort confirmed by the runtime for that exact spawn. If the runtime does not expose it, record null; never copy `selected_worker_reasoning` into observed merely because it was requested. Telemetry is fail-open: a collection failure is reported concisely but must not block checkpoint harvest, fencing, cancellation, join, or delivery.

`telemetry latency report` uses deterministic nearest-rank p50/p95 over uncensored terminal observations and separately reports completed, success, censored, missing, and checkpoint counts. Treat `eligible_for_tuning=true` only as permission to evaluate a homogeneous group after at least 20 uncensored samples with confirmed observed effort. It is not permission to mutate policy automatically. Compare latency with success/censoring before moving `shadow` to `adaptive`, and keep `legacy` as the rollback switch.

Quota pressure may constrain speculative fan-out and Parent repair budget for quota-sensitive strategies, but must not silently lower configured reasoning/quality floors. Safety ceilings remain authoritative.

Lifecycle/work-unit policy is deterministic. Do not invent historical latency predictions outside explicit runtime logic.

## 13. Context and concurrency discipline

Prefer targeted search, concise excerpts, diff-scoped review, and small validation output. Avoid full-repo dumps, duplicate agents, rereading unchanged files, Parent reimplementation of Worker work, or cancelling useful work only to recreate it.

`max_concurrent_threads` is a per-stage concurrency ceiling. `implementation_workers` is concurrent implementation topology. Bounded `minimum_work_units` is a logical transaction count and may therefore be executed across multiple serial waves; it does not itself increase writable concurrency.

Parallel writable work requires isolated non-overlapping scopes/worktrees already represented by `writable_workstreams`. A downstream fallback writer is not a new proven workstream merely because replan occurred.

## 14. Re-plan checkpoints

Re-profile and invoke planner again when:

- complexity/risk materially changes;
- explicit quality intent materially changes;
- root cause is disproven;
- cross-module dependency appears;
- writable isolation changes;
- required stage chooses `fallback_policy=replan`;
- Parent repair cycles fail;
- reliable quota/runtime state materially changes.

Replan from evaluator-provided scope, never original task by default. For `checkpoint_remaining_delta`, harvested checkpoint is authoritative boundary. For `uncovered_scope`, derive smallest still-uncovered scope. A new plan never overrides old writable-worker fencing.

Completed bounded units remain prior evidence across replan unless concrete new evidence invalidates them. Do not restart already accepted units merely because a later unit failed.

## Compatibility invariant

For schema-v3 users with no strategy/routing fields:

```text
strategy = efficient
routing = adaptive
review = auto
fanout = auto
quality_intent = normal
```

Persistent policy remains schema v4. ExecutionPlan schema v10 adds optional task-level cumulative budget and reasoning-rollout decision fields alongside StagePolicy convergence/repair/work-unit/checkpoint-rearm fields. Older plans without `task_budget`, `reasoning_rollout`, `soft_timeout_seconds`, meaningful-progress/checkpoint state, `checkpoint_rearm_seconds`, `max_worker_repair_attempts`, or work-unit fields retain historical behavior for that run. In particular, missing checkpoint-rearm policy is safe one-shot behavior and absent task-budget/work-unit/rollout fields resolve to the legacy path; updates must not retroactively split, cancel, change reasoning, or reset already-running Workers.
