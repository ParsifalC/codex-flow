---
name: flow-pilot
description: Profile non-trivial technical work, compile a deterministic ExecutionPlan through the codex-flow strategy runtime, then execute parent/worker/review/repair and asynchronous worker lifecycle exactly from that plan while honoring current-task and repository policy.
---

# FlowPilot Strategy Runtime

FlowPilot is the semantic profiler and execution runtime for codex-flow. It is **not** a second strategy engine.

The invariant is:

> **FlowPilot profiles. `strategy_runtime.py` + the strategy registry decide. FlowPilot executes the returned plan.**

Do not independently re-implement strategy topology, capability selection, reasoning selection, quota policy, worker counts, review mode, fan-out, lifecycle/join policy, cancellation policy, fallback policy, or repair budget in this skill. The installed planner and built-in strategy registry are the single source of truth for those decisions. Hard Worker lifecycle safety invariants are evaluated by the installed deterministic lifecycle helper rather than improvised by Parent.

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

If that command prints `true`, **stop FlowPilot strategy processing for this task only** and continue with ordinary Codex execution. The token is consumed atomically, so concurrent tasks cannot both claim the same temporary bypass. The persistent global master switch remains enabled and the following task returns to normal strategy processing.

If the returned `enabled` field is `false`, **stop FlowPilot strategy processing for this task**:

- do not build a FlowPilot TaskProfile;
- do not compile an ExecutionPlan;
- do not apply codex-flow strategy, routing, modifier, WorkerBudget, lifecycle, repair, or role-capability decisions;
- do not automatically spawn/delegate Workers on behalf of FlowPilot;
- continue with ordinary Codex execution using the active Codex runtime/configuration.

The switch disables codex-flow automatic distribution, not Codex's native Agent capability. If the user explicitly asks to use native subagents outside FlowPilot, that explicit request may still be honored when appropriate.

`[strategy].enabled` is a **global master gate**. Repository policy and current-task strategy/routing/modifier overrides cannot re-enable it. Existing profile/routing/modifier values remain stored while disabled and become effective again after the user re-enables the switch.

Missing `enabled` in an older policy is backward-compatible and resolves to `true`.

When the switch is enabled, normal planner precedence applies:

The planner resolves policy in this order, from strongest to weakest:

```text
hard runtime / safety ceilings
  > explicit current-task overrides
  > repository .codex-flow.toml
  > ~/.codex/codex-flow.toml
  > codex-flow release defaults
```

Repository policy is discovered automatically from the current working directory up to the repository root. It may choose strategy/routing/modifiers, tighten runtime ceilings, and raise reasoning floors. It must not silently lower user reasoning floors.

Persistent strategy and routing are independent:

- `[strategy].profile`: `efficient`, `balanced`, `quality`, or `speed`.
- `[routing].mode`: `adaptive`, `direct`, or `delegate`.

Composable modifiers are also independent:

- `[modifiers].review`: `auto`, `standard`, or `strict`.
- `[modifiers].fanout`: `auto`, `conservative`, or `aggressive`.

Explicit current-task user intent overrides repository/global strategy, routing, and modifiers for this task only. It must not mutate persistent policy.

Routing overrides:

- `direct` — do not spawn or delegate to subagents for this task.
- `delegate` — use subagent delegation for execution when the runtime supports it and safe scoping is possible.
- `adaptive` — let the deterministic planner choose direct or delegated execution from the TaskProfile.

Strategy overrides:

- `efficient` — minimize expensive Parent use and total waste while moving deep execution loops to efficient Workers.
- `balanced` — balance quality, quota consumption, and wall-clock latency with moderate safe worker fan-out.
- `quality` — prioritize correctness through deeper Worker reasoning, wider exploration, independent verification, and role-scoped Parent-class capability when explicit quality intent warrants it.
- `speed` — minimize wall-clock latency by saturating proven-safe Worker concurrency.

Modifier overrides may be expressed explicitly, for example “strict review”, “standard review”, “conservative fan-out”, or “aggressive fan-out”. Do not infer them from incidental wording.

