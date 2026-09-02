# FlowPilot Multi-Strategy Runtime

FlowPilot is the semantic profiler and execution runtime for codex-flow. **Policy schema v4** separates the optimization objective from execution constraints, while **ExecutionPlan schema v7** carries the concrete WorkerBudget, task intent, per-role capability/reasoning policy, and topology selected for one task.

```text
User Task
   ↓
Task Profiler (FlowPilot semantic reasoning)
   ↓
TaskProfile
   ↓
Strategy Runtime
   ├─ policy precedence
   ├─ Strategy Registry
   │  ├─ efficient
   │  ├─ balanced
   │  ├─ quality
   │  └─ speed
   ├─ WorkerBudget
   ├─ Strategy resource hooks
   ├─ Modifiers
   ├─ runtime / quota state
   └─ generic Plan Compiler
   ↓
ExecutionPlan v7
   ↓
──────────────── hard boundary ────────────────
   ↓
Flow Runtime (FlowPilot)
   ↓
Role Agents
   ├─ worker-explorer
   ├─ worker-implementer
   └─ worker-reviewer
   ↓
Parent final verification / bounded repair
   ↓
Telemetry
```

The critical invariant is:

> **FlowPilot profiles. `strategy_runtime.py` plus the strategy registry decide. FlowPilot executes the returned plan.**

The Skill must not keep another copy of strategy topology, Worker counts, capability selection, reasoning policy, review policy, or quota logic.

## Design invariants

1. **Strategy is an optimization objective, not an executor.**
2. **Routing is a constraint, not a strategy.** `direct`, `delegate`, and `adaptive` are orthogonal to strategy selection.
3. **WorkerBudget is a preference envelope, not a fixed Worker count.** Runtime converts it into concrete counts using TaskProfile evidence and hard ceilings.
4. **Strategy semantics stay in StrategySpec modules.** The generic compiler may invoke strategy hooks, but it must not branch on built-in literals such as `efficient`, `balanced`, `quality`, or `speed`.
5. **Quality intent is task semantics, not technical risk.** `quality_intent=strong|absolute` represents explicit user optimization intent and must not be encoded by faking `risk=critical`.
6. **Only the selected strategy consumes strategy-specific semantics.** A non-`quality` strategy may carry `quality_intent` for observability, but that field must not alter its topology or resources.
7. **Model capability and reasoning effort are independent axes.** `latest-efficient + max` is not assumed equivalent to `latest-capable`.
8. **Capability is role-scoped.** Explorer, Implementer, and Reviewer may receive different capability/model/reasoning choices in one plan.
9. **Modifiers are orthogonal behavior controls.** Review rigor and fan-out do not create combinatorial strategy names.
10. **Role Agents are strategy-agnostic capabilities.** Explorer, implementer, and reviewer prompts are reused across strategies.
11. **Model slugs are not strategy semantics.** Strategy expresses capability/resource intent; policy/runtime resolve current models.
12. **Expensive Parent capability is reserved for high-value semantic decisions.** Delegated Worker roles use at least one higher reasoning tier than Parent whenever the effort ladder permits it.
13. **`max` is the top effort tier.** If Parent is explicitly forced to `max`, Worker roles can only equal `max`; the plan records this limitation.
14. **Writable fan-out requires evidence.** Multiple implementers require already-proven isolated, non-overlapping writable workstreams.
15. **Safety and hard ceilings belong to Runtime.** A strategy cannot bypass write-conflict checks, `writable_workstreams`, modifiers, runtime ceilings, or repair ceilings.
16. **`max_concurrent_threads` is a per-stage ceiling.** Exploration, implementation, and review are separate stages, so `planned_worker_count` may exceed it.
17. **Configured floors are hard floors.** Strategy/quota state may not silently lower them.
18. **Task profiling is continuous.** Material evidence or explicit quality-intent changes require re-profile + recompile rather than ad-hoc plan mutation.
19. **Telemetry is observational.** Planning adds no LLM calls merely to estimate usage or quota.
20. **Release defaults have one source of truth.** `policy/defaults.toml` drives installer and planner defaults.
21. **Installer/update policy round-trips are lossless for supported fields.**

## Strategy Registry, WorkerBudget, and resource hooks

Built-in strategies live under:

