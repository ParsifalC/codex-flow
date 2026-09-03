# Configuration & Multi-Strategy Policy

<div align="center">

[ 简体中文 ](configuration.md) | [ English ](configuration.en.md)

</div>

This document describes **codex-flow policy schema v4**: strategies, routing, composable modifiers, capability/reasoning policy, repository policy, runtime ceilings, quota-aware planning, and environment overrides.

> Persistent policy remains **schema v4**. Dynamic WorkerBudget, `quality_intent`, and role-scoped resource selection belong to the per-task **ExecutionPlan v7**, so they do not require a persistent-policy schema bump.

See [strategy-runtime.md](strategy-runtime.md) for the architecture and full plan contract.

---

## Global policy

The user policy is stored at:

```text
~/.codex/codex-flow.toml
```

A fresh install currently generates:

```toml
schema_version = 4

[ui]
language = "auto"

[strategy]
enabled = true
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
reasoning_policy = "adaptive"
routine_effort = "high"
complex_effort = "high"
critical_effort = "xhigh"

[worker]
model_policy = "latest-efficient"
model = "auto"
resolved_model = "gpt-5.6-luna"
min_reasoning_effort = "xhigh"
reasoning_policy = "adaptive"
routine_effort = "xhigh"
complex_effort = "xhigh"
critical_effort = "max"

[runtime]
max_concurrent_threads = 4
max_repair_cycles = 2

[telemetry]
enabled = true
summary = true
notifications = true
retention_days = 30
source = "hooks+app-server"
```

The asymmetric reasoning defaults are deliberate: the expensive high-capability Parent handles architecture and semantic decisions, while the much cheaper Worker absorbs deeper exploration, implementation, debugging, verification, and repair loops.

Schema-v3 policies remain semantically compatible. Missing strategy/routing/modifier sections resolve to:

```text
strategy_enabled = true
strategy = efficient
routing = adaptive
review = auto
fanout = auto
quality_intent = normal
```

`quality_intent` is not persisted. It is current-task TaskProfile semantics and defaults to `normal`.

Installer/update migrates to schema v4 while preserving supported existing values. Existing users therefore keep their custom reasoning matrix; the new matrix is primarily the fresh-install release default.

---

## Policy precedence

`[strategy].enabled` is a global master gate above normal strategy precedence. When `false`, FlowPilot does not build a TaskProfile, compile an ExecutionPlan, or automatically dispatch Workers. Repository policy and current-task overrides cannot re-enable it. Stored profile/routing/modifier values are retained and resume when the switch is enabled again.

```text
hard runtime / safety ceilings
  > explicit current-task overrides
  > repository .codex-flow.toml
  > global user policy
  > release defaults
```

Task-level overrides can choose strategy/routing/modifiers but cannot raise a resolved hard ceiling.

---

## Strategy, routing, and modifiers

### `[strategy]`

`enabled` controls FlowPilot automatic strategy dispatch and defaults to `true`:

```bash
codex-flow strategy enabled
codex-flow strategy disable
codex-flow strategy enable
```

Disabling it turns off **codex-flow automatic planning and dispatch only**. It does not change Codex's native `[agents].enabled`, so explicit native-subagent use remains available.

Repository `.codex-flow.toml` may override profile/routing/modifiers while the master switch is enabled, but it cannot override a global `enabled = false`. This prevents a repository from silently re-enabling distribution after the user turned it off globally.

- `efficient` — minimize expensive Parent use and total waste while offloading deep execution to efficient Workers.
- `balanced` — balance quality, quota, and wall-clock latency with moderate safe Worker fan-out.
- `quality` — maximize correctness through deeper Worker reasoning, wider exploration, independent review, and **role-scoped** high capability when explicit quality intent warrants it.
- `speed` — minimize wall-clock latency by saturating proven-safe Worker concurrency.

A strategy does not hard-code one worker count. It emits a WorkerBudget plus strategy resource hooks; Runtime combines those with TaskProfile evidence, quota state, and hard ceilings to compile concrete explorer / implementer / reviewer counts and resources.

### `[routing]`

- `adaptive` — selected strategy supplies direct/delegate preference from TaskProfile.
- `direct` — Parent executes and self-reviews with no subagents.
- `delegate` — use Workers when safely scopeable and runtime-supported.

### `[modifiers]`

`review`:

- `auto` — strategy/task decide review topology.
- `standard` — Parent review.
- `strict` — independent reviewer stage plus Parent final verification when delegated.

`fanout`:

- `auto` — strategy/task decide.
- `conservative` — reduce speculative and writable fan-out.
- `aggressive` — increase safe fan-out without bypassing WorkerBudget or runtime/safety ceilings.

---

## Quality intent

`quality_intent` is **current-task TaskProfile semantics**, not persistent policy and not an alias for `risk`:

```text
normal | strong | absolute
```