**Strategy and routing are orthogonal.** `quality + direct` and `efficient + delegate` are both valid. Modifiers do not create new strategy names.

## 1. Build only the semantic TaskProfile

Before broad execution, classify the task into this contract:

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

`writable_workstreams` means the number of **already identified, isolated, non-overlapping writable scopes/worktrees**. Default it to `1`. Never claim `2+` merely because parallel writes would be faster.

`quality_intent` is current-task semantic intent, not persistent policy and not a synonym for technical risk. Default it to `normal`.

- `normal`: ordinary quality expectations; do not infer a premium-model preference merely because the task is non-trivial.
- `strong`: the user explicitly prioritizes quality/correctness over ordinary cost efficiency, such as “quality first”, “use stronger models”, “prefer reliability over cost”, or equivalent clear intent.
- `absolute`: the user explicitly asks for the highest practical quality and accepts materially higher cost/latency, such as “highest quality”, “cost does not matter”, “use the strongest available models and verification”, or equivalent unambiguous intent.

Do not convert strong quality wording into `risk=critical`. Technical risk and user optimization intent are independent dimensions. Do not infer `strong` or `absolute` from generic words such as “careful”, “good”, or “review this”.

Guidance:

- `small`: obvious localized work with low uncertainty/risk.
- `routine`: clear implementation path and ordinary validation.
- `complex`: architecture/debugging/refactor/migration/cross-system uncertainty.
- `critical`: security, destructive/data-integrity, production-critical risk, or repeated failure where correctness dominates cost.
- `parallelism=none`: no planner-created parallel workers, including explorers.
- `write_conflict=high`: writable work is not safe to fan out.

Do not generate profiling prose unless useful. The profile exists to feed the planner.

Re-profile only when material evidence changes risk, scope, uncertainty, parallelism, workstream isolation, iteration intensity, or explicit quality intent.

## 2. Compile the authoritative ExecutionPlan

After TaskProfile construction, invoke the installed deterministic planner before broad execution:

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

The planner automatically discovers repository policy and reliable quota state. For explicit current-task overrides, append only the requested dimensions:

```text
--profile efficient|balanced|quality|speed
--routing adaptive|direct|delegate
--review auto|standard|strict
--fanout auto|conservative|aggressive
```

The planner automatically:

- merges release, user, and repository policy with the defined precedence;
- loads the selected built-in strategy from the installed strategy registry;
- resolves a strategy-specific `worker_budget` envelope;
- computes workstream-aware explorer / implementer / reviewer counts inside that budget;
- resolves strategy-owned StagePolicy for exploration / implementation / review;
- gives delegated Worker roles at least one higher reasoning tier than Parent when the effort ladder permits it;
- lets only the selected strategy consume strategy-specific TaskProfile semantics such as `quality_intent`;
- lets `quality` promote high-value Implementer/Reviewer capability for strong/absolute intent while ordinary Explorers remain efficient-worker-first unless technical risk itself is critical;
- applies hard runtime thread/repair/lifecycle ceilings and writable-isolation checks;
- reads reliable app-server quota state when available and normalizes it before strategy logic;
- emits one ExecutionPlan without extra LLM calls.

If the helper or strategy registry is unavailable, treat that as an installation/runtime failure. Do **not** silently recreate the strategy logic from this document; use the conservative installed Codex baseline and tell the user the strategy planner is unavailable.

## 3. ExecutionPlan is the hard strategy/runtime boundary

Current contract (schema v8):

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
    max_explorers
    max_implementers
    max_reviewers
    max_total_workers
    speculation
  exploration_workers
  implementation_workers
  reviewer_workers
  planned_worker_count
  exploration_stage | none
  implementation_stage | none
  review_stage | none
    join_policy: opportunistic | quorum | required
    min_successful_workers
    idle_timeout_seconds
    hard_timeout_seconds
    cancel_if_superseded
    cancel_stragglers_after_quorum
    fallback_policy: continue_partial | parent_delta | replan | fail
  review_mode
  max_repair_cycles
  max_concurrent_threads
  escalate_on_failure
  quota_pressure
  repo_policy | none
  context_mode
  notes