```text
scripts/strategies/
├── __init__.py
├── base.py
├── efficient.py
├── balanced.py
├── quality.py
└── speed.py
```

`base.py` defines `StrategySpec` and `WorkerBudget`.

```text
WorkerBudget
  max_explorers
  max_implementers
  max_reviewers
  max_total_workers
  speculation: low | medium | high
```

A StrategySpec can express:

```text
adaptive_route(task)
effort(task, role)
worker_budget(task)
independent_review(task)
capability(task, role)       → worker | parent
exploration_bonus(task)      → non-negative integer
reviewer_bonus(task)         → non-negative integer
notes(task)                  → tuple[str, ...]
allow_parallel_write
quota_sensitive
```

The role-based `capability()` hook is intentionally abstract. `"worker"` means the configured efficient Worker policy; `"parent"` means the configured Parent-class capability policy. Strategy modules do not hard-code model slugs.

Runtime remains responsible for generic mechanics only:

```text
policy precedence
TaskProfile validation
routing overrides
modifiers
configured reasoning floors
Worker-role-over-Parent reasoning invariant
base exploration/reviewer demand formulas
strategy bonus application
writable isolation proof
write-conflict checks
per-stage thread ceilings
quota normalization/enforcement
role-resource materialization
ExecutionPlan construction
```

This split lets strategies become more aggressive without duplicating safety logic or leaking strategy-specific conditions back into the compiler.

## Built-in strategy budgets

The numbers below are **maximum strategy envelopes**, not promises that every task will spawn that many agents. Runtime still requires task evidence and respects the configured thread ceiling.

| Strategy | Typical demanding-task budget | Speculation | Writable fan-out | Quota-sensitive |
| --- | --- | --- | --- | --- |
| `efficient` | up to 2 explorers / 2 implementers / 1 reviewer / 5 total | low | only with proven isolation + aggressive modifier | yes |
| `balanced` | up to 3 explorers / 3 implementers / 1 reviewer / 5 total | medium | proven isolated workstreams | yes |
| `quality` normal | up to 4 explorers / 3 implementers / 2 reviewers / 6–7 total | high | proven isolated workstreams | no |
| `quality` strong | up to 4 explorers / 3 implementers / 2 reviewers / 7 total | high | proven isolated workstreams | no |
| `quality` absolute | up to 4 explorers / 4 implementers / 2 reviewers / 8 total | high | proven isolated workstreams | no |
| `speed` | up to 4 explorers / 8 implementers / 1 reviewer / 8 total | high | saturate proven isolated workstreams | no |

With the default runtime ceiling of four threads, a `speed` or absolute-quality plan can use four isolated implementers simultaneously when four real writable workstreams are proven.

### `efficient`

Objective: minimize expensive Parent usage and total waste while moving deep execution/debug loops to cheaper Workers.

- small low-risk work stays direct;
- iterative, cross-module, repo-wide, uncertain, or exploration-heavy work delegates more readily;
- demanding work can use multiple explorers instead of forcing Parent to perform all discovery;
- quota pressure collapses speculative fan-out and may reduce repair budget;
- all roles remain on the configured efficient Worker capability policy.

### `balanced`

Objective: balance quality, quota, and latency.

- moderate parallel exploration;
- up to three isolated implementation workstreams;
- quota pressure can reduce topology to a conservative shape;
- Worker-role reasoning remains deeper than Parent reasoning;
- `quality_intent` does not change topology/resources because `balanced` does not consume it.

### `quality`

Objective: maximize correctness through deep reasoning, broader exploration, independent verification, and premium capability at the stages where it has the highest decision value.

`quality_intent` has three levels:

```text
normal
  ordinary quality target
  prefer latest-efficient roles with deep/max reasoning

strong
  explicit quality-over-cost preference
  target xhigh Parent / max Worker-role reasoning
  ordinary Explorer stays latest-efficient
  Implementer / Reviewer may use Parent-class latest-capable

absolute
  explicit highest-quality preference
  correctness > quota / latency inside hard safety ceilings
  target max Parent / max Worker-role reasoning
  ordinary Explorer stays latest-efficient
  Implementer / Reviewer may use Parent-class latest-capable
  allow up to two independent reviewers and the largest quality WorkerBudget
```

Additional rules:

