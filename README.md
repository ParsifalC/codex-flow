# codex-flow

Fast, low-friction cost-aware multi-agent defaults for Codex.

**Use a qualifying high-capability model to plan and review. Use a cheaper worker for execution loops.**

`codex-flow` is intentionally capability-driven rather than tied to a specific flagship model slug.

## Default strategy

```text
small task         -> parent handles directly
medium/large task  -> qualifying parent plans
                    -> cheaper worker explores / implements / tests
                    -> qualifying parent reviews
                    -> worker performs bounded fixes if needed
                    -> parent gives final acceptance
```

A parent qualifies by policy, not by name. The default is:

- prefer the latest available high-capability model
- minimum parent reasoning effort: `high`
- `high`, `xhigh`, and `max` all qualify
- exact minimum model: `auto` by default, but configurable
- worker model and reasoning effort are independently configurable

So `gpt-5.6-sol/xhigh` is one valid configuration, not a requirement.

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

Restart Codex after installation, then use it normally. No special prompt is required.

```text
Refactor the renew workflow and keep backward compatibility.
```

You can also invoke the workflow explicitly:

```text
Use $cost-aware-development and refactor the renew workflow.
```

## Policy

Installation creates `~/.codex/codex-flow.toml`:

```toml
[parent]
model_policy = "latest-capable"
min_model = "auto"
min_reasoning_effort = "high"

[worker]
model = "gpt-5.6-luna"
reasoning_effort = "high"

[runtime]
max_concurrent_threads = 4
```

The parent model is never hard-pinned by codex-flow. `latest-capable` means the workflow should prefer the current recommended high-capability generation when Codex exposes a stable way to select/elevate it. If automatic elevation is unavailable, the configured minimum remains the guardrail rather than silently pretending an underpowered parent qualifies.

The worker currently defaults to Luna because it is the cost-oriented GPT-5.6 tier, but that is an installation default, not part of the architecture.

## Configure at install time

macOS/Linux example:

```bash
CODEX_FLOW_PARENT_MIN_EFFORT=high \
CODEX_FLOW_PARENT_MIN_MODEL=auto \
CODEX_FLOW_WORKER_MODEL=gpt-5.6-luna \
CODEX_FLOW_WORKER_EFFORT=high \
bash install.sh
```

Available overrides:

```text
CODEX_FLOW_PARENT_MODEL_POLICY   default: latest-capable
CODEX_FLOW_PARENT_MIN_MODEL      default: auto
CODEX_FLOW_PARENT_MIN_EFFORT     default: high
CODEX_FLOW_WORKER_MODEL          default: gpt-5.6-luna
CODEX_FLOW_WORKER_EFFORT         default: high
CODEX_FLOW_MAX_THREADS           default: 4
```

This lets teams pin a minimum family/version when required, while normal installations can keep the parent policy future-facing.

## Reasoning policy

Reasoning is treated as a minimum plus a task-adaptive choice, not one fixed value:

```text
parent planning/review          >= high
routine worker execution          high
difficult debugging/refactor      xhigh
hardest quality-first work         max
```

`max` is deliberately not the universal default. The workflow should use the lowest qualifying level that gives enough reliability for the task.

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

The installer backs up an existing `config.toml` before changing the managed `[agents]` keys.

## Verify

```bash
bash scripts/doctor
```

The doctor verifies the installed policy and checks that Codex subagent routing matches it.

## Uninstall

```bash
bash scripts/uninstall
```

The uninstall script removes files owned by codex-flow and leaves unrelated Codex configuration alone.

## Compatibility strategy

Codex multi-agent behavior is evolving, so codex-flow uses three layers:

1. `codex-flow.toml` expresses model/effort policy separately from implementation details.
2. `[agents]` provides a concrete default worker route for the installed Codex version.
3. Generic custom agents and the orchestration Skill provide richer explorer/implementer behavior where supported.

This separation lets the current concrete model change without rewriting the workflow itself.

## Design principles

- High-capability tokens are spent at decision gates, not implementation loops.
- Model eligibility is expressed as a capability/effort threshold rather than one hardcoded flagship slug.
- Prefer the latest suitable generation when it can be selected reliably.
- Children receive compact task packets instead of irrelevant parent history when supported.
- Review checks the diff and evidence instead of re-solving the task.
- Read-only exploration may run in parallel; overlapping writable workers should not.
- Repair loops are bounded.

## Status

Early private preview. Codex model routing and multi-agent APIs are changing quickly, so policy separation, `doctor`, and compatibility fallbacks are first-class parts of the project.
