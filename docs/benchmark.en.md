# Benchmark-Driven Routing

<div align="center">

[ 简体中文 ](benchmark.md) | [ English ](benchmark.en.md)

</div>

The benchmark is designed to answer three distinct questions without mixing their evidence:

1. Does Sol outperform Luna and Terra when all three run directly at the same reasoning effort?
2. Does the fixed-effort `codex-flow` strategy preserve Sol-level quality while reducing total cost and improving on Luna direct?
3. Does class-adaptive reasoning add enough quality to justify its extra cost over fixed-high flow?

Results are advisory. Real model runs must accumulate enough evidence before routing changes are considered, and `policy/benchmark.toml` keeps `auto_apply = false`.

The built-in benchmark passes each experimental `reasoning_effort` directly to `codex exec`; it does not traverse the FlowPilot planner. It therefore cannot prove that an `ExecutionPlan.reasoning_rollout` proposed/selected value was actually applied to a delegated Worker. Validate rollout decisions separately with runtime-observed effort, completed/censored sample counts, and p50/p95 latency evidence.

---

## Five Pre-Registered Strategies

Both `quick` and `full` use the same matrix:

| Strategy ID | Execution | Reasoning |
| :--- | :--- | :--- |
| `luna-direct` | Luna implements and repairs | `high` |
| `terra-direct` | Terra implements and repairs | `high` |
| `sol-direct` | Sol implements and repairs | `high` |
| `codex-flow-high` | Sol parent + Luna worker | both `high` |
| `codex-flow-adaptive` | Sol parent + Luna worker | routine `high`, complex `xhigh`, critical `max` |

The first four strategies form the controlled same-effort comparison. `codex-flow-adaptive` is deliberately excluded from the Sol and fixed-flow advantage claims; it is compared only with `codex-flow-high`.

---

## Balanced Corpus

The corpus contains six deterministic engineering tasks, balanced across the three classes:

| Task | Class | Focus |
| :--- | :--- | :--- |
| `routine-query-normalization` | routine | localized Unicode and whitespace behavior |
| `routine-env-precedence` | routine | configuration precedence and edge cases |
| `complex-renew-provider-refactor` | complex | reusable provider registry, validation, and legacy compatibility |
| `complex-config-migration` | complex | deep-copy-safe old/new configuration migration and idempotency |
| `critical-resumable-migration` | critical | validated, journaled, resumable, idempotent migration |
| `critical-atomic-state-write` | critical | durable atomic replacement, permissions, symlink safety, and cleanup |

Generate the corpus without calling a model:

```bash
codex-flow benchmark-corpus quick
```

Profiles are defined in `benchmark/profiles.json`:

```text
quick: 6 tasks × 5 strategies × 1 repetition = 30 runs
full:  6 tasks × 5 strategies × 3 repetitions = 90 runs
```

---

## Evidence Tests

Analyze with the immutable GPT-5.6 price snapshot:

```bash
codex-flow benchmark-analyze \
  --results benchmark/results/quick-001.jsonl \
  --prices benchmark/prices/gpt-5.6-2026-08-30.json \
  --json
```

Thresholds are pre-registered in `policy/benchmark.toml`. Evidence is marked sufficient only when the compared strategies have the same task/repetition sample keys.

### 1. Sol Capability
For each class, Sol/high is compared with the strongest Luna/high or Terra/high direct result. Sol must be no worse on final pass rate and materially improve at least one registered quality measure: final pass rate, first-pass rate, or repairs.

### 2. Fixed-High Flow Advantage
`codex-flow-high` must:
- Preserve Sol/high final quality within the configured non-inferiority margin;
- Reduce total parent+worker reference cost versus Sol/high by the configured amount; and
- Materially improve final quality, first-pass quality, or repairs versus Luna/high direct.

### 3. Adaptive Reasoning Value
`codex-flow-adaptive` is compared only with `codex-flow-high`. It must materially improve final pass rate, first-pass rate, or repairs while remaining inside the configured cost-increase ceiling.