- normal complex/high-risk/high-verification tasks still target `xhigh` Parent and `max` Worker-role reasoning;
- `strong/absolute` quality preference alone does **not** make read-only exploration premium-model work;
- when `complexity=critical` or `risk=critical`, Explorer / Implementer / Reviewer may all use Parent-class capability because discovery itself becomes high-risk decision work;
- strong/absolute intent remains subject to runtime safety ceilings, write-conflict checks, and proven writable workstreams;
- quota pressure does not cost-collapse `quality`, because the strategy is not quota-sensitive.

This produces the intended economic shape for a routine strong-quality task:

```text
Parent       latest-capable / xhigh
Explorer     latest-efficient / max
Implementer  latest-capable / max
Reviewer     latest-capable / max
```

Capability and reasoning remain independent: Explorer can be cheap-model `max` while Implementer/Reviewer use Parent-class `max`.

### `speed`

Objective: minimize wall-clock latency by saturating safe Worker concurrency.

- non-small parallelizable work delegates;
- writable implementation count scales with `writable_workstreams`, budget, and runtime ceiling instead of being hard-coded to two;
- read-only exploration can fan out independently;
- speed never authorizes overlapping writes;
- `quality_intent` does not alter speed topology/resources.

## Role Agents

```text
worker-explorer
  read-only discovery, evidence collection, competing hypotheses

worker-implementer
  isolated implementation, tests, debugging, bounded repair

worker-reviewer
  independent read-only review, regression hunting, acceptance validation
```

The same role can be used differently by each strategy. ExecutionPlan v7 makes resource selection explicit per role rather than treating “Worker” as one task-wide capability bucket.

## Policy precedence

Strongest to weakest:

```text
hard runtime / safety ceilings
  > explicit current-task overrides
  > repository .codex-flow.toml
  > ~/.codex/codex-flow.toml
  > codex-flow release defaults
```

Repository policy may choose strategy/routing/modifiers, raise reasoning floors, and tighten runtime ceilings. It cannot silently weaken user floors.

## Policy schema v4

The persistent policy remains schema v4. WorkerBudget and `quality_intent` are per-task ExecutionPlan concepts and therefore do **not** require a persistent-policy schema bump.

```toml
schema_version = 4

[strategy]
profile = "efficient"

[routing]
mode = "adaptive"

[modifiers]
review = "auto"
fanout = "auto"
```

Current fresh-install reasoning defaults are intentionally asymmetric:

```toml
[parent]
min_reasoning_effort = "high"
routine_effort = "high"
complex_effort = "high"
critical_effort = "xhigh"

[worker]
min_reasoning_effort = "xhigh"
routine_effort = "xhigh"
complex_effort = "xhigh"
critical_effort = "max"
```

Runtime then enforces for every delegated Worker role:

```text
role_reasoning >= next_tier(parent_reasoning)
```

where:

```text
high  → xhigh
xhigh → max
max   → max
```

User/repository floors can still raise either side. Capability escalation remains independent from this effort ladder.

## Routing and modifiers

Routing is independent from strategy:

- `adaptive`: selected strategy supplies direct/delegate preference from TaskProfile;
- `direct`: Parent executes with no subagents;
- `delegate`: delegated execution when supported and safely scoped.

Modifiers:

```text
review: auto | standard | strict
fanout: auto | conservative | aggressive
```

`conservative` reduces speculative exploration and writable fan-out. `aggressive` can increase safe fan-out but still cannot invent isolated writable workstreams or exceed strategy/runtime budgets.

## TaskProfile contract

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

`quality_intent` defaults to `normal`. It is set only from explicit current-task user intent. Generic requests to be careful, review code, or produce good work do not automatically imply `strong` or `absolute`.

`writable_workstreams` is evidence, not a desired Worker count. `4` means four isolated non-overlapping writable scopes/worktrees have actually been identified. Runtime may then authorize up to four implementers if strategy budget and hard ceilings allow it.

`parallelism=none` remains a hard TaskProfile constraint: execution stages are sequential and explorer fan-out is disabled.

## Dynamic fan-out

Runtime calculates **strategy-agnostic base exploration demand** from:

```text
uncertainty
exploration_need
complexity
scope
verification_cost
```

The selected strategy may add `exploration_bonus(task)`. For example, only `quality` translates `strong/absolute quality_intent` into extra exploration demand. Therefore the same `quality_intent` on `balanced` cannot silently create extra explorers.

