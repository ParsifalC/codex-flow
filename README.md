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

### Windows PowerShell

```powershell
.\install.ps1
```

Restart Codex, then use it normally. No special prompt is required.

```text
Refactor the renew workflow and keep backward compatibility.
```

Explicit invocation is also available:

```text
Use $cost-aware-development and refactor the renew workflow.
```

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
```

Teams can therefore pin a minimum generation/model when reproducibility matters, while normal installations stay future-facing.

## What gets installed

```text
~/.codex/
├── config.toml
├── codex-flow.toml
├── agents/
│   ├── worker-explorer.toml
│   └── worker-implementer.toml
└── skills/
    └── cost-aware-development/
        └── SKILL.md
```

Repository policy data lives in:

```text
policy/defaults.toml
```

The installer backs up an existing `config.toml` before changing codex-flow-managed `[agents]` keys.

## Verify

```bash
bash scripts/doctor
```

`doctor` checks the installed Skill/roles, policy schema, minimum effort guarantees, resolved worker model, and the actual Codex subagent baseline.

## Uninstall

```bash
bash scripts/uninstall
```

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
- Children receive compact task packets instead of irrelevant parent history.
- Parent review checks diff + evidence instead of reimplementing.
- Read-only exploration may run in parallel; overlapping writable workers should not.
- Repair loops are bounded; repeated failure triggers reassessment/escalation.

## Status

Private preview. Current Codex source exposes default subagent model/reasoning configuration and role layers, while some App/V2 releases still have model/effort override and custom-role regressions. codex-flow therefore favors adaptive behavior with a reliable baseline rather than assuming every runtime supports perfect dynamic routing.