- `normal` — default. Ordinary quality requirements; `quality` prefers `latest-efficient` Workers with deep reasoning.
- `strong` — the user explicitly prioritizes quality over ordinary cost efficiency. `quality` may promote high-value **Implementer / Reviewer** capability to the Parent's `latest-capable` policy; ordinary read-only Explorers stay `latest-efficient`.
- `absolute` — the user explicitly asks for the highest practical quality and accepts higher cost/latency. `quality` prioritizes correctness inside hard runtime/safety ceilings, increases fan-out/review budget, and uses Parent-class capability for key Implementer / Reviewer roles; ordinary Explorers still do not upgrade merely because of quality preference.

Explorers may also use Parent-class capability when the technical profile itself is `complexity=critical` or `risk=critical`, because exploration then becomes a high-value, high-risk decision stage.

Do not infer `strong/absolute` merely from technical risk, and do not fake `risk=critical` to encode user quality preference. These are separate dimensions.

Examples:

```bash
codex-flow strategy plan --profile quality --quality-intent strong --complexity complex
codex-flow strategy plan --profile quality --quality-intent absolute --parallelism high --writable-workstreams 4
```

`quality_intent` is consumed **only by the `quality` strategy**. Under `efficient`, `balanced`, or `speed`, it may remain in the Plan for observability but must not change topology, capability, reasoning, review, or Worker counts.

---

## WorkerBudget

WorkerBudget is not persisted in `codex-flow.toml`. Each strategy produces it while compiling one ExecutionPlan:

```text
max_explorers
max_implementers
max_reviewers
max_total_workers
speculation: low | medium | high
```

Typical demanding-task envelopes:

| Strategy | Explorers | Implementers | Reviewers | Total | Speculation |
| --- | ---: | ---: | ---: | ---: | --- |
| `efficient` | 2 | 2 | 1 | 5 | low |
| `balanced` | 3 | 3 | 1 | 5 | medium |
| `quality normal/strong` | 4 | 3 | 2 | 6–7 | high |
| `quality absolute` | 4 | 4 | 2 | 8 | high |
| `speed` | 4 | 8 | 1 | 8 | high |

These are maxima, not mandatory spawn counts. Runtime compiles concrete counts from actual task evidence.

For example, `speed` may allow eight implementers in its strategy budget, but the default runtime ceiling is four and writable fan-out still requires the same number of proven isolated writable workstreams.

---

## Repository policy

A repository may provide:

```text
<repo>/.codex-flow.toml
```

Example:

```toml
[strategy]
profile = "quality"

[routing]
mode = "adaptive"

[modifiers]
review = "strict"
fanout = "conservative"

[parent]
min_reasoning_effort = "xhigh"

[worker]
min_reasoning_effort = "max"

[runtime]
max_concurrent_threads = 2
max_repair_cycles = 1
```

Repository policy may select strategy/routing/modifiers, raise Parent/Worker reasoning floors, and tighten runtime ceilings. It cannot silently lower global user floors. `quality_intent` is not repository policy; it comes from current-task semantics.

```bash
codex-flow strategy show --effective
codex-flow strategy plan --repo-policy none --complexity routine
codex-flow strategy plan --repo-policy ./policy.toml --complexity routine
```

---

## Parent and Worker reasoning policy

The Runtime intentionally does not give Parent and Worker the same default reasoning depth.

### Fresh-install matrix

| Task class | Parent | Worker baseline |
| --- | --- | --- |
| routine | `high` | `xhigh` |
| complex | `high` | `xhigh` |
| critical | `xhigh` | `max` |

For **delegated** plans Runtime additionally enforces for every Worker role:

```text
role_reasoning >= next_tier(parent_reasoning)
```

with:

```text
high  → xhigh
xhigh → max
max   → max
```

Therefore:

```text
Parent high  → Explorer / Implementer / Reviewer at least xhigh
Parent xhigh → Explorer / Implementer / Reviewer at least max
Parent max   → Worker roles max (no higher supported tier exists)
```

If user/repository policy forces Parent to `max`, the plan records that Worker roles cannot strictly exceed it instead of inventing a nonexistent effort tier.

### Capability is separate from reasoning

Deep Worker reasoning does not automatically mean using a Parent-class model, and `latest-efficient + max` is not treated as equivalent to `latest-capable`.

ExecutionPlan v7 exposes separate role resources:

```text
explorer_capability_policy / explorer_model / explorer_reasoning
implementer_capability_policy / implementer_model / implementer_reasoning
reviewer_capability_policy / reviewer_model / reviewer_reasoning
```

A normal complex `quality` task generally keeps all three roles on `latest-efficient + max reasoning`.

With `quality_intent=strong` or `absolute`, even technically routine work may request:

```text
Explorer     → latest-efficient + max reasoning
Implementer  → latest-capable + max reasoning
Reviewer     → latest-capable + max reasoning
```

Genuinely critical complexity/risk may request `latest-capable` for Explorer / Implementer / Reviewer even under normal quality intent. If the active Codex runtime cannot apply model/capability overrides per spawn, the installed Worker baseline is used and the limitation is reported.

