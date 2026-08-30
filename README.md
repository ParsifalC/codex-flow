# codex-flow

Fast, low-friction cost-aware multi-agent defaults for Codex.

**Use a qualifying high-capability parent to decide. Use a cheaper worker to execute. Increase reasoning only when the task proves it needs more.**

`codex-flow` is capability-driven rather than tied to one permanent model slug or one fixed reasoning level.

## Default strategy

```text
SMALL      -> qualifying parent handles directly
ROUTINE    -> parent plans(high) -> worker executes(high) -> parent reviews(high)
COMPLEX    -> parent plans(high/xhigh) -> worker executes(high/xhigh) -> parent reviews(high/xhigh)
CRITICAL   -> quality-first escalation; xhigh/max only when justified
```

A parent qualifies by policy, not by name. Defaults prefer the latest available high-capability model, require parent reasoning `>= high`, keep the exact model floor configurable, and choose the worker independently. `gpt-5.6-sol/xhigh` is therefore a valid example, not a requirement.

## Per-task routing override

Users can explicitly override subagent routing for the current task without changing persistent configuration.

```text
direct     -> do not use subagents for this task
delegate   -> explicitly prefer subagent execution for this task
adaptive   -> use normal codex-flow routing for this task
```

Natural-language equivalents are supported when the intent is unambiguous, for example:

```text
不要使用子 agent，直接完成
这次直接做
跳过 worker
不用 delegation

使用子 agent
这次交给 worker 实现

按默认策略
自动决定是否使用子 agent
```

A current-task routing instruction takes priority over codex-flow defaults and persistent routing policy, but applies only to that task and is never written back to user configuration. If multiple routing instructions conflict in the same task, the latest unambiguous instruction wins.

`direct` disables delegation only. Classification, adaptive reasoning effort, validation, acceptance criteria, bounded repair, and review still apply. The workflow becomes `parent -> implementation -> self-review` instead of `parent -> worker -> parent review`.

## Install

### macOS / Linux

```bash
git clone git@github.com:ParsifalC/codex-flow.git
cd codex-flow
bash install.sh
```

### Windows PowerShell

```powershell
git clone git@github.com:ParsifalC/codex-flow.git
cd codex-flow
.\install.ps1
```

The management command is installed under `~/.local/bin`. Restart Codex after installation, then use Codex normally.

## Daily management

```bash
codex-flow status
codex-flow doctor
codex-flow update
codex-flow benchmark-local quick
codex-flow uninstall
```

`update` fast-forwards the original checkout, preserves explicit user pins, reruns installation, and resolves only `auto` values against new release recommendations.

## Adaptive policy

Installation creates `~/.codex/codex-flow.toml` similar to:

```toml
schema_version = 2

[parent]
model_policy = "latest-capable"
min_model = "auto"
min_reasoning_effort = "high"
reasoning_policy = "adaptive"
routine_effort = "high"
complex_effort = "xhigh"
critical_effort = "max"

[worker]
model_policy = "latest-efficient"
model = "auto"
resolved_model = "gpt-5.6-luna"
min_reasoning_effort = "high"
reasoning_policy = "adaptive"
routine_effort = "high"
complex_effort = "xhigh"
critical_effort = "max"

[runtime]
max_concurrent_threads = 4
max_repair_cycles = 2
```

`model = "auto"` follows release recommendations; a concrete model remains pinned across updates. The active parent is never hard-pinned by recommendation metadata.

## Built-in benchmark corpus

The deterministic six-task corpus covers localized bug fixing, configuration precedence, multi-file compatibility refactoring, configuration migration, bounded retry semantics, and crash-safe state persistence.

Profiles:

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

Every task gets a deterministic seed commit and an external verifier outside the writable task repository.

## Recommended real run: local Codex session

v0.8 makes the local authenticated Codex session the primary real-benchmark path. No API key is required when your local Codex CLI is already authenticated through ChatGPT or another supported local login method.

Run:

```bash
codex-flow update
codex-flow benchmark-local quick
```

The command performs the whole flow:

