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

The management command is installed under `~/.local/bin`. Restart Codex after installation, then use Codex normally; no special prompt is required.

## Daily management

```bash
codex-flow status
codex-flow doctor
codex-flow update
codex-flow benchmark-corpus quick
codex-flow benchmark --help
codex-flow benchmark-analyze --help
codex-flow uninstall
```

`update` fast-forwards the original checkout, preserves explicit user pins, reruns installation, and resolves only `auto` values against the new release recommendations.

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

`model = "auto"` follows release recommendations; a concrete model remains pinned across updates. The concrete Codex `[agents]` baseline stays conservative because per-spawn model/effort overrides are not equally reliable across all Codex App/V2 versions.

## Reasoning selection

The workflow chooses the lowest sufficient qualifying effort:

| Task class | Parent | Worker |
| --- | --- | --- |
| SMALL | `high` or current qualifying effort | none |
| ROUTINE | `high` | `high` |
| COMPLEX | `high`/`xhigh` | `high`/`xhigh` |
| CRITICAL | `xhigh`/`max` | `xhigh`/`max` only when quality-first |

`max` is never the universal default. Complexity, risk, or failed lower-effort attempts must justify escalation.

## Automatic model recommendations

`scripts/check-recommendation.py` and `.github/workflows/model-recommendation.yml` conservatively inspect OpenAI official model documentation and maintain release recommendations through reviewable PRs.

The automation discovers the newest qualifying Sol/Terra/Luna generation, verifies `high`, `xhigh`, and `max` reasoning plus modern agent tooling, records the latest qualifying flagship only as `parent_recommended_model` metadata, and chooses the lowest-cost qualifying Terra/Luna worker recommendation. It fails closed when parsing/capability verification is incomplete and never overwrites an installed user's explicit pin.

The active parent remains policy-driven; recommendation metadata never hard-pins it.

## Built-in benchmark corpus

The deterministic six-task corpus calibrates routing from measured engineering outcomes rather than price alone. It covers localized bug fixing, configuration precedence, multi-file compatibility refactoring, configuration migration, bounded retry semantics, and crash-safe state persistence.

Generate it without calling any model:

```bash
codex-flow benchmark-corpus quick
```

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

Materialization never invokes a model. Every task gets a deterministic seed commit and an external verifier outside the writable task repository. The full profile can consume substantial tokens and is never launched automatically.

## Run and analyze locally

```bash
codex-flow benchmark \
  --manifest .codex-flow-benchmark/manifest.json \
  --output benchmark/results/quick-001.jsonl
```

Every model/effort/repetition starts from a fresh clone at the same commit. Failed verification can trigger bounded repairs using the same model/effort. Token usage is accumulated across the first attempt and repairs, so the measured unit is **cost to finish the task**, not first-call price.

Analyze with the bundled immutable GPT-5.6 price snapshot:

```bash
codex-flow benchmark-analyze \
  --results benchmark/results/quick-001.jsonl \
  --prices benchmark/prices/gpt-5.6-2026-08-30.json \
  --json
```

The analyzer applies quality gates before cost comparison. A cheaper configuration that misses pass-rate or repair thresholds cannot win. Benchmark conclusions remain advisory; `policy/benchmark.toml` keeps `auto_apply = false`.

## Guarded paid benchmark on GitHub Actions

v0.7 adds `.github/workflows/benchmark-quick.yml` for the first real 18-run data collection without turning paid benchmarking into an automatic CI behavior.

The workflow is **manual `workflow_dispatch` only**. It has no `push`, `pull_request`, or schedule trigger. Before any Codex model execution it requires:

```text
Repository secret: OPENAI_API_KEY
Confirmation:      RUN QUICK 18
```

It exposes only the quick profile; the 90-run full profile is deliberately not available as an Actions button. The Codex npm version can be pinned per run, and both requested and actual CLI versions are stored with the artifact.

The runner uses `--fail-fast-infrastructure`: a non-zero Codex exit with zero reported usage (for example authentication/CLI/model availability failure) stops the remaining batch instead of repeating the same infrastructure error 18 times.

At the end of the job, available files are uploaded as a 30-day artifact, including raw JSONL, manifest, immutable prices, analysis JSON, readable Markdown report, Codex CLI version, and codex-flow commit. Partial/failing runs keep the evidence generated before failure.

The Markdown report includes overall pass rate, infrastructure failures, repairs, token totals, estimated cost, per-model/effort results, and advisory task-class routing. If results exist, the same report is rendered into the GitHub Actions job summary.

Full setup and safety notes: `docs/benchmark-actions.md`.

## Measurement boundaries

Current Codex JSONL reports input/cached/output usage but not a reliably separate reasoning-token field, and does not reliably expose the provider-returned model identifier. Results therefore record the requested model/effort and the accounting fields Codex actually emits.

The GitHub workflow authenticates through `OPENAI_API_KEY`; it does not commit credentials or synthesize an interactive login. Benchmark results record the Codex CLI version because harness changes are another experimental variable.

Full benchmark methodology: `docs/benchmark.md`.

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

## Compatibility model

codex-flow deliberately uses several layers rather than depending on one unstable runtime feature:

1. `codex-flow.toml` — model/effort policy.
2. `policy/defaults.toml` — release-time `auto` recommendations.
3. Codex `[agents]` — stable worker fallback.
4. Skill + generic worker roles — classification, delegation, adaptive escalation, review, bounded repairs.
5. Recommendation automation — official-source model/price maintenance through PRs.
6. Benchmark corpus + runner + analyzer — advisory evidence for routing calibration.
7. Guarded manual Actions workflow — reproducible quick data collection without automatic paid execution.

## CI

Normal CI never invokes a paid model. It validates shell/Python/PowerShell syntax, deterministic model recommendation fixtures, quality-first benchmark analysis, report rendering, runner isolation/repair/token aggregation and infrastructure fail-fast behavior, deterministic corpus generation and seed verifier failure, Unix install/update flows, and Windows install/status/doctor/uninstall behavior.

## Status

Private preview, version 0.7.0. Model recommendation changes remain reviewable; benchmark routing remains advisory; paid benchmark execution is always explicit; installed users change behavior only through explicit update/install actions and explicit pins remain authoritative.
