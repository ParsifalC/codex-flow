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

Starting with `0.9.0`, installation/upgrades remove the legacy `cost-aware-development` skill so the same routing policy cannot be loaded twice.

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

The management command is installed under `~/.local/bin`. When the default shell is Bash or zsh, installation also adds one marked, idempotent block to the corresponding shell rc file. That block adds the CLI directory to `PATH` and registers subcommand completion, including `usage last`, `benchmark-local quick|full`, and `benchmark-corpus quick|full`. Restart Codex after installation, then use it normally.

FlowPilot telemetry merges managed command hooks into `~/.codex/hooks.json` without replacing unrelated user hooks. Because Codex applies a security trust flow to command hooks, **the first installation or a later hook-content change may require one trust approval**. If Codex prompts, inspect and approve the hooks with `/hooks`. Normal tasks require no additional action after approval.

Shell selection follows `CODEX_FLOW_SHELL` when set, otherwise the basename of `SHELL`. Use `CODEX_FLOW_SHELL_CONFIG_DIR` to place the managed shell files in another configuration directory.

## Deterministic task summary

Telemetry is enabled by default and treats **one user turn as one flow run**. Codex lifecycle hooks record participation; the locally authenticated `codex app-server` supplies thread usage and rate-limit snapshots; formatting is pure Python and does not trigger another LLM inference.

It records, when available:

- Parent and participating Worker count, type, model, and observed status
- thread-level input, cached input, output, and total tokens
- estimated credits and optional cost when the server billing route exposes them
- account rate-limit `usedPercent` before and after the run, reported as percentage-point movement

Example:

```text
FlowPilot summary
  participants  1 parent + 3 workers
  parent        gpt-5.6-sol   82.4k tokens
  worker        worker-explorer     gpt-5.6-luna  116.8k tokens  completed
  worker        worker-implementer  gpt-5.6-luna  401.2k tokens  completed
  worker        worker-implementer  gpt-5.6-luna   68.4k tokens  completed
  attributed    668.8k tokens  1.840 credits
  account quota 5h 31%→34% (+3 pp); 7d 18%→19% (+1 pp)
```

Two measurements are deliberately kept separate:

- **Attributed usage** comes from the Parent/Worker threads. If the server cannot expose thread billing for a thread, the field remains unavailable rather than being estimated.
- **Account quota change during run** is account-wide. Concurrent Codex sessions can also move the same quota window, so that delta is never presented as exclusive consumption by this flow.

Telemetry is fail-open. Missing app-server capabilities or usage fields never fail the task; only those statistics become unavailable.

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

## Daily management

```bash
codex-flow status
codex-flow doctor
codex-flow usage last
codex-flow usage last --json
codex-flow update
codex-flow benchmark-local quick
codex-flow uninstall
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
source = "hooks+app-server"
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

The local authenticated Codex session is the primary real-benchmark path. No API key is required when your local Codex CLI is already authenticated through ChatGPT or another supported local login method.

```bash
codex-flow update
codex-flow benchmark-local quick
```

The command checks git/Python/Codex, materializes the frozen quick corpus, validates 18 planned runs with a dry-run, shows a quota/token warning, requires the exact confirmation `RUN QUICK 18`, executes the real benchmark, fails fast on zero-usage infrastructure/authentication failures, analyzes the results, and renders a Markdown report.

By default it writes timestamped files under `benchmark/results/`:

```text
quick-<timestamp>.jsonl
quick-<timestamp>.analysis.json
quick-<timestamp>.report.md
quick-<timestamp>.meta.json
```

For the first quick run, budget roughly up to ~5M total tokens as a conservative planning ceiling. Actual use can be much lower or higher depending on tool loops and repair attempts.

### Cost semantics

When the benchmark is run through a ChatGPT/Codex subscription, dollar figures are **API-equivalent reference costs only**. They provide a normalized comparison using the pinned API price snapshot and are not the actual amount charged against the ChatGPT subscription.

Primary measurements are pass rate, repair cycles, input/cached/output tokens, total token efficiency, wall time, and API-equivalent reference cost.

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

The analyzer applies quality gates before comparing reference cost. Benchmark conclusions remain advisory; `policy/benchmark.toml` keeps `auto_apply = false`.

## Optional API-key GitHub Actions benchmark

`.github/workflows/benchmark-quick.yml` remains available as an optional headless execution path for users with an OpenAI API key. It is manual `workflow_dispatch` only, requires `OPENAI_API_KEY` plus the exact confirmation `RUN QUICK 18`, exposes only the quick profile, and uploads result artifacts. Normal CI never invokes it.

## Automatic model recommendations

`scripts/check-recommendation.py` and `.github/workflows/model-recommendation.yml` conservatively inspect OpenAI official model documentation and maintain release recommendations through reviewable PRs. The active parent remains policy-driven; worker `auto` recommendations change only through release defaults and explicit user updates.

## Measurement boundaries

Benchmarking and normal FlowPilot telemetry use separate measurement paths. Benchmarks keep their reproducible JSONL experiment contract. Interactive telemetry prefers app-server thread usage and rate-limit snapshots. Fields the server does not expose remain unavailable; subscription quota is never inferred from token counts.

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
CODEX_FLOW_BIN_DIR                default: ~/.local/bin
CODEX_FLOW_SHELL                  default: basename of SHELL (Bash/zsh auto-configured)
CODEX_FLOW_SHELL_CONFIG_DIR       default: HOME
```

## CI

Normal CI never invokes a paid model. It validates shell/Python/PowerShell syntax, model recommendation fixtures, benchmark analysis/reporting, runner isolation/repair/token aggregation and infrastructure fail-fast behavior, deterministic corpus generation, FlowPilot routing-override installation, deterministic telemetry fixtures and hook lifecycle management, and Unix/Windows installer/update flows.

## Status

Private preview, version `0.9.0`. FlowPilot is the default orchestration skill. Per-task `direct`, `delegate`, and `adaptive` overrides remain explicit and non-persistent. Normal-task telemetry is enabled by default and adds no model inference. Model recommendation changes remain reviewable; benchmark routing remains advisory; real benchmark execution remains explicit; explicit user pins remain authoritative.
