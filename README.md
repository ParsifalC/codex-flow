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

A parent qualifies by policy, not by name:

- prefer the latest available high-capability model
- minimum parent reasoning effort: `high`
- `high`, `xhigh`, and `max` qualify
- exact model floor: `auto` by default, configurable when a team needs a fixed minimum
- worker model selection is independent and defaults to the current cost-efficient recommendation

So `gpt-5.6-sol/xhigh` is a valid example, not a requirement.

## Install

### macOS / Linux

```bash
git clone git@github.com:ParsifalC/codex-flow.git
cd codex-flow
bash install.sh
```

The management command is installed to `~/.local/bin/codex-flow` by default. If that directory is already on `PATH`, the command works immediately. Otherwise add it to `PATH` once.

### Windows PowerShell

```powershell
git clone git@github.com:ParsifalC/codex-flow.git
cd codex-flow
.\install.ps1
```

The Windows command wrapper is installed under `~/.local/bin`. Add that directory to the user `PATH` once if it is not already present.

Restart Codex after installation, then use Codex normally. No special prompt is required.

```text
Refactor the renew workflow and keep backward compatibility.
```

Explicit invocation is also available:

```text
Use $cost-aware-development and refactor the renew workflow.
```

## Daily management

After installation:

```bash
codex-flow status
codex-flow doctor
codex-flow update
codex-flow uninstall
```

`status` shows the installed release, source checkout, parent policy, resolved worker model, and minimum reasoning levels.

`update` performs a fast-forward `git pull` in the original checkout, preserves explicit user policy values, reruns the installer, then validates the result. Values left as `auto` are intentionally resolved again against the new release recommendations.

That means a future model-generation update can move the default worker recommendation without overwriting a team that explicitly pinned its worker model or effort.

Because this repository is private, updates intentionally reuse the original git checkout and the user's normal GitHub authentication instead of embedding credentials or private download URLs.

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

`model = "auto"` is intentionally different from a hardcoded architecture dependency. At install/update time it resolves through `policy/defaults.toml` to the current codex-flow recommendation. When the model generation changes, the recommendation can move without changing the workflow or agent roles.

The concrete worker baseline is written into Codex `[agents]` because current Codex App/V2 builds do not expose perfectly reliable per-spawn model/effort overrides across all versions. The Skill requests higher effort dynamically where supported; otherwise the installed `high` baseline remains the safe fallback.

## Effort selection

The workflow chooses the **lowest sufficient qualifying effort**:

| Task class | Parent | Worker |
| --- | --- | --- |
| SMALL | `high` or current qualifying effort | none |
| ROUTINE | `high` | `high` |
| COMPLEX | `high`/`xhigh` | `high`/`xhigh` |
| CRITICAL | `xhigh`/`max` | `xhigh`/`max` only when quality-first |

`max` is never the universal default. Actual complexity, risk, or failed lower-effort attempts must justify escalation.

## Configure at install time

```bash
CODEX_FLOW_PARENT_MIN_EFFORT=high \
CODEX_FLOW_PARENT_MIN_MODEL=auto \
CODEX_FLOW_WORKER_MODEL=auto \
CODEX_FLOW_WORKER_MIN_EFFORT=high \
bash install.sh
```

Useful overrides:

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

Teams can therefore pin a minimum generation/model when reproducibility matters, while normal installations stay future-facing.

## Automatic model recommendations

`codex-flow` includes a conservative recommendation bot in `scripts/check-recommendation.py` and `.github/workflows/model-recommendation.yml`.

The scheduled workflow reads only OpenAI's official model documentation. It discovers the newest Sol/Terra/Luna family, verifies that candidate models support `high`, `xhigh`, and `max` reasoning plus modern agent tooling, reads official token prices, and then:

- records the newest qualifying Sol model as `parent_recommended_model` metadata
- chooses the lowest-cost qualifying Terra/Luna model as the release worker recommendation
- changes nothing if parsing or capability verification is incomplete
- opens or refreshes a PR only when `policy/defaults.toml` would actually change

The worker cost ranking uses a transparent heuristic (`70% input price + 30% output price`) only to compare qualifying worker tiers. It is not presented as a user's exact bill estimate.

The parent recommendation is deliberately **metadata only**. It does not set the active parent model and does not weaken the policy rule that any qualifying high-capability parent with reasoning `>= high` may own planning/review.

The worker recommendation affects only installations with:

```toml
[worker]
model = "auto"
```

Explicit model pins remain authoritative across `codex-flow update`.

For deterministic CI, recommendation logic is tested against `tests/fixtures/models.json`; live OpenAI documentation is contacted only by the scheduled/manual recommendation workflow.

Current official GPT-5.6 guidance identifies Sol as flagship, Terra as balanced, and Luna as cost-sensitive/high-volume, with all three supporting `high`, `xhigh`, and `max`. The release recommendation therefore remains Luna until official data indicates a newer qualifying lower-cost worker.

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

Repository policy data lives in:

```text
policy/defaults.toml
```

The installer backs up an existing `config.toml` before changing codex-flow-managed `[agents]` keys.

## Compatibility model

Codex multi-agent behavior is still evolving, so codex-flow uses four layers:

1. `codex-flow.toml` — model/effort policy, independent of historical model slugs.
2. `policy/defaults.toml` — current release-time model recommendations used by `auto`.
3. Codex `[agents]` — a stable high-effort, cost-efficient worker fallback.
4. Skill + generic worker roles — task classification, compact delegation, adaptive escalation, evidence-based review, and bounded repair.

This deliberately avoids depending on one unstable runtime feature for correctness.

## Design principles

- High-capability tokens are spent at decision gates, not implementation loops.
- Parent eligibility is a capability + minimum-effort threshold.
- Prefer the latest suitable generation without permanently encoding its slug into workflow semantics.
- `high` is the normal floor; `xhigh/max` are earned by complexity or evidence.
- `auto` follows release recommendations; explicit pins survive updates.
- Recommendation automation fails closed and changes policy only through reviewable PRs.
- Children receive compact task packets instead of irrelevant parent history.
- Parent review checks diff + evidence instead of reimplementing.
- Read-only exploration may run in parallel; overlapping writable workers should not.
- Repair loops are bounded; repeated failure triggers reassessment/escalation.

## CI

The repository validates:

- shell/Python syntax for Unix installer, CLI, scripts, and recommendation checker
- deterministic recommendation selection against offline fixtures
- Unix install -> status/doctor -> override -> uninstall smoke flow
- PowerShell syntax plus Windows install/status/doctor/uninstall smoke flow

## Status

Private preview. Recommendation updates are automatic only for release defaults and only through a reviewable PR. Installed users change behavior only when they run `codex-flow update`; explicit pins remain authoritative.
