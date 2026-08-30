# Benchmark-driven routing

The benchmark is designed to answer three different questions without mixing their evidence:

1. Does Sol outperform Luna and Terra when all three run directly at the same reasoning effort?
2. Does the fixed-effort codex-flow strategy preserve Sol-level quality while reducing total cost and improving on Luna direct?
3. Does class-adaptive reasoning add enough quality to justify its extra cost over fixed-high flow?

Results are advisory. Real model runs must accumulate enough evidence before routing changes are considered, and `policy/benchmark.toml` keeps `auto_apply = false`.

## Five pre-registered strategies

Both `quick` and `full` use the same matrix:

| Strategy ID | Execution | Reasoning |
| --- | --- | --- |
| `luna-direct` | Luna implements and repairs | `high` |
| `terra-direct` | Terra implements and repairs | `high` |
| `sol-direct` | Sol implements and repairs | `high` |
| `codex-flow-high` | Sol parent + Luna worker | both `high` |
| `codex-flow-adaptive` | Sol parent + Luna worker | routine `high`, complex `xhigh`, critical `max` |

The first four strategies form the controlled same-effort comparison. `codex-flow-adaptive` is deliberately excluded from the Sol and fixed-flow advantage claims; it is compared only with `codex-flow-high`.

The adaptive policy is class-adaptive and pre-registered before execution. It does not inspect a result and then retroactively change the reasoning effort.

## Balanced corpus

The corpus contains six deterministic engineering tasks, balanced across the three classes:

| Task | Class | Focus |
| --- | --- | --- |
| `routine-query-normalization` | routine | localized Unicode and whitespace behavior |
| `routine-env-precedence` | routine | configuration precedence and edge cases |
| `complex-renew-provider-refactor` | complex | reusable provider registry, validation, and legacy compatibility |
| `complex-config-migration` | complex | deep-copy-safe old/new configuration migration and idempotency |
| `critical-resumable-migration` | critical | validated, journaled, resumable, idempotent migration |
| `critical-atomic-state-write` | critical | durable atomic replacement, permissions, symlink safety, and cleanup |

`benchmark/corpus.json` stores each seed repository, fixed prompt, and verifier. `scripts/materialize-corpus.py` creates independent Git repositories with deterministic seed commits. Verifiers are written outside the worker-writable repository and invoked by absolute path, so a strategy cannot pass by editing its acceptance criteria.

Generate the corpus without calling a model:

```bash
codex-flow benchmark-corpus quick
```

Profiles are defined in `benchmark/profiles.json`:

```text
quick: 6 tasks × 5 strategies × 1 repetition = 30 runs
full:  6 tasks × 5 strategies × 3 repetitions = 90 runs
```

`quick` contains only two samples per class and strategy, so it is a smoke/observational run. `full` contains six samples per class and strategy and meets the default minimum of three samples. Neither profile is launched automatically by install, update, ordinary CI, recommendation automation, or corpus materialization.

## Explicit flow protocol

Direct strategies use one model for implementation and bounded verifier-guided repairs. Flow strategies use explicit, separately metered phases:

```text
fresh clone at fixed commit
        ↓
Sol parent: read-only plan
        ↓
Luna worker: implementation
        ↓
fixed external verifier
        ↓
Sol parent: read-only review
        ↓
pass? ── yes ──> record result
  │
  no
  ↓
Luna worker: bounded delta repair
        ↓
verify and review again
```

The parent never writes the task repository. Flow cost and wall time include both parent and worker calls; token usage is attributed by role, model, and resolved reasoning effort. This makes the strategy comparison an end-to-end measurement instead of pricing only the worker.

Every strategy/repetition starts from a new temporary clone at the configured full commit SHA. A failed external verifier can trigger at most `max_repair_cycles` repairs. Authentication, quota, timeout, or CLI failures are fail-closed and are not treated as implementation defects.

## Manifest schema v2

`benchmark/manifest.schema.json` is the canonical manifest schema and `benchmark/manifest.example.json` contains the complete five-strategy matrix. A compact custom example is:

```json
{
  "schema_version": 2,
  "repetitions": 3,
  "timeout_seconds": 1800,
  "max_repair_cycles": 2,
  "matrix": [
    {"id":"luna-direct","strategy":"direct","model":"gpt-5.6-luna","reasoning_effort":"high"},
    {"id":"terra-direct","strategy":"direct","model":"gpt-5.6-terra","reasoning_effort":"high"},
    {"id":"sol-direct","strategy":"direct","model":"gpt-5.6-sol","reasoning_effort":"high"},
    {
      "id":"codex-flow-high",
      "strategy":"flow",
      "reasoning_policy":"fixed",
      "parent":{"model":"gpt-5.6-sol","reasoning_effort":"high"},
      "worker":{"model":"gpt-5.6-luna","reasoning_effort":"high"}
    },
    {
      "id":"codex-flow-adaptive",
      "strategy":"flow",
      "reasoning_policy":"adaptive",
      "parent":{"model":"gpt-5.6-sol","reasoning_effort":{"routine":"high","complex":"xhigh","critical":"max"}},
      "worker":{"model":"gpt-5.6-luna","reasoning_effort":{"routine":"high","complex":"xhigh","critical":"max"}}
    }
  ],
  "tasks": [{
    "id":"compatibility-refactor",
    "class":"complex",
    "source":"/absolute/path/to/frozen-repo",
    "base_ref":"0123456789abcdef0123456789abcdef01234567",
    "prompt":"Implement the requested change without weakening acceptance criteria.",
    "verify":["python3","/absolute/path/to/external-verifier.py"]
  }]
}
```