Writable implementation fan-out requires all of:

```text
parallelism == high
write_conflict == low
writable_workstreams >= 2
strategy allows parallel write OR fanout modifier == aggressive
```

Implementation count is bounded by:

```text
writable_workstreams
strategy.worker_budget.max_implementers
runtime.max_concurrent_threads
```

Review demand follows the same split: Runtime owns a generic technical-risk base formula; the selected strategy may add `reviewer_bonus(task)`. Absolute quality uses that hook to request the second independent reviewer.

The total plan can therefore look like:

```text
2 explorers
→ 4 isolated implementers
→ 2 independent reviewers
→ Parent final verification
```

while `max_concurrent_threads=4`, because at no single stage are more than four Workers active concurrently.

## RuntimeState and quota

```text
quota_pressure: unknown | low | medium | high | critical
max_concurrent_threads
max_repair_cycles
```

Quota is read from the existing app-server rate-limit path and normalized before strategy use. `unknown` is used when reliable state is unavailable.

For quota-sensitive strategies (`efficient`, `balanced`), high/critical pressure can reduce explorers, implementers, reviewers, and repair budget. It does **not** reduce configured reasoning floors or the Worker-role-over-Parent reasoning invariant.

`quality` is deliberately not quota-sensitive. Strong/absolute quality retains Parent-class capability for high-value Implementer/Reviewer roles under quota pressure; ordinary Explorer capability remains independently selected. Hard runtime and safety ceilings still apply.

## ExecutionPlan v7

The deterministic planner emits:

```text
ExecutionPlan
  schema_version = 7
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

The concrete per-role resource fields and `*_workers` values are authoritative. FlowPilot must execute them and must not reinterpret either the strategy name or quality intent after compilation.

When an execution stage is absent, its role resources are `none`. For example, if `exploration_workers=0`, all `explorer_*` fields are `none`; when `review_mode=parent`, `reviewer_workers=0` and all `reviewer_*` fields are `none`.

## Anti-monolith guard

Tests explicitly reject built-in strategy comparisons in `scripts/strategy_runtime.py`:

```text
strategy == "efficient"
strategy == "balanced"
strategy == "quality"
strategy == "speed"
```

and their `!=` forms. This guard is intentionally regex-based so it matches the real source text rather than escaped shell literals.

Behavioral tests additionally compare `balanced` plans under `quality_intent=normal` and `strong` and require topology/resources to remain identical. Role-resource tests require routine strong/absolute quality to keep Explorer efficient while promoting Implementer/Reviewer.

## Installer and update round-trip

For supported global policy fields:

```text
explicit CODEX_FLOW_* environment override
  > existing ~/.codex/codex-flow.toml value
  > policy/defaults.toml release value
```

Existing users keep their configured reasoning matrix during reinstall/update. Fresh installs receive the Worker-first defaults. `quality_intent` is not persisted by the installer because it is a current-task semantic signal.

## CLI

```bash
codex-flow strategy show
codex-flow strategy show --effective
codex-flow strategy profiles
codex-flow strategy set quality
codex-flow strategy routing adaptive

codex-flow strategy plan \
  --profile quality \
  --quality-intent strong \
  --complexity complex \
  --uncertainty high \
  --parallelism high

codex-flow strategy plan \
  --profile quality \
  --quality-intent absolute \
  --parallelism high \
  --write-conflict low \
  --writable-workstreams 4
```

The resulting JSON shows quality intent, WorkerBudget, concrete per-stage Worker counts, and separate Explorer / Implementer / Reviewer capability/model/reasoning resources.

## Adding a new built-in strategy

A new strategy should:

1. add `scripts/strategies/<name>.py`;
2. export one `STRATEGY = StrategySpec(...)`;
3. define a clear optimization objective, WorkerBudget, and only the resource/demand hooks it needs;
4. register the strategy in `scripts/strategies/__init__.py`;
5. reuse TaskProfile and ExecutionPlan contracts;
6. avoid model-slug-specific semantics;
7. leave isolation checks, reasoning invariant, modifiers, quota enforcement, and hard ceilings in `strategy_runtime.py`;
8. never add built-in-strategy literal branches to the generic compiler;
9. add deterministic planner tests, including isolation from unrelated task semantics;
10. avoid creating a new Skill/Agent unless a genuinely new execution role exists.
