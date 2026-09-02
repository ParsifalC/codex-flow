---
name: flow-pilot
description: Profile non-trivial technical work, compile a deterministic ExecutionPlan through the codex-flow strategy runtime, then execute parent/worker/review/repair exactly from that plan while honoring current-task and repository policy.
---

# FlowPilot Strategy Runtime

FlowPilot is the semantic profiler and execution runtime for codex-flow. It is **not** a second strategy engine.

The invariant is:

> **FlowPilot profiles. `strategy_runtime.py` + the strategy registry decide. FlowPilot executes the returned plan.**

Do not independently re-implement strategy topology, capability selection, reasoning selection, quota policy, worker counts, review mode, fan-out, or repair budget in this skill. The installed planner and built-in strategy registry are the single source of truth for those decisions.

Default compatibility remains `strategy = efficient` plus `routing = adaptive`.

## 0. Policy precedence and current-task intent

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
- gives delegated Worker roles at least one higher reasoning tier than Parent when the effort ladder permits it;
- lets only the selected strategy consume strategy-specific TaskProfile semantics such as `quality_intent`;
- lets `quality` promote high-value Implementer/Reviewer capability for strong/absolute intent while ordinary Explorers remain efficient-worker-first unless technical risk itself is critical;
- applies hard runtime thread/repair ceilings and writable-isolation checks;
- reads reliable app-server quota state when available and normalizes it before strategy logic;
- emits one ExecutionPlan without extra LLM calls.

If the helper or strategy registry is unavailable, treat that as an installation/runtime failure. Do **not** silently recreate the strategy logic from this document; use the conservative installed Codex baseline and tell the user the strategy planner is unavailable.

## 3. ExecutionPlan is the hard strategy/runtime boundary

Current contract (schema v7):

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
  review_mode
  max_repair_cycles
  max_concurrent_threads
  escalate_on_failure
  quota_pressure
  repo_policy | none
  context_mode
  notes
