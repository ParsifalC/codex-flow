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

A parent qualifies by policy, not by name. The defaults prefer the latest available high-capability model, require parent reasoning `>= high`, keep the exact model floor configurable, and choose the worker independently. `gpt-5.6-sol/xhigh` is therefore a valid example, not a requirement.

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

The automation:

- discovers the newest qualifying Sol/Terra/Luna generation
- verifies `high`, `xhigh`, and `max` reasoning plus modern agent tooling
- records the latest qualifying flagship only as `parent_recommended_model` metadata
- chooses the lowest-cost qualifying Terra/Luna worker recommendation
- changes nothing when parsing/capability verification is incomplete
- never overwrites an installed user's explicit model pin

The active parent remains policy-driven; recommendation metadata never hard-pins it.

## Real benchmark runner

v0.5 adds a real, reproducible Codex runner so routing can eventually be calibrated from measured task outcomes instead of price alone.

Create a manifest based on `benchmark/manifest.example.json`, using a frozen repository and preferably a full 40-character commit SHA:

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
    "prompt":"Implement the fixed task without modifying the verifier.",
    "verify":["python3","tests/verify_task.py"]
  }]
}
```

Run the matrix:

```bash
codex-flow benchmark \
  --manifest benchmark-real.json \
  --output benchmark/results/run-001.jsonl
```

Every model/effort/repetition starts from a fresh temporary clone at the same commit. After the first implementation, a fixed verifier runs; failures may trigger bounded repair attempts with the same model/effort. Input, cached-input, and output usage are accumulated across the initial attempt and repairs, so the measured unit is **cost to finish the task**, not cost of the first call.

Then analyze it with an immutable price snapshot:

```bash
codex-flow benchmark-analyze \
  --results benchmark/results/run-001.jsonl \
  --prices benchmark-prices.json \
  --json
```

The analyzer applies quality gates first and compares dollar cost only among configurations that meet the required pass rate, sample count, and repair-cycle threshold. Benchmark conclusions are advisory only; `policy/benchmark.toml` keeps `auto_apply = false`.

Current measurement boundaries are explicit: Codex JSONL reports input/cached/output usage but not a reliably separate reasoning-token field, and it does not reliably expose the provider-returned model identifier. Results therefore record the requested model/effort and the accounting fields Codex actually emits. The runner also uses wall-clock timeout plus repair limits because deterministic agent-turn budgeting is not yet a stable `codex exec` capability.

Full details: `docs/benchmark.md`.

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

## What gets installed

```text
~/.codex/
├── config.toml
├── codex-flow.toml
├── codex-flow/
│   ├── source
│   └── version
├── agents/
│   ├── worker-explorer.toml
│   └── worker-implementer.toml
└── skills/
    └── cost-aware-development/
        └── SKILL.md

~/.local/bin/
└── codex-flow            # Unix
# or codex-flow.cmd/.ps1   # Windows
```

## Compatibility model

codex-flow deliberately uses several layers rather than depending on one unstable runtime feature:

1. `codex-flow.toml` — model/effort policy.
2. `policy/defaults.toml` — release-time `auto` recommendations.
3. Codex `[agents]` — stable worker fallback.
4. Skill + generic worker roles — classification, delegation, adaptive escalation, review, bounded repairs.
5. Benchmark runner/analyzer — advisory evidence for future routing calibration.

## CI

The repository validates shell/Python/PowerShell syntax, deterministic model recommendation fixtures, benchmark analyzer quality-first routing, benchmark runner isolation/repair/token aggregation with a fake Codex executable, Unix install/update flows, and Windows install/status/doctor/uninstall smoke behavior.

## Status

Private preview, version 0.5.0. Model recommendation changes remain reviewable; benchmark routing remains advisory; installed users change behavior only through explicit update/install actions and explicit pins remain authoritative.
