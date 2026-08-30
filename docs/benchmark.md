# Benchmark-driven routing

`codex-flow` v0.6 includes a deterministic built-in corpus, the real Codex runner from v0.5, and the advisory analyzer introduced in v0.4.

It does **not** fabricate benchmark data and it does **not** automatically rewrite release routing. Real model runs must first accumulate enough evidence.

## Goal

Model routing should optimize for **quality first, cost second**.

For each task class (`routine`, `complex`, `critical`) the analyzer:

1. groups runs by model + reasoning effort
2. checks minimum sample count
3. checks task-class pass-rate threshold
4. checks average repair-cycle threshold
5. rejects configurations that fail the quality gate
6. among the remaining configurations, chooses the lowest average dollar cost

Default gates live in `policy/benchmark.toml`:

```toml
[quality]
routine_min_pass_rate = 0.90
complex_min_pass_rate = 0.95
critical_min_pass_rate = 1.00
min_samples_per_configuration = 3
max_average_repair_cycles = 1.0
```

These are intentionally conservative starting values, not universal truths.

## Built-in v0.6 corpus

The first corpus contains six deterministic engineering tasks:

| Task | Class | Focus |
| --- | --- | --- |
| `routine-query-normalization` | routine | localized Unicode/whitespace bug |
| `routine-env-precedence` | routine | configuration precedence and edge cases |
| `complex-renew-provider-refactor` | complex | multi-file provider dispatch with legacy API compatibility |
| `complex-config-migration` | complex | backward-compatible old/new configuration migration |
| `complex-bounded-retry` | complex | precise retry/error semantics and attempt accounting |
| `critical-atomic-state-write` | critical | crash-safe atomic state replacement and cleanup |

`benchmark/corpus.json` stores the seed files, fixed task prompt, and verifier for each task. `scripts/materialize-corpus.py` turns those definitions into independent Git repositories.

Materialization is deterministic: seed commits use fixed author metadata and timestamps, so an unchanged corpus produces the same commit SHA on different machines. Verifiers are written **outside** each writable task repository and the generated manifest invokes them by absolute path. A benchmark worker therefore cannot pass by weakening or editing its verifier.

Generate the low-cost comparison set without calling any model:

```bash
codex-flow benchmark-corpus quick
```

This creates `.codex-flow-benchmark/manifest.json` and six frozen task repositories. The command prints the planned run count and stops; it does not execute Codex.

Profiles are defined in `benchmark/profiles.json`:

```text
quick
  6 tasks × 3 configs × 1 repetition = 18 runs
  Luna/high
  Terra/xhigh
  Sol/high

full
  6 tasks × 5 configs × 3 repetitions = 90 runs
  Luna/high
  Luna/xhigh
  Terra/high
  Terra/xhigh
  Sol/high
```

`full` can incur substantial real model usage. It is deliberately never launched by install, update, CI, recommendation automation, or corpus materialization. A user must explicitly run the generated manifest.

The bundled GPT-5.6 price snapshot is `benchmark/prices/gpt-5.6-2026-08-30.json`. Price snapshots are immutable benchmark inputs rather than live billing lookups, so reports remain reproducible after future price changes.

## Real runner

A benchmark manifest freezes the task source, starting ref, prompt, external verifier, model matrix, repetition count, timeout, and repair budget. See `benchmark/manifest.schema.json` and `benchmark/manifest.example.json`.

Run the built-in quick corpus after materializing it:

```bash
codex-flow benchmark \
  --manifest .codex-flow-benchmark/manifest.json \
  --output benchmark/results/quick-001.jsonl
```

For custom tasks, the minimal manifest shape is:

```json
{
  "schema_version": 1,
  "repetitions": 3,
  "timeout_seconds": 1800,
  "max_repair_cycles": 2,
  "matrix": [
    {"model":"gpt-5.6-luna","reasoning_effort":"high"},
    {"model":"gpt-5.6-terra","reasoning_effort":"xhigh"}
  ],
  "tasks": [{
    "id":"localized-fix-001",
    "class":"routine",
    "source":"/absolute/path/to/frozen-repo",
    "base_ref":"<full-commit-sha>",
    "prompt":"Implement the fixed task without changing the verifier.",
    "verify":["python3","/absolute/path/to/verify_task.py"]
  }]
}
```

Use `--dry-run` to validate/filter a manifest without spending model tokens. `--only-task` and `--only-model` support bounded experiments.

## Isolation and repair semantics

Every model/effort/repetition run starts from a new temporary clone and detached checkout of the configured `base_ref`. This prevents one configuration from inheriting another configuration's edits.

The runner performs:

```text
fresh clone at fixed commit
        ↓
codex exec with requested model/effort
        ↓
fixed external verifier argv
        ↓
pass? ── yes ──> record result
  │
  no
  ↓
bounded repair prompt with verifier output
        ↓
same model/effort repairs
        ↓
verify again
```

Repair cycles are part of the measurement because a cheap first attempt that repeatedly fails can be more expensive end-to-end than a more capable worker.

For benchmark integrity, keep verifier code outside the writable task repo whenever possible. The built-in corpus does this automatically. Custom manifests should also use an immutable/external verifier or independently verify that the worker did not modify acceptance logic.

Infrastructure failures are fail-closed: if `codex exec` exits non-zero because of authentication, quota, timeout, CLI/configuration failure, or another execution error, the run is recorded as failed and the runner does not spend repair cycles trying to treat infrastructure failure as an implementation defect.

## Codex invocation

The runner currently uses the non-interactive JSONL surface roughly equivalent to:

```bash
codex exec \
  --ephemeral \
  --json \
  --ignore-user-config \
  --sandbox workspace-write \
  --model <model> \
  -c 'model_reasoning_effort="<effort>"' \
  --cd <fresh-clone> \
  <prompt>
```

User configuration is ignored for benchmark execution so local defaults do not silently change a comparison. Authentication still comes from the user's normal Codex installation.

## Measurement boundaries

Current `codex exec --json` terminal events expose `input_tokens`, `cached_input_tokens`, and `output_tokens`. The runner sums those fields across the initial attempt and every repair attempt.

Current Codex JSONL does not reliably expose a separate reasoning-token field, so codex-flow does not invent one. Reasoning usage remains represented through the accounting fields Codex actually reports.

The runner records the **requested** model and reasoning effort. Current Codex JSONL also does not reliably provide the provider-returned model identifier, so the result should not be interpreted as independent proof that a provider alias resolved to a specific backend model.

Codex also does not currently provide a stable deterministic `max-agent-turns` control for `exec`; the runner therefore uses a wall-clock timeout plus a fixed repair-cycle budget. Keep tasks bounded and compare repeated samples rather than treating wall time as deterministic agent work.

## Result format

Each run is one JSON object in JSONL:

```json
{"schema_version":1,"task_id":"refactor-001","task_class":"complex","model":"gpt-5.6-luna","reasoning_effort":"xhigh","passed":true,"input_tokens":180000,"cached_input_tokens":30000,"output_tokens":50000,"repair_cycles":1,"wall_time_seconds":84.2,"source_commit":"...","repetition":1,"codex_exit_code":0,"verification_excerpt":"","diagnostic_excerpt":""}
```

The canonical result schema is `benchmark/schema.json`.

## Analyze

Analyze a built-in GPT-5.6 corpus run with the immutable snapshot:

```bash
codex-flow benchmark-analyze \
  --results benchmark/results/quick-001.jsonl \
  --prices benchmark/prices/gpt-5.6-2026-08-30.json \
  --json
```

The result is advisory:

```json
{
  "advisory_only": true,
  "recommendations": {
    "routine": {"model":"...","reasoning_effort":"high"},
    "complex": {"model":"...","reasoning_effort":"xhigh"},
    "critical": null
  }
}
```

`null` means no tested configuration has enough evidence to pass that class's quality gate.

## Why quality comes first

A cheaper model can consume less money per attempt but still cost more end-to-end if it causes repeated repairs, parent rework, or failed acceptance criteria.

The analyzer therefore never selects a configuration solely because its token price is lower. A configuration must first meet the class-specific quality and repair thresholds.

The deterministic analyzer fixture demonstrates this intentionally: Luna/high wins `routine` when it meets the gate and is cheaper, while a failing Luna/xhigh complex configuration is rejected and Terra/xhigh wins despite higher per-token pricing. Critical routing requires 100% pass rate by default.

The deterministic runner test separately uses a fake Codex executable and a temporary Git repository to prove fresh checkout, failed verification, one repair, token aggregation, fail-closed infrastructure handling, and final pass without spending real model tokens. Corpus CI additionally proves that all six seeds initially fail their verifier and that materialized commit SHAs are deterministic.

## Promotion policy

`policy/benchmark.toml` currently sets:

```toml
[promotion]
auto_apply = false
```

Benchmark conclusions must therefore be reviewed before changing release routing. Installed users should never be silently switched based on a small or noisy sample.

## Growing the corpus

The built-in v0.6 tasks are a first calibration set, not a claim of broad production representativeness. Future tasks should add different languages, larger codebases, CI/CD workflows, dependency migrations, compatibility-preserving API changes, and infrastructure changes with strict validation.

Each task needs frozen acceptance criteria and a reproducible starting commit. Model/config comparisons are meaningful only when they start from equivalent state.
