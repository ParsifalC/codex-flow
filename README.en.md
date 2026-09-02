# codex-flow

[简体中文](README.md) | **English**

Low-friction, capability-aware multi-agent orchestration defaults for Codex. The default orchestration skill is **FlowPilot** (`flow-pilot`).

**Use a qualifying high-capability parent to decide. Use an efficient worker to execute. Increase reasoning only when the task proves it needs more.**

`codex-flow` routes by model capability and task complexity instead of permanently pinning one model slug or one reasoning level. It also records deterministic Parent/Worker participation, usage, and account quota-window movement without invoking another model to produce the summary.

## Default strategy

```text
SMALL      -> qualifying parent handles directly
ROUTINE    -> parent plans(high) -> worker executes(high) -> parent reviews(high)
COMPLEX    -> parent plans(high/xhigh) -> worker executes(high/xhigh) -> parent reviews(high/xhigh)
CRITICAL   -> quality-first escalation; xhigh/max only when justified
```

A parent qualifies by policy, not by name. Defaults prefer the latest available high-capability model, require parent reasoning `>= high`, keep the exact model floor configurable, and choose the worker independently. `gpt-5.6-sol/xhigh` is therefore a valid example, not a requirement.

## FlowPilot

FlowPilot owns task classification, routing, reasoning effort, worker delegation, review, and bounded repair. It is not a fixed model and is broader than a cost-saving rule: it chooses sufficient capability and parallelism while preserving the quality gate.

Installed skill:

```text
~/.codex/skills/flow-pilot/SKILL.md
```

## Per-task routing override

Users can explicitly override subagent routing for the current task without changing persistent configuration.

```text
direct     -> do not use subagents for this task
delegate   -> explicitly prefer subagent execution for this task
adaptive   -> use normal FlowPilot routing for this task
```

Natural-language equivalents are supported when the intent is unambiguous, for example:

```text
Do not use subagents; complete this directly.
Do this one directly.
Skip the worker.
Do not delegate.

Use a subagent.
Have the worker implement this task.

Use the default strategy.
Automatically decide whether to use a subagent.
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

The management command is installed under `~/.local/bin`. When the default shell is Bash or zsh, installation also adds one marked, idempotent block to the corresponding shell rc file. That block adds the CLI directory to `PATH` and registers subcommand completion, including `usage last`, `benchmark-local quick|full`, and `benchmark-corpus quick|full`.

After installation, **fully quit Codex and open it again**; starting a new task alone is not enough. After the restart, start a new task/turn because an already-running turn cannot rebuild its starting snapshot. When telemetry is enabled, run `/hooks` and approve FlowPilot telemetry there if it is pending approval. When telemetry is disabled, no hook authorization is required, but you must still fully restart Codex and start a new task/turn.

FlowPilot telemetry merges managed command hooks into `~/.codex/hooks.json` without replacing unrelated user hooks. Because Codex applies a security trust flow to command hooks, **the first installation or a later hook-content change may require one trust approval**. If Codex prompts, inspect and approve the hooks with `/hooks`. Normal tasks require no additional action after approval. With telemetry disabled, these hooks are not installed and no hook authorization is required.

Shell selection follows `CODEX_FLOW_SHELL` when set, otherwise the basename of `SHELL`. Use `CODEX_FLOW_SHELL_CONFIG_DIR` to place the managed shell files in another configuration directory.

## Deterministic task summary

Telemetry is enabled by default and treats **one user turn as one flow run**. Codex lifecycle hooks record participation and provide Parent/Worker transcripts; the collector computes each turn from native `token_count` events. The locally authenticated `codex app-server` supplies rate-limit snapshots plus estimated credits/cost when a thread billing route is available. Formatting is pure Python and does not trigger another LLM inference.

It records, when available:

- Parent and participating Worker count, type, model, observed reasoning effort, and status
- turn-level input, cached input, output, reasoning output, and total tokens from Parent/Worker transcripts
- estimated credits and optional cost when the server billing route exposes them
- account rate-limit `usedPercent` (consumed percentage) before and after the run, including remaining percentage and movement
- Desktop session name, with a local session-index fallback when a new thread is not materialized by app-server yet

Example:

```text
FlowPilot summary
  participants  1 parent + 3 workers
  parent        gpt-5.6-sol (high)   82.4k tokens
  worker        worker-explorer     gpt-5.6-luna (high)  116.8k tokens  completed
  worker        worker-implementer  gpt-5.6-luna (xhigh) 401.2k tokens  completed
  worker        worker-implementer  gpt-5.6-luna (high)   68.4k tokens  completed
  attributed    668.8k tokens  1.840 credits
  account quota (used) 5h 31%→34% (+3 pp; 66% remaining); 7d 18%→19% (+1 pp; 81% remaining)