The runner enforces fixed string efforts for direct/fixed strategies and complete per-class maps for adaptive flow. Built-in profile materialization additionally enforces one identical effort across all controlled strategies.

Validate or filter a manifest without model calls:

```bash
codex-flow benchmark --manifest manifest.json --dry-run
```

`--only-task`, `--only-model`, and `--only-strategy` support bounded experiments.

## Running and measurement

After materializing the built-in corpus:

```bash
codex-flow benchmark \
  --manifest .codex-flow-benchmark/manifest.json \
  --output benchmark/results/quick-001.jsonl \
  --fail-fast-infrastructure
```

The runner invokes non-interactive, ephemeral `codex exec` sessions with user configuration ignored, an explicit model, and an explicit reasoning effort. Authentication still comes from the user's Codex installation.

Current Codex JSONL provides input, cached-input, and output usage. It does not reliably expose a separate reasoning-token field or a provider-returned final model identifier, so the benchmark records only the requested model/effort and usage fields that can be measured consistently. A wall-clock timeout and repair budget bound execution; wall time is observational rather than deterministic.

Each result row uses `benchmark/schema.json` schema v2. Important fields include:

- `strategy_id`, `strategy`, and `reasoning_policy`
- parent `model`/`reasoning_effort` and optional worker fields
- `passed`, `first_passed`, `repair_cycles`, and `review_cycles`
- top-level aggregate token usage and per-actor `model_usage`
- wall time, source commit, verifier excerpt, and diagnostics

For mixed-model flow rows, top-level usage must exactly equal the sum of `model_usage`. The analyzer and report renderer retain read compatibility with schema-v1 direct results.

## Evidence tests

Analyze with the immutable GPT-5.6 price snapshot:

```bash
codex-flow benchmark-analyze \
  --results benchmark/results/quick-001.jsonl \
  --prices benchmark/prices/gpt-5.6-2026-08-30.json \
  --json
```

Thresholds are pre-registered in `policy/benchmark.toml`. Evidence is marked sufficient only when the compared strategies have the same task/repetition sample keys; partial or unpaired batches remain visible but cannot demonstrate an advantage.

### Sol capability

For each class, Sol/high is compared with the strongest Luna/high or Terra/high direct result. Sol must be no worse on final pass rate and materially improve at least one registered quality measure: final pass rate, first-pass rate, or repairs. Cost is not part of this capability claim.

### Fixed-high flow advantage

`codex-flow-high` must:

- preserve Sol/high final quality within the configured non-inferiority margin;
- reduce total parent+worker reference cost versus Sol/high by the configured amount; and
- materially improve final quality, first-pass quality, or repairs versus Luna/high direct.

This prevents a cheap but lower-quality worker from being labeled a flow advantage and prevents parent usage from disappearing from cost accounting.

### Adaptive reasoning value

`codex-flow-adaptive` is compared only with `codex-flow-high`. It must materially improve final pass rate, first-pass rate, or repairs while remaining inside the configured cost-increase ceiling. Its result cannot be used to claim that Sol or fixed-high flow won a same-effort comparison.

The analyzer also applies class quality gates before recommending the lowest-cost eligible strategy:

```toml
[quality]
routine_min_pass_rate = 0.90
complex_min_pass_rate = 0.95
critical_min_pass_rate = 1.00
min_samples_per_configuration = 3
max_average_repair_cycles = 1.0
```

A `null` recommendation means no tested strategy has enough evidence to pass the class gate.

## Reporting and interpretation

`scripts/render-benchmark-report.py` produces four views:

- aggregate strategy quality, repairs, reviews, wall time, and mixed-model reference cost;
- Sol same-effort capability evidence;
- fixed-high flow evidence against Sol and Luna;
- adaptive reasoning evidence against fixed-high flow.

Dollar values use the immutable `benchmark/prices/gpt-5.6-2026-08-30.json` API snapshot. They are API-equivalent reference costs, not ChatGPT subscription charges.

The corpus is a controlled calibration set, not a claim of broad production representativeness. Future additions should preserve class balance, use frozen starting commits and external acceptance criteria, and add languages, larger codebases, dependency migrations, CI/CD work, and infrastructure changes. Model and strategy comparisons are meaningful only when they begin from equivalent state and keep the controlled reasoning effort fixed.