```

Once compiled, execute this plan. Do not reinterpret the strategy name or `quality_intent` to change topology, resource selection, or lifecycle behavior.

Examples of prohibited duplication:

- do not add explorers beyond `exploration_workers` because the strategy is `quality`;
- do not upgrade a model locally because `quality_intent=strong`; per-role capability is already encoded in the plan;
- do not increase implementers beyond `implementation_workers` because the strategy is `speed`;
- do not spawn extra reviewers beyond `reviewer_workers`;
- do not treat `worker_budget` maxima as mandatory worker counts; the planner has already converted the budget into concrete counts;
- do not independently change review rigor from a modifier or strategy name after compilation;
- do not lower or raise parent/explorer/implementer/reviewer reasoning from a table in this skill;
- do not substitute role capability/model choices that are absent from the plan;
- do not invent lifecycle timeout/retry/cancellation rules from the strategy name;
- do not terminate a non-terminal Worker merely because one or more `wait()` calls returned without a final result;
- do not expand repair cycles beyond the plan;
- do not replace `direct` with delegation because delegation seems useful.

The planner may emit capability/model intent that the active Codex build cannot override per spawn. In that case use the installed baseline supported by the runtime, preserve topology/review/lifecycle/repair, and report the limitation rather than pretending the requested override was applied.

## 4. Parent owns semantic decisions

The qualifying parent owns:

- root cause / architecture;
- scope and non-goals;
- compatibility constraints;
- implementation sequence;
- risks;
- acceptance criteria;
- construction and later revision of TaskProfile.

Parent should spend reasoning on high-value semantic decisions rather than duplicating Worker execution loops. Delegated Workers intentionally run with deeper reasoning than Parent by default because the efficient Worker model is materially cheaper. If Parent is explicitly forced to `max`, Worker roles can only equal `max` because no higher effort tier exists.

Model capability and reasoning effort are independent axes. `Luna max` is not treated as equivalent to Parent-class capability; strong/absolute `quality_intent` may therefore request `latest-capable` for Implementer/Reviewer roles even when their reasoning is already `max`. Read-only Explorers remain on efficient capability by default so premium capability is concentrated at higher-value decision points.

Read-only exploration requested by the plan may supply evidence, but it does not own final architecture decisions.

## 5. Async Worker lifecycle and scope tracking

Lifecycle is part of ExecutionPlan, not an ad-hoc Parent heuristic.

For every planned Worker, assign a stable bounded `scope_id` before spawn. The scope must identify the evidence/workstream that Worker owns. Do not create duplicate scopes unless independent duplicate verification is an explicit acceptance need.

Track Workers using these semantic states when the active runtime exposes enough evidence:

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

State rules:

- `progressing`: the Worker has recent observable activity, including a completed tool/command/search/file-read event, a new evidence message, or an explicitly visible in-flight operation.
- `stalled`: no observable progress for at least `idle_timeout_seconds` and no visible in-flight work.
- `failed`: the Agent/tool/runtime reports a terminal error.
- `superseded`: the same bounded scope has already been covered with equivalent evidence by Parent or another execution path, and that stage has `cancel_if_superseded=true`.
- `cancelled`: cancellation/termination has actually been confirmed.

`idle_timeout_seconds` is a renewable **progress lease**, not a completion deadline. New observable progress renews the lease. `hard_timeout_seconds` is the absolute wall-clock ceiling from Worker start.

**A `wait()` timeout is never a Worker timeout.** A high-reasoning Worker can be healthy and slow. Repeated `wait()` calls returning without a terminal result do not by themselves justify `stalled`, `failed`, or cancellation.

If the active Codex runtime does not expose sufficient intermediate activity to measure idle time reliably, do not guess. Keep a non-terminal Worker as `running`/`progressing` unless there is explicit failure, clear stall evidence, supersession, or the hard timeout is reached.

### Deterministic lifecycle evaluator

When timestamps/activity evidence are reliable enough to make a lifecycle decision, do not calculate timeout/fallback behavior in prose. Invoke the installed evaluator. **All timestamp arguments are Unix seconds** such as Python `time.time()`. Do not pass 13-digit millisecond telemetry/JavaScript timestamps; the evaluator deliberately fails fast on obvious millisecond input instead of silently converting it.

```bash
python3 ~/.codex/codex-flow/strategies/lifecycle_runtime.py \
  --policy-json '<the relevant exploration_stage / implementation_stage / review_stage JSON>' \
  --scope-id <scope-id> \
  --stage exploration|implementation|review \
  --started-at <unix-seconds> \
  --last-progress-at <unix-seconds> \
  --now <unix-seconds> \
  [--writable] [--in-flight] \
  [--terminal-success] [--terminal-failure] \
  [--scope-superseded] [--cancel-confirmed] \
  [--replacement-isolated]