```

Two measurements are deliberately kept separate:

- **Attributed tokens** come from the hook-provided Parent/Worker transcripts and are calculated from cumulative counters for the current turn. They remain unavailable only when the current rollout token shape cannot be recognized.
- **Estimated credits/cost** are added only when app-server exposes a thread billing route. They are never inferred from token counts or account balance.
- **Account quota** `usedPercent` is the consumed percentage, not the remaining percentage; `remaining` is calculated from that official value. The API exposes an integer percentage snapshot, so a short run can show `70% → 70% (no change)` when it does not cross a whole percentage point; this is not a hard-coded value.
- **Account quota change during run** is account-wide. Concurrent Codex sessions can also move the same quota window, so that delta is never presented as exclusive consumption by this flow.

`summary = true` controls whether the Stop hook emits a separate summary through Codex's supported `systemMessage` channel; it does not rewrite the assistant's already-generated final prose. If the active UI does not surface that system message, use `usage last` below. `summary = false` suppresses the message without disabling collection.

By default, macOS Notification Center also receives a short notification after each completed parent run with the project, worker count, total tokens, and duration. It does not include the full prompt or summary body. Disable it with `notifications = false` or `CODEX_FLOW_TELEMETRY_NOTIFICATIONS=false`. Every run is stored as its own JSON file under `~/.codex/codex-flow/telemetry/runs/` and retained for 30 days by default; use `retention_days` or `CODEX_FLOW_TELEMETRY_RETENTION_DAYS` to change the period. `last.json` remains a pointer to the most recently completed run.

Worker correlation uses a durable `agent_id` index first, then parent/worker lifecycle windows as a fallback. Orphans written by older collectors are merged on the next parent Stop; their source files remain with `merged_into` / `worker_sources` provenance until retention expires.

Telemetry is fail-open. Missing app-server capabilities, transcript token events, or usage fields never fail the task; only those statistics become unavailable.

Re-open the last result or consume its raw JSON with:

```bash
codex-flow usage last
codex-flow usage last --json
```

To install without telemetry hooks:

```bash
CODEX_FLOW_TELEMETRY_ENABLED=false bash install.sh
```

On Windows, set the same environment variable before running `install.ps1`.

## Daily Management & Interactive Console

Run `codex-flow` without arguments in any interactive terminal to open the Moyu-style management console, allowing you to browse recent runs, list task history, view project aggregations, run diagnostics, and trigger benchmarks.

```bash
# Interactive Management Console
codex-flow

# Core Status & Diagnostics
codex-flow status
codex-flow doctor
codex-flow update
codex-flow uninstall

# Telemetry & Usage Analytics
codex-flow usage last                      # Last task summary
codex-flow usage list                      # Task history table (-n 10, -p <project>, --today)
codex-flow usage show 1                    # Inspect #1 task details card (or by run ID)
codex-flow usage stats                     # 30-day project aggregation & worker offload ratio
codex-flow usage stats --json              # Structured JSON for external analysis

# Benchmark
codex-flow benchmark-local quick
```

`update` fast-forwards the original checkout, preserves explicit model/reasoning pins and the telemetry switch, reruns installation, and resolves only `auto` values against new release recommendations.

## Adaptive policy

Installation creates `~/.codex/codex-flow.toml` similar to:

```toml
schema_version = 3

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

[telemetry]
enabled = true
summary = true
notifications = true
retention_days = 30
source = "hooks+app-server"
```

`model = "auto"` follows release recommendations; a concrete model remains pinned across updates. The active parent is never hard-pinned by recommendation metadata.

## Built-in benchmark corpus

The deterministic six-task corpus is balanced across two routine, two complex, and two critical tasks. It measures direct-model capability, fixed-effort flow value, and adaptive reasoning separately. It covers localized fixes, configuration precedence, registry compatibility refactoring, alias-safe configuration migration, resumable data migration, and crash-durable state persistence.

Profiles:

```text
quick
  6 tasks × 5 strategies × 1 repetition = 30 runs
  Luna direct/high
  Terra direct/high
  Sol direct/high
  Flow fixed: Sol parent/high + Luna worker/high
  Flow adaptive: routine=high, complex=xhigh, critical=max

full
  6 tasks × 5 strategies × 3 repetitions = 90 runs
  the same five strategies as quick