```text
check git/python/codex
show codex CLI version
        ↓
materialize frozen quick corpus
        ↓
dry-run validate 18 planned runs
        ↓
show quota/token warning
        ↓
require confirmation:
RUN QUICK 18
        ↓
run 18 real Codex executions
        ↓
fail fast on zero-usage infrastructure/auth failures
        ↓
analyze results
        ↓
render Markdown report
```

By default it writes timestamped files under `benchmark/results/`:

```text
quick-<timestamp>.jsonl
quick-<timestamp>.analysis.json
quick-<timestamp>.report.md
quick-<timestamp>.meta.json
```

The metadata records the Codex CLI version, codex-flow commit, local-auth execution mode, manifest path, and result/report paths.

For the first quick run, budget roughly up to ~5M total tokens as a conservative planning ceiling. Actual use can be much lower or higher depending on tool loops and repair attempts.

### Cost semantics

When the benchmark is run through a ChatGPT/Codex subscription, the dollar figures in reports are **API-equivalent reference costs only**. They are calculated from a pinned API price snapshot to compare configurations consistently; they are **not** the actual amount charged against the ChatGPT subscription.

The primary measurements for subscription use are therefore:

- pass rate
- repair cycles
- input/cached/output tokens
- total token efficiency
- wall time
- API-equivalent reference cost for normalized model comparison

## Lower-level benchmark commands

You can still run each stage separately:

```bash
codex-flow benchmark-corpus quick

codex-flow benchmark \
  --manifest .codex-flow-benchmark/manifest.json \
  --output benchmark/results/quick-001.jsonl \
  --fail-fast-infrastructure

codex-flow benchmark-analyze \
  --results benchmark/results/quick-001.jsonl \
  --prices benchmark/prices/gpt-5.6-2026-08-30.json \
  --json
```

The analyzer applies quality gates before comparing reference cost. Benchmark conclusions remain advisory; `policy/benchmark.toml` keeps `auto_apply = false`.

## Optional API-key GitHub Actions benchmark

`.github/workflows/benchmark-quick.yml` remains available as an optional headless execution path for users who have an OpenAI API key. It is not the default benchmark route.

It is manual `workflow_dispatch` only, requires `OPENAI_API_KEY` plus the exact confirmation `RUN QUICK 18`, exposes only the 18-run quick profile, and uploads results/analysis/report metadata as an artifact. Normal CI never invokes it.

## Automatic model recommendations

`scripts/check-recommendation.py` and `.github/workflows/model-recommendation.yml` conservatively inspect OpenAI official model documentation and maintain release recommendations through reviewable PRs. The active parent remains policy-driven; worker `auto` recommendations change only through release defaults and explicit user updates.

## Measurement boundaries

Current Codex JSONL reports input/cached/output usage but not a reliably separate reasoning-token field, and it does not reliably expose the provider-returned model identifier. Results therefore record the requested model/effort and the accounting fields Codex actually emits.

Full methodology: `docs/benchmark.md`.
Optional Actions setup: `docs/benchmark-actions.md`.

## Install-time overrides

```text
CODEX_FLOW_PARENT_MODEL_POLICY    default: latest-capable
CODEX_FLOW_PARENT_MIN_MODEL       default: auto
CODEX_FLOW_PARENT_MIN_EFFORT      default: high
CODEX_FLOW_WORKER_MODEL_POLICY    default: latest-efficient
CODEX_FLOW_WORKER_MODEL           default: auto
CODEX_FLOW_WORKER_MIN_EFFORT      default: high
CODEX_FLOW_MAX_THREADS            default: 4
CODEX_FLOW_MAX_REPAIR_CYCLES      default: 2
CODEX_FLOW_BIN_DIR                default: ~/.local/bin
```

## CI

Normal CI never invokes a paid model. It validates shell/Python/PowerShell syntax, model recommendation fixtures, quality-first benchmark analysis, report rendering, runner isolation/repair/token aggregation and infrastructure fail-fast behavior, deterministic corpus generation, routing-override skill installation, and installer/update flows.

## Status

Private preview, version 0.8.1. Local authenticated benchmarking is the primary real-data path. Per-task `direct`, `delegate`, and `adaptive` routing overrides are explicit and non-persistent. Model recommendation changes remain reviewable; benchmark routing remains advisory; real benchmark execution is always explicit; explicit user pins remain authoritative.