```

Use its `state`, `action`, `cancel_required`, `replacement_allowed`, `fence_required`, and `fallback_policy` as the lifecycle decision. Parent supplies only observable facts and semantic scope overlap; the helper owns timing transitions, cancellation requirements, and writable writer fencing.

If `cancel_required=true`, request cancellation/termination of the old non-terminal Worker even when `action` already permits `continue_partial`, `parent_delta`, or an isolated `replan`. A hard/idle lifecycle exit must not leave a Worker silently running in the background. When an isolated downstream writer is authorized with `--replacement-isolated`, it may proceed while cancellation of the old Worker is still required, but the old output must be fenced from integration.

`fallback_policy` is `null` for terminal success and for already-satisfied superseded scopes. A non-null value means failure/cancellation/stall still requires the corresponding fallback handling; do not infer fallback work when it is absent.

If the helper is unavailable, treat that as an installation/runtime failure. For writable implementation, fail safe: never introduce another writer into the same live scope while the previous Worker is non-terminal. For any hard-timeout/stalled non-terminal Worker, request cleanup rather than leaving it running indefinitely.

Parent execution is fork/join, not fork/block:

1. spawn planned Workers;
2. continue Parent work that does not overlap their `scope_id`s;
3. consume completed Worker evidence opportunistically;
4. only perform a lifecycle join when Parent reaches a dependency on that stage;
5. never redo a Worker's entire scope merely because it has not returned yet.

### Join policies

`opportunistic`:
- do not block Parent specifically for Worker results;
- consume completed evidence if available;
- fallback may continue with partial evidence.

`quorum`:
- at the join point, require at least `min_successful_workers` terminal successful results unless affected Workers have been validly superseded;
- reaching numeric quorum does **not** make every remaining distinct scope worthless;
- `cancel_stragglers_after_quorum=true` only authorizes cancellation when a straggler no longer owns unique acceptance-relevant evidence.

`required`:
- every non-superseded assigned scope must be covered before the stage is considered satisfied;
- the stage must also meet `min_successful_workers` unless a new plan changes that requirement;
- do not silently replace required independent review with Parent self-review when `cancel_if_superseded=false`.

### Supersession

Supersession is overlap-aware cancellation, not a timeout shortcut.

Examples:

- a PR-metadata Explorer is still running, but Parent already obtained the same PR metadata and checks: the Worker may become `superseded` when policy allows;
- a Runtime reviewer is still actively reading/running tests while Parent works on unrelated branding/build tasks: its scope is **not** superseded and it must not be cancelled merely for running longer than expected.

### Fallback policies

Fallback always operates on the missing delta, never by restarting the whole stage:

- `continue_partial`: proceed when current evidence already satisfies acceptance needs;
- `parent_delta`: Parent covers only uncovered scope/evidence; for a writable implementation delta, Parent is a new writer and must satisfy the hard writable writer fence first;
- `replan`: update TaskProfile if needed and compile a new plan for the remaining delta; any new writable Implementer must satisfy the same fence;
- `fail`: surface the unresolved stage failure instead of silently replacing it.

For a non-terminal Worker, `cancel_required=true` is independent of the fallback action: fallback may make forward progress where safe, but the old Worker still must be reclaimed.

Worker lifecycle failure/stall does **not** consume `max_repair_cycles`. Repair cycles are for defects in implementation output, not scheduler/infrastructure latency.

### Hard writable writer fence

This safety invariant outranks strategy preference. Once an implementation Worker owns a writable scope and becomes stalled/hard-timed-out while non-terminal, **any fallback that creates a downstream writer** must be fenced. That includes both:

- `parent_delta`, where Parent becomes the downstream writer;
- `replan`, where a replacement Implementer/execution path becomes the downstream writer.

A downstream writer may enter only after either:

1. the old writable Worker is confirmed terminal/cancelled/failed; or
2. the downstream writer is explicitly assigned a fresh isolated worktree and the old Worker's output is fenced from integration (`--replacement-isolated`).

Until one of those conditions is true, the evaluator returns `action=request_cancel`, `cancel_required=true`, and `fence_required=true`. For `replan`, `replacement_allowed=false` additionally blocks spawning the replacement. Never let a recovered old Worker and Parent/replacement write the same live scope concurrently.

If condition 2 is used, `parent_delta` or an isolated replacement may proceed before the old Worker is terminal, but `cancel_required` remains true and the old output must remain excluded from integration.

## 6. Execute exploration exactly from the plan

If `exploration_workers == 0`, perform targeted discovery in the parent context; `exploration_stage` must be `none`.

If greater than zero, delegate that many bounded read-only investigations to distinct questions such as call sites, tests, workflows/config, compatibility, or competing root-cause hypotheses. Assign each Explorer a distinct `scope_id`. The planner may request several explorers when uncertainty/scope or the selected strategy's demand policy justify them; do not collapse them to one merely out of habit.

Prefer `worker-explorer` when supported. Do not duplicate investigations. Respect `max_concurrent_threads` as the per-stage hard concurrency ceiling. Apply `explorer_capability_policy`, `explorer_model`, and `explorer_reasoning` exactly when the active Codex runtime supports per-spawn overrides; otherwise use the installed Worker baseline and report the limitation if material.

Execute exploration join/cancellation/fallback only from `exploration_stage`. In particular, do not kill a Luna `xhigh/max` Explorer merely because it has taken multiple Parent wait intervals while continuing to read files, run commands, or produce other observable progress.

## 7. Compact handoff for delegated implementation

For each planned implementation worker, hand off only:

- `scope_id` / isolated writable scope;
- Goal;
- Root cause/design decision;
- Relevant files/components;
- Steps;
- Constraints/non-goals;
- Acceptance criteria;
- Required validation.

Prefer fresh/no-history child context when supported.

If the plan requests multiple implementation workers, verify the TaskProfile evidence still proves the corresponding number of distinct non-overlapping writable workstreams. If that evidence has become false, **re-profile and recompile the plan** instead of silently changing worker count.

Prefer `worker-implementer` for planned implementation workers. Apply `implementer_capability_policy`, `implementer_model`, and `implementer_reasoning` exactly when supported by the runtime. If a requested per-spawn override is unsupported, fall back to the installed Worker baseline and report the limitation rather than re-planning resource policy locally.

Implementation normally uses a required lifecycle. Do not cancel a progressing writable Worker merely to have Parent recreate the same patch. On implementation failure/stall, follow `implementation_stage.fallback_policy` through the deterministic lifecycle evaluator. Neither `parent_delta` nor `replan` authorizes another writer to enter the old Worker's live scope until the hard writable writer fence is satisfied.

## 8. Worker implements and proves

Workers make only scoped changes, run narrow validation first, fix failures caused by their patch, and return evidence:

- scope id;
- changed files;
- concise implementation summary;
- validation commands/results;
- deviations;
- unresolved risks/failures.

Evidence beats verbose logs.

## 9. Review exactly according to the plan

Parent review always checks the relevant diff, affected call sites, validation evidence, acceptance criteria, architecture consistency, and regression risk.

- `review_mode=parent`: parent review only; `reviewer_workers == 0`, `review_stage == none`, and all `reviewer_*` fields are `none`.
- `review_mode=independent+parent`: spawn exactly `reviewer_workers` independent reviewers, each using `reviewer_capability_policy`, `reviewer_model`, and `reviewer_reasoning`, then execute the `review_stage` join before parent final verification.

When more than one reviewer is requested, give them non-duplicative bounded `scope_id`s (for example correctness/regressions vs. acceptance/architecture, or Runtime semantics vs. installation/platform integration) rather than asking identical questions.

Prefer the dedicated read-only `worker-reviewer` role for independent review. Reviewers must inspect the patch adversarially and report findings; they must not silently turn themselves into implementers.

If two deep reviewers own complementary scopes and are still progressing, do not terminate them solely because Parent has completed unrelated work or because multiple waits returned. At the join point, apply `review_stage` exactly. Parent self-review should cover only a missing delta authorized by fallback, not restart both review scopes from zero.

If the active runtime cannot apply the requested reviewer model/capability/reasoning override, use the installed Worker baseline and report the limitation. Do not select a replacement reviewer policy from the strategy name or `quality_intent`.

Direct mode still requires parent self-review.

Do not infer review depth, reviewer resources, or lifecycle from the strategy/modifier name after the plan has been compiled.

## 10. Repair from bounded delta tasks

On implementation defect, send the smallest useful repair delta: exact defect, impact, required correction, relevant symbol/file, and validation.

Never exceed `max_repair_cycles` from ExecutionPlan.

If repair fails or new evidence materially changes the task, update TaskProfile and compile a **new** ExecutionPlan. Do not mutate the old plan ad hoc.

Do not count Worker stall/failure/supersession as an implementation repair cycle.

## 11. Quota and telemetry discipline

Quota must never be guessed. The planner reads app-server rate-limit state when available; unavailable state becomes `unknown`.

Telemetry remains observational and deterministic. Never call a model solely to estimate tokens, quota, duration, or produce a usage summary.

Quota pressure may reduce speculative fan-out or repair budget for quota-sensitive strategies, but configured reasoning/quality floors and the Worker-over-Parent reasoning invariant must not be silently lowered. `quality` is correctness-first; strong/absolute quality intent is allowed to retain Parent-class capability on high-value roles under quota pressure. Safety ceilings still apply.

Lifecycle v1 uses deterministic strategy policies, a deterministic lifecycle evaluator, and Runtime hard ceilings. Do not invent historical latency predictions. Future telemetry-driven latency adaptation may be added only as explicit planner/runtime logic.

## 12. Context and concurrency discipline

Prefer targeted search, concise excerpts, diff-scoped review, and small validation output. Avoid full-repo dumps, duplicated agents, rereading unchanged files, parent reimplementation of Worker work, or cancelling useful Worker work only to recreate it in Parent.

`max_concurrent_threads` is a **per-stage concurrency ceiling**, not the total number of Workers in the plan. `planned_worker_count` may exceed it because exploration, implementation, and review are separate stages.

Parallel work must be independent. Writable fan-out requires isolated non-overlapping scopes/worktrees already represented by `writable_workstreams`.

A downstream writer created by fallback is **not** an additional proven writable workstream merely because Parent took over or replanning occurred. It must satisfy the hard writable writer fence first.

## 13. Re-plan checkpoints

Re-profile and invoke the planner again when:

- complexity/risk materially changes;
- explicit quality intent materially changes;
- the root cause is disproven;
- a cross-module dependency appears;
- writable workstream isolation changes;
- a required stage chooses `fallback_policy=replan` after failure/stall;
- repair cycles fail;
- reliable quota/runtime state materially changes.

Re-plan from the delta; do not restart the task without evidence. For writable work, a new plan never overrides the old Worker's fencing requirement.

## Compatibility invariant

For schema-v3 users with no strategy/routing fields:

```text
strategy = efficient
routing = adaptive
review = auto
fanout = auto
quality_intent = normal
```

Persistent policy remains schema v4. ExecutionPlan schema v8 adds deterministic StagePolicy fields; the deterministic planner and strategy registry define their concrete values, and the installed lifecycle evaluator applies timing/fallback state transitions, cancellation requirements, timestamp validation, and hard writable writer fencing.
