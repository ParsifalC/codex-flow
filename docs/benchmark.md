# Benchmark-driven routing

`codex-flow` v0.5 includes a real Codex benchmark runner plus the advisory analyzer introduced in v0.4.

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

## Real runner

A benchmark manifest freezes the task source, starting ref, prompt, verifier, model matrix, repetition count, timeout, and repair budget. See `benchmark/manifest.schema.json` and `benchmark/manifest.example.json`.

Minimal shape:

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
    "verify":["python3","tests/verify_task.py"]
  }]
}
```

Run it after installing codex-flow:

```bash
codex-flow benchmark \
  --manifest benchmark-real.json \
  --output benchmark/results/run-001.jsonl
```

Or invoke the script directly:

```bash
python3 scripts/run-benchmark.py \
  --manifest benchmark-real.json \
  --output benchmark/results/run-001.jsonl
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
fixed verifier argv
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

The verifier is an argv array rather than an arbitrary shell string. Benchmark tasks should keep verifier code inside the frozen source repo and explicitly tell the model not to modify or weaken it.

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

## Price snapshot

Cost analysis uses a separate immutable price snapshot so old reports remain reproducible when future model prices change.

Example:

```json
{
  "gpt-5.6-luna": {"input": 0.20, "cached_input": 0.02, "output": 1.20},
  "gpt-5.6-terra": {"input": 2.00, "cached_input": 0.20, "output": 12.00}
}
```

Prices are dollars per 1M tokens.

## Analyze

```bash
codex-flow benchmark-analyze \
  --results benchmark/results/run-001.jsonl \
  --prices benchmark-prices.json \
  --json
```

or:

```bash
python3 scripts/analyze-benchmark.py \
  --results benchmark/results/run-001.jsonl \
  --prices benchmark-prices.json \
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

The deterministic analyzer fixture demonstrates this intentionally:

- Luna/high wins `routine` because it passes the quality gate and is cheaper.
- Luna/xhigh fails the `complex` pass-rate gate in the fixture.
- Terra/xhigh therefore wins `complex` despite higher per-token pricing.
- Critical routing requires 100% pass rate by default.

The deterministic runner test separately uses a fake Codex executable and a temporary Git repository to prove that fresh checkout, failed verification, one repair, token aggregation, and final pass are recorded correctly without spending real model tokens.

## Promotion policy

`policy/benchmark.toml` currently sets:

```toml
[promotion]
auto_apply = false
```

Benchmark conclusions must therefore be reviewed before changing release routing. Installed users should never be silently switched based on a small or noisy sample.

## Building a useful corpus

A real corpus should contain repeated, deterministic tasks across several engineering domains instead of one repository only. Useful categories include localized bug fixes, multi-file refactors, test-driven feature implementation, CI/CD workflow repairs, dependency/configuration migrations, compatibility-preserving API changes, and infrastructure changes with strict validation.

Each task needs frozen acceptance criteria and a reproducible starting commit. Model/config comparisons are meaningful only when they start from equivalent state.