```

Once compiled, execute this plan. Do not reinterpret the strategy name or `quality_intent` to change topology or resource selection.

Examples of prohibited duplication:

- do not add explorers beyond `exploration_workers` because the strategy is `quality`;
- do not upgrade a model locally because `quality_intent=strong`; per-role capability is already encoded in the plan;
- do not increase implementers beyond `implementation_workers` because the strategy is `speed`;
- do not spawn extra reviewers beyond `reviewer_workers`;
- do not treat `worker_budget` maxima as mandatory worker counts; the planner has already converted the budget into concrete counts;
- do not independently change review rigor from a modifier or strategy name after compilation;
- do not lower or raise parent/explorer/implementer/reviewer reasoning from a table in this skill;
- do not substitute role capability/model choices that are absent from the plan;
- do not expand repair cycles beyond the plan;
- do not replace `direct` with delegation because delegation seems useful.

The planner may emit capability/model intent that the active Codex build cannot override per spawn. In that case use the installed baseline supported by the runtime, preserve topology/review/repair, and report the limitation rather than pretending the requested override was applied.

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

## 5. Execute exploration exactly from the plan

If `exploration_workers == 0`, perform targeted discovery in the parent context.

If greater than zero, delegate that many bounded read-only investigations to distinct questions such as call sites, tests, workflows/config, compatibility, or competing root-cause hypotheses. The planner may request several explorers when uncertainty/scope or the selected strategy's demand policy justify them; do not collapse them to one merely out of habit.

Prefer `worker-explorer` when supported. Do not duplicate investigations. Respect `max_concurrent_threads` as the per-stage hard concurrency ceiling. Apply `explorer_capability_policy`, `explorer_model`, and `explorer_reasoning` exactly when the active Codex runtime supports per-spawn overrides; otherwise use the installed Worker baseline and report the limitation if material.

## 6. Compact handoff for delegated implementation

For each planned implementation worker, hand off only:

- Goal
- Root cause/design decision
- Isolated scope
- Relevant files/components
- Steps
- Constraints/non-goals
- Acceptance criteria
- Required validation

Prefer fresh/no-history child context when supported.

If the plan requests multiple implementation workers, verify the TaskProfile evidence still proves the corresponding number of distinct non-overlapping writable workstreams. If that evidence has become false, **re-profile and recompile the plan** instead of silently changing worker count.

Prefer `worker-implementer` for planned implementation workers. Apply `implementer_capability_policy`, `implementer_model`, and `implementer_reasoning` exactly when supported by the runtime. If a requested per-spawn override is unsupported, fall back to the installed Worker baseline and report the limitation rather than re-planning resource policy locally.

## 7. Worker implements and proves

Workers make only scoped changes, run narrow validation first, fix failures caused by their patch, and return evidence:

- changed files;
- concise implementation summary;
- validation commands/results;
- deviations;
- unresolved risks/failures.

Evidence beats verbose logs.

## 8. Review exactly according to the plan

Parent review always checks the relevant diff, affected call sites, validation evidence, acceptance criteria, architecture consistency, and regression risk.

- `review_mode=parent`: parent review only; `reviewer_workers == 0` and all `reviewer_*` fields are `none`.
- `review_mode=independent+parent`: spawn exactly `reviewer_workers` independent reviewers, each using `reviewer_capability_policy`, `reviewer_model`, and `reviewer_reasoning`, then perform parent final verification.

When more than one reviewer is requested, give them non-duplicative review objectives (for example correctness/regressions vs. acceptance/architecture) rather than asking identical questions.

Prefer the dedicated read-only `worker-reviewer` role for independent review. Reviewers must inspect the patch adversarially and report findings; they must not silently turn themselves into implementers.

If the active runtime cannot apply the requested reviewer model/capability/reasoning override, use the installed Worker baseline and report the limitation. Do not select a replacement reviewer policy from the strategy name or `quality_intent`.

Direct mode still requires parent self-review.

Do not infer review depth or reviewer resources from the strategy or modifier name after the plan has been compiled.

## 9. Repair from bounded delta tasks

On failure, send the smallest useful repair delta: exact defect, impact, required correction, relevant symbol/file, and validation.

Never exceed `max_repair_cycles` from ExecutionPlan.

If repair fails or new evidence materially changes the task, update TaskProfile and compile a **new** ExecutionPlan. Do not mutate the old plan ad hoc.

## 10. Quota and telemetry discipline

Quota must never be guessed. The planner reads app-server rate-limit state when available; unavailable state becomes `unknown`.

Telemetry remains observational and deterministic. Never call a model solely to estimate tokens, quota, or produce a usage summary.

Quota pressure may reduce speculative fan-out or repair budget for quota-sensitive strategies, but configured reasoning/quality floors and the Worker-over-Parent reasoning invariant must not be silently lowered. `quality` is correctness-first; strong/absolute quality intent is allowed to retain Parent-class capability on high-value roles under quota pressure. Safety ceilings still apply.

## 11. Context and concurrency discipline

Prefer targeted search, concise excerpts, diff-scoped review, and small validation output. Avoid full-repo dumps, duplicated agents, rereading unchanged files, or parent reimplementation of worker work.

`max_concurrent_threads` is a **per-stage concurrency ceiling**, not the total number of Workers in the plan. `planned_worker_count` may exceed it because exploration, implementation, and review are separate stages.

Parallel work must be independent. Writable fan-out requires isolated non-overlapping scopes/worktrees already represented by `writable_workstreams`.

## 12. Re-plan checkpoints

Re-profile and invoke the planner again when:

- complexity/risk materially changes;
- explicit quality intent materially changes;
- the root cause is disproven;
- a cross-module dependency appears;
- writable workstream isolation changes;
- repair cycles fail;
- reliable quota/runtime state materially changes.

Re-plan from the delta; do not restart the task without evidence.

## Compatibility invariant

For schema-v3 users with no strategy/routing fields:

```text
strategy = efficient
routing = adaptive
review = auto
fanout = auto
quality_intent = normal
```

The deterministic planner and strategy registry, not this skill, define the concrete execution behavior for that compatibility profile.
