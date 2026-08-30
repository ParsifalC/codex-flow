# Benchmark-driven routing

`codex-flow` v0.4 adds an advisory benchmark layer for calibrating worker model and reasoning choices with real Codex task results.

It does **not** fabricate benchmark data and it does **not** automatically rewrite release routing. The benchmark must first accumulate real runs.

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

## Result format

Each real benchmark run is one JSON object (JSONL is recommended):

```json
{"schema_version":1,"task_id":"refactor-001","task_class":"complex","model":"gpt-5.6-luna","reasoning_effort":"xhigh","passed":true,"input_tokens":180000,"cached_input_tokens":30000,"output_tokens":50000,"repair_cycles":1}
```

The schema is documented in `benchmark/schema.json`.

Required measurements:

- task id and class
- actual worker model
- actual reasoning effort
- pass/fail against fixed acceptance criteria
- input tokens
- cached input tokens
- output/reasoning tokens reported as output tokens by the runtime/accounting surface
- repair cycles

Optional measurements include wall time, source commit, and notes.

## Price snapshot

Cost analysis uses a separate immutable price snapshot so old benchmark reports remain reproducible when future model prices change.

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
python3 scripts/analyze-benchmark.py \
  --results path/to/results.jsonl \
  --prices path/to/prices.json \
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

The deterministic fixture demonstrates this intentionally:

- Luna/high wins `routine` because it passes the quality gate and is cheaper.
- Luna/xhigh fails the `complex` pass-rate gate in the fixture.
- Terra/xhigh therefore wins `complex` despite higher per-token pricing.
- Critical routing requires 100% pass rate by default.

## Promotion policy

`policy/benchmark.toml` currently sets:

```toml
[promotion]
auto_apply = false
```

This means benchmark conclusions should be reviewed before changing release policy or routing behavior.

A future version may generate routing-policy PRs after stronger statistical safeguards are added, but installed users should never be silently switched based on a small or noisy sample.

## Building a useful corpus

A real corpus should contain repeated, deterministic tasks across several engineering domains instead of one repository only. Useful categories include:

- localized bug fixes
- multi-file refactors
- test-driven feature implementation
- CI/CD workflow repairs
- dependency or configuration migrations
- compatibility-preserving API changes
- infrastructure changes with strict validation

Each task should have frozen acceptance criteria and a reproducible starting commit/worktree. Model/config comparisons are meaningful only when they start from equivalent state.