```

The three direct strategies and fixed flow all use `high`, so model and workflow conclusions are not confounded by reasoning effort. Adaptive flow is analyzed separately. Flow explicitly executes `Sol read-only plan → Luna implementation → external verifier → Sol read-only review → Luna delta repair`, with parent and worker usage attributed separately. Every task gets a deterministic seed commit and an external verifier outside the writable task repository.

Quick has only two samples per class and is observational. Full provides six samples per class/strategy and satisfies the default evidence threshold.

## Recommended real run: local Codex session

The local authenticated Codex session is the primary real-benchmark path. No API key is required when your local Codex CLI is already authenticated through ChatGPT or another supported local login method.

```bash
codex-flow update
codex-flow benchmark-local quick
```

The command checks git/Python/Codex, materializes the frozen quick corpus, validates 30 planned runs with a dry-run, shows a quota/token warning, requires the exact confirmation `RUN QUICK 30`, executes the real benchmark, fails fast on zero-usage infrastructure/authentication failures, analyzes the results, and renders a Markdown report.

By default it writes timestamped files under `benchmark/results/`:

```text
quick-<timestamp>.jsonl
quick-<timestamp>.analysis.json
quick-<timestamp>.report.md
quick-<timestamp>.meta.json
```

For the first quick run, budget roughly up to ~15M total tokens as a conservative planning ceiling. Flow planning/review and repair loops add usage, and actual consumption can differ substantially.

### Cost semantics

When the benchmark is run through a ChatGPT/Codex subscription, dollar figures are **API-equivalent reference costs only**. They provide a normalized comparison using the pinned API price snapshot and are not the actual amount charged against the ChatGPT subscription.

Primary measurements are final and first-pass rates, repair/review cycles, input/cached/output tokens, total token efficiency, wall time, and API-equivalent reference cost. Flow cost includes both parent and worker usage.

## Lower-level benchmark commands

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

The analyzer reports same-effort Sol capability evidence, fixed-flow value versus Sol and Luna, and adaptive-flow value versus fixed flow before applying quality-first cost routing. Benchmark conclusions remain advisory; `policy/benchmark.toml` keeps `auto_apply = false`.

## Optional API-key GitHub Actions benchmark

`.github/workflows/benchmark-quick.yml` remains available as an optional headless execution path for users with an OpenAI API key. It is manual `workflow_dispatch` only, requires `OPENAI_API_KEY` plus the exact confirmation `RUN QUICK 30`, exposes only the quick profile, and uploads result artifacts. Normal CI never invokes it.

## Automatic model recommendations

`scripts/check-recommendation.py` and `.github/workflows/model-recommendation.yml` conservatively inspect OpenAI official model documentation and maintain release recommendations through reviewable PRs. The active parent remains policy-driven; worker `auto` recommendations change only through release defaults and explicit user updates.

## Measurement boundaries

Benchmarking and normal FlowPilot telemetry use separate measurement paths. Benchmarks keep their reproducible JSONL experiment contract. Interactive token attribution reads hook-provided transcripts, while billing and quota data come from app-server. Billing fields the server does not expose remain unavailable; subscription quota is never inferred from token counts.

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
CODEX_FLOW_TELEMETRY_ENABLED      default: true
CODEX_FLOW_TELEMETRY_NOTIFICATIONS default: true (macOS Notification Center)
CODEX_FLOW_TELEMETRY_RETENTION_DAYS default: 30
CODEX_FLOW_BIN_DIR                default: ~/.local/bin
CODEX_FLOW_SHELL                  default: basename of SHELL (Bash/zsh auto-configured)
CODEX_FLOW_SHELL_CONFIG_DIR       default: HOME
```

## CI

Normal CI never invokes a paid model. It validates shell/Python/PowerShell syntax, model recommendation fixtures, benchmark analysis/reporting, runner isolation/repair/token aggregation and infrastructure fail-fast behavior, deterministic corpus generation, FlowPilot routing-override installation, deterministic telemetry fixtures and hook lifecycle management, and Unix/Windows installer/update flows.

## Current Status

Private preview, version `1.2.0`. FlowPilot is the default orchestration skill. Per-task `direct`, `delegate`, and `adaptive` overrides remain explicit and non-persistent. Normal-task telemetry is enabled by default and adds no model inference. Model recommendation changes remain reviewable; benchmark routing remains advisory; real benchmark execution remains explicit; explicit user pins remain authoritative. Includes native macOS real-time floating widget support.