---

## Writable Worker fan-out

Multiple implementers require all of:

```text
parallelism == high
write_conflict == low
writable_workstreams >= 2
```

Concrete implementation count is bounded by:

```text
TaskProfile.writable_workstreams
Strategy WorkerBudget.max_implementers
Runtime max_concurrent_threads
```

`writable_workstreams=4` means four isolated non-overlapping writable scopes/worktrees have actually been identified; it is evidence, not a requested worker count. Absolute quality cannot bypass this rule.

---

## Runtime ceilings

`[runtime]`:

- `max_concurrent_threads` — hard **per-stage** concurrency ceiling.
- `max_repair_cycles` — repair ceiling before re-profile/re-plan.

Exploration, implementation, and review are separate stages, so `planned_worker_count` may exceed `max_concurrent_threads`.

Example:

```text
2 explorers
→ 4 implementers
→ 2 reviewers
```

The plan contains eight Workers overall, while no stage exceeds four concurrent Workers.

---

## Quota-aware planning

Rate-limit state is normalized to:

```text
unknown | low | medium | high | critical
```

`efficient` and `balanced` are quota-sensitive. High/critical pressure may reduce explorer/implementer/reviewer fan-out and repair budget. It does **not** reduce configured reasoning floors or the Worker-role-over-Parent reasoning invariant.

`quality` is not quota-sensitive. In particular, strong/absolute quality intent does not downgrade Parent-class Implementer/Reviewer capability because quota pressure is high; hard runtime/safety ceilings still apply.

```bash
codex-flow strategy plan --quota-pressure unknown --complexity complex
codex-flow strategy plan --profile quality --quality-intent absolute --quota-pressure critical
```

---

## Strategy CLI

```bash
codex-flow strategy show
codex-flow strategy profiles
codex-flow strategy set quality
codex-flow strategy routing adaptive
codex-flow strategy show --effective

codex-flow strategy plan \
  --profile quality \
  --quality-intent strong \
  --complexity complex \
  --uncertainty high \
  --scope cross-module \
  --parallelism high \
  --write-conflict low \
  --exploration-need high \
  --writable-workstreams 4
```

Plan JSON includes:

```text
quality_intent
explorer_capability_policy
explorer_model
explorer_reasoning
implementer_capability_policy
implementer_model
implementer_reasoning
reviewer_capability_policy
reviewer_model
reviewer_reasoning
worker_budget
exploration_workers
implementation_workers
reviewer_workers
planned_worker_count
```

---

## Environment variables

| Variable | Fresh-install default | Purpose |
| --- | --- | --- |
| `CODEX_FLOW_STRATEGY` | `efficient` | Global strategy |
| `CODEX_FLOW_ROUTING_MODE` | `adaptive` | Global routing |
| `CODEX_FLOW_REVIEW_MODIFIER` | `auto` | Review modifier |
| `CODEX_FLOW_FANOUT_MODIFIER` | `auto` | Fan-out modifier |
| `CODEX_FLOW_QUOTA_PRESSURE` | auto-detected | Normalized quota diagnostic override |
| `CODEX_FLOW_PARENT_MODEL_POLICY` | `latest-capable` | Parent capability policy |
| `CODEX_FLOW_PARENT_MIN_MODEL` | `auto` | Parent model floor |
| `CODEX_FLOW_PARENT_MIN_EFFORT` | `high` | Parent reasoning floor |
| `CODEX_FLOW_WORKER_MODEL_POLICY` | `latest-efficient` | Worker baseline capability policy |
| `CODEX_FLOW_WORKER_MODEL` | `auto` | Worker baseline model request |
| `CODEX_FLOW_WORKER_MIN_EFFORT` | `xhigh` | Worker baseline reasoning floor |
| `CODEX_FLOW_MAX_THREADS` | `4` | Per-stage Worker thread ceiling |
| `CODEX_FLOW_MAX_REPAIR_CYCLES` | `2` | Repair ceiling |
| `CODEX_FLOW_TELEMETRY_ENABLED` | `true` | Telemetry toggle |
| `CODEX_FLOW_TELEMETRY_NOTIFICATIONS` | `true` | Notification toggle |
| `CODEX_FLOW_TELEMETRY_RETENTION_DAYS` | `30` | Telemetry retention |
| `CODEX_FLOW_LANGUAGE` | `auto` | UI language override |
| `CODEX_FLOW_BIN_DIR` | `~/.local/bin` | CLI install directory |

There is intentionally no environment variable or global policy setting for `quality_intent`; it must represent explicit current-task semantics rather than a static default.

---

## Native Codex Agent fallback

A fresh installation configures:

```toml
[agents]
enabled = true
max_concurrent_threads_per_session = 4
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "xhigh"
```

This is only the runtime fallback. ExecutionPlan v7 carries per-role resource intent; the baseline is used when the active runtime cannot apply a requested per-spawn override.
